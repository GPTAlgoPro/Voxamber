import Foundation
import Observation
import QwenNative

@MainActor @Observable
final class ModelManager {
    nonisolated static let modelName = "千问 Qwen3.5 · 4B INT4"
    nonisolated static let modelID = "qwen3.5-4b-mlx-int4"
    let engine: QwenEngine
    private(set) var installed = false
    private(set) var loaded = false
    private var operationBusy = false
    private(set) var isUnloading = false
    private(set) var busy: Bool {
        get { operationBusy || isUnloading }
        set { operationBusy = newValue }
    }
    private(set) var progress: Double = 0
    private(set) var status = "尚未安装"
    var errorMessage: String?
    @ObservationIgnored private let resourceStore = VerifiedModelStore(root: URL.documentsDirectory.appending(path: "Models"))
    @ObservationIgnored private let appleSource = AppleHostedModelSource()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private let unloadRuntime: @Sendable () async -> Void

    init(unloadRuntime: (@Sendable () async -> Void)? = nil) {
        let engine = QwenEngine()
        self.engine = engine
        self.unloadRuntime = unloadRuntime ?? { await engine.unload() }
    }

    var eligible: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        ProcessInfo.processInfo.physicalMemory >= 11 * 1024 * 1024 * 1024
        #endif
    }

    func checkInstallation() async {
        guard !busy else { return }
        busy = true; status = "正在检查本机模型"
        defer { busy = false }
        do {
            directory = try await resourceStore.verifyInstalled(manifest: try Self.manifest())
            installed = true; status = "已就绪 · 可离线使用"
        } catch VerifiedModelStoreError.notInstalled { installed = false; status = "尚未安装" }
        catch { installed = false; status = "模型不完整，请重新安装" }
    }

    func download() { install(from: nil) }
    func importModel(_ url: URL) { install(from: url) }
    func cancelDownload() { operation?.cancel() }

    private func install(from source: URL?) {
        guard eligible, !busy else { return }
        busy = true; progress = 0; errorMessage = nil
        status = source == nil ? "正在从 Apple 下载模型素材" : "正在导入并校验"
        let update: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in self?.progress = value }
        }
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let manifest = try Self.manifest()
                await unload()
                if let source {
                    directory = try await resourceStore.importDirectory(source, manifest: manifest, progress: update)
                } else {
                    let managed = try await appleSource.download(progress: { value in update(value * 0.75) })
                    status = "正在校验并安装 Apple 素材"
                    directory = try await resourceStore.importDirectory(managed, manifest: manifest,
                        progress: { value in update(0.75 + value * 0.25) })
                    // Retain the verified private model, then release the redundant managed copy.
                    try? await appleSource.removeManagedCopy()
                }
                installed = true; progress = 1; status = "已就绪 · 可离线使用"
            } catch is CancellationError { status = installed ? "已就绪 · 新安装已取消" : "已取消，重试可复用已完成文件" }
            catch let error as URLError where error.code == .cancelled { status = "已取消，重试可复用已完成文件" }
            catch { status = installed ? "已就绪 · 新安装未完成" : "安装未完成"; errorMessage = error.localizedDescription }
        }
    }

    func prepare() async throws {
        guard eligible else { throw StudioError.message("本机 AI 需要 12GB 或以上内存设备。你仍可用预设和参数创作。") }
        guard !busy else { throw StudioError.message("模型正在处理，请稍候。") }
        guard installed, let directory else { throw StudioError.message("请先在“本机模型”安装模型。首次下载后可离线使用。") }
        if !loaded {
            status = "正在载入模型"
            do { try await engine.load(modelDirectory: directory); loaded = true; status = "已载入 · 离线运行" }
            catch { status = "载入失败"; throw error }
        }
    }

    func unload() async {
        if let unloadTask { await unloadTask.value; return }
        // A prepare must never mistake a model being released for a hot model.
        loaded = false
        isUnloading = true
        let task = Task {
            await unloadRuntime()
            // Every joining caller observes final state before this task ends.
            unloadTask = nil
            isUnloading = false
            if installed { status = "已就绪 · 可离线使用" }
        }
        unloadTask = task
        await task.value
    }

    func remove() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await unload()
        do { try await resourceStore.remove(id: Self.modelID); installed = false; directory = nil; status = "尚未安装" }
        catch { errorMessage = error.localizedDescription }
    }

    private static func manifest() throws -> LocalModelManifest {
        guard let url = Bundle.main.url(forResource: "LanguageModel", withExtension: "json") else {
            throw StudioError.message("App 中缺少模型资源清单，请重新安装 App。")
        }
        return try JSONDecoder().decode(LocalModelManifest.self, from: Data(contentsOf: url))
    }
}
