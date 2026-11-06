#if SCENE_QA
import Foundation
import CryptoKit
import Darwin

/// QA companion only: invokes the same controller actions as the visible
/// sample/import and generate buttons. No weights, model inference or templates
/// are substituted for a user's scene. The fixture is explicitly Codex-authored.
@MainActor enum SceneStudioDeviceProbe {
    static let previewState = ModelPreviewLoadState()
    static func run(model: SceneStudioModel) async {
        let folder = URL.documentsDirectory.appending(path: "SceneStudioQA/" + UUID().uuidString)
        let began = Date()
        var report: [String: Any] = ["sourceAuthor": "Codex-authored bundled test scene",
            "onDeviceLanguageModelInference": false, "normalAppDataChanged": false,
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown"]
        do {
            guard Bundle.main.bundleIdentifier == "com.kaisun.voxamber.scene-qa" else {
                throw SceneStudioError.message("仅允许在独立验收 App 中运行。")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.newProject()
            if ProcessInfo.processInfo.arguments.contains("--qa-shared-inbox") {
                guard let resource = Bundle.main.url(forResource: "RobotScene", withExtension: "js") else {
                    throw SceneStudioError.message("缺少验收场景")
                }
                let inbox = try SceneImportInbox.openShared()
                let bytes = try Data(contentsOf: resource)
                let item = try await inbox.store(bytes: bytes, originalFilename: "shared-robot.js")
                let listing = try await inbox.list()
                guard listing.pending.contains(where: { $0.id == item.id }) else {
                    throw SceneStudioError.message("系统共享目录未返回新导入项")
                }
                model.title = "系统共享目录 · 原生验收"
                model.acceptShared(item)
                await model.waitForCurrentOperation()
                let after = try await inbox.list()
                guard !after.pending.contains(where: { $0.id == item.id }), Data(model.source.utf8) == bytes else {
                    throw SceneStudioError.message("共享导入或确认未完成")
                }
                report["productionSharedInboxToControllerPassed"] = true
                report["sourceBytesPreservedAcrossAppGroup"] = true
                report["systemShareSheetProviderUIExercised"] = false
            } else if ProcessInfo.processInfo.arguments.contains("--qa-palace") {
                report["sourceAuthor"] = "Original Codex-session palace PoC with host-precomputed geometry"
                model.title = "琉金重檐殿 · 官方原生验收"
                model.importFile(URL.documentsDirectory.appending(path: "QAImports/palace.js"))
            } else { model.importExample() }
            await model.waitForCurrentOperation()
            try Task.checkCancellation()
            guard model.errorMessage == nil, !model.source.isEmpty else {
                throw SceneStudioError.message(model.errorMessage ?? "示例导入失败")
            }
            let imported = Date().timeIntervalSince(began)
            model.generateAndSave()
            await model.waitForCurrentOperation()
            try Task.checkCancellation()
            guard let project = model.selected, project.committed, model.errorMessage == nil else {
                throw SceneStudioError.message(model.errorMessage ?? "生成或保存没有返回已提交作品")
            }
            let generated = Date().timeIntervalSince(began)
            let glb = try Data(contentsOf: project.glbURL), usdz = try Data(contentsOf: project.usdzURL)
            guard digest(glb) == project.glbSHA256, digest(usdz) == project.usdzSHA256,
                  digest(Data(model.source.utf8)) == project.sourceSHA256 else {
                throw SceneStudioError.message("回读文件校验失败")
            }
            try glb.write(to: folder.appending(path: "model.glb"), options: .withoutOverwriting)
            try usdz.write(to: folder.appending(path: "model.usdz"), options: .withoutOverwriting)
            try Data(model.source.utf8).write(to: folder.appending(path: "source.js"), options: .withoutOverwriting)
            report.merge(["controllerSourceImportPassed": true, "controllerGenerateAndSavePassed": true,
                "importSeconds": imported, "generateSaveAndReadbackSeconds": generated,
                "projectID": project.id.uuidString, "revision": project.revision.uuidString,
                "sourceSHA256": project.sourceSHA256, "glbSHA256": project.glbSHA256,
                "usdzSHA256": project.usdzSHA256, "glbBytes": glb.count, "usdzBytes": usdz.count,
                "sdkVersion": project.compilerVersion, "sdkRevision": project.compilerRevision,
                "modelBusyAfterAwait": model.busy, "availableProcessBytesAfter": os_proc_available_memory()], uniquingKeysWith: { _, new in new })
            let previewLimit = Date().addingTimeInterval(8)
            while previewState.phase != .ready && previewState.phase != .failed && Date() < previewLimit {
                try await Task.sleep(for: .milliseconds(100))
            }
            report["productionViewportPhase"] = String(describing: previewState.phase)
            report["productionViewportError"] = previewState.errorMessage ?? ""
            report["productionViewportEntityAttached"] = previewState.entity?.scene != nil
            do {
                let png = try await ProjectThumbnailService.shared.thumbnail(for: .init(projectID: project.id,
                    revision: project.revision, fileDigest: project.usdzSHA256, fileURL: project.usdzURL))
                try png.write(to: folder.appending(path: "thumbnail.png"), options: .withoutOverwriting)
                report["productionQuickLookThumbnailReturned"] = true
                report["thumbnailBytes"] = png.count; report["thumbnailSHA256"] = digest(png)
            } catch {
                report["productionQuickLookThumbnailReturned"] = false
                report["thumbnailError"] = String(reflecting: error)
            }
            report["status"] = "native-generation-saved-pending-visual-review"
            report["visualAcceptance"] = "pending-human-and-image-review"
        } catch { report["status"] = "failed"; report["error"] = String(reflecting: error) }
        report["totalSeconds"] = Date().timeIntervalSince(began)
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appending(path: "report.json"), options: .atomic)
        } catch { model.errorMessage = "验收记录写入失败：" + error.localizedDescription }
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
