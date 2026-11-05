import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import QuickLookThumbnailing

struct ProjectThumbnailSource: Hashable, Sendable {
    let projectID: UUID
    let revision: UUID
    let fileDigest: String
    let fileURL: URL

    func cacheKey(pixels: Int = 256) -> String {
        let fields = ["usdz-thumbnail-v1", projectID.uuidString, revision.uuidString,
                      fileDigest.lowercased(), fileURL.standardizedFileURL.absoluteString, String(pixels)]
        return SHA256.hash(data: Data(fields.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum ProjectThumbnailError: LocalizedError, Sendable {
    case missingSource, changedSource, unavailable, invalidImage, timedOut
    var errorDescription: String? { "作品预览暂不可用，请稍后重试。" }
}

struct ProjectThumbnailRenderer: Sendable {
    let render: @Sendable (URL, Int) async throws -> Data
    static let quickLook = Self { url, pixels in
        try await QuickLookThumbnailOperation.render(url: url, pixels: pixels)
    }
}

/// One owned Quick Look request at a time. Only model thumbnails are accepted;
/// system file-type icons can never masquerade as the project's rendered image.
@MainActor private final class QuickLookThumbnailOperation {
    private let request: QLThumbnailGenerator.Request
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false

    init(url: URL, pixels: Int) {
        request = QLThumbnailGenerator.Request(fileAt: url,
            size: CGSize(width: pixels, height: pixels), scale: 1, representationTypes: .thumbnail)
        request.contentType = UTType(filenameExtension: "usdz") ?? .item
        request.iconMode = false
        request.minimumDimension = 32
    }

    static func render(url: URL, pixels: Int) async throws -> Data {
        try Task.checkCancellation()
        let operation = QuickLookThumbnailOperation(url: url, pixels: pixels)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)); operation.cancel(error: ProjectThumbnailError.timedOut) }
            catch {}
        }
        do {
            let data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { operation.start($0) }
            } onCancel: {
                Task { @MainActor in operation.cancel(error: CancellationError()) }
            }
            timeout.cancel(); await timeout.value
            return data
        } catch {
            timeout.cancel(); await timeout.value
            throw error
        }
    }

    private func start(_ continuation: CheckedContinuation<Data, Error>) {
        guard !finished, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            // Convert on the callback's thread. Only Sendable Data crosses back
            // to MainActor, never the framework's mutable representation object.
            let data = representation?.type == .thumbnail
                ? representation.flatMap { Self.png($0.cgImage) } : nil
            Task { @MainActor [weak self] in
                if let data { self?.finish(.success(data)) }
                else { self?.finish(.failure(ProjectThumbnailError.unavailable)) }
            }
        }
    }

    private func cancel(error: any Error) {
        guard !finished else { return }
        QLThumbnailGenerator.shared.cancel(request)
        finish(.failure(error))
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        let waiting = continuation; continuation = nil
        waiting?.resume(with: result)
    }

    private nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Derived cache only: it never writes model revisions or a project's commit
/// pointer. Cancellation belongs to each caller; shared requests survive while
/// another visible card still needs them. The worker queue bounds renderer cost.
actor ProjectThumbnailService {
    static let shared = ProjectThumbnailService()
    private struct Job {
        let source: ProjectThumbnailSource
        let token: UUID
        var waiters: [UUID: CheckedContinuation<Data, Error>]
    }
    private struct Active {
        let key: String
        let token: UUID
        let task: Task<Void, Never>
    }
    private let directory: URL
    private let renderer: ProjectThumbnailRenderer
    private let pixels: Int
    private let maximumDiskBytes: Int
    private let memory = NSCache<NSString, NSData>()
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var active: Active?

    init(directory: URL = URL.cachesDirectory.appending(path: "VoxamberModelThumbnails-v1", directoryHint: .isDirectory),
         pixels: Int = 256, renderer: ProjectThumbnailRenderer = .quickLook,
         maximumMemoryBytes: Int = 8 * 1024 * 1024, maximumDiskBytes: Int = 64 * 1024 * 1024) {
        self.directory = directory; self.renderer = renderer
        self.pixels = min(320, max(192, pixels)); self.maximumDiskBytes = maximumDiskBytes
        memory.totalCostLimit = maximumMemoryBytes; memory.countLimit = 64
    }

    func thumbnail(for source: ProjectThumbnailSource) async throws -> Data {
        try Task.checkCancellation()
        let key = source.cacheKey(pixels: pixels), waiter = UUID()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var job = jobs[key] {
                    job.waiters[waiter] = continuation; jobs[key] = job
                } else {
                    jobs[key] = Job(source: source, token: UUID(), waiters: [waiter: continuation])
                    queue.append(key)
                }
                startNext()
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, waiter: waiter) }
        }
        // Cancellation and a cache/render completion can reach this actor in
        // either order. The caller's cancellation wins before returning data.
        try Task.checkCancellation()
        return data
    }

    func invalidate(projectID: UUID) {
        for (key, job) in jobs where job.source.projectID == projectID {
            jobs.removeValue(forKey: key); queue.removeAll { $0 == key }
            job.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            if active?.key == key, active?.token == job.token { active?.task.cancel() }
        }
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory.appending(path: projectID.uuidString, directoryHint: .isDirectory))
    }

    func reduceMemory() {
        let waiting = jobs.values.flatMap { $0.waiters.values }
        jobs.removeAll(); queue.removeAll(); memory.removeAllObjects()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        active?.task.cancel()
    }

    // Small deterministic observability for cancellation/coalescing tests.
    func pendingCounts() -> (jobs: Int, waiters: Int, active: Bool) {
        (jobs.count, jobs.values.reduce(0) { $0 + $1.waiters.count }, active != nil)
    }

    private func cancelWaiter(key: String, waiter: UUID) {
        guard var job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            jobs.removeValue(forKey: key); queue.removeAll { $0 == key }
            if active?.key == key, active?.token == job.token { active?.task.cancel() }
        } else { jobs[key] = job }
    }

    private func startNext() {
        guard active == nil else { return }
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard let job = jobs[key], !job.waiters.isEmpty else { continue }
            let token = job.token, source = job.source
            let task = Task { [weak self] in
                guard let self else { return }
                let result: Result<Data, Error>
                do { result = .success(try await self.produce(source: source, key: key)) }
                catch { result = .failure(error) }
                await self.finish(key: key, token: token, result: result)
            }
            active = Active(key: key, token: token, task: task)
            return
        }
    }

    private func finish(key: String, token: UUID, result: Result<Data, Error>) {
        if let job = jobs[key], job.token == token {
            jobs.removeValue(forKey: key)
            job.waiters.values.forEach { $0.resume(with: result) }
        }
        if active?.key == key, active?.token == token { active = nil }
        startNext()
    }

    private func produce(source: ProjectThumbnailSource, key: String) async throws -> Data {
        try validateSource(source)
        if let cached = memory.object(forKey: key as NSString) { return cached as Data }
        let file = cacheFile(source: source, key: key)
        if let data = try? Data(contentsOf: file), let cost = Self.pngCost(data, maximumDimension: pixels) {
            memory.setObject(data as NSData, forKey: key as NSString, cost: cost)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }
        try? FileManager.default.removeItem(at: file)
        let data = try await renderer.render(source.fileURL, pixels)
        try Task.checkCancellation()
        try validateSource(source)
        guard let cost = Self.pngCost(data, maximumDimension: pixels) else { throw ProjectThumbnailError.invalidImage }
        try Task.checkCancellation()
        // Derived disk-cache failures do not discard a valid rendered image.
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            pruneDiskCache()
        } catch {}
        memory.setObject(data as NSData, forKey: key as NSString, cost: cost)
        return data
    }

    private func validateSource(_ source: ProjectThumbnailSource) throws {
        try Task.checkCancellation()
        guard source.fileURL.isFileURL, FileManager.default.fileExists(atPath: source.fileURL.path) else { throw ProjectThumbnailError.missingSource }
        let file = try FileHandle(forReadingFrom: source.fileURL)
        defer { try? file.close() }
        var hasher = SHA256(), done = false
        while !done {
            try Task.checkCancellation()
            try autoreleasepool {
                let data = try file.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { done = true } else { hasher.update(data: data) }
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == source.fileDigest.lowercased() else { throw ProjectThumbnailError.changedSource }
    }

    private func cacheFile(source: ProjectThumbnailSource, key: String) -> URL {
        directory.appending(path: source.projectID.uuidString, directoryHint: .isDirectory).appending(path: key + ".png")
    }

    private func pruneDiskCache() {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, cost, _) in files where total > maximumDiskBytes {
            try? FileManager.default.removeItem(at: url); total -= cost
        }
    }

    private static func pngCost(_ data: Data, maximumDimension: Int) -> Int? {
        guard data.count > 32, data.count <= 4 * 1024 * 1024,
              data.starts(with: [137,80,78,71,13,10,26,10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 16, height >= 16, width <= maximumDimension, height <= maximumDimension,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              decoded.width == width, decoded.height == height else { return nil }
        return max(data.count, width * height * 4)
    }
}
