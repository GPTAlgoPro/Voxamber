import Foundation
import CryptoKit
import Darwin

public enum ProgramProjectStoreError: LocalizedError, Equatable, Sendable {
    case invalidInput, unsafePath, unsupportedVersion, invalidMetadata, corruptArtifact
    case staleRevision, sizeLimit, ioFailure, commitOutcomeUnknown
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "导入信息或模型文件不完整，请重新生成。"
        case .unsafePath: "作品路径无法读取，原文件已保留。"
        case .unsupportedVersion: "此作品版本暂不支持，原文件已保留。"
        case .invalidMetadata, .corruptArtifact: "作品内容校验未通过，原文件已保留。"
        case .staleRevision: "作品已有新版本或被删除，请从作品页重新打开再修改。"
        case .sizeLimit: "场景或模型超过当前本机处理范围，请让你的 AI 简化后重试。"
        case .ioFailure: "保存遇到问题，请检查可用空间后重试。"
        case .commitOutcomeUnknown: "保存状态暂时无法确认，请先到作品页查看。"
        }
    }
}
public enum ProgramPublicationPhase: Equatable, Sendable { case staged, committing, committed }

/// Codable stores relative files, never an App container path. Store-returned
/// records bind these URLs to verified absolute files. Standalone decoding is
/// metadata only and has relative URLs; read through the Store.
public struct ProgramProject: Identifiable, Codable, Sendable {
    public struct FileInfo: Codable, Sendable {
        public let relativePath: String
        public let byteCount: Int64
        public let sha256: String
    }
    public struct Files: Codable, Sendable {
        public let originalImport: FileInfo
        public let source: FileInfo
        public let glb: FileInfo
        public let usdz: FileInfo
        fileprivate var ordered: [FileInfo] { [originalImport, source, glb, usdz] }
    }
    public let schemaVersion: Int
    public let kind: String
    public let id: UUID
    public let title: String
    public let revision: UUID
    public let parentRevision: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    public let sourceSHA256: String
    public let originalImportSHA256: String
    public let glbSHA256: String
    public let usdzSHA256: String
    public let compilerVersion: String
    public let compilerRevision: String
    /// Unverified user text, not a model identity or local-inference assertion.
    public let userDeclaredProvider: String?
    public let files: Files
    fileprivate var directory: URL? = nil
    public var committed: Bool { directory != nil }
    public var originalImportURL: URL { url(files.originalImport) }
    public var sourceURL: URL { url(files.source) }
    public var glbURL: URL { url(files.glb) }
    public var usdzURL: URL { url(files.usdz) }
    private func url(_ file: FileInfo) -> URL {
        directory?.appendingPathComponent(file.relativePath) ?? URL(string: file.relativePath)!
    }
    fileprivate func bound(to directory: URL) -> Self { var p = self; p.directory = directory; return p }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, id, title, revision, parentRevision, createdAt, updatedAt
        case sourceSHA256, originalImportSHA256, glbSHA256, usdzSHA256
        case compilerVersion, compilerRevision, userDeclaredProvider, files
    }
    fileprivate static func text(_ s: String, limit: Int) -> Bool {
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.utf8.count <= limit
            && !s.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    fileprivate func validate() throws {
        guard schemaVersion == 1, kind == "importedSceneProgram" else { throw ProgramProjectStoreError.unsupportedVersion }
        guard Self.text(title, limit: 4096), Self.text(compilerVersion, limit: 512),
              Self.text(compilerRevision, limit: 512),
              userDeclaredProvider.map({ Self.text($0, limit: 512) }) ?? true,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt, parentRevision != revision else { throw ProgramProjectStoreError.invalidMetadata }
        let names = ["original-import.data", "source.js", "model.glb", "model.usdz"]
        let limits = [ProgramProjectStore.maximumOriginalImportBytes, ProgramProjectStore.maximumSourceBytes,
                      ProgramProjectStore.maximumGLBBytes, ProgramProjectStore.maximumUSDZBytes]
        let hashes = [originalImportSHA256, sourceSHA256, glbSHA256, usdzSHA256]
        for (i, file) in files.ordered.enumerated() {
            guard file.relativePath == "revisions/\(revision.uuidString)/\(names[i])",
                  file.byteCount > 0, file.byteCount <= limits[i], file.sha256 == hashes[i],
                  file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ProgramProjectStoreError.invalidMetadata
            }
        }
    }
}

/// Only Documents/ScenePrograms by default; never accesses legacy Creations.
/// Loading contract for the README: absent project directory -> nil; an existing
/// but corrupt/incomplete record -> typed error. list() fails closed on corrupt
/// UUID records. Reads do not migrate, regenerate, restore or rewrite records.
/// A successful publish is committed. Cancellation after pointer rename cannot
/// turn it into CancellationError. This is storage, not a compiler/AI validator.
public actor ProgramProjectStore {
    public static let maximumOriginalImportBytes: Int64 = 4 * 1024 * 1024
    public static let maximumSourceBytes: Int64 = 1024 * 1024
    public static let maximumGLBBytes: Int64 = 256 * 1024 * 1024
    public static let maximumUSDZBytes: Int64 = 512 * 1024 * 1024
    private static let metadataLimit = 256 * 1024
    public let root: URL
    private let suppliedRoot: URL
    private let observer: @Sendable (ProgramPublicationPhase) -> Void
    private let encoder: JSONEncoder

    public init(root: URL = URL.documentsDirectory.appendingPathComponent("ScenePrograms"),
                publicationObserver: @escaping @Sendable (ProgramPublicationPhase) -> Void = { _ in }) {
        suppliedRoot = root.standardizedFileURL
        // Canonicalize the caller-selected parent, including OS /var aliases.
        // A root/project/artifact symlink itself never becomes authority.
        self.root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true).standardizedFileURL
        observer = publicationObserver
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    }

    public func list() throws -> [ProgramProject] {
        try Task.checkCancellation()
        guard let fd = try openRoot(create: false) else { return [] }
        defer { close(fd) }
        var result: [ProgramProject] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: name), name == id.uuidString else { continue }
            if let p = try loadFromRoot(id: id, rootFD: fd) { result.append(p) }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func load(id: UUID) throws -> ProgramProject? {
        try Task.checkCancellation()
        guard let fd = try openRoot(create: false) else { return nil }
        defer { close(fd) }
        return try loadFromRoot(id: id, rootFD: fd)
    }
    public func readSource(_ project: ProgramProject) throws -> String {
        guard let current = try load(id: project.id), current.revision == project.revision else {
            throw ProgramProjectStoreError.staleRevision
        }
        guard let rootFD = try openRoot(create: false) else { throw ProgramProjectStoreError.staleRevision }
        defer { close(rootFD) }
        let p = try directory(parent: rootFD, name: project.id.uuidString); defer { close(p) }
        let r = try directory(parent: p, name: "revisions"); defer { close(r) }
        let v = try directory(parent: r, name: project.revision.uuidString); defer { close(v) }
        let fd = openat(v, "source.js", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(fd) }
        let data = try read(fd: fd, maximum: Int(Self.maximumSourceBytes))
        guard digest(data) == current.sourceSHA256, let text = String(data: data, encoding: .utf8) else {
            throw ProgramProjectStoreError.corruptArtifact
        }
        return text
    }

    public func publish(title: String, originalImport: Data, source: String, glb: Data, usdz: Data,
                        compilerVersion: String, compilerRevision: String,
                        userDeclaredProvider: String? = nil, parent: ProgramProject? = nil) throws -> ProgramProject {
        try Task.checkCancellation()
        let data = [originalImport, Data(source.utf8), glb, usdz]
        let limits = [Self.maximumOriginalImportBytes, Self.maximumSourceBytes, Self.maximumGLBBytes, Self.maximumUSDZBytes]
        guard ProgramProject.text(title, limit: 4096), ProgramProject.text(compilerVersion, limit: 512),
              ProgramProject.text(compilerRevision, limit: 512),
              userDeclaredProvider.map({ ProgramProject.text($0, limit: 512) }) ?? true,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.utf8.contains(0) else { throw ProgramProjectStoreError.invalidInput }
        for (i, bytes) in data.enumerated() {
            guard !bytes.isEmpty, Int64(bytes.count) <= limits[i] else { throw ProgramProjectStoreError.sizeLimit }
        }
        try validateHeaders(glb: glb, usdz: usdz)
        guard let rootFD = try openRoot(create: parent == nil) else { throw ProgramProjectStoreError.staleRevision }
        defer { close(rootFD) }
        let id = parent?.id ?? UUID(), revision = UUID(), name = id.uuidString
        let projectURL = root.appendingPathComponent(name, isDirectory: true)
        let isNew = parent == nil
        if isNew, mkdirat(rootFD, name, 0o700) != 0 { throw ProgramProjectStoreError.ioFailure }
        let p = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard p >= 0 else {
            if isNew { _ = unlinkat(rootFD, name, AT_REMOVEDIR) }
            throw isNew ? ProgramProjectStoreError.unsafePath : .staleRevision
        }
        defer { close(p) }
        var committed = false, moved = false
        var revisionsFD: Int32 = -1
        let pending = ".pending-" + revision.uuidString, tempPointer = ".pointer-" + revision.uuidString
        defer {
            if !committed {
                _ = unlinkat(p, tempPointer, 0)
                removeOwnedRevision(parent: p, name: pending)
                if moved, revisionsFD >= 0 { removeOwnedRevision(parent: revisionsFD, name: revision.uuidString) }
                if isNew {
                    _ = unlinkat(p, "revisions", AT_REMOVEDIR)
                    _ = unlinkat(p, ".program.lock", 0)
                    _ = unlinkat(rootFD, name, AT_REMOVEDIR)
                }
            }
            if revisionsFD >= 0 { close(revisionsFD) }
        }
        let lockFD = openat(p, ".program.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG else { throw ProgramProjectStoreError.unsafePath }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ProgramProjectStoreError.staleRevision }
        defer { _ = flock(lockFD, LOCK_UN) }
        let previous = try readPointer(projectFD: p)
        if let parent {
            guard let previous, previous.id == id, previous.revision == parent.revision else { throw ProgramProjectStoreError.staleRevision }
            try verify(previous, projectFD: p, projectURL: projectURL)
        } else if previous != nil { throw ProgramProjectStoreError.staleRevision }
        guard mkdirat(p, pending, 0o700) == 0 else { throw ProgramProjectStoreError.ioFailure }
        let staged = try directory(parent: p, name: pending); defer { close(staged) }
        let names = ["original-import.data", "source.js", "model.glb", "model.usdz"]
        var infos: [ProgramProject.FileInfo] = []
        for (i, bytes) in data.enumerated() {
            let sha = try write(bytes, name: names[i], directory: staged)
            infos.append(.init(relativePath: "revisions/\(revision.uuidString)/\(names[i])", byteCount: Int64(bytes.count), sha256: sha))
        }
        let now = Date()
        let record = ProgramProject(schemaVersion: 1, kind: "importedSceneProgram", id: id, title: title,
            revision: revision, parentRevision: previous?.revision, createdAt: previous?.createdAt ?? now,
            updatedAt: now, sourceSHA256: infos[1].sha256, originalImportSHA256: infos[0].sha256,
            glbSHA256: infos[2].sha256, usdzSHA256: infos[3].sha256,
            compilerVersion: compilerVersion, compilerRevision: compilerRevision, userDeclaredProvider: userDeclaredProvider,
            files: .init(originalImport: infos[0], source: infos[1], glb: infos[2], usdz: infos[3]))
        try record.validate()
        let metadata = try encoder.encode(record)
        _ = try write(metadata, name: "revision.json", directory: staged)
        for (i, info) in infos.enumerated() { try verifyFile(directory: staged, name: names[i], info: info) }
        guard fsync(staged) == 0 else { throw ProgramProjectStoreError.ioFailure }
        observer(.staged); try Task.checkCancellation()
        if mkdirat(p, "revisions", 0o700) != 0, errno != EEXIST { throw ProgramProjectStoreError.ioFailure }
        revisionsFD = try directory(parent: p, name: "revisions")
        guard renameatx_np(p, pending, revisionsFD, revision.uuidString, UInt32(RENAME_EXCL)) == 0 else { throw ProgramProjectStoreError.ioFailure }
        moved = true
        guard fsync(revisionsFD) == 0 else { throw ProgramProjectStoreError.ioFailure }
        _ = try write(metadata, name: tempPointer, directory: p)
        let current = try readPointer(projectFD: p)
        guard current?.revision == previous?.revision, current?.id == previous?.id else { throw ProgramProjectStoreError.staleRevision }
        let linked = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard linked >= 0 else { throw ProgramProjectStoreError.staleRevision }
        var linkedInfo = stat(), heldInfo = stat()
        let unchanged = fstat(linked, &linkedInfo) == 0 && fstat(p, &heldInfo) == 0
            && linkedInfo.st_dev == heldInfo.st_dev && linkedInfo.st_ino == heldInfo.st_ino
        close(linked)
        guard unchanged else { throw ProgramProjectStoreError.staleRevision }
        observer(.committing); try Task.checkCancellation()
        guard renameat(p, tempPointer, p, "project.json") == 0 else { throw ProgramProjectStoreError.ioFailure }
        committed = true
        // No cancellation checks after atomic pointer replacement.
        if fsync(p) != 0 {
            let confirmed = try? readPointer(projectFD: p, checkCancellation: false)
            guard confirmed?.revision == revision else { throw ProgramProjectStoreError.commitOutcomeUnknown }
        }
        observer(.committed)
        return record.bound(to: projectURL)
    }

    private func openRoot(create: Bool) throws -> Int32? {
        guard suppliedRoot.isFileURL, root.isFileURL, !root.lastPathComponent.isEmpty else { throw ProgramProjectStoreError.unsafePath }
        var original = stat()
        if lstat(suppliedRoot.path, &original) == 0, original.st_mode & S_IFMT == S_IFLNK { throw ProgramProjectStoreError.unsafePath }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            if !create { return nil }
            let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(parent) }
            if mkdirat(parent, root.lastPathComponent, 0o700) != 0, errno != EEXIST { throw ProgramProjectStoreError.ioFailure }
            fd = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw ProgramProjectStoreError.unsafePath }; return fd
    }
    private func directory(parent: Int32, name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProgramProjectStoreError.unsafePath }; return fd
    }
    private func loadFromRoot(id: UUID, rootFD: Int32) throws -> ProgramProject? {
        let fd = openat(rootFD, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(fd) }
        guard let record = try readPointer(projectFD: fd), record.id == id else { throw ProgramProjectStoreError.invalidMetadata }
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try verify(record, projectFD: fd, projectURL: url); return record.bound(to: url)
    }
    private func readPointer(projectFD: Int32, checkCancellation: Bool = true) throws -> ProgramProject? {
        let fd = openat(projectFD, "project.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(fd) }
        let data = try read(fd: fd, maximum: Self.metadataLimit, checkCancellation: checkCancellation)
        do {
            let record = try JSONDecoder().decode(ProgramProject.self, from: data)
            try record.validate(); return record
        } catch is CancellationError { throw CancellationError() }
        catch let error as ProgramProjectStoreError { throw error }
        catch { throw ProgramProjectStoreError.invalidMetadata }
    }
    private func verify(_ record: ProgramProject, projectFD: Int32, projectURL: URL) throws {
        try record.validate()
        let revisions = try directory(parent: projectFD, name: "revisions"); defer { close(revisions) }
        let fd = try directory(parent: revisions, name: record.revision.uuidString); defer { close(fd) }
        let names = ["original-import.data", "source.js", "model.glb", "model.usdz"]
        for (i, file) in record.files.ordered.enumerated() { try verifyFile(directory: fd, name: names[i], info: file) }
        let metadataFD = openat(fd, "revision.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard metadataFD >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(metadataFD) }
        let data = try read(fd: metadataFD, maximum: Self.metadataLimit)
        guard let immutable = try? JSONDecoder().decode(ProgramProject.self, from: data),
              (try? encoder.encode(immutable)) == (try? encoder.encode(record)) else { throw ProgramProjectStoreError.invalidMetadata }
        let url = projectURL.appendingPathComponent("revisions/" + record.revision.uuidString)
        guard Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == Set(names + ["revision.json"]) else { throw ProgramProjectStoreError.invalidMetadata }
    }
    private func write(_ data: Data, name: String, directory: Int32) throws -> String {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(fd) }
        var hasher = SHA256()
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let n = min(1024 * 1024, bytes.count - offset)
                let part = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + n)])
                hasher.update(bufferPointer: part)
                var written = 0
                while written < n {
                    let count = Darwin.write(fd, part.baseAddress!.advanced(by: written), n - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ProgramProjectStoreError.ioFailure }; written += count
                }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw ProgramProjectStoreError.ioFailure }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func verifyFile(directory: Int32, name: String, info: ProgramProject.FileInfo) throws {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProgramProjectStoreError.unsafePath }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size == info.byteCount else { throw ProgramProjectStoreError.corruptArtifact }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024), bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ProgramProjectStoreError.ioFailure }; if count == 0 { break }
            bytes += Int64(count); guard bytes <= info.byteCount else { throw ProgramProjectStoreError.corruptArtifact }
            hash.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, same(before, after), bytes == info.byteCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == info.sha256 else { throw ProgramProjectStoreError.corruptArtifact }
    }
    private func read(fd: Int32, maximum: Int, checkCancellation: Bool = true) throws -> Data {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximum else { throw ProgramProjectStoreError.invalidMetadata }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if checkCancellation { try Task.checkCancellation() }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw ProgramProjectStoreError.ioFailure }; if n == 0 { break }
            guard data.count <= maximum - n else { throw ProgramProjectStoreError.sizeLimit }
            data.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, same(before, after) else { throw ProgramProjectStoreError.corruptArtifact }
        return data
    }
    private func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func validateHeaders(glb: Data, usdz: Data) throws {
        guard glb.count >= 20, glb.starts(with: [0x67, 0x6c, 0x54, 0x46]),
              glb[4] == 2, glb[5] == 0, glb[6] == 0, glb[7] == 0,
              usdz.count >= 4, usdz.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw ProgramProjectStoreError.corruptArtifact }
        let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(glb[8 + $1]) << UInt32(8 * $1) }
        guard Int(size) == glb.count else { throw ProgramProjectStoreError.corruptArtifact }
    }
    private func removeOwnedRevision(parent: Int32, name: String) {
        guard let fd = try? directory(parent: parent, name: name) else { return }; defer { close(fd) }
        for file in ["original-import.data", "source.js", "model.glb", "model.usdz", "revision.json"] { _ = unlinkat(fd, file, 0) }
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }
}
