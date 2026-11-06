import Foundation
import Observation
import CreationCore
import GoogleThreeLiveNative

@MainActor @Observable
final class SceneStudioModel {
    var title = ""
    var source = ""
    var originalImport = Data()
    var projects: [ProgramProject] = []
    var legacyProjects: [LegacySceneProject] = []
    var pendingShares: [SceneImportInboxItem] = []
    var selected: ProgramProject?
    var editing: ProgramProject?
    var busy = false
    var stage = "从你的 AI 带来一个创意"
    var notice: String?
    var errorMessage: String?
    var startedAt: Date?
    @ObservationIgnored private let engine = GoogleThreeLiveEngine()
    @ObservationIgnored private let store = ProgramProjectStore()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var mutationEpoch = UUID()

    func refresh() async {
        guard !busy else { return }
        let epoch = mutationEpoch
        do {
            let saved = try await store.list()
            guard epoch == mutationEpoch, !Task.isCancelled else { return }
            projects = saved
            let legacy = try await LegacyProjectReader.list()
            guard epoch == mutationEpoch, !Task.isCancelled else { return }
            legacyProjects = legacy.projects
            if legacy.unreadableCount > 0 { notice = "部分历史作品尚无法读取，原文件已保留。" }
        } catch { if epoch == mutationEpoch, !Task.isCancelled { errorMessage = error.localizedDescription } }
        do {
            let inbox = try SceneImportInbox.openShared()
            let incoming = try await inbox.list().pending
            guard epoch == mutationEpoch, !Task.isCancelled else { return }
            pendingShares = incoming
        } catch {
            if epoch == mutationEpoch, !Task.isCancelled { notice = "系统分享收件箱暂不可用，仍可粘贴代码或导入文件。" }
        }
    }

    func acceptShared(_ item: SceneImportInboxItem) {
        guard !busy else { return }
        start(stage: "正在导入分享的场景") { [self] in
            let inbox = try SceneImportInbox.openShared()
            let payload = try await inbox.read(entryID: item.id)
            try await accept(payload.bytes, fileName: item.originalFilename)
            do {
                try await inbox.acknowledge(entryID: item.id)
                pendingShares.removeAll { $0.id == item.id }
            } catch { notice = "场景已导入；分享收件记录暂未归档，可稍后重试。" }
        }
    }

    func importExample() {
        guard let url = Bundle.main.url(forResource: "RobotScene", withExtension: "js") else { return }
        title = "几何旅行者 · 示例"
        importFile(url)
    }

    func importText(_ text: String) {
        importData(Data(text.utf8), fileName: nil)
    }

    func importFile(_ url: URL) {
        guard !busy else { return }
        start(stage: "正在读取场景文件") { [self] in
            let reader = Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw SceneStudioError.message("请选择一个代码或文本文件。")
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 4 * 1_024 * 1_024 + 1) ?? Data()
                try Task.checkCancellation()
                return bytes
            }
            let data = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            try Task.checkCancellation()
            try await accept(data, fileName: url.lastPathComponent)
        }
    }

    func importData(_ data: Data, fileName: String?) {
        guard !busy else { return }
        start(stage: "正在检查导入内容") { [self] in
            try await accept(data, fileName: fileName)
        }
    }

    private func accept(_ data: Data, fileName: String?) async throws {
        let javascript = fileName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() == "js" } ?? false
        let parser = Task.detached(priority: .userInitiated) {
            try SceneSourceImport.parse(data, hint: javascript ? .rawJavaScript : .automatic)
        }
        let parsed = try await withTaskCancellationHandler { try await parser.value } onCancel: { parser.cancel() }
        try Task.checkCancellation()
        originalImport = parsed.originalData
        source = parsed.source
        if let fileName, title.isEmpty {
            title = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        }
        selected = nil
        stage = "场景已导入，点击生成即可在本机编译"
        notice = "已保留原始内容；尚未运行场景。"
        try saveDraft()
    }

    func generateAndSave() {
        guard !busy, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let inputSource = source
        let inputOriginal = originalImport.isEmpty ? Data(source.utf8) : originalImport
        let inputTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = editing
        start(stage: "正在本机生成三维模型") { [self] in
            let result = try await engine.compile(source: inputSource)
            try Task.checkCancellation()
            stage = "正在保存模型与来源"
            let saved = try await store.publish(title: inputTitle.isEmpty ? "未命名作品" : inputTitle,
                originalImport: inputOriginal, source: result.source, glb: result.glb, usdz: result.usdz,
                compilerVersion: result.sdkVersion, compilerRevision: result.sdkSourceRevision, parent: parent)
            // Successful publication is the commit boundary. Cancellation after
            // that point cannot turn a saved work into a reported cancellation.
            projects.removeAll { $0.id == saved.id }
            projects.insert(saved, at: 0)
            selected = saved
            editing = saved
            title = saved.title
            stage = "作品已保存"
            notice = "可预览、分享模型，或把场景代码带回你的 AI 继续修改。"
            try? saveDraft()
        }
    }

    func open(_ project: ProgramProject) {
        guard !busy else { return }
        start(stage: "正在校验作品") { [self] in
            guard let loaded = try await store.load(id: project.id) else {
                throw SceneStudioError.message("这件作品已不在作品库中。")
            }
            let code = try await store.readSource(loaded)
            try Task.checkCancellation()
            selected = loaded; editing = loaded; title = loaded.title; source = code
            originalImport = try Data(contentsOf: loaded.originalImportURL)
            stage = "作品已打开"
            try saveDraft()
        }
    }

    func newProject() {
        guard !busy else { return }
        mutationEpoch = UUID()
        title = ""; source = ""; originalImport = Data(); selected = nil; editing = nil
        notice = nil; errorMessage = nil; stage = "从你的 AI 带来一个创意"
        try? saveDraft()
    }

    func sourceWasEdited() {
        mutationEpoch = UUID()
        notice = "代码已修改，重新生成后会保存为新版本。"
        try? saveDraft()
    }

    func cancel() { guard busy else { return }; stage = "正在结束当前操作"; operation?.cancel() }
    func waitForCurrentOperation() async { await operation?.value }

    private func start(stage: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let id = UUID(); owner = id; busy = true; errorMessage = nil; notice = nil
        mutationEpoch = UUID()
        startedAt = Date(); self.stage = stage
        operation = Task { [self] in
            defer {
                if owner == id { busy = false; owner = nil; operation = nil; startedAt = nil }
            }
            do { try await work() }
            catch {
                if error is CancellationError || Task.isCancelled {
                    await engine.cancelAndWait()
                    self.stage = "操作已取消"
                } else {
                    errorMessage = error.localizedDescription
                    self.stage = "本次操作未完成"
                }
            }
        }
    }

    private struct Draft: Codable {
        let title: String
        let source: String
        let originalImport: Data
        let parentID: UUID?
        let parentRevision: UUID?
    }
    private var draftURL: URL { .documentsDirectory.appending(path: "scene-program-draft.json") }
    private func saveDraft() throws {
        let draft = Draft(title: title, source: source, originalImport: originalImport,
                          parentID: editing?.id, parentRevision: editing?.revision)
        try JSONEncoder().encode(draft).write(to: draftURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func restoreDraft() async {
        guard !busy, source.isEmpty, FileManager.default.fileExists(atPath: draftURL.path) else { return }
        let epoch = mutationEpoch
        do {
            let size = try draftURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1_024 * 1_024 else { throw SceneStudioError.message("草稿超过读取范围，原文件已保留。") }
            let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: draftURL))
            guard draft.source.utf8.count <= 1_048_576, draft.originalImport.count <= 4 * 1_024 * 1_024 else {
                throw SceneStudioError.message("草稿内容超出场景范围，原文件已保留。")
            }
            var restoredParent: ProgramProject?
            if let id = draft.parentID {
                guard let parent = try await store.load(id: id), parent.revision == draft.parentRevision else {
                    throw SceneStudioError.message("草稿引用的作品已有变化，请从作品库重新打开。")
                }
                restoredParent = parent
            }
            guard epoch == mutationEpoch, !busy, source.isEmpty, !Task.isCancelled else { return }
            editing = restoredParent
            title = draft.title; source = draft.source; originalImport = draft.originalImport
            if !source.isEmpty { stage = "已恢复上次的场景草稿" }
        } catch { if epoch == mutationEpoch, !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

enum SceneStudioError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}
