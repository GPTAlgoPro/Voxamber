import SwiftUI
import UIKit
import CryptoKit
import Foundation
import RealityKit

/// QApp-only manual graphics checks. Never starts a model or accesses the normal
/// App container. Root adds the unchanged production viewport/thumbnail sources.
@MainActor struct PhoneNativePreviewPanel:View {
    var isGenerationBusy=false
    init(isGenerationBusy:Bool=false){self.isGenerationBusy=isGenerationBusy}
    @State private var selected:MeasuredModel?
    @State private var presented:MeasuredModel?
    @State private var request:ThumbnailRequest?
    @State private var activeToken:UUID?
    @State private var thumbnail:UIImage?
    @State private var status="请刷新最近的完整链实测模型。"
    @State private var rendering=false
    @State private var cancelling=false
    @State private var previewState=ModelPreviewLoadState()
    @State private var previewReceipt:[String:String]=[:]
    @Environment(\.scenePhase) private var scenePhase

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("真实模型预览与缩略图").font(.headline)
            if let selected {
                Text(selected.directoryName).font(.caption).textSelection(.enabled)
                Text(ByteCountFormatter.string(fromByteCount:selected.bytes,countStyle:.file)).font(.caption).foregroundStyle(.secondary)
            }
            Button("刷新最近实测模型"){refresh()}.disabled(isGenerationBusy || rendering)
            HStack {
                Button("打开真实三维预览"){presented=selected}.disabled(selected==nil || isGenerationBusy || rendering)
                Button("生成真实缩略图") {
                    guard let selected else{return}
                    thumbnail=nil;status="正在请求生产 Quick Look 缩略图…"
                    request=ThumbnailRequest(model:selected,token:UUID())
                }.disabled(selected==nil || isGenerationBusy || rendering)
            }
            if rendering {
                ProgressView(cancelling ? "正在取消缩略图请求…" : "正在生成缩略图…")
                Button("取消缩略图") {cancelling=true;request=nil}
                    .disabled(cancelling)
            }
            if let thumbnail {
                Image(uiImage:thumbnail).resizable().scaledToFit().frame(maxHeight:240)
                    .accessibilityLabel("从真实USDZ生成的Quick Look缩略图")
            }
            Text(status).font(.caption).textSelection(.enabled)
        }
        .task {
            refresh()
            if automaticallyPreview,let selected {
                request=ThumbnailRequest(model:selected,token:UUID())
            }
        }
        .task(id:request) {
            guard let request else{return}
            await render(request)
        }
        .onChange(of:isGenerationBusy){_,busy in if busy{request=nil;presented=nil}}
        .onChange(of:scenePhase){_,phase in if phase == .background{request=nil;presented=nil}}
        .onDisappear{request=nil}
        .sheet(item:$presented){model in
            NavigationStack {
                ModelViewport(url:model.url,loadState:previewState)
                    .navigationTitle("真实实测模型")
                    .toolbar {ToolbarItem(placement:.confirmationAction){Button("完成"){presented=nil}}}
            }
        }
        .task(id:previewState.phase) {
            guard previewState.phase != .idle else{return}
            if previewState.phase == .ready {
                do {try await Task.sleep(for:.seconds(1))}catch{return}
            }
            guard !Task.isCancelled else{return}
            previewReceipt["viewportPhase"]=String(describing:previewState.phase)
            previewReceipt["entityAttachedToScene"]=String(previewState.entity?.scene != nil)
            previewReceipt["viewportError"]=previewState.errorMessage ?? ""
            persistReceipt()
        }
    }

    private struct MeasuredModel:Identifiable,Hashable {
        let url:URL
        let directoryName:String
        let bytes:Int64
        let modified:Date
        var id:String{url.absoluteString}
    }
    private struct ThumbnailRequest:Hashable {let model:MeasuredModel;let token:UUID}
    private struct ThumbnailResult:Sendable {let png:Data;let sourceSHA:String}

    private func refresh() {
        guard !isGenerationBusy,!rendering else{return}
        do {
            let root=URL.documentsDirectory.appending(path:"Measurements",directoryHint:.isDirectory)
                .standardizedFileURL.resolvingSymlinksInPath()
            let directories=try FileManager.default.contentsOfDirectory(at:root,
                includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])
            var models:[MeasuredModel]=[]
            for directory in directories where directory.lastPathComponent.hasPrefix("full-native-") {
                let folder=try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard folder.isDirectory==true,folder.isSymbolicLink != true else{continue}
                let fileName=materialControl ? "material-control.usdz" : "model.usdz"
                let file=directory.appending(path:fileName).standardizedFileURL
                guard let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]),
                      values.isRegularFile==true,values.isSymbolicLink != true,let bytes=values.fileSize,bytes>0,
                      file.resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else{continue}
                models.append(.init(url:file,directoryName:directory.lastPathComponent,bytes:Int64(bytes),modified:values.contentModificationDate ?? .distantPast))
            }
            let latest=models.sorted{a,b in a.modified==b.modified ? a.directoryName>b.directoryName : a.modified>b.modified}.first
            if latest != selected{thumbnail=nil;previewReceipt=[:];previewState=ModelPreviewLoadState()}
            selected=latest
            status=latest==nil ? "尚未找到完整链实测 model.usdz；不会用旧基线或图片替代。" : "仅在点击按钮后打开模型或请求真实缩略图。"
        }catch{selected=nil;thumbnail=nil;status="读取实测目录失败：\(error.localizedDescription)"}
    }

    private func render(_ value:ThumbnailRequest)async {
        guard !isGenerationBusy,!Task.isCancelled else{return}
        activeToken=value.token;rendering=true;cancelling=false
        defer {
            if activeToken==value.token{activeToken=nil;rendering=false;cancelling=false}
        }
        // The SwiftUI task owns this child and awaits it on success, failure or
        // cancellation; handlers never create a fire-and-forget worker.
        let owned=Task{try await Self.actualThumbnail(value)}
        do {
            let result=try await withTaskCancellationHandler {try await owned.value} onCancel:{owned.cancel()}
            try Task.checkCancellation()
            guard request?.token==value.token,selected?.url==value.model.url,
                  let image=UIImage(data:result.png) else{return}
            thumbnail=image;status="真实 Quick Look 缩略图已返回（\(result.png.count) bytes）。USDZ SHA256：\(result.sourceSHA)"
            do {
                try result.png.write(to:value.model.url.deletingLastPathComponent().appending(path:materialControl ? "phone-material-control-thumbnail.png" : "phone-actual-quicklook-thumbnail.png"),options:.atomic)
                previewReceipt["thumbnailStatus"]="returned-production-quicklook-thumbnail"
                previewReceipt["sourceUSDZSHA256"]=result.sourceSHA
                previewReceipt["thumbnailSHA256"]=SHA256.hash(data:result.png).map{String(format:"%02x",$0)}.joined()
                previewReceipt["thumbnailBytes"]=String(result.png.count)
            }catch{previewReceipt["thumbnailEvidenceWriteError"]=error.localizedDescription}
            persistReceipt()
            if automaticallyPreview{presented=value.model}
        }catch {
            guard activeToken==value.token else{return}
            if Task.isCancelled || error is CancellationError {
                thumbnail=nil;status="缩略图请求已取消；可再次点击重试。"
            }else {
                let ns=error as NSError
                thumbnail=nil;status="生产缩略图失败：\(String(reflecting:error))\n\(ns.domain) / \(ns.code) · \(error.localizedDescription)"
                previewReceipt["thumbnailStatus"]="failed"
                previewReceipt["thumbnailError"]=String(reflecting:error)
                persistReceipt()
                if automaticallyPreview{presented=value.model}
            }
        }
    }

    private func persistReceipt() {
        guard let selected else{return}
        previewReceipt["modelDirectory"]=selected.directoryName
        previewReceipt["modelFile"]=selected.url.lastPathComponent
        previewReceipt["explicitNeutralMaterialControl"]=String(materialControl)
        previewReceipt["normalAppDataChanged"]="false"
        previewReceipt["visualAppearanceAcceptance"]="pending-human-observation"
        do {
            let data=try JSONSerialization.data(withJSONObject:previewReceipt,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:selected.url.deletingLastPathComponent().appending(path:materialControl ? "phone-material-control-preview-receipt.json" : "phone-production-preview-receipt.json"),options:.atomic)
        }catch{status += "\n验收记录写入失败：\(error.localizedDescription)"}
    }

    private var materialControl:Bool{ProcessInfo.processInfo.arguments.contains("--qa-native-preview-material-control")}
    private var automaticallyPreview:Bool{materialControl || ProcessInfo.processInfo.arguments.contains("--qa-native-preview")}

    private static func actualThumbnail(_ request:ThumbnailRequest)async throws->ThumbnailResult {
        try Task.checkCancellation()
        let file=try FileHandle(forReadingFrom:request.model.url);defer{try? file.close()}
        var digest=SHA256()
        while let data=try file.read(upToCount:1_048_576),!data.isEmpty {
            try Task.checkCancellation();digest.update(data:data);await Task.yield()
        }
        let sha=digest.finalize().map{String(format:"%02x",$0)}.joined()
        let source=ProjectThumbnailSource(projectID:UUID(),revision:request.token,fileDigest:sha,fileURL:request.model.url)
        let png=try await ProjectThumbnailService.shared.thumbnail(for:source)
        try Task.checkCancellation()
        return .init(png:png,sourceSHA:sha)
    }
}

/// QApp-only label adapter. Normal App already owns its declaration and does
/// not compile this ShapeDeviceQA folder.
enum StudioCopy {
    static func text(_ chinese:String,_ english:String)->String{chinese}
}
