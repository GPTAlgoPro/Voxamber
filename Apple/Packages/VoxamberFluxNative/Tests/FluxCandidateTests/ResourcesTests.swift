import XCTest
import Foundation
import CryptoKit
@testable import FluxCandidateResources

final class ResourcesTests: XCTestCase {
    func testPinnedManifestAndPayloadBudget() throws {
        let manifest = try FluxResourceManifest.pinned()
        XCTAssertEqual(manifest.files.count, 14)
        XCTAssertEqual(Set(manifest.files.map(\.relativePath)).count, 14)
        XCTAssertEqual(manifest.files.filter { $0.path.hasSuffix("safetensors") }.count, 4)
        XCTAssertEqual(manifest.files.filter { $0.path.hasSuffix("safetensors") }.map(\.byteCount).reduce(0, +), 4_692_595_250)
        XCTAssertTrue(manifest.files.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 })
    }

    func testWholeHashAdmissionAndIdentity() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let admitted = try FluxResourceVerifier.verify(root: fixture.root, manifest: fixture.manifest)
        try admitted.assertUnchanged()
        XCTAssertEqual(admitted.transformerDirectory.lastPathComponent, "transformer")
    }

    func testSameSizeCorruptionFailsClosed() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let path = f.root.appendingPathComponent("Qwen3/model.safetensors")
        var bytes = try Data(contentsOf: path); bytes[0] ^= 1; try bytes.write(to: path)
        XCTAssertThrowsError(try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest)) {
            XCTAssertEqual($0 as? FluxResourceError, .hashMismatch("Qwen3/model.safetensors"))
        }
    }

    func testMissingRequiredFileNeverSearchesOtherCaches() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Qwen3/config.json"))
        XCTAssertThrowsError(try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest))
    }

    func testLeafAndDirectorySymlinksRejected() throws {
        for directory in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let original = f.root.appendingPathComponent(directory ? "Qwen3" : "Qwen3/model.safetensors")
            let moved = f.root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            XCTAssertThrowsError(try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest))
        }
    }

    func testExtraTensorIsRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data([1, 2, 3]).write(to: f.root.appendingPathComponent("Qwen3/foreign.safetensors"))
        XCTAssertThrowsError(try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest)) {
            XCTAssertEqual($0 as? FluxResourceError, .unexpectedPayload("Qwen3"))
        }
    }

    func testForeignNestedVAECannotBypassPinnedRoot() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let foreign = f.root.appendingPathComponent("VAE/vae")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("foreign unverified model".utf8).write(to: foreign.appendingPathComponent("diffusion_pytorch_model.safetensors"))
        XCTAssertThrowsError(try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest)) {
            XCTAssertEqual($0 as? FluxResourceError, .unexpectedPayload("VAE/vae"))
        }
    }

    func testIdentityMutationAfterAdmissionIsRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admitted = try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest)
        try Data([1]).write(to: f.root.appendingPathComponent("Qwen3/model.safetensors"))
        XCTAssertThrowsError(try admitted.assertUnchanged())
    }

    func testExtraTensorAddedAfterAdmissionIsRejectedAtBoundary() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admitted = try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest)
        try Data([1]).write(to: f.root.appendingPathComponent("Qwen3/z.safetensors"))
        XCTAssertThrowsError(try admitted.assertUnchanged()) {
            XCTAssertEqual($0 as? FluxResourceError, .unexpectedPayload("Qwen3"))
        }
    }

    func testPathTraversalRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.manifestData) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        files[0]["path"] = "../outside"; object["files"] = files
        let manifest = try JSONDecoder().decode(FluxResourceManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try FluxResourceVerifier.verify(root: f.root, manifest: manifest)) {
            XCTAssertEqual($0 as? FluxResourceError, .unsafePath)
        }
    }

    func testAlreadyCancelledVerificationRejects() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = TestGate()
        let task = Task {
            await gate.wait()
            return try FluxResourceVerifier.verify(root: f.root, manifest: f.manifest)
        }
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled verification accepted") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }

    private func fixture() throws -> (root: URL, manifest: FluxResourceManifest, manifestData: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try FluxResourceManifest.pinned()
        var files: [[String: Any]] = []
        for file in source.files {
            let bytes = Data(("synthetic CPU fixture: " + file.relativePath).utf8)
            let destination = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination)
            files.append(["component": file.component, "repository": file.repository, "revision": file.revision,
                          "path": file.path, "byteCount": bytes.count,
                          "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()])
        }
        let data = try JSONSerialization.data(withJSONObject: ["files": files])
        return (root, try JSONDecoder().decode(FluxResourceManifest.self, from: data), data)
    }
}

actor TestGate {
    var released = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { released = true; let continuations = waiting; waiting = []; continuations.forEach { $0.resume() } }
}
