import Foundation
import XCTest
import CreationCore
import ThreeLiveNative
#if canImport(ThreeLiveStudio)
@testable import ThreeLiveStudio
#else
@testable import ThumbnailNativeChecks
#endif

/// Isolated native fixtures verify storage boundaries; they are never inserted
/// into the real library and are not evidence of AI generation quality.
@MainActor final class ProjectThumbnailStoreTests: XCTestCase {
    func testThumbnailFailureCannotInvalidateCommittedNativeFilesOrMetadata() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let thumbnails = ProjectThumbnailService(directory: root.appending(path: "cache"),
            renderer: .init { _,_ in throw ProjectThumbnailError.unavailable })
        let store = ProjectStore(root: root.appending(path: "projects"), thumbnails: thumbnails)
        let meshes = try SceneGenerator.generate(for: .lamp)
        let glb = try ThreeLiveNative.exportGLB(meshes), usdz = try ThreeLiveNative.exportUSDZ(meshes)
        let saved = try await store.publish(spec: .lamp, prompt: "Isolated thumbnail storage fixture", glb: glb, usdz: usdz, replacing: nil)
        let pointer = saved.usdzURL.deletingLastPathComponent().deletingLastPathComponent().appending(path: "project.json")
        let metadata = try Data(contentsOf: pointer)
        do { _ = try await store.thumbnail(for: saved.project); XCTFail("Renderer failure must be observable") }
        catch { XCTAssertTrue(error is ProjectThumbnailError) }
        XCTAssertEqual(try Data(contentsOf: pointer), metadata)
        XCTAssertEqual(try Data(contentsOf: saved.glbURL), glb)
        XCTAssertEqual(try Data(contentsOf: saved.usdzURL), usdz)
        let reopened = ProjectStore(root: root.appending(path: "projects"), thumbnails: thumbnails)
        let projects = try await reopened.list(); XCTAssertEqual(projects, [saved.project])
        let loaded = try await reopened.load(saved.project); XCTAssertEqual(loaded.project, saved.project)
    }

    func testDeletedProjectCannotBeListedOrRestoredByThumbnailRequest() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let thumbnails = ProjectThumbnailService(directory: root.appending(path: "cache"),
            renderer: .init { _,_ in throw ProjectThumbnailError.unavailable })
        let library = root.appending(path: "projects")
        let store = ProjectStore(root: library, thumbnails: thumbnails)
        let meshes = try SceneGenerator.generate(for: .robot)
        let saved = try await store.publish(spec: .robot, prompt: "Isolated deletion fixture",
            glb: ThreeLiveNative.exportGLB(meshes), usdz: ThreeLiveNative.exportUSDZ(meshes), replacing: nil)
        try await store.remove(saved.project)
        do { _ = try await store.thumbnail(for: saved.project); XCTFail("Deleted project has no thumbnail source") }
        catch { XCTAssertTrue(error is ProjectThumbnailError) }
        let reopened = ProjectStore(root: library, thumbnails: thumbnails)
        let projects = try await reopened.list(); XCTAssertTrue(projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: saved.project.id.uuidString).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "cache").appending(path: saved.project.id.uuidString).path))
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ThumbnailStoreTests-" + UUID().uuidString)
    }
}
