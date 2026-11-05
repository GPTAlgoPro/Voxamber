import Foundation
import XCTest
import CreationCore
import ThreeLiveNative
@testable import ThreeLiveStudio

@MainActor
final class ProjectStoreTests: XCTestCase {
    func testPublishedProjectReopensWithExactNativeFilesAndRevisionMetadata() async throws {
        try await withStore { store, root in
            let files = try nativeFiles(.chair)
            let saved = try await store.publish(spec: .chair, prompt: "青玉扶手椅", glb: files.glb,
                                                usdz: files.usdz, replacing: nil)
            let reopened = ProjectStore(root: root)
            let projects = try await reopened.list()
            XCTAssertEqual(projects, [saved.project])
            let loaded = try await reopened.load(try XCTUnwrap(projects.first))
            XCTAssertEqual(try Data(contentsOf: loaded.glbURL), files.glb)
            XCTAssertEqual(try Data(contentsOf: loaded.usdzURL), files.usdz)
            let revision = try JSONDecoder().decode(CreationProject.self,
                from: Data(contentsOf: loaded.glbURL.deletingLastPathComponent().appending(path: "revision.json")))
            XCTAssertEqual(revision, saved.project)
            XCTAssertFalse(try contents(loaded.glbURL.deletingLastPathComponent().deletingLastPathComponent())
                .contains(where: { $0.lastPathComponent.hasPrefix(".pending-") }))
        }
    }

    func testReplacementPublishesNewRevisionAndPreservesPreviousReadableAssets() async throws {
        try await withStore { store, root in
            let oldFiles = try nativeFiles(.chair)
            let old = try await store.publish(spec: .chair, prompt: "第一版", glb: oldFiles.glb,
                                              usdz: oldFiles.usdz, replacing: nil)
            var changed = SceneSpec.chair
            changed.name = "自由新造型"; changed.nodes[0].color = "#33DDAA"; changed.nodes[0].size[0] = 1.3
            let newFiles = try nativeFiles(changed)
            let new = try await store.publish(spec: changed, prompt: "改成青色并加宽", glb: newFiles.glb,
                                              usdz: newFiles.usdz, replacing: old.project)
            XCTAssertEqual(new.project.id, old.project.id)
            XCTAssertEqual(new.project.createdAt, old.project.createdAt)
            XCTAssertNotEqual(new.project.revision, old.project.revision)
            XCTAssertNotEqual(new.project.glbSHA256, old.project.glbSHA256)
            let projects = try await ProjectStore(root: root).list()
            XCTAssertEqual(projects, [new.project])
            XCTAssertEqual(try Data(contentsOf: old.glbURL), oldFiles.glb)
            XCTAssertEqual(try Data(contentsOf: old.usdzURL), oldFiles.usdz)
            let reloaded = try await store.load(new.project)
            XCTAssertEqual(try Data(contentsOf: reloaded.glbURL), newFiles.glb)
        }
    }

    func testRejectedCorruptOutputCannotReplacePreviouslySavedProject() async throws {
        try await withStore { store, root in
            let files = try nativeFiles(.chair)
            let saved = try await store.publish(spec: .chair, prompt: "保留这一版", glb: files.glb,
                                                usdz: files.usdz, replacing: nil)
            let pointer = projectPointer(root, saved.project)
            let originalPointer = try Data(contentsOf: pointer)
            var corruptedGLB = files.glb
            corruptedGLB[0] ^= 0xff
            do {
                _ = try await store.publish(spec: .chair, prompt: "损坏输出", glb: corruptedGLB,
                                            usdz: files.usdz, replacing: saved.project)
                XCTFail("Corrupted generated output must not become a published revision")
            } catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: pointer), originalPointer)
            let projects = try await ProjectStore(root: root).list()
            XCTAssertEqual(projects, [saved.project])
            _ = try await store.load(saved.project)
        }
    }

    func testCancelledSavePreservesPublishedRevisionAndLeavesNoStaging() async throws {
        try await withStore { store, root in
            let files = try nativeFiles(.robot)
            let saved = try await store.publish(spec: .robot, prompt: "星际机器人", glb: files.glb,
                                                usdz: files.usdz, replacing: nil)
            let pointer = projectPointer(root, saved.project)
            let originalPointer = try Data(contentsOf: pointer)
            let cancelled = Task { () throws -> ProjectAssets in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.publish(spec: .robot, prompt: "取消这次保存", glb: files.glb,
                                               usdz: files.usdz, replacing: saved.project)
            }
            do { _ = try await cancelled.value; XCTFail("A cancelled save must throw") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: pointer), originalPointer)
            XCTAssertFalse(try contents(pointer.deletingLastPathComponent())
                .contains(where: { $0.lastPathComponent.hasPrefix(".pending-") }))
            _ = try await ProjectStore(root: root).load(saved.project)
        }
    }

    func testPointerCommitFailureKeepsOldManifestAndDoesNotLeakUnpublishedRevision() async throws {
        try await withStore { store, root in
            let files = try nativeFiles(.robot)
            let saved = try await store.publish(spec: .robot, prompt: "保留星际机器人", glb: files.glb,
                                                usdz: files.usdz, replacing: nil)
            let pointer = projectPointer(root, saved.project)
            let originalPointer = try Data(contentsOf: pointer)
            // Lock only the commit pointer. Model staging writes still use the real filesystem.
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: pointer.path) }
            do { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: pointer.path) }
            catch { throw XCTSkip("This filesystem does not support an immutable-file commit failure") }
            do {
                _ = try await store.publish(spec: .robot, prompt: "提交必须失败", glb: files.glb,
                                            usdz: files.usdz, replacing: saved.project)
                XCTFail("Replacing an immutable commit pointer must fail")
            } catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: pointer), originalPointer)
            _ = try await ProjectStore(root: root).load(saved.project)
            let revisions = try contents(pointer.deletingLastPathComponent()).filter {
                UUID(uuidString: $0.lastPathComponent) != nil
            }
            XCTAssertEqual(revisions.map(\.lastPathComponent), [saved.project.revision.uuidString],
                           "A failed commit must discard the newly-created unpublished revision")
        }
    }

    func testHashCorruptionInEitherFormatIsRejectedWhileParametersRemainRecoverable() async throws {
        try await withStore { store, root in
            let files = try nativeFiles(.lamp)
            let saved = try await store.publish(spec: .lamp, prompt: "环光工作灯", glb: files.glb,
                                                usdz: files.usdz, replacing: nil)
            for (url, original) in [(saved.glbURL, files.glb), (saved.usdzURL, files.usdz)] {
                var altered = original
                altered[altered.count - 1] ^= 0x01
                try altered.write(to: url, options: .atomic)
                do { _ = try await store.load(saved.project); XCTFail("Altered bytes must fail hash validation") }
                catch { XCTAssertFalse(error is CancellationError) }
                let recoverable = try await ProjectStore(root: root).list()
                XCTAssertEqual(recoverable.first?.specification, SceneSpec.lamp)
                try original.write(to: url, options: .atomic)
                _ = try await store.load(saved.project)
            }
        }
    }

    func testDraftRestoresExactInputAfterReopeningAndRejectsCorruption() async throws {
        try await withStore { store, root in
            var spec = SceneSpec.lamp
            spec.name = "未完成的自由造型"; spec.nodes[0].color = "#FFFFEE"
            let prompt = "把灯座改成象牙白，其他保留。\n稍后继续。"
            try await store.saveDraft(spec: spec, prompt: prompt)
            let draft = await ProjectStore(root: root).loadDraft()
            XCTAssertEqual(draft?.spec, spec)
            XCTAssertEqual(draft?.prompt, prompt)
            try Data("{broken".utf8).write(to: root.appending(path: "draft.json"), options: .atomic)
            let corrupted = await ProjectStore(root: root).loadDraft()
            XCTAssertNil(corrupted)
        }
    }

    func testInterruptedStagingAndBrokenMetadataDoNotReplaceLastPublishedRevision() async throws {
        try await withStore { store, root in
            let files = try nativeFiles(.chair)
            let saved = try await store.publish(spec: .chair, prompt: "最后完整版本", glb: files.glb,
                                                usdz: files.usdz, replacing: nil)
            let directory = projectPointer(root, saved.project).deletingLastPathComponent()
            let pending = directory.appending(path: ".pending-" + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            try files.glb.write(to: pending.appending(path: "model.glb"))
            let orphan = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try files.usdz.write(to: orphan.appending(path: "model.usdz"))
            let broken = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: broken.appending(path: "project.json"))
            try Data("ignored".utf8).write(to: root.appending(path: "unrelated.txt"))
            let reopened = ProjectStore(root: root)
            let projects = try await reopened.list()
            XCTAssertEqual(projects, [saved.project])
            XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path),
                           "A restarted library should remove incomplete staging files")
            let loaded = try await reopened.load(saved.project)
            XCTAssertEqual(try Data(contentsOf: loaded.glbURL), files.glb)
        }
    }

    func testDeletingOneProjectPreservesOtherProjectsAndUnfinishedDraft() async throws {
        try await withStore { store, root in
            let aFiles = try nativeFiles(.chair), bFiles = try nativeFiles(.robot)
            let a = try await store.publish(spec: .chair, prompt: "作品甲", glb: aFiles.glb,
                                            usdz: aFiles.usdz, replacing: nil)
            let b = try await store.publish(spec: .robot, prompt: "作品乙", glb: bFiles.glb,
                                            usdz: bFiles.usdz, replacing: nil)
            let beforeDeletion = try await store.list()
            XCTAssertEqual(beforeDeletion, [b.project, a.project])
            try await store.saveDraft(spec: .lamp, prompt: "保留草稿")
            try await store.remove(a.project)
            let reopened = ProjectStore(root: root)
            let remaining = try await reopened.list()
            XCTAssertEqual(remaining, [b.project])
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.glbURL.path))
            let surviving = try await reopened.load(b.project)
            XCTAssertEqual(try Data(contentsOf: surviving.usdzURL), bFiles.usdz)
            let draft = await reopened.loadDraft()
            XCTAssertEqual(draft?.prompt, "保留草稿")
            XCTAssertEqual(draft?.spec, SceneSpec.lamp)
        }
    }

    private func nativeFiles(_ spec: SceneSpec) throws -> (glb: Data, usdz: Data) {
        let meshes = try SceneGenerator.generate(for: spec)
        return (try ThreeLiveNative.exportGLB(meshes), try ThreeLiveNative.exportUSDZ(meshes))
    }

    private func projectPointer(_ root: URL, _ project: CreationProject) -> URL {
        root.appending(path: project.id.uuidString).appending(path: "project.json")
    }

    private func contents(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    private func withStore(_ test: @MainActor (ProjectStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ProjectStoreTests-" + UUID().uuidString,
                                                                         directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await test(ProjectStore(root: directory), directory)
    }
}
