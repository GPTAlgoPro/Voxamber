import BackgroundAssets
import Foundation
import StoreKit
import System

enum AppleHostedModelSourceError: LocalizedError, Sendable {
    case busy
    case configurationMissing
    case testFlightRequired
    case invalidManagedLayout
    case serviceUnavailable
    case cancellationCleanupFailed

    var errorDescription: String? {
        let english=Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
        switch self {
        case .busy:
            return english ? "A model download or cleanup is still in progress. Please wait." : "模型下载或清理仍在进行，请稍候。"
        case .configurationMissing:
            return english ? "This installation is missing Apple model-download configuration. Update Voxamber in TestFlight." : "此安装缺少 Apple 模型下载配置，请更新维珀的 TestFlight 版本。"
        case .testFlightRequired:
            return english ? "Apple-hosted models require the Voxamber TestFlight or App Store installation and an Apple Account with access to it." : "Apple 托管模型需要安装维珀的 TestFlight 或 App Store 版本，并使用具有访问资格的 Apple 账户。"
        case .invalidManagedLayout:
            return english ? "Apple's downloaded model files are incomplete or cannot be imported safely. Update Voxamber and retry." : "Apple 下载的模型文件不完整或无法安全导入，请更新维珀后重试。"
        case .serviceUnavailable:
            return english ? "The Apple-hosted model is temporarily unavailable. Check your connection and TestFlight access, then retry." : "Apple 托管模型暂不可用，请检查网络和 TestFlight 资格后重试。"
        case .cancellationCleanupFailed:
            return english ? "Download cancellation could not finish cleanup. Retry to clear the previous transfer before starting again." : "下载取消尚未完成清理；重试会先清理旧任务，再开始下载。"
        }
    }
}

/// Owns this one Apple-hosted pack. Its caller imports the returned directory
/// through VerifiedModelStore before optionally removing the managed copy.
actor AppleHostedModelSource {
    static let packID="Voxamber-Qwen35-4B-INT4"
    static let modelID="qwen3.5-4b-mlx-int4"
    static let appGroupID="group.com.kaisun.voxamber.background-assets"
    static let appBundleID="com.kaisun.voxamber"
    static let downloaderBundleID="com.kaisun.voxamber.model-downloader"
    private static let extensionPoint="com.apple.background-asset-downloader-extension"
    private static let fileNames=["chat_template.jinja","config.json","model.safetensors",
        "model.safetensors.index.json","preprocessor_config.json","processor_config.json",
        "tokenizer.json","tokenizer_config.json","video_preprocessor_config.json","vocab.json"]

    private var activeID:UUID?
    private var cancellingID:UUID?
    private var transferStarted=false
    private var removal:Task<Void,Error>?
    private var cleanupRequired=false

    var busy:Bool { activeID != nil }

    func download(progress:@escaping @Sendable (Double)->Void) async throws->URL {
        try Task.checkCancellation()
        let id=try beginOperation()
        defer { finishOperation(id) }
        try Self.validateConfiguration()
        try await Self.requireStoreInstallation()
        try Task.checkCancellation()
        // Never construct this singleton until all bundle/entitlement guards
        // have passed. The SDK traps for malformed managed-asset app bundles.
        let manager=AssetPackManager.shared

        return try await withTaskCancellationHandler {
            do {
                if cleanupRequired { try await clearManagedPack(id:id,manager:manager) }
                try Task.checkCancellation()
                let pack=try await Self.currentPack(using:manager)
                try Task.checkCancellation()
                transferStarted=true
                progress(0)
                let directory=try await withThrowingTaskGroup(of:Void.self,returning:URL.self) { group in
                    // This observer cannot outlive the download scope.
                    group.addTask {
                        for await update in manager.statusUpdates(forAssetPackWithID:Self.packID) {
                            guard !Task.isCancelled,await self.isActiveID(id) else { return }
                            switch update {
                            case .began: progress(0)
                            case .downloading(_,let value):
                                let fraction=value.fractionCompleted
                                progress(fraction.isFinite ? min(1,max(0,fraction)) : 0)
                            case .finished: progress(1);return
                            case .failed: return // ensureLocalAvailability supplies the actual failure.
                            case .paused: break
                            @unknown default: break
                            }
                        }
                    }
                    defer { group.cancelAll() }
                    if #available(iOS 26.4,macOS 26.4,*) {
                        try await manager.ensureLocalAvailability(of:pack,requireLatestVersion:true)
                    } else {
                        try await manager.ensureLocalAvailability(of:pack)
                        let status=try await manager.status(ofAssetPackWithID:Self.packID)
                        guard status.contains(.upToDate) else { throw AppleHostedModelSourceError.serviceUnavailable }
                    }
                    try Task.checkCancellation()
                    return try Self.managedModelDirectory(using:manager)
                }
                try Task.checkCancellation()
                guard isActiveID(id) else { throw CancellationError() }
                progress(1)
                return directory
            } catch {
                if Task.isCancelled || error is CancellationError || cancellingID == id {
                    cancellingID=id
                    if transferStarted || cleanupRequired || removal != nil {
                        do { try await clearManagedPack(id:id,manager:manager) }
                        catch { throw AppleHostedModelSourceError.cancellationCleanupFailed }
                    }
                    throw CancellationError()
                }
                if let error=error as? AppleHostedModelSourceError { throw error }
                throw AppleHostedModelSourceError.serviceUnavailable
            }
        } onCancel: {
            // A synchronous cancellation handler can only request an actor
            // hop. The UUID prevents a delayed hop from cancelling a retry.
            Task { await self.requestCancellation(id:id,manager:manager) }
        }
    }

    /// Call only after private, atomic import succeeds. This never touches
    /// the private VerifiedModelStore or any other downloaded asset pack.
    func removeManagedCopy() async throws {
        let id=try beginOperation()
        defer { finishOperation(id) }
        try Self.validateConfiguration()
        let manager=AssetPackManager.shared
        cleanupRequired=true
        do { try await clearManagedPack(id:id,manager:manager) }
        catch { throw AppleHostedModelSourceError.cancellationCleanupFailed }
    }

    private func beginOperation() throws->UUID {
        guard activeID == nil else { throw AppleHostedModelSourceError.busy }
        let id=UUID();activeID=id;cancellingID=nil;transferStarted=false;removal=nil
        return id
    }

    private func finishOperation(_ id:UUID) {
        guard activeID == id else { return }
        activeID=nil;cancellingID=nil;transferStarted=false;removal=nil
        // cleanupRequired survives failures; a retry clears the old pack
        // before it is allowed to start another system download.
    }

    private func isActiveID(_ id:UUID)->Bool { activeID == id && cancellingID != id }

    private func requestCancellation(id:UUID,manager:AssetPackManager) async {
        guard activeID == id else { return }
        cancellingID=id
        guard transferStarted || cleanupRequired else { return }
        try? await clearManagedPack(id:id,manager:manager)
        // Only the owning download finishes/releases its slot, after it has
        // also awaited this same cleanup task.
    }

    private func clearManagedPack(id:UUID,manager:AssetPackManager) async throws {
        guard activeID == id else { return }
        cleanupRequired=true
        let task:Task<Void,Error>
        if let removal { task=removal }
        else {
            // An owned, awaited task deliberately does not inherit the
            // cancelled caller's flag, so SDK removal can actually execute.
            let created=Task<Void,Error> {
                do { try await manager.remove(assetPackWithID:Self.packID) }
                catch let error as ManagedBackgroundAssetsError {
                    if case .assetPackNotFound(let missingID)=error,missingID == Self.packID { return }
                    throw error
                }
            }
            removal=created;task=created
        }
        try await task.value
        if activeID == id { cleanupRequired=false }
    }

    private nonisolated static func validateConfiguration() throws {
        #if targetEnvironment(simulator)
        throw AppleHostedModelSourceError.testFlightRequired
        #else
        let bundle=Bundle.main
        guard bundle.bundleIdentifier == appBundleID,
              bundle.object(forInfoDictionaryKey:"BAHasManagedAssetPacks") as? Bool == true,
              bundle.object(forInfoDictionaryKey:"BAUsesAppleHosting") as? Bool == true,
              bundle.object(forInfoDictionaryKey:"BAAppGroupID") as? String == appGroupID,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:appGroupID) != nil,
              hasDownloaderExtension(in:bundle.bundleURL) else {
            throw AppleHostedModelSourceError.configurationMissing
        }
        #endif
    }

    private nonisolated static func hasDownloaderExtension(in appURL:URL)->Bool {
        let directory=appURL.appendingPathComponent("Extensions",isDirectory:true)
        guard let entries=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) else { return false }
        return entries.contains { url in
            guard url.pathExtension == "appex",let bundle=Bundle(url:url),
                  bundle.bundleIdentifier == downloaderBundleID,
                  bundle.object(forInfoDictionaryKey:"BAAppGroupID") as? String == appGroupID,
                  let attributes=bundle.object(forInfoDictionaryKey:"EXAppExtensionAttributes") as? [String:Any] else { return false }
            return attributes["EXExtensionPointIdentifier"] as? String == extensionPoint
        }
    }

    private nonisolated static func requireStoreInstallation() async throws {
        do {
            guard case .verified(let transaction)=try await AppTransaction.shared,
                  // TestFlight uses the sandbox, where Apple documents
                  // appID as nil. Verify the signed bundle and environment.
                  transaction.bundleID == appBundleID,
                  transaction.environment == .sandbox || transaction.environment == .production else {
                throw AppleHostedModelSourceError.testFlightRequired
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw AppleHostedModelSourceError.testFlightRequired
        }
    }

    private nonisolated static func currentPack(using manager:AssetPackManager) async throws->AssetPack {
        if #available(iOS 27,macOS 27,*) {
            let manifest=try await manager.manifest
            guard let pack=manifest.assetPack(withID:packID) else { throw AppleHostedModelSourceError.serviceUnavailable }
            return pack
        } else { return try await manager.assetPack(withID:packID) }
    }

    private nonisolated static func managedModelDirectory(using manager:AssetPackManager) throws->URL {
        let prefix="models/"+modelID+"/"
        let config=try manager.url(for:FilePath(prefix+"config.json"))
        let directory=config.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        for name in fileNames {
            let url=try manager.url(for:FilePath(prefix+name)).resolvingSymlinksInPath().standardizedFileURL
            guard url == directory.appendingPathComponent(name).standardizedFileURL,
                  FileManager.default.isReadableFile(atPath:url.path),
                  (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true else {
                throw AppleHostedModelSourceError.invalidManagedLayout
            }
        }
        return directory
    }
}
