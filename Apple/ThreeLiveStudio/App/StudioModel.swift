import Foundation
import UIKit
import Observation
import CreationCore
import ThreeLiveNative

enum StudioTab: Hashable { case create, library, models }
enum GenerationStopReason: String, Sendable { case user, background, memoryPressure }

@MainActor @Observable
final class StudioModel {
    var tab = StudioTab.create
    var sceneSpec: SceneSpec? = StudioModel.blankScene
    var prompt = ""
    var assets: ProjectAssets?
    var projects: [CreationProject] = []
    private var operationBusy = false
    private(set) var isCleaningUp = false
    var busy: Bool {
        get { operationBusy || isCleaningUp }
        set { operationBusy = newValue }
    }
    var stage = ""
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    var notice: String?
    var showParameters = false
    private(set) var stopReason: GenerationStopReason?
    private(set) var lastStopLatency: Double?
    let models: ModelManager
    @ObservationIgnored let store: ProjectStore
    @ObservationIgnored private let backgroundTasks: BackgroundTaskClient
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var stopRequestedAt: ContinuousClock.Instant?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupID: UUID?
    @ObservationIgnored private var cleanupOperation: Task<Void, Never>?
    @ObservationIgnored private var backgroundLease: BackgroundTaskLease?

    init(models: ModelManager = ModelManager(), store: ProjectStore = ProjectStore(),
         backgroundTasks: BackgroundTaskClient = .system) {
        self.models = models
        self.store = store
        self.backgroundTasks = backgroundTasks
    }

    static var blankScene: SceneSpec {
        SceneSpec(name: StudioCopy.text("自由造型", "Untitled creation"), nodes: [SceneNode(id: "form", primitive: .sphere,
            position: [0,0.25,0], size: [0.5,0.5,0.5], color: "#59D4C3", metallic: 0.25, roughness: 0.35)])
    }

    var hasUnbuiltChanges: Bool { assets?.project.specification != sceneSpec }
    var canExport: Bool { assets != nil && !hasUnbuiltChanges && !busy }

    func start() async {
        #if DEVICE_QA
        if ProcessInfo.processInfo.arguments.contains("--qa-inference") {
            UIApplication.shared.isIdleTimerDisabled = true
            let id = UUID()
            operationID = id
            let task = Task { await DeviceAcceptanceProbe.run(studio: self) }
            work = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            finishOperation(id: id)
            await models.checkInstallation()
            return
        }
        #endif
        if let draft = await store.loadDraft() { sceneSpec = draft.spec; prompt = draft.prompt }
        await refreshLibrary()
        await models.checkInstallation()
    }

    func refreshLibrary() async {
        do { projects = try await store.list() }
        catch { errorMessage = error.localizedDescription }
    }

    func selectScenePreset(_ preset: SceneSpec) {
        guard !busy else { return }
        sceneSpec = preset; assets = nil; notice = nil
        prompt = "创建\(preset.name)，保持它的结构和材质。"
        persistDraft()
    }

    func newCreation() {
        guard !busy else { return }
        assets = nil; sceneSpec = Self.blankScene; prompt = ""; tab = .create; notice = nil
    }

    func generate(usingAI: Bool) {
        guard !busy else { return }
        if usingAI && !models.installed { tab = .models; return }
        busy = true; errorMessage = nil; notice = nil; elapsed = 0; stopReason = nil; lastStopLatency = nil; stopRequestedAt = nil
        let id = UUID()
        operationID = id
        let start = Date()
        let initialScene = sceneSpec ?? .chair
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = assets?.project
        timer = Task {
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        work = Task {
            defer { finishOperation(id: id) }
            do {
                draftTask?.cancel()
                try await store.saveDraft(spec: initialScene, prompt: request)
                var proposedScene = initialScene
                var timings: [String: Double] = [:]
                if usingAI {
                    guard !request.isEmpty else { throw StudioError.message("写下你想创建或修改的物体。") }
                    stage = "正在唤醒本机 AI"
                    try await models.prepare()
                    try Task.checkCancellation()
                    let began = Date()
                    stage = "正在理解你的构想"
                    let response = try await models.engine.generateJSON(
                        systemPrompt: ScenePrompt.system,
                        prompt: try ScenePrompt.userRequest(request, currentSpec: previous == nil ? nil : initialScene),
                        maxTokens: 3072, onProgress: { _ in })
                    try Task.checkCancellation()
                    proposedScene = try SceneSpec.decodeModelResponse(response)
                    timings["interpretation"] = Date().timeIntervalSince(began)
                }
                stage = "正在构造三维几何"
                let geometryStart = Date()
                let finalScene = proposedScene
                let geometryTask = Task.detached(priority: .userInitiated) {
                    try SceneGenerator.generate(for: finalScene)
                }
                let meshes = try await withTaskCancellationHandler { try await geometryTask.value } onCancel: { geometryTask.cancel() }
                timings["geometry"] = Date().timeIntervalSince(geometryStart)
                try Task.checkCancellation()
                stage = "正在生成模型文件"
                let exportStart = Date()
                let exportTask = Task.detached(priority: .userInitiated) {
                    let glb = try ThreeLiveNative.exportGLB(meshes)
                    try Task.checkCancellation()
                    let usdz = try ThreeLiveNative.exportUSDZ(meshes)
                    return (glb, usdz)
                }
                let (glb, usdz) = try await withTaskCancellationHandler { try await exportTask.value } onCancel: { exportTask.cancel() }
                timings["export"] = Date().timeIntervalSince(exportStart)
                try Task.checkCancellation()
                stage = "正在安全保存作品"
                let result = try await store.publish(spec: proposedScene, prompt: request, glb: glb, usdz: usdz, replacing: previous)
                assets = result; sceneSpec = proposedScene
                elapsed = Date().timeIntervalSince(start)
                timings["total"] = elapsed
                await saveMeasurement(timings, ai: usingAI, project: result.project)
                await refreshLibrary()
                notice = "已保存到作品库"
                stage = "已完成"
            } catch is CancellationError {
                stage = isCleaningUp ? "正在停止" : "已取消"
                switch stopReason {
                case .background: notice = "离开 App 后已停止生成，之前的作品已保留。"
                case .memoryPressure: notice = "设备内存紧张，本次生成已停止，之前的作品已保留。"
                default: notice = "已取消，之前保存的作品仍在。"
                }
            }
            catch { stage = "未完成"; errorMessage = error.localizedDescription }
        }
    }

    func cancel(reason: GenerationStopReason = .user) {
        guard busy, let operation = work, !operation.isCancelled else { return }
        stopReason = reason
        stopRequestedAt = .now
        operation.cancel()
        stage = "正在停止"
    }

    private func finishOperation(id: UUID) {
        guard operationID == id else { return }
        work = nil
        operationID = nil
        operationBusy = false
        guard !isCleaningUp else { return }
        stopTimer()
        recordStopLatency()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func recordStopLatency() {
        guard !busy else { return }
        guard let requested = stopRequestedAt else { return }
        let duration = requested.duration(to: .now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        lastStopLatency = seconds
        stopRequestedAt = nil
        let receipt: [String: Any] = ["schemaVersion": 1, "reason": stopReason?.rawValue ?? "unknown",
            "secondsToIdle": seconds, "busy": busy, "hasOwnedTask": work != nil, "terminalStage": stage,
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
        let url = URL.documentsDirectory.appending(path: "Measurements/last-stop.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { /* Local timing diagnostics do not change the stopped state. */ }
    }

    func handleMemoryPressure() {
        requestCleanup(reason: .memoryPressure, needsBackgroundLease: false)
    }

    func open(_ project: CreationProject) async {
        guard !busy else { return }
        do {
            let result = try await store.load(project)
            assets = result; sceneSpec = project.specification; prompt = project.prompt; tab = .create; notice = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ project: CreationProject) async {
        guard !busy else { return }
        do {
            try await store.remove(project)
            if assets?.project.id == project.id { assets = nil }
            await refreshLibrary()
        } catch { errorMessage = error.localizedDescription }
    }

    func persistDraft() {
        draftTask?.cancel()
        let value = sceneSpec ?? Self.blankScene, text = prompt
        draftTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await store.saveDraft(spec: value, prompt: text)
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }

    func enterBackground() {
        requestCleanup(reason: .background, needsBackgroundLease: true)
        draftTask?.cancel()
        let value = sceneSpec ?? Self.blankScene, text = prompt
        Task { try? await store.saveDraft(spec: value, prompt: text) }
    }

    private func requestCleanup(reason: GenerationStopReason, needsBackgroundLease: Bool) {
        if let id = cleanupID {
            if needsBackgroundLease { acquireBackgroundLease(for: id) }
            return
        }
        // Close admission synchronously, before cancelling or awaiting work.
        // finishOperation may clear its own task, but cannot reopen this gate.
        isCleaningUp = true
        let id = UUID()
        cleanupID = id
        let pending = work
        cleanupOperation = pending
        cancel(reason: reason)
        if needsBackgroundLease { acquireBackgroundLease(for: id) }
        cleanupTask = Task {
            await pending?.value
            await models.unload()
            finishCleanup(id: id)
        }
    }

    private func acquireBackgroundLease(for id: UUID) {
        guard cleanupID == id, backgroundLease == nil else { return }
        let pending = cleanupOperation
        backgroundLease = BackgroundTaskLease(client: backgroundTasks) { pending?.cancel() }
    }

    private func finishCleanup(id: UUID) {
        guard cleanupID == id else { return }
        backgroundLease?.end()
        backgroundLease = nil
        cleanupOperation = nil
        cleanupTask = nil
        cleanupID = nil
        isCleaningUp = false
        if stage == "正在停止", stopReason != nil { stage = "已取消" }
        guard work == nil else { return }
        stopTimer()
        recordStopLatency()
    }

    private func saveMeasurement(_ timings: [String: Double], ai: Bool, project: CreationProject) async {
        let record = RunMeasurement(project: project.id, revision: project.revision, createdAt: Date(),
            model: ai ? ModelManager.modelName : "manual", os: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemory: ProcessInfo.processInfo.physicalMemory, thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            timings: timings)
        let url = URL.documentsDirectory.appending(path: "Measurements", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url.appending(path: project.revision.uuidString + ".json"), options: .atomic)
        } catch { /* Measurements must never invalidate an already-published user project. */ }
    }
}

/// Platform effects are injected so lifecycle tests drive the production
/// admission/cleanup path without requiring an expiring UIKit assertion.
@MainActor
struct BackgroundTaskClient {
    var begin: (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    var end: (UIBackgroundTaskIdentifier) -> Void

    static var system: Self {
        Self(begin: { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "Stop on-device generation", expirationHandler: expiration)
        }, end: { UIApplication.shared.endBackgroundTask($0) })
    }
}

@MainActor
final class BackgroundTaskLease {
    private let client: BackgroundTaskClient
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var hasEnded = false

    init(client: BackgroundTaskClient, onExpiration: @escaping @MainActor @Sendable () -> Void) {
        self.client = client
        let identifier = client.begin { [weak self] in
            onExpiration()
            self?.end()
        }
        self.identifier = identifier
        // An unavailable assertion may expire during begin itself.
        if hasEnded, identifier != .invalid {
            client.end(identifier)
            self.identifier = .invalid
        }
    }

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        let identifier = self.identifier
        self.identifier = .invalid
        if identifier != .invalid { client.end(identifier) }
    }
}

private struct RunMeasurement: Codable {
    let project: UUID; let revision: UUID; let createdAt: Date; let model: String; let os: String
    let physicalMemory: UInt64; let thermalState: Int; let timings: [String: Double]
}
