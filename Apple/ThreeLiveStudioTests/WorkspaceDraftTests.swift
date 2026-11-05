import XCTest
import CreationCore
@testable import ThreeLiveStudio

final class WorkspaceDraftTests: XCTestCase {
    func testLegacyDraftWireRemainsIdentical() throws {
        struct Legacy: Codable { let spec: SceneSpec; let prompt: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let old = try encoder.encode(Legacy(spec: .chair, prompt: "保留此草稿"))
        let draft = try JSONDecoder().decode(WorkspaceDraft.self, from: old)
        XCTAssertEqual(draft.spec, .chair)
        XCTAssertEqual(try encoder.encode(draft), old)
    }

    func testTextDraftContainsNoInventedGeometry() throws {
        let data = try JSONEncoder().encode(WorkspaceDraft(prompt: "自由想象"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "textOnly")
        XCTAssertNil(object["spec"])
        let restored = try JSONDecoder().decode(WorkspaceDraft.self, from: data)
        XCTAssertNil(restored.spec)
        XCTAssertEqual(restored.prompt, "自由想象")
    }

    func testNeuralReferenceRoundtripDoesNotBecomeAScene() throws {
        let id = UUID(), revision = UUID()
        let data = try JSONEncoder().encode(WorkspaceDraft(neuralProjectID: id, revision: revision, prompt: "继续调整"))
        let restored = try JSONDecoder().decode(WorkspaceDraft.self, from: data)
        guard case .neuralProject(let actualID, let actualRevision) = restored.content else {
            return XCTFail("Neural references cannot be restored as procedural drafts")
        }
        XCTAssertEqual(actualID, id); XCTAssertEqual(actualRevision, revision); XCTAssertNil(restored.spec)
    }

    func testUnsavedNeuralRecipeRoundtripsWithExactRevision() throws {
        let id = UUID(), revision = UUID()
        let recipe = try NeuralEditRecipe(translationXYZ: [0.123456789, -2, 3],
            rotationXYZdegrees: [0, 45, 90], positiveScaleXYZ: [0.5, 1, 2])
        let data = try JSONEncoder().encode(WorkspaceDraft(neuralProjectID: id, revision: revision,
            prompt: "继续调整", neuralEditRecipe: recipe))
        let draft = try JSONDecoder().decode(WorkspaceDraft.self, from: data)
        try draft.validateForRestore()
        XCTAssertEqual(draft.neuralEditRecipe, recipe)
        guard case .neuralProject(let actualID, let actualRevision) = draft.content else { return XCTFail() }
        XCTAssertEqual(actualID, id); XCTAssertEqual(actualRevision, revision)
    }

    func testRecipeCannotBeAttachedToTextOrLegacyProceduralDraft() throws {
        let encoder = JSONEncoder()
        let recipe = try JSONSerialization.jsonObject(with: encoder.encode(NeuralEditRecipe()))
        for data in [try encoder.encode(WorkspaceDraft(prompt: "想象")),
                     try encoder.encode(WorkspaceDraft(spec: .chair, prompt: "编辑"))] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["neuralEditRecipe"] = recipe
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceDraft.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testMissingProjectCannotBeRevivedBySavingOrRestoringItsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DraftRef-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let id = UUID(), revision = UUID()
        let draft = WorkspaceDraft(neuralProjectID: id, revision: revision, prompt: "已删除的作品")
        do { try await store.saveDraft(draft); XCTFail("A missing project cannot acquire a draft reference") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: id.uuidString).path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: root.appending(path: "draft.json"))
        let restored = await store.loadDraft()
        XCTAssertNil(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: id.uuidString).path))
    }

    func testIncompleteProceduralTypingIsStoredWithoutBeingRestoredAsValidGeometry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DraftEdit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var incomplete = SceneSpec.chair; incomplete.nodes[0].size[1] = 0
        try await store.saveDraft(spec: incomplete, prompt: "正在输入")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "draft.json").path))
        let restored = await store.loadDraft()
        XCTAssertNil(restored)
    }
}
