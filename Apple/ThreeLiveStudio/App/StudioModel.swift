import Foundation
import UIKit
import Observation
import CreationCore
import ThreeLiveNative
import QwenNative
import CryptoKit
import VoxamberCreationNative
import VoxamberImageNative
import VoxamberShapeNative

enum StudioTab: Hashable { case create, library, models }
enum GenerationStopReason: String, Sendable { case user, background, memoryPressure }

@MainActor @Observable
final class StudioModel {
    var tab = StudioTab.create
    var sceneSpec: SceneSpec?
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
    var referenceImagePNG: Data?
    var neuralEditRecipe = try! NeuralEditRecipe()
    private(set) var stopReason: GenerationStopReason?
    private(set) var lastStopLatency: Double?
    let models: ModelManager
    let neuralModels: NeuralModelManager
    @ObservationIgnored private let neuralEngine: NativeCreationEngine
    @ObservationIgnored private var publicationPermit: PublicationPermit?
    @ObservationIgnored let store: ProjectStore
    @ObservationIgnored private let backgroundTasks: BackgroundTaskClient
    @ObservationIgnored private let idleTimerLease: GenerationIdleTimerLease
    @ObservationIgnored private let memoryPressure: MemoryPressureClient
    @ObservationIgnored private var memoryMonitor: CriticalMemoryPressureMonitor?
    @ObservationIgnored private var memoryReclaimTask: Task<Void, Never>?
    @ObservationIgnored private var memoryReclaimID: UUID?
    @ObservationIgnored private var memoryPressureSequence: UInt64 = 0
    @ObservationIgnored private var pendingMemoryWarning: (owner: UUID, before: AppMemorySnapshot)?
    @ObservationIgnored private var memoryBudgetRecords: [MemoryBudgetRecord] = []
    private(set) var lastMemoryAction: MemoryPressureAction?
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
         backgroundTasks: BackgroundTaskClient = .system, idleTimer: IdleTimerClient = .system,
         memoryPressure: MemoryPressureClient? = nil, monitorCriticalMemory: Bool = true,
         neuralModels: NeuralModelManager? = nil) {
        let creator = NativeCreationEngine()
        neuralEngine = creator
        self.neuralModels = neuralModels ?? NeuralModelManager(beforeResourceMutation: { await creator.unload() })
        self.models = models
        self.store = store
        self.backgroundTasks = backgroundTasks
        self.idleTimerLease = GenerationIdleTimerLease(client: idleTimer)
        self.memoryPressure = memoryPressure ?? .system(engine: models.engine)
        if monitorCriticalMemory {
            memoryMonitor = CriticalMemoryPressureMonitor { [weak self] in self?.handleMemoryPressure(.critical) }
        }
    }

    static var blankScene: SceneSpec {
        SceneSpec(name: StudioCopy.text("自由造型", "Untitled creation"), nodes: [SceneNode(id: "form", primitive: .sphere,
            position: [0,0.25,0], size: [0.5,0.5,0.5], color: "#59D4C3", metallic: 0.25, roughness: 0.35)])
    }

    var hasUnbuiltChanges: Bool {
        isNeuralCreation ? neuralEditRecipe != savedNeuralEditRecipe : assets?.project.specification != sceneSpec
    }
    private var savedNeuralEditRecipe: NeuralEditRecipe {
        if let content = assets?.project.content, case .neuralMesh(let mesh) = content,
           let recipe = mesh.editRecipe { return recipe }
        return try! NeuralEditRecipe()
    }
    func resetNeuralEdits() {
        guard !busy else { return }
        neuralEditRecipe = savedNeuralEditRecipe
        persistDraft()
    }
    var canExport: Bool { assets != nil && !hasUnbuiltChanges && !busy }
    var isNeuralCreation: Bool {
        guard let content = assets?.project.content else { return false }
        if case .neuralMesh = content { return true }
        return false
    }
    var physicalScaleKnown: Bool {
        if let content = assets?.project.content, case .neuralMesh(let mesh) = content {
            return mesh.provenance.physicalScaleKnown
        }
        return true
    }
    var sceneForAIContext: SceneSpec? {
        guard let sceneSpec else { return nil }
        if assets != nil { return sceneSpec }
        var blank = Self.blankScene
        // A saved untouched draft stays blank when the App language changes.
        if ["自由造型", "Untitled creation"].contains(sceneSpec.name) { blank.name = sceneSpec.name }
        return sceneSpec == blank ? nil : sceneSpec
    }

    func start() async {
        #if DEVICE_QA
        if ProcessInfo.processInfo.arguments.contains("--qa-neural-shape") {
            let id = UUID()
            operationID = id; idleTimerLease.begin(for: id)
            let task = Task { await NeuralShapeDeviceProbe.run(studio: self) }
            work = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            finishOperation(id: id)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-inference") {
            let id = UUID()
            operationID = id
            idleTimerLease.begin(for: id)
            let task = Task { await DeviceAcceptanceProbe.run(studio: self) }
            work = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            finishOperation(id: id)
            await models.checkInstallation()
            return
        }
        #endif
        await refreshLibrary()
        if let draft = await store.loadDraft() {
            prompt = draft.prompt
            switch draft.content {
            case .proceduralScene(let scene): sceneSpec = scene
            case .textOnly: sceneSpec = nil
            case .neuralProject(let id, let revision):
                if let project = projects.first(where: { $0.id == id && $0.revision == revision }) {
                    do {
                        assets = try await store.load(project); sceneSpec = nil
                        neuralEditRecipe = draft.neuralEditRecipe ?? savedNeuralEditRecipe
                    }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        await models.checkInstallation()
        await neuralModels.checkInstallation()
        recordMemoryBudget(phase: "startup")
    }

    func refreshLibrary() async {
        do { projects = try await store.list() }
        catch { errorMessage = error.localizedDescription }
    }

    func selectScenePreset(_ preset: SceneSpec) {
        guard !busy else { return }
        sceneSpec = preset; assets = nil; notice = nil; referenceImagePNG = nil
        neuralEditRecipe = try! NeuralEditRecipe()
        prompt = "创建\(preset.name)，保持它的结构和材质。"
        persistDraft()
    }

    func newCreation() {
        guard !busy else { return }
        assets = nil; sceneSpec = nil; prompt = ""; tab = .create; notice = nil; referenceImagePNG = nil
        neuralEditRecipe = try! NeuralEditRecipe()
        persistDraft()
    }

    func generate(usingAI: Bool) {
        if usingAI { generateNeuralCreation(); return }
        guard !busy else { return }
        // A neural mesh has no procedural SceneSpec. Until the neural creator
        // owns this action, legacy generation cannot overwrite it with a sphere.
        guard !isNeuralCreation else { return }
        if usingAI && !models.installed { tab = .models; return }
        busy = true; errorMessage = nil; notice = nil; elapsed = 0; stopReason = nil; lastStopLatency = nil; stopRequestedAt = nil
        let id = UUID()
        operationID = id
        if usingAI { idleTimerLease.begin(for: id) }
        let start = Date()
        let initialScene = sceneSpec ?? Self.blankScene
        let aiContext = sceneForAIContext
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
                    recordMemoryBudget(phase: "before-model-load")
                    try await models.prepare()
                    recordMemoryBudget(phase: "after-model-load")
                    try Task.checkCancellation()
                    let began = Date()
                    stage = "正在理解你的构想"
                    let completion = InferenceCompletionCapture()
                    defer {
                        if let value = completion.value { saveInferenceCompletion(value, operationID: id) }
                    }
                    let response = try await models.engine.generateJSON(
                        systemPrompt: ScenePrompt.system,
                        prompt: try ScenePrompt.userRequest(request, currentSpec: aiContext),
                        maxTokens: 3072,
                        // Keep the phone-verified single-turn protocol while staged assembly is evaluated.
                        onProgress: { _ in },
                        onCompletion: { completion.record($0) })
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

    private func generateNeuralCreation() {
        guard !busy, !neuralModels.busy else { return }
        guard let resources = neuralModels.resources, neuralModels.ready else { tab = .models; return }
        guard ProcessInfo.processInfo.physicalMemory >= 12_000_000_000 else {
            errorMessage = "本机 AI 创作需要 12GB 或以上内存的 iPhone。你仍可编辑已有作品。"; return
        }
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, request.count <= 2000 else {
            errorMessage = "请用 1–2000 个字符描述你的构想。"; return
        }
        busy = true; errorMessage = nil; notice = nil; referenceImagePNG = nil
        elapsed = 0; stopReason = nil; stopRequestedAt = nil; lastStopLatency = nil
        let id = UUID(), began = Date(), previous = assets?.project
        let permit = PublicationPermit()
        operationID = id; publicationPermit = permit; idleTimerLease.begin(for: id)
        timer = Task {
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(began)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        work = Task {
            defer { finishOperation(id: id) }
            let temporary = FileManager.default.temporaryDirectory.appending(path: "VoxamberCreation-" + id.uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                draftTask?.cancel()
                try await store.saveDraft(currentWorkspaceDraft())
                let result = try await neuralEngine.generate(prompt: request, seed: UInt64.random(in: 0...UInt64.max),
                    resources: resources,
                    onProgress: { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.operationID == id, !self.isCleaningUp,
                                  self.work?.isCancelled != true, permit.state == .active else { return }
                            switch value.phase {
                            case .interpreting: self.stage = "正在理解你的构想"
                            case .drawingReference:
                                self.stage = "正在绘制参考造型"
                                if let step = value.completedSteps, let total = value.totalSteps {
                                    self.stage += " \(step)/\(total)"
                                }
                            case .preparingSubject: self.stage = "正在整理造型轮廓"
                            case .generatingShape: self.stage = "正在生成三维形体"
                            case .complete: self.stage = "正在校验三维模型"
                            }
                        }
                    }, onReferenceImage: { png in
                        Task { @MainActor [weak self] in
                            guard let self, self.operationID == id, !self.isCleaningUp,
                                  self.work?.isCancelled != true, permit.state == .active else { return }
                            self.referenceImagePNG = png
                        }
                    })
                try permit.check()
                let filePreparation = Task.detached(priority: .userInitiated) {
                    try permit.check()
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    let glb = temporary.appending(path: "model.glb"), usdz = temporary.appending(path: "model.usdz")
                    let prepared = temporary.appending(path: "source.png"), reference = temporary.appending(path: "reference.png")
                    try result.shape.glbData.write(to: glb, options: .atomic)
                    try permit.check()
                    try result.shape.usdzData.write(to: usdz, options: .atomic)
                    try permit.check()
                    try result.preparedReference.pngData.write(to: prepared, options: .atomic)
                    try result.referencePNG.write(to: reference, options: .atomic)
                    try permit.check()
                    let statistics = try NeuralProjectValidator.inspectGLB(glb, baseGeometry: true)
                    return try Self.neuralPublicationInput(result: result, request: request, previous: previous,
                        files: .init(glb: glb, usdz: usdz, baseMesh: glb, sourcePNG: prepared, referencePNG: reference),
                        statistics: statistics)
                }
                let input = try await withTaskCancellationHandler {
                    try await filePreparation.value
                } onCancel: { filePreparation.cancel() }
                try permit.check()
                stage = "正在安全保存作品"
                let saved = try await store.publishNeural(input, replacing: previous, permit: permit)
                // Commit has won. A later cancellation cannot relabel the saved
                // revision as an abandoned generation or delete it.
                assets = saved; sceneSpec = nil; elapsed = Date().timeIntervalSince(began)
                neuralEditRecipe = savedNeuralEditRecipe
                try? await store.saveDraft(.init(neuralProjectID: saved.project.id, revision: saved.project.revision, prompt: request))
                await refreshLibrary()
                saveNeuralMeasurement(result: result, project: saved.project, total: elapsed)
                notice = "已保存到作品库"; stage = "已完成"
            } catch is CancellationError {
                stage = isCleaningUp ? "正在停止" : "已取消"
                switch stopReason {
                case .background: notice = "离开 App 后已停止生成，之前的作品已保留。"
                case .memoryPressure: notice = "设备内存紧张，本次生成已停止，之前的作品已保留。"
                default: notice = "已取消，之前保存的作品仍在。"
                }
            } catch { stage = "未完成"; errorMessage = error.localizedDescription }
        }
    }

    func saveNeuralEdits() {
        guard !busy, isNeuralCreation, hasUnbuiltChanges, let original = assets else { return }
        let recipe = neuralEditRecipe, id = UUID(), began = Date(), permit = PublicationPermit()
        busy = true; operationID = id; publicationPermit = permit; idleTimerLease.begin(for: id)
        errorMessage = nil; notice = nil; elapsed = 0; stopReason = nil; stopRequestedAt = nil; lastStopLatency = nil
        stage = "正在更新三维模型"
        timer = Task {
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(began)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        work = Task {
            defer { finishOperation(id: id) }
            let temporary = FileManager.default.temporaryDirectory.appending(path: "VoxamberEdit-" + id.uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                draftTask?.cancel()
                try await store.saveDraft(currentWorkspaceDraft())
                let preparation = Task.detached(priority: .userInitiated) {
                    try NeuralEditPreparation.prepare(assets: original, recipe: recipe,
                                                      temporary: temporary, permit: permit)
                }
                let input = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                try permit.check()
                stage = "正在安全保存作品"
                let saved = try await store.publishNeural(input, replacing: original.project, permit: permit)
                assets = saved; neuralEditRecipe = savedNeuralEditRecipe; elapsed = Date().timeIntervalSince(began)
                try? await store.saveDraft(currentWorkspaceDraft())
                await refreshLibrary()
                stage = "已完成"; notice = "已保存到作品库"
            } catch is CancellationError {
                stage = isCleaningUp ? "正在停止" : "已取消"
                notice = "已取消，之前保存的作品仍在。"
            } catch { stage = "未完成"; errorMessage = error.localizedDescription }
        }
    }

    private nonisolated static func neuralPublicationInput(result: NativeCreationResult, request: String, previous: CreationProject?,
                                        files: NeuralPublicationFiles, statistics: NeuralMeshStatistics) throws -> NeuralPublicationInput {
        let manifests = try NeuralModelManifest.loadAll()
        func manifest(_ group: NeuralModelGroup) throws -> NeuralModelManifest {
            guard let found = manifests.first(where: { $0.group == group }) else { throw NeuralModelError.invalidCatalog }
            return found
        }
        let intent = try manifest(.intent), image = try manifest(.image), shape = try manifest(.shape)
        let shapeProvenance = result.shape.provenance
        let imageConfiguration: [String: Any] = ["steps": 20, "size": 768, "guidanceScale": 7.5,
            "reduceMemory": true, "scheduler": "dpmSolverMultistep", "textAndUNetCompute": "cpuAndNeuralEngine",
            "vaeCompute": "cpuAndGPU", "vaeScale": 0.13025]
        let imageSHA = SHA256.hash(data: try JSONSerialization.data(withJSONObject: imageConfiguration, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
        let evidence = try JSONDecoder().decode(NeuralGenerationEvidence.self,
            from: JSONEncoder().encode(result.shape.validationReceipt))
        let provenance = NeuralPipelineProvenance(pipelineID: "voxamber-native-neural-v1", method: .textToImageToShape,
            imageStage: .init(modelID: image.id, modelRevision: SDXLResources.modelRevision,
                modelManifestSHA256: try image.pinIdentity, configurationSHA256: imageSHA,
                runtimeVersion: "AppleSDXL-ea2805dc", seed: UInt64(UInt32(truncatingIfNeeded: result.seed))),
            shapeStage: .init(modelID: shapeProvenance.modelID, modelRevision: shapeProvenance.modelSourceRevision,
                modelManifestSHA256: try shape.pinIdentity, configurationSHA256: shapeProvenance.configurationSHA256,
                runtimeVersion: shapeProvenance.runtimeMLXVersion, seed: shapeProvenance.seed),
            preparedPNG_SHA256: shapeProvenance.inputPNG_SHA256, generatedAt: Date(),
            physicalScaleKnown: shapeProvenance.physicalScaleKnown, parentRevision: previous?.revision,
            intentStage: .init(modelID: intent.id, modelRevision: intent.sourceReferenceURL.lastPathComponent,
                configurationSHA256: intent.files.first(where: { $0.path == "config.json" })?.sha256 ?? ""),
            intentBrief: .init(title: result.intent.title, positiveEnglish: result.intent.positivePrompt,
                negativeEnglish: result.intent.negativePrompt, requestedSeed: result.seed))
        return .init(name: result.intent.title, prompt: request, files: files, statistics: statistics,
            baseStatistics: statistics, provenance: provenance, generationEvidence: evidence)
    }

    private func saveNeuralMeasurement(result: NativeCreationResult, project: CreationProject, total: Double) {
        let record: [String: Any] = ["appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "project": project.id.uuidString, "revision": project.revision.uuidString,
            "pipeline": "voxamber-native-neural-v1", "totalSeconds": total, "stageSeconds": result.stageSeconds,
            "vertices": result.shape.mesh.vertexCount, "triangles": result.shape.mesh.triangleCount,
            "actualNeuralWeightsUsed": result.shape.validationReceipt.actualNeuralWeightsUsed,
            "physicalScaleKnown": result.shape.provenance.physicalScaleKnown]
        let url = URL.documentsDirectory.appending(path: "Measurements/last-neural-pipeline.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { /* Local counts cannot invalidate an already committed work. */ }
    }

    func cancel(reason: GenerationStopReason = .user) {
        guard busy, let operation = work, !operation.isCancelled else { return }
        if let publicationPermit, !publicationPermit.revoke() { return }
        stopReason = reason
        stopRequestedAt = .now
        operation.cancel()
        stage = "正在停止"
    }

    private func finishOperation(id: UUID) {
        guard operationID == id else { return }
        work = nil
        publicationPermit = nil
        operationID = nil
        operationBusy = false
        guard !isCleaningUp else { return }
        idleTimerLease.end(for: id)
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

    func handleMemoryPressure(_ severity: MemoryPressureSeverity = .warning) {
        if severity == .warning, isCleaningUp { return }
        let before = memoryPressure.snapshot()
        // Critical pressure and an exceeded process limit must cancel before
        // waiting for the model allocator's evaluation lock.
        if severity == .critical || before.availableProcessBytes == 0 || work == nil {
            memoryPressureSequence &+= 1
            pendingMemoryWarning = nil
            let action = MemoryPressurePolicy.action(severity: severity, snapshot: before, hasOwnedOperation: work != nil)
            lastMemoryAction = action
            saveMemoryPressure(severity: severity, action: action, before: before, after: before,
                               reclaimed: false, allocator: nil, oldOperationEnded: false)
            requestCleanup(reason: .memoryPressure, needsBackgroundLease: false)
            return
        }
        if memoryReclaimTask != nil {
            if let operationID { pendingMemoryWarning = (operationID, before) }
            return
        }
        memoryPressureSequence &+= 1
        let sequence = memoryPressureSequence
        let id = UUID(), owner = operationID
        memoryReclaimID = id
        lastMemoryAction = .reclaimAndContinue
        memoryReclaimTask = Task {
            // QwenEngine is an independent actor. A cache trim can wait on GPU
            // evaluation; never perform that synchronous wait on the UI actor.
            let allocator = await memoryPressure.reclaimUnusedCache()
            guard memoryReclaimID == id else { return }
            memoryReclaimTask = nil
            memoryReclaimID = nil
            let pending = pendingMemoryWarning
            pendingMemoryWarning = nil
            let currentPending = pending.flatMap { $0.owner == operationID ? $0 : nil }
            // A later critical event has already cancelled and recorded its
            // decision. An older warning must never replace that evidence.
            guard !isCleaningUp,
                  memoryPressureSequence == sequence || currentPending != nil else { return }
            let after = memoryPressure.snapshot()
            let eventOwner = currentPending?.owner ?? owner
            let stale = operationID != eventOwner
            let action: MemoryPressureAction = stale ? .reclaimAndContinue :
                MemoryPressurePolicy.action(severity: severity, snapshot: after, hasOwnedOperation: work != nil)
            lastMemoryAction = action
            saveMemoryPressure(severity: severity, action: action, before: currentPending?.before ?? before, after: after,
                               reclaimed: true, allocator: allocator, oldOperationEnded: stale)
            if !stale, action != .reclaimAndContinue {
                requestCleanup(reason: .memoryPressure, needsBackgroundLease: false)
            }
        }
    }

    private func saveMemoryPressure(severity: MemoryPressureSeverity, action: MemoryPressureAction,
                                    before: AppMemorySnapshot, after: AppMemorySnapshot,
                                    reclaimed: Bool, allocator: QwenMemorySnapshot?, oldOperationEnded: Bool) {
        let record = MemoryPressureRecord(time: Date(),
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            severity: severity, action: action, stage: stage, elapsedSeconds: elapsed,
            hasOwnedOperation: work != nil, before: before, afterReclaim: after,
            reclaimCompleted: reclaimed, allocatorAfterReclaim: allocator,
            relatedOperationAlreadyEnded: oldOperationEnded)
        let url = URL.documentsDirectory.appending(path: "Measurements/last-memory-pressure.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url, options: .atomic)
        } catch { /* Local resource diagnostics never decide whether a task is cancelled. */ }
    }

    private func recordMemoryBudget(phase: String) {
        memoryBudgetRecords.append(MemoryBudgetRecord(time: Date(), phase: phase,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            snapshot: memoryPressure.snapshot()))
        if memoryBudgetRecords.count > 32 { memoryBudgetRecords.removeFirst(memoryBudgetRecords.count - 32) }
        let url = URL.documentsDirectory.appending(path: "Measurements/memory-budget.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(memoryBudgetRecords).write(to: url, options: .atomic)
        } catch { /* Resource snapshots do not alter a user's creation or task state. */ }
    }

    func open(_ project: CreationProject) async {
        guard !busy else { return }
        do {
            let result = try await store.load(project)
            assets = result; sceneSpec = project.specification; prompt = project.prompt; tab = .create; notice = nil
            neuralEditRecipe = savedNeuralEditRecipe
            referenceImagePNG = nil
            persistDraft()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ project: CreationProject) async {
        guard !busy else { return }
        do {
            try await store.remove(project)
            if assets?.project.id == project.id {
                draftTask?.cancel()
                assets = nil
                referenceImagePNG = nil
                sceneSpec = nil
                neuralEditRecipe = try! NeuralEditRecipe()
                prompt = ""
                try await store.saveDraft(.init(prompt: ""))
            }
            await refreshLibrary()
        } catch { errorMessage = error.localizedDescription }
    }

    func persistDraft() {
        draftTask?.cancel()
        let draft = currentWorkspaceDraft()
        draftTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await store.saveDraft(draft)
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }

    func enterBackground() {
        requestCleanup(reason: .background, needsBackgroundLease: true)
        draftTask?.cancel()
        let draft = currentWorkspaceDraft()
        Task { try? await store.saveDraft(draft) }
    }

    private func currentWorkspaceDraft() -> ProjectStore.Draft {
        if isNeuralCreation, let project = assets?.project {
            return .init(neuralProjectID: project.id, revision: project.revision, prompt: prompt,
                         neuralEditRecipe: neuralEditRecipe)
        }
        if let sceneSpec { return .init(spec: sceneSpec, prompt: prompt) }
        return .init(prompt: prompt)
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
        let pendingOperationID = operationID
        cleanupOperation = pending
        cancel(reason: reason)
        if needsBackgroundLease { acquireBackgroundLease(for: id) }
        cleanupTask = Task {
            await pending?.value
            await models.unload()
            finishCleanup(id: id, operationID: pendingOperationID)
        }
    }

    private func acquireBackgroundLease(for id: UUID) {
        guard cleanupID == id, backgroundLease == nil else { return }
        let pending = cleanupOperation
        backgroundLease = BackgroundTaskLease(client: backgroundTasks) { pending?.cancel() }
    }

    private func finishCleanup(id: UUID, operationID: UUID?) {
        guard cleanupID == id else { return }
        backgroundLease?.end()
        backgroundLease = nil
        cleanupOperation = nil
        cleanupTask = nil
        cleanupID = nil
        isCleaningUp = false
        if stage == "正在停止", stopReason != nil { stage = "已取消" }
        guard work == nil else { return }
        if let operationID { idleTimerLease.end(for: operationID) }
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

    private func saveInferenceCompletion(_ value: QwenGenerationCompletion, operationID: UUID) {
        let record = InferenceCompletionRecord(operationID: operationID, createdAt: Date(),
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            model: ModelManager.modelID, completion: value)
        let url = URL.documentsDirectory.appending(path: "Measurements/last-inference.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url, options: .atomic)
        } catch { /* Local counts and termination diagnostics never change the creation result. */ }
    }
}

private struct InferenceCompletionRecord: Codable {
    let operationID: UUID
    let createdAt: Date
    let appBuild: String
    let model: String
    let completion: QwenGenerationCompletion
}

#if DEVICE_QA
extension StudioModel: NeuralShapeProbeState {}
#endif

private final class InferenceCompletionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: QwenGenerationCompletion?
    func record(_ value: QwenGenerationCompletion) { lock.withLock { completion = value } }
    var value: QwenGenerationCompletion? { lock.withLock { completion } }
}

@MainActor
struct IdleTimerClient {
    var isDisabled: () -> Bool
    var setDisabled: (Bool) -> Void

    static var system: Self {
        Self(isDisabled: { UIApplication.shared.isIdleTimerDisabled },
             setDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 })
    }
}

/// One admitted AI operation owns this setting through inference and cleanup.
/// A delayed completion carrying an old ID cannot release a newer lease.
@MainActor
final class GenerationIdleTimerLease {
    private let client: IdleTimerClient
    private var owner: UUID?
    private var previousValue = false

    init(client: IdleTimerClient) { self.client = client }

    func begin(for operationID: UUID) {
        guard owner == nil else { return }
        owner = operationID
        previousValue = client.isDisabled()
        client.setDisabled(true)
    }

    func end(for operationID: UUID) {
        guard owner == operationID else { return }
        owner = nil
        client.setDisabled(previousValue)
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
