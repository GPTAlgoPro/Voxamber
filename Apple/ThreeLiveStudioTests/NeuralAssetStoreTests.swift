import CryptoKit
import Foundation
import XCTest
#if canImport(ThreeLiveStudio)
@testable import ThreeLiveStudio
#else
@testable import NeuralAssetStoreHarness
#endif

/// Small file fixtures exercise admission/copy semantics; no neural inference.
@MainActor final class NeuralAssetStoreTests: XCTestCase {
    func testBundledProductionCatalogSeparatesExactPinsFromPublication() throws {
        #if canImport(ThreeLiveStudio)
        let bundle = Bundle.main
        #else
        let bundle = Bundle.module
        #endif
        let manifests = try NeuralModelManifest.loadAll(bundle: bundle)
        XCTAssertEqual(manifests.map(\.group), [.intent, .image, .shape])
        XCTAssertEqual(manifests.map { $0.files.count }, [10, 27, 2])
        XCTAssertEqual(manifests.map(\.byteCount), [645_315_928, 3_052_951_670, 2_490_380_596])
        XCTAssertEqual(Set(manifests.map(\.apple.assetPackID)).count, 3)
        XCTAssertEqual(Set(manifests.map(\.apple.contractRelativePath)).count, 3)
        #if canImport(ThreeLiveStudio)
        XCTAssertTrue(manifests.allSatisfy { $0.apple.available })
        for group in NeuralModelGroup.allCases {
            let url = try XCTUnwrap(bundle.url(forResource: group.manifestName, withExtension: "json", subdirectory: "NeuralModels")
                ?? bundle.url(forResource: group.manifestName, withExtension: "json"))
            let frozen = try JSONDecoder().decode(NeuralModelManifest.self, from: Data(contentsOf: url))
            XCTAssertFalse(frozen.apple.available, "The approved uploaded contract must remain immutable")
            XCTAssertEqual(try frozen.pinIdentity, try XCTUnwrap(manifests.first { $0.group == group }).pinIdentity)
        }
        #else
        XCTAssertTrue(manifests.allSatisfy { !$0.apple.available })
        #endif
        XCTAssertFalse(manifests.contains { $0.id == "qwen3.5-4b-mlx-int4" })
        XCTAssertEqual(manifests[2].files.first?.sha256, "30b93ce8a801551b905c35d1203d71d947a6b35b3d271aa5820b11d40faf45c7")
    }

    func testPublicationBindsExactModelsAndDoesNotChangeContentIdentity() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let rows = try fixture.manifests.map { model in
            NeuralModelDelivery.Pack(group: model.group, modelID: model.id, assetPackID: model.apple.assetPackID,
                modelPinIdentitySHA256: try model.pinIdentity, serverState: model.group == .shape ? "PENDING" : "COMPLETE", version: "1")
        }
        let delivery = NeuralModelDelivery(schemaVersion: 1, bundleID: "com.kaisun.voxamber", platform: "IOS", packs: rows)
        let resolved = try delivery.applying(to: fixture.manifests)
        for (original, published) in zip(fixture.manifests, resolved) {
            XCTAssertEqual(try original.pinIdentity, try published.pinIdentity)
            XCTAssertEqual(original.files, published.files)
            XCTAssertEqual(published.apple.available, published.group != .shape)
        }
    }

    func testPublicationRejectsWrongPinAndDuplicateOrMissingGroups() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let rows = try fixture.manifests.map { model in
            NeuralModelDelivery.Pack(group: model.group, modelID: model.id, assetPackID: model.apple.assetPackID,
                modelPinIdentitySHA256: try model.pinIdentity, serverState: "COMPLETE", version: "1")
        }
        var wrongPin = rows
        let first = rows[0]
        wrongPin[0] = .init(group: first.group, modelID: first.modelID, assetPackID: first.assetPackID,
            modelPinIdentitySHA256: String(repeating: "0", count: 64), serverState: "COMPLETE", version: "1")
        for candidates in [wrongPin, [rows[0], rows[0], rows[2]], Array(rows.dropLast())] {
            let delivery = NeuralModelDelivery(schemaVersion: 1, bundleID: "com.kaisun.voxamber", platform: "IOS", packs: candidates)
            XCTAssertThrowsError(try delivery.applying(to: fixture.manifests))
        }
        let foreign = NeuralModelDelivery(schemaVersion: 1, bundleID: "com.example.other", platform: "IOS", packs: rows)
        XCTAssertThrowsError(try foreign.applying(to: fixture.manifests))
    }

    func testReadinessRequiresAllThreeExactPrivateGroups() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try NeuralAssetStore(root: fixture.root, manifests: fixture.manifests)
        var check = try await store.checkInstallation()
        XCTAssertFalse(check.ready); XCTAssertTrue(check.directories.isEmpty)
        for group in NeuralModelGroup.allCases {
            _ = try await store.importGroup(group, from: fixture.source(group))
            check = try await store.checkInstallation()
            XCTAssertEqual(check.directories.count, (NeuralModelGroup.allCases.firstIndex(of: group) ?? 0) + 1)
        }
        XCTAssertTrue(check.ready)
        for group in NeuralModelGroup.allCases {
            XCTAssertEqual(check.directories[group], fixture.root.appending(path: fixture.manifest(group).id, directoryHint: .isDirectory))
        }
    }

    func testLegacy4BDoesNotAdmitAnyNewGroup() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let legacy = fixture.root.appending(path: "qwen3.5-4b-mlx-int4")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old model".utf8).write(to: legacy.appending(path: "model.safetensors"))
        let store = try NeuralAssetStore(root: fixture.root, manifests: fixture.manifests)
        let check = try await store.checkInstallation()
        XCTAssertFalse(check.ready); XCTAssertEqual(check.directories.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testCorruptionAndUnlistedInstalledFilesRevokeReadiness() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try NeuralAssetStore(root: fixture.root, manifests: fixture.manifests)
        for group in NeuralModelGroup.allCases { _ = try await store.importGroup(group, from: fixture.source(group)) }
        let before = try await store.checkInstallation(); XCTAssertTrue(before.ready)
        let image = try XCTUnwrap(before.directories[.image])
        let model = image.appending(path: "weights/model.bin")
        let original = try Data(contentsOf: model)
        try Data(repeating: 0x44, count: original.count).write(to: model)
        let corrupt = try await store.checkInstallation()
        XCTAssertFalse(corrupt.ready); XCTAssertNil(corrupt.directories[.image])
        try original.write(to: model)
        try Data("unlisted".utf8).write(to: image.appending(path: "extra.bin"))
        let extra = try await store.checkInstallation(); XCTAssertFalse(extra.ready)
        XCTAssertNil(extra.directories[.image])
    }

    func testWrongSourceAndSymlinkNeverPublishShape() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try NeuralAssetStore(root: fixture.root, manifests: fixture.manifests)
        do { _ = try await store.importGroup(.shape, from: fixture.source(.intent)); XCTFail("Different group must fail") }
        catch { XCTAssertFalse(error is CancellationError) }
        let file = fixture.source(.shape).appending(path: "weights/model.bin")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.source(.intent).appending(path: "weights/model.bin"))
        do { _ = try await store.importGroup(.shape, from: fixture.source(.shape)); XCTFail("Links must fail") }
        catch { XCTAssertFalse(error is CancellationError) }
        let check = try await store.checkInstallation()
        XCTAssertFalse(check.ready); XCTAssertNil(check.directories[.shape])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: fixture.manifest(.shape).id).path))
    }

    func testCancelledImportSettlesAndAllowsNextOperation() async throws {
        let fixture = try Fixture(large: true); defer { fixture.remove() }
        let store = try NeuralAssetStore(root: fixture.root, manifests: fixture.manifests)
        let owner = CancellationOwner()
        let task = Task {
            try await store.importGroup(.intent, from: fixture.source(.intent)) { progress in
                if progress > 0 && progress < 1 { owner.cancel() }
            }
        }
        owner.set(task)
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let check = try await store.checkInstallation(); XCTAssertFalse(check.ready)
        _ = try await store.importGroup(.image, from: fixture.source(.image))
        let after = try await store.checkInstallation(); XCTAssertNotNil(after.directories[.image])
    }

    func testInvalidCatalogsRejectedBeforeFilesystemMutation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        XCTAssertThrowsError(try NeuralAssetStore(root: fixture.root, manifests: Array(fixture.manifests.prefix(2))))
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.manifests[0])) as? [String: Any])
        var files = try XCTUnwrap(raw["files"] as? [[String: Any]])
        files[0]["path"] = "../outside.bin"; raw["files"] = files
        let bad = try JSONDecoder().decode(NeuralModelManifest.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try bad.validate())
        raw["files"] = [files[0], files[0]]
        let duplicates = try JSONDecoder().decode(NeuralModelManifest.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try duplicates.validate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testPackIdentityTracksPinsAndIgnoresPublicationFlag() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let manifest = fixture.manifest(.shape)
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        var apple = try XCTUnwrap(raw["apple"] as? [String: Any]); apple["available"] = true; raw["apple"] = apple
        let published = try JSONDecoder().decode(NeuralModelManifest.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(try manifest.pinIdentity, try published.pinIdentity)
        var files = try XCTUnwrap(raw["files"] as? [[String: Any]]); files[0]["sha256"] = String(repeating: "a", count: 64); raw["files"] = files
        let altered = try JSONDecoder().decode(NeuralModelManifest.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNotEqual(try manifest.pinIdentity, try altered.pinIdentity)
    }

    #if canImport(ThreeLiveStudio)
    func testUnpublishedDownloadCannotReportSuccessOrMutateStore() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let manager = NeuralModelManager(root: fixture.root, manifests: fixture.manifests)
        manager.download(group: .image)
        XCTAssertFalse(manager.busy); XCTAssertFalse(manager.ready); XCTAssertNil(manager.resources)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testGroupScopedCancellationAndJoin() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let gate = ResourceGate()
        let manager = NeuralModelManager(beforeResourceMutation: { await gate.wait() }, root: fixture.root, manifests: fixture.manifests)
        manager.importModel(group: .intent, from: fixture.source(.intent))
        await gate.waitUntilEntered()
        manager.cancel(group: .image)
        XCTAssertTrue(manager.busy)
        manager.cancel(group: .intent)
        await gate.release()
        await manager.waitForCurrentOperation()
        XCTAssertFalse(manager.busy); XCTAssertFalse(manager.ready); XCTAssertNil(manager.resources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: fixture.manifest(.intent).id).path))
    }
    #endif

    private struct Fixture: Sendable {
        let directory: URL
        let root: URL
        let manifests: [NeuralModelManifest]
        init(large: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "neural-fixture-" + UUID().uuidString)
            root = directory.appending(path: "private")
            var built: [NeuralModelManifest] = []
            for (index, group) in NeuralModelGroup.allCases.enumerated() {
                let source = directory.appending(path: group.rawValue)
                try FileManager.default.createDirectory(at: source.appending(path: "weights"), withIntermediateDirectories: true)
                let bytes = Data(repeating: UInt8(index + 1), count: large && group == .intent ? 16 * 1024 * 1024 : 128)
                try bytes.write(to: source.appending(path: "weights/model.bin"))
                let file = NeuralModelManifest.File(path: "weights/model.bin", byteCount: Int64(bytes.count),
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), sourceURL: nil)
                let id = "fixture-" + group.rawValue
                built.append(NeuralModelManifest(formatVersion: 1, group: group, id: id, displayName: id,
                    identityStatus: "synthetic-not-neural", sourceReferenceURL: URL(string: "https://example.invalid/fixture")!,
                    apple: .init(assetPackID: "Fixture-" + group.rawValue, modelRootRelativePath: "models/" + id,
                                 available: false, contractRelativePath: "model-contract.json"), files: [file]))
            }
            manifests = built
        }
        func source(_ group: NeuralModelGroup) -> URL { directory.appending(path: group.rawValue) }
        func manifest(_ group: NeuralModelGroup) -> NeuralModelManifest { manifests.first { $0.group == group }! }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

private final class CancellationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, Error>?
    private var cancelled = false
    func set(_ task: Task<URL, Error>) {
        lock.lock(); self.task = task; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock(); current?.cancel()
    }
}

#if canImport(ThreeLiveStudio)
private actor ResourceGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { waiting?.resume(); waiting = nil }
}
#endif
