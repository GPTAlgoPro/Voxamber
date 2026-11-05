import Foundation
import CryptoKit
import Darwin

public struct ModelFile: Codable, Sendable, Equatable {
    public let path: String
    public let url: URL
    public let byteCount: Int64
    public let sha256: String
    public let mirrorURLs: [URL]

    public init(path: String, url: URL, byteCount: Int64, sha256: String, mirrorURLs: [URL] = []) {
        self.path = path; self.url = url; self.byteCount = byteCount
        self.sha256 = sha256; self.mirrorURLs = mirrorURLs
    }
}

public struct LocalModelManifest: Codable, Sendable, Equatable {
    public let id: String
    public let files: [ModelFile]
    public init(id: String, files: [ModelFile]) { self.id = id; self.files = files }
}

public enum VerifiedModelStoreError: LocalizedError, Sendable {
    case invalidManifest(String)
    case busy
    case notInstalled
    case invalidFile(String)
    case downloadFailed(String)
    case insufficientSpace(Int64)
    case unsafeFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "模型清单无效：" + reason
        case .busy: return "模型资源正在处理，请稍候。"
        case .notInstalled: return "模型尚未完整安装，请先下载或导入。"
        case .invalidFile(let path): return "模型文件不完整或校验失败：" + path
        case .downloadFailed(let path): return "模型文件下载未完成：\(path)。请稍后重试，或从“文件”导入。"
        case .insufficientSpace(let bytes):
            return "可用空间不足，请至少预留 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) 后重试。"
        case .unsafeFile(let path): return "模型资源包含不安全的文件或链接：" + path
        }
    }
}

/// Serializes model-pack installation and publishes only a completely verified directory.
/// Verified files in the private pending directory survive cancellation and failed downloads.
public actor VerifiedModelStore {
    public let root: URL
    private var operating = false
    private static let metadataName = ".verified-model-manifest.json"

    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    public func install(manifest: LocalModelManifest,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try begin(manifest)
        defer { operating = false }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return try await installPack(manifest: manifest, source: nil, session: session, progress: progress)
    }

    public func importDirectory(_ directory: URL, manifest: LocalModelManifest,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try begin(manifest)
        defer { operating = false }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        try Self.requireDirectory(directory)
        return try await installPack(manifest: manifest, source: directory, session: nil, progress: progress)
    }

    public func verifyInstalled(manifest: LocalModelManifest) async throws -> URL {
        try begin(manifest)
        defer { operating = false }
        let destination = root.appending(path: manifest.id, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw VerifiedModelStoreError.notInstalled
        }
        try await verifyPack(destination, manifest: manifest)
        return destination
    }

    public func remove(id: String) throws {
        guard !operating else { throw VerifiedModelStoreError.busy }
        try Self.validateID(id)
        let destination = root.appending(path: id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let prefix = ".pending-" + id + "-"
            for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                let suffix = entry.lastPathComponent.dropFirst(prefix.count)
                guard suffix.utf8.count == 64,
                      suffix.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else { continue }
                try FileManager.default.removeItem(at: entry)
            }
        }
    }

    private func begin(_ manifest: LocalModelManifest) throws {
        guard !operating else { throw VerifiedModelStoreError.busy }
        try Task.checkCancellation()
        try Self.validate(manifest)
        operating = true
    }

    private func installPack(manifest: LocalModelManifest, source: URL?, session: URLSession?,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Self.ensureDirectory(root)
        let destination = root.appending(path: manifest.id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try await verifyPack(destination, manifest: manifest)
                progress(1)
                return destination
            } catch is CancellationError { throw CancellationError() }
            catch { /* Preserve this old directory until the replacement is complete. */ }
        }
        let encodedManifest = try Self.manifestData(manifest)
        let fingerprint = SHA256.hash(data: encodedManifest).map { String(format: "%02x", $0) }.joined()
        let pending = root.appending(path: ".pending-" + manifest.id + "-" + fingerprint, directoryHint: .isDirectory)
        try Self.ensureDirectory(pending)
        for entry in try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
            where entry.lastPathComponent.hasPrefix(".incoming-") {
            try FileManager.default.removeItem(at: entry)
        }
        try encodedManifest.write(to: pending.appending(path: Self.metadataName), options: .atomic)
        var reusable: Set<String> = []
        var completed: Int64 = 0
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.byteCount }
        for file in manifest.files {
            try Self.ensureParent(of: file.path, inside: pending)
            let candidate = pending.appending(path: file.path)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            do {
                try await Self.utility { try Self.verify(candidate, file: file, within: pending) }
                reusable.insert(file.path)
                completed += file.byteCount
            } catch is CancellationError { throw CancellationError() }
            catch { try FileManager.default.removeItem(at: candidate) }
        }
        progress(Self.fraction(completed, total))
        let missing = manifest.files.filter { !reusable.contains($0.path) }
        try Self.checkDiskSpace(root, required: missing.reduce(Int64(0)) { $0 + $1.byteCount }
                                + (missing.map(\.byteCount).max() ?? 0) + 100_000_000)
        for file in missing {
            try Task.checkCancellation()
            let base = completed
            let update: @Sendable (Int64) -> Void = { bytes in
                progress(Self.fraction(base + min(file.byteCount, max(0, bytes)), total))
            }
            let installedFile = pending.appending(path: file.path)
            try Self.ensureParent(of: file.path, inside: pending)
            if let source {
                let external = source.appending(path: file.path)
                try await copyAndVerify(external, file: file, sourceRoot: source, destination: installedFile,
                                        pending: pending, update: update)
            } else if let session {
                try await download(file, session: session, destination: installedFile, pending: pending, update: update)
            } else { throw VerifiedModelStoreError.downloadFailed(file.path) }
            completed += file.byteCount
            progress(Self.fraction(completed, total))
        }
        // Re-read every private candidate before the directory becomes visible to the engine.
        try await verifyPack(pending, manifest: manifest)
        try Task.checkCancellation()
        try Self.publish(pending, destination: destination)
        progress(1)
        return destination
    }

    private func download(_ file: ModelFile, session: URLSession, destination: URL, pending: URL,
                          update: @escaping @Sendable (Int64) -> Void) async throws {
        var tried: Set<URL> = []
        for url in [file.url] + file.mirrorURLs where tried.insert(url).inserted {
            try Task.checkCancellation()
            let delegate = VerifiedDownloadDelegate(maximum: file.byteCount, update: update)
            do {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
                let (temporary, response) = try await session.download(for: request, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw VerifiedModelStoreError.downloadFailed(file.path)
                }
                try await copyAndVerify(temporary, file: file, sourceRoot: temporary.deletingLastPathComponent(),
                                        destination: destination, pending: pending, update: update)
                return
            } catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                // A corrupt response is also eligible for the next independent mirror.
                continue
            }
        }
        throw VerifiedModelStoreError.downloadFailed(file.path)
    }

    private func copyAndVerify(_ source: URL, file: ModelFile, sourceRoot: URL, destination: URL,
                               pending: URL, update: @escaping @Sendable (Int64) -> Void) async throws {
        let incoming = pending.appending(path: ".incoming-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: incoming) }
        try await Self.utility {
            try Self.requireRegularFile(source, within: sourceRoot)
            try Self.copy(source, to: incoming, expected: file.byteCount, update: update)
            try Self.verify(incoming, file: file, within: pending)
        }
        try Task.checkCancellation()
        // A file is reusable only after its private on-disk bytes have passed the hash check.
        try FileManager.default.moveItem(at: incoming, to: destination)
    }

    private func verifyPack(_ directory: URL, manifest: LocalModelManifest) async throws {
        try Self.requireDirectory(directory)
        try await Self.utility {
            let allowed = Set(manifest.files.map(\.path) + [Self.metadataName])
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
                throw VerifiedModelStoreError.notInstalled
            }
            let prefix = directory.standardizedFileURL.path + "/"
            for case let entry as URL in entries {
                try Task.checkCancellation()
                let values = try entry.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else {
                    throw VerifiedModelStoreError.unsafeFile(entry.lastPathComponent)
                }
                if values.isRegularFile == true {
                    let relative = String(entry.standardizedFileURL.path.dropFirst(prefix.count))
                    guard allowed.contains(relative) else { throw VerifiedModelStoreError.invalidFile(relative) }
                }
            }
            for file in manifest.files {
                try Task.checkCancellation()
                try Self.verify(directory.appending(path: file.path), file: file, within: directory)
            }
        }
    }

    private nonisolated static func validateID(_ id: String) throws {
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !id.isEmpty, id.utf8.count <= 100, !id.hasPrefix("."), !id.contains(".."),
              id.unicodeScalars.allSatisfy({ permitted.contains($0) }) else {
            throw VerifiedModelStoreError.invalidManifest("资源标识不合法")
        }
    }

    private nonisolated static func validate(_ manifest: LocalModelManifest) throws {
        try validateID(manifest.id)
        guard !manifest.files.isEmpty, manifest.files.count <= 256 else {
            throw VerifiedModelStoreError.invalidManifest("文件数量不合法")
        }
        var paths: Set<String> = []
        var total: Int64 = 0
        for file in manifest.files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.isEmpty, file.path.utf8.count <= 1_024, !file.path.hasPrefix("/"),
                  !file.path.contains("\\"), !file.path.contains("%"),
                  !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  file.path != metadataName, components.first?.hasPrefix(".incoming-") != true,
                  paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  file.byteCount > 0, file.byteCount <= 16 * 1_024 * 1_024 * 1_024,
                  file.sha256.utf8.count == 64,
                  file.sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
                  ([file.url] + file.mirrorURLs).allSatisfy({ $0.scheme == "https" && $0.host != nil }) else {
                throw VerifiedModelStoreError.invalidManifest("路径、下载地址、大小或校验值不合法")
            }
            total += file.byteCount
            guard total <= 64 * 1_024 * 1_024 * 1_024 else {
                throw VerifiedModelStoreError.invalidManifest("模型资源超过支持的大小")
            }
        }
        for path in paths {
            var parts = path.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                guard !paths.contains(parts.joined(separator: "/")) else {
                    throw VerifiedModelStoreError.invalidManifest("文件与目录路径冲突")
                }
            }
        }
    }

    private nonisolated static func manifestData(_ manifest: LocalModelManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    private nonisolated static func fraction(_ value: Int64, _ total: Int64) -> Double {
        min(0.99, max(0, Double(value) / Double(total)))
    }

    private nonisolated static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VerifiedModelStoreError.unsafeFile(url.lastPathComponent)
        }
    }

    private nonisolated static func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try requireDirectory(url) }
        else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    private nonisolated static func ensureParent(of path: String, inside root: URL) throws {
        var parent = root
        for component in path.split(separator: "/").dropLast() {
            parent.append(path: String(component), directoryHint: .isDirectory)
            try ensureDirectory(parent)
        }
    }

    private nonisolated static func requireRegularFile(_ url: URL, within root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { throw VerifiedModelStoreError.unsafeFile(url.lastPathComponent) }
        let relative = filePath.dropFirst(rootPath.count + 1)
        var candidate = root
        for component in relative.split(separator: "/") {
            candidate.append(path: String(component))
            let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw VerifiedModelStoreError.unsafeFile(String(component)) }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw VerifiedModelStoreError.unsafeFile(url.lastPathComponent) }
    }

    private nonisolated static func verify(_ url: URL, file: ModelFile, within root: URL) throws {
        try Task.checkCancellation()
        try requireRegularFile(url, within: root)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(file.byteCount) else { throw VerifiedModelStoreError.invalidFile(file.path) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var read: Int64 = 0
        while true {
            let didRead = try autoreleasepool {
                try Task.checkCancellation()
                guard let block = try handle.read(upToCount: 4 * 1_024 * 1_024), !block.isEmpty else { return false }
                read += Int64(block.count)
                guard read <= file.byteCount else { throw VerifiedModelStoreError.invalidFile(file.path) }
                digest.update(data: block)
                return true
            }
            if !didRead { break }
        }
        guard read == file.byteCount,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256.lowercased() else {
            throw VerifiedModelStoreError.invalidFile(file.path)
        }
    }

    private nonisolated static func copy(_ source: URL, to destination: URL, expected: Int64,
                                         update: @Sendable (Int64) -> Void) throws {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(expected) else { throw VerifiedModelStoreError.invalidFile(source.lastPathComponent) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw VerifiedModelStoreError.invalidFile(destination.lastPathComponent)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var written: Int64 = 0
        while true {
            let didRead = try autoreleasepool {
                try Task.checkCancellation()
                guard let block = try input.read(upToCount: 4 * 1_024 * 1_024), !block.isEmpty else { return false }
                written += Int64(block.count)
                guard written <= expected else { throw VerifiedModelStoreError.invalidFile(source.lastPathComponent) }
                try output.write(contentsOf: block)
                update(written)
                return true
            }
            if !didRead { break }
        }
        guard written == expected else { throw VerifiedModelStoreError.invalidFile(source.lastPathComponent) }
        try output.synchronize()
    }

    private nonisolated static func checkDiskSpace(_ root: URL, required: Int64) throws {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
        if let available, available < required { throw VerifiedModelStoreError.insufficientSpace(required) }
    }

    private nonisolated static func publish(_ pending: URL, destination: URL) throws {
        try requireDirectory(pending)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists { try requireDirectory(destination) }
        let result = pending.path.withCString { source in
            destination.path.withCString { target in
                exists ? renamex_np(source, target, UInt32(RENAME_SWAP)) : Darwin.rename(source, target)
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // With RENAME_SWAP, this now holds the replaced old pack, not the newly-published pack.
        if exists { try? FileManager.default.removeItem(at: pending) }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var installed = destination
        try? installed.setResourceValues(values)
    }

    private nonisolated static func utility<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

private final class VerifiedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    let update: @Sendable (Int64) -> Void
    init(maximum: Int64, update: @escaping @Sendable (Int64) -> Void) { self.maximum = maximum; self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum { downloadTask.cancel(); return }
        update(totalBytesWritten)
    }
}
