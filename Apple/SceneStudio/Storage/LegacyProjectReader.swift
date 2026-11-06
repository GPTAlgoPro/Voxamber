import Foundation
import CryptoKit

struct LegacySceneProject: Identifiable, Sendable {
    let id: UUID
    let revision: UUID
    let title: String
    let updatedAt: Date
    let glbURL: URL
    let usdzURL: URL
    let usdzSHA256: String
}

struct LegacySceneListing: Sendable {
    let projects: [LegacySceneProject]
    let unreadableCount: Int
}

enum LegacyProjectReadError: Error { case unsafePath, invalidMetadata, changedFile, corruptArtifact, sizeLimit }

/// Current pointers only. Never enumerates revisions to recover a deleted or
/// invalid pointer, and never creates, repairs, migrates or removes a file.
enum LegacyProjectReader {
    @concurrent static func list(root supplied: URL = URL.documentsDirectory.appendingPathComponent("Creations")) async throws -> LegacySceneListing {
        try Task.checkCancellation()
        let root = supplied.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(supplied.lastPathComponent, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else { return .init(projects: [], unreadableCount: 0) }
        try directory(root)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var projects: [LegacySceneProject] = [], unreadable = 0
        for folder in folders {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                guard folder.lastPathComponent == id.uuidString else { throw LegacyProjectReadError.unsafePath }
                try directory(folder)
                let pointer = folder.appendingPathComponent("project.json")
                let bytes = try small(pointer)
                let metadata = try JSONDecoder().decode(LegacyPointer.self, from: bytes)
                try uniqueJSONKeys(bytes)
                guard metadata.id == id, [1,2].contains(metadata.schemaVersion),
                      metadata.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                      metadata.createdAt.timeIntervalSinceReferenceDate.isFinite,
                      metadata.updatedAt >= metadata.createdAt,
                      validHash(metadata.glbSHA256), validHash(metadata.usdzSHA256) else { throw LegacyProjectReadError.invalidMetadata }
                let title: String
                if metadata.schemaVersion == 1 {
                    guard let value = metadata.specification?.name else { throw LegacyProjectReadError.invalidMetadata }; title = value
                } else {
                    guard metadata.specification == nil, let value = metadata.name else { throw LegacyProjectReadError.invalidMetadata }; title = value
                }
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
                      !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LegacyProjectReadError.invalidMetadata }
                let revision = folder.appendingPathComponent(metadata.revision.uuidString, isDirectory: true)
                try directory(revision)
                let glb = revision.appendingPathComponent("model.glb"), usdz = revision.appendingPathComponent("model.usdz")
                guard try await digest(glb, limit: 256 * 1024 * 1024) == metadata.glbSHA256,
                      try await digest(usdz, limit: 512 * 1024 * 1024) == metadata.usdzSHA256 else { throw LegacyProjectReadError.corruptArtifact }
                // An atomic pointer replacement during hashing invalidates this
                // read; no previous revision is substituted.
                guard try small(pointer) == bytes else { throw LegacyProjectReadError.changedFile }
                try directory(root); try directory(folder); try directory(revision)
                projects.append(.init(id: id, revision: metadata.revision, title: title, updatedAt: metadata.updatedAt,
                    glbURL: glb, usdzURL: usdz, usdzSHA256: metadata.usdzSHA256))
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        return .init(projects: projects.sorted { a,b in a.updatedAt == b.updatedAt ? a.id.uuidString < b.id.uuidString : a.updatedAt > b.updatedAt }, unreadableCount: unreadable)
    }

    private struct LegacyPointer: Decodable {
        struct SpecificationTitle: Decodable { let name: String }
        let id: UUID; let revision: UUID; let schemaVersion: Int
        let createdAt: Date; let updatedAt: Date
        let specification: SpecificationTitle?; let name: String?
        let glbSHA256: String; let usdzSHA256: String
    }
    private struct FileIdentity: Equatable {
        let size: Int64; let device: UInt64; let inode: UInt64; let modified: Date
    }
    private static func directory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else { throw LegacyProjectReadError.unsafePath }
    }
    private static func identity(_ url: URL, limit: Int64) throws -> FileIdentity {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
              let size = (a[.size] as? NSNumber)?.int64Value, size > 0, size <= limit,
              let device = (a[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value,
              let date = a[.modificationDate] as? Date else { throw LegacyProjectReadError.unsafePath }
        return .init(size: size, device: device, inode: inode, modified: date)
    }
    private static func small(_ url: URL) throws -> Data {
        let limit: Int64 = 1_048_576, before = try identity(url, limit: limit)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count <= Int(limit) - chunk.count else { throw LegacyProjectReadError.sizeLimit }; data.append(chunk)
        }
        guard data.count == before.size, try identity(url, limit: limit) == before else { throw LegacyProjectReadError.changedFile }
        return data
    }
    private static func digest(_ url: URL, limit: Int64) async throws -> String {
        let before = try identity(url, limit: limit)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(), count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); count += Int64(data.count)
            guard count <= limit else { throw LegacyProjectReadError.sizeLimit }
            hasher.update(data: data); await Task.yield()
        }
        guard count == before.size, try identity(url, limit: limit) == before else { throw LegacyProjectReadError.changedFile }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func validHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// Reject ambiguous metadata keys without decoding legacy scene/mesh
    /// descriptors. JSONDecoder already validates JSON syntax and required types.
    private static func uniqueJSONKeys(_ data: Data) throws {
        let b = Array(data); var i = 0, depth = 0, keys: [Int: Set<String>] = [:]
        while i < b.count {
            if i.isMultiple(of: 4096) { try Task.checkCancellation() }
            if b[i] == 34 {
                let start = i; i += 1; var escaped = false
                while i < b.count {
                    let value = b[i]; i += 1
                    if escaped { escaped = false } else if value == 92 { escaped = true } else if value == 34 { break }
                }
                if keys[depth] != nil {
                    var next = i
                    while next < b.count, [9,10,13,32].contains(b[next]) { next += 1 }
                    if next < b.count, b[next] == 58 {
                        let key = try JSONDecoder().decode(String.self, from: Data(b[start..<i]))
                        guard keys[depth]?.insert(key).inserted == true else { throw LegacyProjectReadError.invalidMetadata }
                    }
                }
            } else {
                if b[i] == 123 { depth += 1; keys[depth] = [] }
                if b[i] == 91 { depth += 1 }
                if b[i] == 125 { keys.removeValue(forKey: depth); depth -= 1 }
                if b[i] == 93 { depth -= 1 }
                guard depth >= 0, depth <= 64 else { throw LegacyProjectReadError.invalidMetadata }
                i += 1
            }
        }
    }
}
