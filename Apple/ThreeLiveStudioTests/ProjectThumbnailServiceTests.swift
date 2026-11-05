import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
#if canImport(ThreeLiveStudio)
@testable import ThreeLiveStudio
#else
@testable import ThumbnailNativeChecks
#endif

private actor ThumbnailGate {
    private var continuations: [UUID: CheckedContinuation<Data, Error>] = [:]
    private(set) var calls = 0
    private(set) var cancellations = 0
    let honorsCancellation: Bool
    init(honorsCancellation: Bool = true) { self.honorsCancellation = honorsCancellation }
    func render() async throws -> Data {
        try Task.checkCancellation()
        let id = UUID(); calls += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuations[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        cancellations += 1
        if honorsCancellation { continuations.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }
    func finish(_ data: Data) {
        let values = continuations.values; continuations.removeAll()
        values.forEach { $0.resume(returning: data) }
    }
}

@MainActor final class ProjectThumbnailServiceTests: XCTestCase {
    func testRealIdentityIncludesRevisionDigestURLAndPixelSize() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try source(in: root, bytes: Data("one".utf8))
        let revision = ProjectThumbnailSource(projectID: first.projectID, revision: UUID(), fileDigest: first.fileDigest, fileURL: first.fileURL)
        let digest = ProjectThumbnailSource(projectID: first.projectID, revision: first.revision, fileDigest: String(repeating: "f", count: 64), fileURL: first.fileURL)
        let url = ProjectThumbnailSource(projectID: first.projectID, revision: first.revision, fileDigest: first.fileDigest, fileURL: first.fileURL.appendingPathExtension("other"))
        XCTAssertNotEqual(first.cacheKey(), revision.cacheKey()); XCTAssertNotEqual(first.cacheKey(), digest.cacheKey())
        XCTAssertNotEqual(first.cacheKey(), url.cacheKey()); XCTAssertNotEqual(first.cacheKey(), first.cacheKey(pixels: 320))
    }

    func testTwoCallersCoalesceAndOneCancellationKeepsOtherRequestAlive() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try source(in: root, bytes: Data("same source".utf8)), gate = ThumbnailGate()
        let cache = ProjectThumbnailService(directory: root.appending(path: "cache"), renderer: .init { _,_ in try await gate.render() })
        let a = Task { try await cache.thumbnail(for: input) }, b = Task { try await cache.thumbnail(for: input) }
        try await wait {
            let waiting = await cache.pendingCounts().waiters, calls = await gate.calls
            return waiting == 2 && calls == 1
        }
        a.cancel()
        do { _ = try await a.value; XCTFail("Cancelled waiter must settle") } catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = await gate.cancellations; XCTAssertEqual(cancelled, 0)
        let image = try png(0x33)
        await gate.finish(image)
        let rendered = try await b.value; XCTAssertEqual(rendered, image)
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
        let cached = try await cache.thumbnail(for: input); XCTAssertEqual(cached, image)
        let finalCalls = await gate.calls; XCTAssertEqual(finalCalls, 1)
    }

    func testLastWaiterCancellationCancelsOwnedRenderAndQueueCanContinue() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try source(in: root, bytes: Data("first".utf8)), gate = ThumbnailGate()
        let cache = ProjectThumbnailService(directory: root.appending(path: "cache"), renderer: .init { _,_ in try await gate.render() })
        let task = Task { try await cache.thumbnail(for: input) }
        try await wait { await gate.calls == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        try await wait {
            let cancelled = await gate.cancellations, active = await cache.pendingCounts().active
            return cancelled == 1 && !active
        }
        let next = Task { try await cache.thumbnail(for: input) }
        try await wait { await gate.calls == 2 }
        let image = try png(0x44); await gate.finish(image)
        let nextImage = try await next.value; XCTAssertEqual(nextImage, image)
    }

    func testLateCancelledResultCannotPersistOrServeDeletedProject() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try source(in: root, bytes: Data("deleted source".utf8)), gate = ThumbnailGate(honorsCancellation: false)
        let cacheRoot = root.appending(path: "cache")
        let cache = ProjectThumbnailService(directory: cacheRoot, renderer: .init { _,_ in try await gate.render() })
        let task = Task { try await cache.thumbnail(for: input) }
        try await wait { await gate.calls == 1 }
        try FileManager.default.removeItem(at: input.fileURL)
        await cache.invalidate(projectID: input.projectID)
        do { _ = try await task.value; XCTFail("Deleted waiter cannot succeed") } catch { XCTAssertTrue(error is CancellationError) }
        await gate.finish(try png(0x55)) // deliberately emulate a late framework callback
        try await wait { await !cache.pendingCounts().active }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appending(path: input.projectID.uuidString).path))
        do { _ = try await cache.thumbnail(for: input); XCTFail("Deleted source must not be served from cache") }
        catch { XCTAssertTrue(error is ProjectThumbnailError) }
    }

    func testDiskReuseDoesNotRenderAgainAndChangedSourceDigestFailsClosed() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try source(in: root, bytes: Data("immutable source".utf8)), cacheRoot = root.appending(path: "cache")
        let image = try png(0x66)
        let first = ProjectThumbnailService(directory: cacheRoot, renderer: .init { _,_ in image })
        let firstImage = try await first.thumbnail(for: input); XCTAssertEqual(firstImage, image)
        let reopened = ProjectThumbnailService(directory: cacheRoot, renderer: .init { _,_ in throw ProjectThumbnailError.unavailable })
        let diskImage = try await reopened.thumbnail(for: input); XCTAssertEqual(diskImage, image)
        try Data("tampered".utf8).write(to: input.fileURL, options: .atomic)
        do { _ = try await reopened.thumbnail(for: input); XCTFail("Content identity must be checked even for cached PNG") }
        catch { XCTAssertTrue(error is ProjectThumbnailError) }
    }

    func testCancelledOldRevisionCannotReplaceNewRevisionWhenRendererFinishesLate() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try source(in: root, bytes: Data("revision one".utf8))
        let file = root.appending(path: "new.usdz"); let newBytes = Data("revision two".utf8)
        try newBytes.write(to: file)
        let new = ProjectThumbnailSource(projectID: old.projectID, revision: UUID(),
            fileDigest: SHA256.hash(data: newBytes).map { String(format: "%02x", $0) }.joined(), fileURL: file)
        let gate = ThumbnailGate(honorsCancellation: false)
        let cache = ProjectThumbnailService(directory: root.appending(path: "cache"), renderer: .init { _,_ in try await gate.render() })
        let stale = Task { try await cache.thumbnail(for: old) }
        try await wait { await gate.calls == 1 }
        stale.cancel()
        do { _ = try await stale.value; XCTFail("Old revision waiter must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let current = Task { try await cache.thumbnail(for: new) }
        await gate.finish(try png(0x22))
        try await wait { await gate.calls == 2 }
        let correctImage = try png(0x99); await gate.finish(correctImage)
        let returned = try await current.value; XCTAssertEqual(returned, correctImage)
        let cached = try await cache.thumbnail(for: new); XCTAssertEqual(cached, correctImage)
    }

    func testUndecodableDiskImageIsRemovedAndRenderedAgain() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try source(in: root, bytes: Data("immutable source".utf8)), cacheRoot = root.appending(path: "cache")
        let image = try png(0x88)
        let first = ProjectThumbnailService(directory: cacheRoot, renderer: .init { _,_ in image })
        _ = try await first.thumbnail(for: input)
        let file = cacheRoot.appending(path: input.projectID.uuidString).appending(path: input.cacheKey() + ".png")
        // Preserve PNG/IHDR and its valid dimensions; remove all pixel data.
        try Data(image.prefix(33)).write(to: file, options: .atomic)
        let gate = ThumbnailGate()
        let reopened = ProjectThumbnailService(directory: cacheRoot, renderer: .init { _,_ in try await gate.render() })
        let request = Task { try await reopened.thumbnail(for: input) }
        try await wait { await gate.calls == 1 }
        await gate.finish(image)
        let rendered = try await request.value; XCTAssertEqual(rendered, image)
        XCTAssertEqual(try Data(contentsOf: file), image)
    }

    func testInvalidRendererDataIsNotCachedAndFailureCanRetryWithoutChangingSource() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("model bytes stay".utf8), input = try source(in: root, bytes: original), cacheRoot = root.appending(path: "cache")
        let failed = ProjectThumbnailService(directory: cacheRoot, renderer: .init { _,_ in Data("icon-or-error".utf8) })
        do { _ = try await failed.thumbnail(for: input); XCTFail("Non-PNG must fail") } catch { XCTAssertTrue(error is ProjectThumbnailError) }
        XCTAssertEqual(try Data(contentsOf: input.fileURL), original)
        let retryImage = try png(0x77)
        let valid = ProjectThumbnailService(directory: cacheRoot, renderer: .init { _,_ in retryImage })
        let retried = try await valid.thumbnail(for: input); XCTAssertFalse(retried.isEmpty)
        XCTAssertEqual(try Data(contentsOf: input.fileURL), original)
    }

    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Owned request state did not converge within one second")
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appending(path: "ThumbnailTests-"+UUID().uuidString) }
    private func source(in root: URL, bytes: Data) throws -> ProjectThumbnailSource {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: UUID().uuidString + ".usdz"); try bytes.write(to: file)
        return ProjectThumbnailSource(projectID: UUID(), revision: UUID(),
            fileDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), fileURL: file)
    }
    private nonisolated func png(_ color: UInt8) throws -> Data {
        let bytes = Data(repeating: color, count: 32*32*4)
        let provider = CGDataProvider(data: bytes as CFData)!
        let image = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let result = NSMutableData(); let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProjectThumbnailError.invalidImage }
        return result as Data
    }
}
