import Foundation
import Observation
import VoxamberCreationNative

struct NeuralGroupState: Identifiable, Sendable {
    let group: NeuralModelGroup
    let name: String
    let byteCount: Int64
    let downloadAvailable: Bool
    var installed: Bool = false
    var error: String?
    var id: NeuralModelGroup { group }
}

/// Resource preparation only. No model is loaded by this controller. Readiness
/// is the conjunction of three complete SHA-verified private installations.
@MainActor @Observable
final class NeuralModelManager {
    private(set) var ready = false
    private(set) var busy = false
    private(set) var stage = "尚未检查新模型"
    private(set) var progress: Double = 0
    private(set) var resources: CreationResources?
    private(set) var groups: [NeuralGroupState] = []
    var errorMessage: String?
    @ObservationIgnored private let store: NeuralAssetStore?
    @ObservationIgnored private let catalogs: [NeuralModelGroup: NeuralModelManifest]
    @ObservationIgnored private let sources: [NeuralModelGroup: NeuralAppleHostedModelSource]
    @ObservationIgnored private let beforeResourceMutation: @Sendable () async -> Void
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var activeGroup: NeuralModelGroup?

    init(beforeResourceMutation: @escaping @Sendable () async -> Void = {},
         root: URL = URL.documentsDirectory.appending(path: "NeuralModels", directoryHint: .isDirectory),
         manifests: [NeuralModelManifest]? = nil, bundle: Bundle = .main) {
        self.beforeResourceMutation = beforeResourceMutation
        do {
            let loaded = try manifests ?? NeuralModelManifest.loadAll(bundle: bundle)
            store = try NeuralAssetStore(root: root, manifests: loaded)
            catalogs = Dictionary(uniqueKeysWithValues: loaded.map { ($0.group, $0) })
            sources = Dictionary(uniqueKeysWithValues: loaded.map { ($0.group, NeuralAppleHostedModelSource(catalog: $0)) })
            groups = NeuralModelGroup.allCases.compactMap { group in
                guard let manifest = catalogs[group] else { return nil }
                return NeuralGroupState(group: group, name: manifest.displayName,
                                        byteCount: manifest.byteCount, downloadAvailable: manifest.apple.available)
            }
        } catch {
            store = nil; catalogs = [:]; sources = [:]
            errorMessage = error.localizedDescription; stage = "资源清单不可用"
        }
    }

    func downloadAvailable(group: NeuralModelGroup) -> Bool { catalogs[group]?.apple.available == true }

    /// Awaitable installation check, with the same owned cancellation slot as imports.
    func checkInstallation() async {
        guard !busy, let store else { return }
        let id = begin(group: nil, stage: "正在逐文件校验三组模型")
        let task = Task { [self] in
            defer { finish(id) }
            do { apply(try await store.checkInstallation(), id: id) }
            catch { fail(error, id: id) }
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func importModel(group: NeuralModelGroup, from directory: URL) {
        var roots = NeuralImportRoots()
        switch group { case .intent: roots.intent = directory; case .image: roots.image = directory; case .shape: roots.shape = directory }
        importRoots(roots)
    }

    /// Each URL is the actual model directory, not its containing archive/root.
    /// Shape directory contains model.q4.safetensors and config.yaml.
    func importRoots(_ roots: NeuralImportRoots) {
        let requested = NeuralModelGroup.allCases.filter { roots[$0] != nil }
        guard !busy, !requested.isEmpty, let store else { return }
        let id = begin(group: requested.count == 1 ? requested.first : nil, stage: "正在准备导入新模型")
        operation = Task { [self] in
            defer { finish(id) }
            do {
                await beforeResourceMutation()
                try Task.checkCancellation()
                for (index, group) in requested.enumerated() {
                    guard let directory = roots[group] else { continue }
                    activeGroup = group
                    stage = "正在导入并校验 · " + (catalogs[group]?.displayName ?? group.rawValue)
                    _ = try await store.importGroup(group, from: directory, progress: progressUpdate(id: id) {
                        (Double(index) + $0) / Double(requested.count)
                    })
                }
                stage = "正在确认三组模型完整性"
                apply(try await store.checkInstallation(), id: id)
            } catch { fail(error, id: id) }
        }
    }

    func download(group: NeuralModelGroup) {
        guard !busy, let store, let source = sources[group] else { return }
        // A missing new pack is explicit; do not initialize Apple's singleton,
        // start a legacy 4B download, or silently fall back to public HTTP.
        guard downloadAvailable(group: group) else {
            errorMessage = NeuralModelError.notPublished.localizedDescription
            stage = "Apple 新资源尚未发布"
            return
        }
        let id = begin(group: group, stage: "正在从 Apple 下载 · " + (catalogs[group]?.displayName ?? group.rawValue))
        operation = Task { [self] in
            defer { finish(id) }
            do {
                await beforeResourceMutation()
                try Task.checkCancellation()
                let directory = try await source.download(progress: progressUpdate(id: id) { $0 * 0.75 })
                stage = "正在校验并安装 Apple 新资源"
                let update = progressUpdate(id: id) { 0.75 + $0 * 0.25 }
                _ = try await NeuralManagedImport.perform {
                    try await store.importGroup(group, from: directory, progress: update)
                } removeManaged: {
                    try await source.removeManagedCopy()
                }
                apply(try await store.checkInstallation(), id: id)
            } catch { fail(error, id: id) }
        }
    }

    /// A different group's cancel cannot stop the active operation. Waiting for
    /// operation completion includes private-copy and Apple cleanup settlement.
    func cancel(group: NeuralModelGroup? = nil) {
        guard busy, group == nil || group == activeGroup else { return }
        stage = "正在停止资源准备"; operation?.cancel()
    }
    func waitForCurrentOperation() async { await operation?.value }

    private func begin(group: NeuralModelGroup?, stage: String) -> UUID {
        let id = UUID(); activeID = id; activeGroup = group; busy = true
        ready = false; resources = nil; progress = 0; errorMessage = nil; self.stage = stage
        return id
    }
    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        busy = false; operation = nil; activeID = nil; activeGroup = nil
    }
    private func apply(_ result: NeuralStoreCheck, id: UUID) {
        guard activeID == id, !Task.isCancelled else { return }
        for index in groups.indices {
            groups[index].installed = result.directories[groups[index].group] != nil
            groups[index].error = result.errors[groups[index].group]
        }
        if result.ready, let intent = result.directories[.intent], let image = result.directories[.image],
           let shape = result.directories[.shape] {
            resources = CreationResources(intentModelDirectory: intent, imageModelDirectory: image,
                                          shapeModelFile: shape.appending(path: "model.q4.safetensors"))
            ready = true; stage = "三组模型已校验 · 可离线使用"; progress = 1
        } else {
            ready = false; resources = nil; stage = "新模型尚未全部安装 · \(result.directories.count)/3"
            progress = Double(result.directories.count) / 3
        }
    }
    private func fail(_ error: Error, id: UUID) {
        guard activeID == id else { return }
        ready = false; resources = nil
        if error is NeuralManagedImportError {
            stage = "模型已保留 · Apple 副本清理未完成"
            errorMessage = error.localizedDescription
        } else if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            stage = "已取消 · 已校验文件可在重试时复用"
        } else { stage = "新模型准备未完成"; errorMessage = error.localizedDescription }
    }
    private func progressUpdate(id: UUID, transform: @escaping @Sendable (Double) -> Double) -> @Sendable (Double) -> Void {
        { [weak self] value in
            let fraction = value.isFinite ? min(1, max(0, value)) : 0
            let mapped = transform(fraction)
            Task { @MainActor [weak self] in
                guard let self, self.activeID == id, self.operation?.isCancelled != true else { return }
                self.progress = min(1, max(0, mapped))
            }
        }
    }
}
