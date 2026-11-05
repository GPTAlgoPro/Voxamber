import XCTest
import CreationCore
@testable import ThreeLiveStudio

@MainActor
final class AIContextTests: XCTestCase {
    func testSelectedUnpublishedStarterIsIncludedAsAIInput() throws {
        let model = StudioModel(monitorCriticalMemory: false)
        model.selectScenePreset(.chair)
        XCTAssertNil(model.assets, "No parameter generation is needed to provide editing context")
        let context = try XCTUnwrap(model.sceneForAIContext)
        XCTAssertEqual(context, .chair)
        let prompt = try ScenePrompt.userRequest(model.prompt, currentSpec: context)
        XCTAssertTrue(prompt.contains("\"id\":\"seat\""))
        XCTAssertTrue(prompt.contains("\"id\":\"leg_fl\""))
    }

    func testUntouchedBlankWorkspaceDoesNotConstrainNewSubjectsToASphere() {
        let model = StudioModel(monitorCriticalMemory: false)
        model.prompt = "自由创作一个任意题材的模型"
        XCTAssertNil(model.sceneForAIContext)
    }

    func testUnpublishedCustomEditsAreIncludedWithoutACategoryLookup() throws {
        let model = StudioModel(monitorCriticalMemory: false)
        var custom = StudioModel.blankScene
        custom.name = "自由轮廓"
        custom.nodes = [.defaultNode(primitive: .extrusion, id: "custom_outline")]
        model.sceneSpec = custom
        XCTAssertEqual(model.sceneForAIContext, custom)
        model.newCreation()
        XCTAssertNil(model.sceneForAIContext)
    }

    func testUntouchedBlankDraftIsLanguageIndependentButCustomNameIsPreserved() {
        let model = StudioModel(monitorCriticalMemory: false)
        for name in ["自由造型", "Untitled creation"] {
            var blank = StudioModel.blankScene
            blank.name = name
            model.sceneSpec = blank
            XCTAssertNil(model.sceneForAIContext)
        }
        var custom = StudioModel.blankScene
        custom.name = "玻璃珠"
        model.sceneSpec = custom
        XCTAssertEqual(model.sceneForAIContext, custom)
    }

    func testDeletingCurrentPublishedCreationClearsItsAIContext() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AIContext-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let model = StudioModel(store: store, monitorCriticalMemory: false)
        model.selectScenePreset(.robot)
        model.generate(usingAI: false)
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        let project = try XCTUnwrap(model.assets?.project)
        await model.delete(project)
        XCTAssertNil(model.assets)
        XCTAssertNil(model.sceneForAIContext)
        XCTAssertEqual(model.sceneSpec, StudioModel.blankScene)
        XCTAssertTrue(model.prompt.isEmpty)
        let savedDraft = await store.loadDraft()
        XCTAssertEqual(savedDraft?.spec, StudioModel.blankScene)
        XCTAssertEqual(savedDraft?.prompt, "")
        let reopened = StudioModel(store: store, monitorCriticalMemory: false)
        await reopened.start()
        XCTAssertNil(reopened.sceneForAIContext)
        XCTAssertTrue(reopened.prompt.isEmpty)
    }
}
