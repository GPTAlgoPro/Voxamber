import Foundation
import CryptoKit
import CreationCore
import Darwin

struct ProjectAssets: Sendable {
    let project: CreationProject
    let glbURL: URL
    let usdzURL: URL
    var baseMeshURL: URL? { neuralURL(.baseMesh) }
    var sourcePNGURL: URL? { neuralURL(.sourcePNG) }
    var referencePNGURL: URL? { neuralURL(.referencePNG) }
    private func neuralURL(_ role: NeuralArtifactRole) -> URL? {
        guard case .neuralMesh(let mesh) = project.content, let ref = mesh.artifact(role) else { return nil }
        return glbURL.deletingLastPathComponent().appending(path: ref.relativePath)
    }
}

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}

enum ProjectPublicationPhase: Sendable { case stagedFilesValidated, readyToCommit, committed }
struct ProjectReadIssue: Sendable { let projectID: UUID; let unsupportedOrUnreadable: Bool }

/// Per-project nonblocking OS lock also protects against another Store instance.
/// Read-only list/open never create this file in legacy project directories.
private final class ProjectDirectoryLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        try ProjectFileIO.safePath(directory)
        let path = directory.appending(path: ".publication.lock")
        try ProjectFileIO.safePath(path)
        let fd = path.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw ProjectStorageError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw ProjectStorageError.staleRevision
        }
        descriptor = fd
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    static func cleanupAllowed(in directory: URL) -> Bool {
        let path = directory.appending(path: ".publication.lock")
        guard FileManager.default.fileExists(atPath: path.path) else { return true }
        guard (try? ProjectFileIO.safePath(path)) != nil else { return false }
        let fd = path.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = flock(fd, LOCK_UN)
        return true
    }
}

actor ProjectStore {
    let root: URL
    private let thumbnails: ProjectThumbnailService
    private let observer: @Sendable (ProjectPublicationPhase) -> Void
    private let pointerWriter: @Sendable (Data, URL) throws -> Void
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private(set) var readIssues: [ProjectReadIssue] = []

    init(root: URL = URL.documentsDirectory.appending(path: "Creations"),
         thumbnails: ProjectThumbnailService = .shared,
         publicationObserver: @escaping @Sendable (ProjectPublicationPhase) -> Void = { _ in },
         pointerWriter: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.root = root.standardizedFileURL; self.thumbnails = thumbnails; observer = publicationObserver
        self.pointerWriter = pointerWriter
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func list() throws -> [CreationProject] {
        try ensureRoot(); readIssues = []
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var result: [CreationProject] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                try ProjectFileIO.safePath(folder)
                let project = try readProject(folder.appending(path: "project.json"))
                guard project.id == id, folder.lastPathComponent == project.id.uuidString else { throw ProjectStorageError.invalidMetadata }
                // No suspension inside publication. A different Store/process can
                // still be copying; do not clean its live staging directory.
                // Snapshot UUID names before checking the lock: a publisher
                // starting after that check cannot contribute a new live UUID
                // to this cleanup snapshot.
                if let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                   ProjectDirectoryLock.cleanupAllowed(in: folder) {
                    for child in children where child.lastPathComponent.hasPrefix(".pending-") {
                        if (try? ProjectFileIO.safePath(child)) != nil { try? FileManager.default.removeItem(at: child) }
                    }
                }
                result.append(project)
            } catch {
                // Unknown/corrupt metadata stays untouched. Never synthesize a scene.
                readIssues.append(.init(projectID: id, unsupportedOrUnreadable: true))
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Existing V1 writer remains source-compatible and retains its wire shape.
    func publish(spec: SceneSpec, prompt: String, glb: Data, usdz: Data,
                 replacing old: CreationProject?, permit supplied: PublicationPermit? = nil) throws -> ProjectAssets {
        let permit = supplied ?? PublicationPermit(); try permit.check(); try spec.validate()
        guard glb.count <= NeuralArtifactLimits.maximumGLBBytes, usdz.count <= NeuralArtifactLimits.maximumUSDZBytes,
              glb.starts(with: [0x67,0x6c,0x54,0x46]), usdz.starts(with: [0x50,0x4b]) else {
            throw StudioError.message("生成的模型文件不完整，请重试。")
        }
        return try transaction(replacing: old, permit: permit) { id, revision, directory in
            try glb.write(to: directory.appending(path: "model.glb"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try permit.check()
            try usdz.write(to: directory.appending(path: "model.usdz"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let now = Date()
            let project = CreationProject(id: id, revision: revision, createdAt: old?.createdAt ?? now,
                updatedAt: now, specification: spec, prompt: prompt, glbSHA256: digest(glb),
                usdzSHA256: digest(usdz), schemaVersion: 1)
            try verifyFile(directory.appending(path: "model.glb"), sha: project.glbSHA256, limit: NeuralArtifactLimits.maximumGLBBytes, permit: permit)
            try verifyFile(directory.appending(path: "model.usdz"), sha: project.usdzSHA256, limit: NeuralArtifactLimits.maximumUSDZBytes, permit: permit)
            return project
        }
    }

    /// True file-backed mesh publication. It never builds or validates a SceneSpec.
    func publishNeural(_ input: NeuralPublicationInput, replacing old: CreationProject?,
                       permit: PublicationPermit) throws -> ProjectAssets {
        try permit.check()
        if let old { try requireCurrent(old) }
        if let parent = input.provenance.parentRevision {
            guard parent == old?.revision else { throw ProjectStorageError.staleRevision }
        }
        let descriptor = try NeuralProjectValidator.inspect(input, permit: permit)
        return try transaction(replacing: old, permit: permit, validateCurrent: { current in
            guard input.provenance.method == .meshTransformOrMaterialEdit else { return }
            // The caller supplies a revision token, not authority to rewrite its
            // origin. Read and validate the current pointer while its directory
            // lock is held, before accepting any new revision files.
            guard let old, let current, current == old,
                  case .neuralMesh(let original) = current.content,
                  input.editRecord?.parentRevision == old.revision,
                  input.prompt == current.prompt,
                  input.generationEvidence == original.generationEvidence,
                  input.baseStatistics == original.baseStatistics,
                  descriptor.artifact(.baseMesh)?.sha256 == original.artifact(.baseMesh)?.sha256,
                  descriptor.artifact(.sourcePNG)?.sha256 == original.artifact(.sourcePNG)?.sha256,
                  descriptor.artifact(.referencePNG)?.sha256 == original.artifact(.referencePNG)?.sha256,
                  input.provenance.pipelineID == original.provenance.pipelineID,
                  input.provenance.imageStage == original.provenance.imageStage,
                  input.provenance.shapeStage == original.provenance.shapeStage,
                  input.provenance.intentStage == original.provenance.intentStage,
                  input.provenance.intentBrief == original.provenance.intentBrief,
                  input.provenance.generatedAt == original.provenance.generatedAt,
                  input.provenance.physicalScaleKnown == original.provenance.physicalScaleKnown,
                  input.provenance.preparedPNG_SHA256 == original.provenance.preparedPNG_SHA256 else {
                throw ProjectStorageError.invalidMetadata
            }
        }) { id, revision, directory in
            var sources: [NeuralArtifactRole: URL] = [.glb: input.files.glb, .usdz: input.files.usdz,
                .baseMesh: input.files.baseMesh, .sourcePNG: input.files.sourcePNG]
            sources[.referencePNG] = input.files.referencePNG
            var written: Set<String> = []
            for reference in descriptor.artifacts where written.insert(reference.relativePath).inserted {
                guard let source = sources[reference.role] else { throw ProjectStorageError.missingArtifact }
                let copied = try ProjectFileIO.fingerprint(source, limit: NeuralProjectValidator.limit(reference.role),
                    copyingTo: directory.appending(path: reference.relativePath), permit: permit)
                guard copied.bytes == reference.byteCount, copied.sha256 == reference.sha256 else { throw ProjectStorageError.invalidArtifact }
            }
            // Re-read copied bytes, including geometry/counts, before the pointer exists.
            try NeuralProjectValidator.validateFiles(in: directory, descriptor: descriptor, permit: permit)
            let now = Date()
            return CreationProject(id: id, revision: revision, createdAt: old?.createdAt ?? now, updatedAt: now,
                name: input.name, content: .neuralMesh(descriptor), prompt: input.prompt,
                glbSHA256: descriptor.artifact(.glb)!.sha256, usdzSHA256: descriptor.artifact(.usdz)!.sha256)
        }
    }

    /// All file work stays synchronous on the Store actor; no reentrant list can
    /// remove staging. The OS lock covers other Store instances on the same root.
    private func transaction(replacing old: CreationProject?, permit: PublicationPermit,
                             validateCurrent: (CreationProject?) throws -> Void = { _ in },
                             stage: (UUID, UUID, URL) throws -> CreationProject) throws -> ProjectAssets {
        try permit.check(); try ensureRoot()
        let id = old?.id ?? UUID(), revision = UUID(), directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        if let old { try requireCurrent(old) }
        else {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw ProjectStorageError.staleRevision }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let directoryLock = try ProjectDirectoryLock(directory: directory)
        defer { withExtendedLifetime(directoryLock) {} }
        let current: CreationProject?
        if let old {
            let stored = try readProject(directory.appending(path: "project.json"))
            guard stored.id == old.id, stored.revision == old.revision else {
                throw ProjectStorageError.staleRevision
            }
            current = stored
        } else { current = nil }
        try validateCurrent(current)
        let pending = directory.appending(path: ".pending-" + revision.uuidString, directoryHint: .isDirectory)
        let destination = directory.appending(path: revision.uuidString, directoryHint: .isDirectory)
        var committed = false, preserveDestinationForUncertainCommit = false
        defer {
            try? FileManager.default.removeItem(at: pending)
            if !committed {
                if !preserveDestinationForUncertainCommit { try? FileManager.default.removeItem(at: destination) }
                if old == nil, !preserveDestinationForUncertainCommit { try? FileManager.default.removeItem(at: directory) }
            }
        }
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        let project = try stage(id, revision, pending)
        try project.validateMetadata()
        let metadata = try encoder.encode(project)
        guard metadata.count <= ProjectFileIO.metadataLimit else { throw ProjectStorageError.sizeLimit }
        try metadata.write(to: pending.appending(path: "revision.json"), options: .atomic)
        observer(.stagedFilesValidated); try permit.check()
        try FileManager.default.moveItem(at: pending, to: destination)
        observer(.readyToCommit)
        let pointer = directory.appending(path: "project.json")
        try permit.commit {
            if let old { try requireCurrentIdentity(old) }
            else { guard !FileManager.default.fileExists(atPath: pointer.path) else { throw ProjectStorageError.staleRevision } }
            try ProjectFileIO.safePath(pointer)
            do { try pointerWriter(metadata, pointer) }
            catch let writingError {
                // Some filesystem errors can be reported after the atomic rename.
                // Report the committed outcome if independent readback proves it.
                let identity: PointerIdentity?
                do {
                    identity = FileManager.default.fileExists(atPath: pointer.path) ? try readPointerIdentity(pointer) : nil
                } catch {
                    preserveDestinationForUncertainCommit = true
                    throw ProjectStorageError.commitOutcomeUnknown
                }
                if identity?.id == id, identity?.revision == revision { return }
                if (identity?.id == old?.id && identity?.revision == old?.revision) || (identity == nil && old == nil) {
                    throw writingError
                }
                preserveDestinationForUncertainCommit = true
                throw ProjectStorageError.commitOutcomeUnknown
            }
        }
        committed = true
        observer(.committed)
        // No cancellation check after the commit point: cancellation cannot undo it.
        return assets(for: project)
    }

    func load(_ project: CreationProject) throws -> ProjectAssets {
        try project.validateMetadata()
        let value = assets(for: project)
        try ProjectFileIO.safePath(value.glbURL)
        switch project.content {
        case .proceduralScene:
            try verifyFile(value.glbURL, sha: project.glbSHA256, limit: NeuralArtifactLimits.maximumGLBBytes)
            try verifyFile(value.usdzURL, sha: project.usdzSHA256, limit: NeuralArtifactLimits.maximumUSDZBytes)
        case .neuralMesh(let mesh):
            try NeuralProjectValidator.validateFiles(in: value.glbURL.deletingLastPathComponent(), descriptor: mesh)
        }
        return value
    }

    func thumbnail(for project: CreationProject) async throws -> Data {
        try project.validateMetadata()
        let url = assets(for: project).usdzURL; try ProjectFileIO.safePath(url)
        return try await thumbnails.thumbnail(for: ProjectThumbnailSource(projectID: project.id,
            revision: project.revision, fileDigest: project.usdzSHA256, fileURL: url))
    }
    func reduceThumbnailMemory() async { await thumbnails.reduceMemory() }

    func remove(_ project: CreationProject) async throws {
        try ensureRoot(); try requireCurrent(project)
        let folder = root.appending(path: project.id.uuidString, directoryHint: .isDirectory)
        let directoryLock = try ProjectDirectoryLock(directory: folder)
        try requireCurrent(project)
        try FileManager.default.removeItem(at: folder)
        withExtendedLifetime(directoryLock) {}
        await thumbnails.invalidate(projectID: project.id)
    }

    // The existing V1 draft API is retained for existing procedural callers.
    // Neural working-state persistence must use its own typed representation;
    // nil SceneSpec must never be translated into this API by the caller.
    func saveDraft(spec: SceneSpec, prompt: String) throws {
        // An editor may temporarily hold an incomplete geometry draft. Keep the
        // V1 write behavior; validation belongs to restore/publish, not typing.
        try saveDraft(Draft(spec: spec, prompt: prompt))
    }
    func saveDraft(_ draft: Draft) throws {
        try Task.checkCancellation(); try ensureRoot()
        if case .neuralProject(let id, let revision) = draft.content {
            let current = try readProject(root.appending(path: id.uuidString).appending(path: "project.json"))
            guard current.id == id, current.revision == revision,
                  case .neuralMesh = current.content else { throw ProjectStorageError.staleRevision }
        }
        let file = root.appending(path: "draft.json"); try ProjectFileIO.safePath(file)
        try encoder.encode(draft).write(to: file, options: .atomic)
    }
    func loadDraft() -> Draft? {
        guard let data = try? ProjectFileIO.readSmall(root.appending(path: "draft.json")),
              let draft = try? decoder.decode(Draft.self, from: data),
              (try? draft.validateForRestore()) != nil else { return nil }
        if case .neuralProject(let id, let revision) = draft.content {
            guard let current = try? readProject(root.appending(path: id.uuidString).appending(path: "project.json")),
                  current.id == id, current.revision == revision,
                  case .neuralMesh = current.content else { return nil }
        }
        return draft
    }
    typealias Draft = WorkspaceDraft

    private func requireCurrent(_ project: CreationProject) throws {
        let pointer = root.appending(path: project.id.uuidString).appending(path: "project.json")
        guard let current = try? readProject(pointer), current.id == project.id, current.revision == project.revision else {
            throw ProjectStorageError.staleRevision
        }
    }
    private struct PointerIdentity: Decodable { let id: UUID; let revision: UUID }
    private func requireCurrentIdentity(_ project: CreationProject) throws {
        let pointer = root.appending(path: project.id.uuidString).appending(path: "project.json")
        guard let identity = try? readPointerIdentity(pointer), identity.id == project.id,
              identity.revision == project.revision else { throw ProjectStorageError.staleRevision }
    }
    /// Commit error readback must remain possible even if cancellation arrived
    /// after the atomic rename; otherwise rollback could delete a committed file.
    private func readPointerIdentity(_ file: URL) throws -> PointerIdentity {
        let (handle, size) = try ProjectFileIO.openRead(file, limit: ProjectFileIO.metadataLimit)
        defer { try? handle.close() }
        var data = Data(); data.reserveCapacity(Int(size))
        while data.count < size {
            guard let part = try handle.read(upToCount: Int(size) - data.count), !part.isEmpty else { throw ProjectStorageError.invalidMetadata }
            data.append(part)
        }
        return try decoder.decode(PointerIdentity.self, from: data)
    }
    private func readProject(_ url: URL) throws -> CreationProject {
        try decoder.decode(CreationProject.self, from: ProjectFileIO.readSmall(url))
    }
    private func assets(for project: CreationProject) -> ProjectAssets {
        let directory = root.appending(path: project.id.uuidString).appending(path: project.revision.uuidString)
        return .init(project: project, glbURL: directory.appending(path: "model.glb"), usdzURL: directory.appending(path: "model.usdz"))
    }
    private func ensureRoot() throws {
        try ProjectFileIO.safePath(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func verifyFile(_ file: URL, sha: String, limit: Int64, permit: PublicationPermit? = nil) throws {
        guard try ProjectFileIO.fingerprint(file, limit: limit, permit: permit).sha256 == sha else {
            throw StudioError.message("作品文件校验失败，之前的作品已保留。")
        }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
