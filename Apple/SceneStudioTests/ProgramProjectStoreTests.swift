import XCTest
import Foundation
import CryptoKit
#if canImport(SceneStudio)
@testable import SceneStudio
#endif

/// Synthetic storage fixtures; not scene-engine compilation or UI acceptance.
@MainActor final class ProgramProjectStoreTests: XCTestCase {
    func testEmptyReadsDoNotTouchLegacyOrCreateRoot() async throws {
        let f = try StoreFixture(); defer { f.remove() }
        let legacy = f.parent.appendingPathComponent("Creations")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: legacy.appendingPathComponent("sentinel"))
        let store = ProgramProjectStore(root: f.root)
        let projects = try await store.list(), missing = try await store.load(id: UUID())
        XCTAssertTrue(projects.isEmpty); XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("sentinel")), Data("keep".utf8))
    }
    func testExactSourceImportURLsAndPortableMetadata() async throws {
        let f = try StoreFixture(); defer { f.remove() }; let store = ProgramProjectStore(root: f.root)
        let original = Data([0xef,0xbb,0xbf,96,96,96] + Array("js\n supplied text\n".utf8) + [96,96,96])
        let source = " \nconst scene = new THREE.Scene();\nreturn scene;\n "
        let p = try await store.publish(title: "Imported", originalImport: original, source: source,
            glb: Self.glb, usdz: Self.usdz, compilerVersion: "sdk", compilerRevision: "fixed")
        XCTAssertTrue(p.committed); XCTAssertEqual(p.kind, "importedSceneProgram")
        XCTAssertNil(p.userDeclaredProvider); XCTAssertTrue(p.sourceURL.isFileURL)
        XCTAssertEqual(try Data(contentsOf: p.originalImportURL), original)
        XCTAssertEqual(try String(contentsOf: p.sourceURL, encoding: .utf8), source)
        let read = try await store.readSource(p); XCTAssertEqual(read, source)
        let value = try await store.load(id: p.id), loaded = try XCTUnwrap(value)
        XCTAssertEqual(loaded.revision, p.revision); XCTAssertEqual(loaded.glbURL, p.glbURL)
        let encoded = try JSONEncoder().encode(p)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(f.parent.path))
        let unbound = try JSONDecoder().decode(ProgramProject.self, from: encoded)
        XCTAssertFalse(unbound.committed); XCTAssertNil(unbound.sourceURL.scheme)
    }
    func testImmutableRevisionAndTwoStoreStaleCAS() async throws {
        let f = try StoreFixture(); defer { f.remove() }
        let a = ProgramProjectStore(root: f.root), b = ProgramProjectStore(root: f.root)
        let p = try await Self.publish(a, source: "first"), original = try Data(contentsOf: p.sourceURL)
        let q = try await Self.publish(b, source: "second", parent: p)
        XCTAssertEqual(p.id, q.id); XCTAssertNotEqual(p.revision, q.revision)
        XCTAssertEqual(p.createdAt, q.createdAt); XCTAssertEqual(q.parentRevision, p.revision)
        XCTAssertEqual(try Data(contentsOf: p.sourceURL), original)
        do { _ = try await Self.publish(a, parent: p); XCTFail("stale parent accepted") }
        catch { XCTAssertEqual(error as? ProgramProjectStoreError, .staleRevision) }
        let current = try await a.load(id: p.id); XCTAssertEqual(current?.revision, q.revision)
    }
    func testDeletedParentCannotBeResurrected() async throws {
        let f = try StoreFixture(); defer { f.remove() }; let store = ProgramProjectStore(root: f.root)
        let p = try await Self.publish(store)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(p.id.uuidString))
        do { _ = try await Self.publish(store, parent: p); XCTFail("deleted parent recreated") }
        catch { XCTAssertEqual(error as? ProgramProjectStoreError, .staleRevision) }
        let missing = try await store.load(id: p.id); XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.sourceURL.path))
    }
    func testAllFourFilesAreHashedOnLoad() async throws {
        for i in 0..<4 {
            let f = try StoreFixture(); defer { f.remove() }; let store = ProgramProjectStore(root: f.root)
            let p = try await Self.publish(store), url = [p.originalImportURL,p.sourceURL,p.glbURL,p.usdzURL][i]
            var data = try Data(contentsOf: url); data[0] ^= 1; try data.write(to: url)
            do { _ = try await store.load(id: p.id); XCTFail("corrupt artifact accepted") }
            catch { XCTAssertEqual(error as? ProgramProjectStoreError, .corruptArtifact) }
        }
    }
    func testArtifactAndRevisionSymlinksRejected() async throws {
        for revisionDirectory in [false, true] {
            let f = try StoreFixture(); defer { f.remove() }; let store = ProgramProjectStore(root: f.root)
            let p = try await Self.publish(store)
            let target = revisionDirectory ? p.sourceURL.deletingLastPathComponent() : p.sourceURL
            let moved = f.parent.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
            do { _ = try await store.load(id: p.id); XCTFail("symlink accepted") }
            catch { XCTAssertEqual(error as? ProgramProjectStoreError, .unsafePath) }
        }
    }
    func testRootSymlinkRejected() async throws {
        let f = try StoreFixture(); defer { f.remove() }
        let outside = f.parent.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: outside)
        let store = ProgramProjectStore(root: f.root)
        do { _ = try await store.list(); XCTFail("root symlink accepted") }
        catch { XCTAssertEqual(error as? ProgramProjectStoreError, .unsafePath) }
    }
    func testCancelBeforeCommitLeavesPriorRevisionAndCleansPending() async throws {
        let f = try StoreFixture(); defer { f.remove() }
        let priorStore = ProgramProjectStore(root: f.root), p = try await Self.publish(priorStore)
        let gate = StoreLatch(.staged), store = ProgramProjectStore(root: f.root, publicationObserver: { gate.observe($0) })
        let task = Task.detached { try await Self.publishDetached(store, parent: p) }
        let arrived = await gate.wait(); task.cancel(); gate.release(); XCTAssertTrue(arrived)
        do { _ = try await task.value; XCTFail("cancelled publish succeeded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let current = try await priorStore.load(id: p.id); XCTAssertEqual(current?.revision, p.revision)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent(p.id.uuidString).path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".pending-") || $0.hasPrefix(".pointer-") })
    }
    func testLateCancellationCannotUndoCommittedRecord() async throws {
        let f = try StoreFixture(); defer { f.remove() }
        let gate = StoreLatch(.committed), store = ProgramProjectStore(root: f.root, publicationObserver: { gate.observe($0) })
        let task = Task.detached { try await Self.publishDetached(store) }
        let arrived = await gate.wait(); task.cancel(); gate.release(); XCTAssertTrue(arrived)
        let p = try await task.value; XCTAssertTrue(p.committed)
        let loaded = try await store.load(id: p.id); XCTAssertEqual(loaded?.revision, p.revision)
    }
    func testForeignFileAndMissingPointerAreNotRepaired() async throws {
        let f = try StoreFixture(); defer { f.remove() }; let store = ProgramProjectStore(root: f.root)
        let p = try await Self.publish(store), extra = p.sourceURL.deletingLastPathComponent().appendingPathComponent("foreign")
        try Data([1]).write(to: extra)
        do { _ = try await store.load(id: p.id); XCTFail("foreign file accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(p.id.uuidString + "/project.json"))
        do { _ = try await store.load(id: p.id); XCTFail("broken pointer accepted") }
        catch { XCTAssertEqual(error as? ProgramProjectStoreError, .invalidMetadata) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.sourceURL.path))
    }
    private static func publish(_ store: ProgramProjectStore, source: String = "source", parent: ProgramProject? = nil) async throws -> ProgramProject {
        try await store.publish(title: "Program", originalImport: Data("original".utf8), source: source,
            glb: glb, usdz: usdz, compilerVersion: "official-sdk", compilerRevision: "fixed",
            userDeclaredProvider: "User-declared", parent: parent)
    }
    private nonisolated static func publishDetached(_ store: ProgramProjectStore, parent: ProgramProject? = nil) async throws -> ProgramProject {
        try await store.publish(title: "Program", originalImport: Data("original".utf8), source: "source",
            glb: glb, usdz: usdz, compilerVersion: "sdk", compilerRevision: "fixed", parent: parent)
    }
    private nonisolated static var glb: Data {
        var json = Data(#"{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[]}]}"#.utf8)
        while !json.count.isMultiple(of: 4) { json.append(32) }
        func word(_ n: UInt32) -> Data { var v = n.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        return Data([0x67,0x6c,0x54,0x46]) + word(2) + word(UInt32(20 + json.count)) + word(UInt32(json.count)) + word(0x4e4f534a) + json
    }
    private nonisolated static var usdz: Data { Data([0x50,0x4b,0x03,0x04,0,0,0,0]) }
}
private struct StoreFixture {
    let parent: URL
    let root: URL
    init() throws {
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        root = parent.appendingPathComponent("ScenePrograms")
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}
private final class StoreLatch: @unchecked Sendable {
    private let phase: ProgramPublicationPhase
    private let arrived = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
    init(_ phase: ProgramPublicationPhase) { self.phase = phase }
    func observe(_ value: ProgramPublicationPhase) {
        guard value == phase else { return }; arrived.signal(); _ = proceed.wait(timeout: .now() + 5)
    }
    private nonisolated func waitForArrivalSynchronously() -> Bool {
        arrived.wait(timeout: .now() + 5) == .success
    }
    func wait() async -> Bool { await Task.detached { self.waitForArrivalSynchronously() }.value }
    func release() { proceed.signal() }
}
