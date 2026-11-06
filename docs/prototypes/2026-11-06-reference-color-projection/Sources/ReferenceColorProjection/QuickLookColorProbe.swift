import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import QuickLookThumbnailing

/// An isolated compatibility observation, never an inference result or an icon.
@MainActor enum QuickLookColorProbe {
    static func run(url: URL, output: URL,sourceKind:String="synthetic-three-vertex-triangle") async throws {
        guard !FileManager.default.fileExists(atPath:output.path) else {throw CocoaError(.fileWriteFileExists)}
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let source=try Data(contentsOf:url),start=Date()
        var report:[String:Any]=["inputUSDZSHA256":fileSHA(source),"sourceKind":sourceKind,
            "attemptCount":1,"usesSystemFileIconAsSuccess":false,"phoneTest":false,
            "productRealityKitCompatibilityEstablished":false]
        do {
            let data=try await ThumbnailOperation.render(url:url)
            try data.write(to:output.appendingPathComponent("quicklook.png"),options:.withoutOverwriting)
            let raster=try ReferenceRaster(png:data)
            let count=stride(from:0,to:raster.rgba.count,by:4).filter { offset in
                let rgb=raster.rgba[offset..<(offset+3)]
                return Int(rgb.max()!)-Int(rgb.min()!)>25 && raster.rgba[offset+3]>128
            }.count
            report["thumbnailReturned"]=true;report["actualRepresentationType"]="thumbnail"
            report["chromaticPixels"]=count;report["chromaticColorObserved"]=count>500
            let opaque=stride(from:0,to:raster.rgba.count,by:4).filter{raster.rgba[$0+3]>128}.count
            report["opaquePixels"]=opaque;report["nonChromaticOpaquePixels"]=opaque-count
            report["PNGWidth"]=raster.width;report["PNGHeight"]=raster.height;report["PNGSHA256"]=fileSHA(data)
        } catch {
            let ns=error as NSError
            report["thumbnailReturned"]=false;report["chromaticColorObserved"]=false
            report["errorDomain"]=ns.domain;report["errorCode"]=ns.code
        }
        guard try Data(contentsOf:url)==source else {throw CocoaError(.fileReadCorruptFile)}
        report["seconds"]=Date().timeIntervalSince(start)
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("quicklook-result.json"),options:.withoutOverwriting)
        print("Native QuickLook small-asset observation completed: \(report)")
    }
}

@MainActor private final class ThumbnailOperation {
    let request: QLThumbnailGenerator.Request
    var continuation: CheckedContinuation<Data,Error>?
    var finished=false
    init(url: URL) {
        request=QLThumbnailGenerator.Request(fileAt:url,size:CGSize(width:256,height:256),scale:1,representationTypes:.thumbnail)
        request.contentType=UTType(filenameExtension:"usdz");request.iconMode=false
    }
    static func render(url: URL) async throws -> Data {
        let operation=ThumbnailOperation(url:url)
        let timeout=Task {do {try await Task.sleep(for:.seconds(20));operation.finish(.failure(CocoaError(.userCancelled)),cancel:true)}catch{}}
        defer {timeout.cancel()}
        return try await withCheckedThrowingContinuation {operation.start($0)}
    }
    func start(_ continuation: CheckedContinuation<Data,Error>) {
        self.continuation=continuation
        QLThumbnailGenerator.shared.generateBestRepresentation(for:request) { [weak self] result,error in
            let data=result?.type == .thumbnail ? result.flatMap{Self.png($0.cgImage)} : nil
            let raw=error as NSError?
            let failure=NSError(domain:raw?.domain ?? "QuickLookColorProbe.noThumbnail",code:raw?.code ?? -1)
            Task { @MainActor [weak self] in
                if let data {self?.finish(.success(data),cancel:false)}
                else {self?.finish(.failure(failure),cancel:false)}
            }
        }
    }
    func finish(_ result: Result<Data,Error>,cancel: Bool) {
        guard !finished else {return};finished=true
        if cancel {QLThumbnailGenerator.shared.cancel(request)}
        let pending=continuation;continuation=nil;pending?.resume(with:result)
    }
    nonisolated static func png(_ image: CGImage) -> Data? {
        let data=NSMutableData()
        guard let writer=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {return nil}
        CGImageDestinationAddImage(writer,image,nil)
        guard CGImageDestinationFinalize(writer) else {return nil}
        return data as Data
    }
}
