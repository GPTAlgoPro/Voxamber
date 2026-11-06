import Foundation
import CreationCore

enum ProjectContent: Codable, Sendable, Equatable {
    case proceduralScene(SceneSpec)
    case neuralMesh(NeuralProjectDescriptor)

    private enum Keys: String, CodingKey { case kind, scene, mesh }
    private enum Kind: String, Codable { case proceduralScene, neuralMesh }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .proceduralScene:
            guard !c.contains(.mesh) else { throw ProjectStorageError.invalidMetadata }
            self = .proceduralScene(try c.decode(SceneSpec.self, forKey: .scene))
        case .neuralMesh:
            guard !c.contains(.scene) else { throw ProjectStorageError.invalidMetadata }
            self = .neuralMesh(try c.decode(NeuralProjectDescriptor.self, forKey: .mesh))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .proceduralScene(let scene):
            try c.encode(Kind.proceduralScene, forKey: .kind); try c.encode(scene, forKey: .scene)
        case .neuralMesh(let mesh):
            try c.encode(Kind.neuralMesh, forKey: .kind); try c.encode(mesh, forKey: .mesh)
        }
    }
}

struct CreationProject: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let revision: UUID
    let createdAt: Date
    let updatedAt: Date
    let name: String
    let content: ProjectContent
    let prompt: String
    let glbSHA256: String
    let usdzSHA256: String
    let schemaVersion: Int

    /// Representation is independent of whether AI or a person made a project.
    var sceneSpec: SceneSpec? {
        if case .proceduralScene(let scene) = content { return scene }
        return nil
    }
    // Transitional projection for existing callers. Never supplies a fallback.
    var specification: SceneSpec? { sceneSpec }

    init(id: UUID, revision: UUID, createdAt: Date, updatedAt: Date,
         specification: SceneSpec, prompt: String, glbSHA256: String,
         usdzSHA256: String, schemaVersion: Int = 1) {
        self.id = id; self.revision = revision; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.name = specification.name; self.content = .proceduralScene(specification)
        self.prompt = prompt; self.glbSHA256 = glbSHA256; self.usdzSHA256 = usdzSHA256
        self.schemaVersion = schemaVersion
    }

    init(id: UUID, revision: UUID, createdAt: Date, updatedAt: Date, name: String,
         content: ProjectContent, prompt: String, glbSHA256: String, usdzSHA256: String) {
        self.id = id; self.revision = revision; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.name = name; self.content = content; self.prompt = prompt
        self.glbSHA256 = glbSHA256; self.usdzSHA256 = usdzSHA256; self.schemaVersion = 2
    }

    private enum Keys: String, CodingKey {
        case id, revision, createdAt, updatedAt, specification, name, content
        case prompt, glbSHA256, usdzSHA256, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw ProjectStorageError.unsupportedVersion }
        id = try c.decode(UUID.self, forKey: .id); revision = try c.decode(UUID.self, forKey: .revision)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        prompt = try c.decode(String.self, forKey: .prompt)
        glbSHA256 = try c.decode(String.self, forKey: .glbSHA256)
        usdzSHA256 = try c.decode(String.self, forKey: .usdzSHA256); schemaVersion = version
        if version == 1 {
            let scene = try c.decode(SceneSpec.self, forKey: .specification)
            content = .proceduralScene(scene); name = scene.name
        } else {
            guard !c.contains(.specification) else { throw ProjectStorageError.invalidMetadata }
            content = try c.decode(ProjectContent.self, forKey: .content)
            name = try c.decode(String.self, forKey: .name)
        }
        try validateMetadata()
    }

    func encode(to encoder: Encoder) throws {
        try validateMetadata()
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(revision, forKey: .revision)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(prompt, forKey: .prompt); try c.encode(glbSHA256, forKey: .glbSHA256)
        try c.encode(usdzSHA256, forKey: .usdzSHA256); try c.encode(schemaVersion, forKey: .schemaVersion)
        if schemaVersion == 1, let sceneSpec { try c.encode(sceneSpec, forKey: .specification) }
        else { try c.encode(name, forKey: .name); try c.encode(content, forKey: .content) }
    }

    func validateMetadata() throws {
        guard (schemaVersion == 1 || schemaVersion == 2), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (schemaVersion == 1 || (name.utf8.count <= 4_096 && prompt.utf8.count <= 262_144)),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              ArtifactReference.isSHA256(glbSHA256), ArtifactReference.isSHA256(usdzSHA256) else {
            throw ProjectStorageError.invalidMetadata
        }
        switch content {
        case .proceduralScene(let scene): try scene.validate()
        case .neuralMesh(let mesh):
            guard schemaVersion == 2 else { throw ProjectStorageError.invalidMetadata }
            try mesh.validate()
            guard mesh.artifact(.glb)?.sha256 == glbSHA256, mesh.artifact(.usdz)?.sha256 == usdzSHA256 else {
                throw ProjectStorageError.invalidMetadata
            }
        }
    }
}

enum ProjectStorageError: LocalizedError, Sendable {
    case unsupportedVersion, invalidMetadata, invalidArtifact, unsafePath, staleRevision, missingArtifact, sizeLimit, commitOutcomeUnknown
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "当前版本无法打开此作品，原文件已保留。"
        case .invalidMetadata: "作品记录不完整，原文件已保留。"
        case .invalidArtifact: "三维文件或来源记录未通过完整性校验。"
        case .unsafePath: "作品文件路径无效。"
        case .staleRevision: "原作品已删除或已有新版本，本次结果未覆盖作品。"
        case .missingArtifact: "作品文件缺失，原记录已保留。"
        case .sizeLimit: "三维文件超过当前原生引擎支持的资源范围。"
        case .commitOutcomeUnknown: "保存状态暂时无法确认，文件已保留。请重新打开作品库检查。"
        }
    }
}
