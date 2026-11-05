import Foundation
import CreationCore

struct WorkspaceDraft: Codable, Sendable {
    enum Content: Sendable {
        case proceduralScene(SceneSpec)
        case textOnly
        case neuralProject(id: UUID, revision: UUID)
    }
    let content: Content
    let prompt: String
    private let formatVersion: Int
    var spec: SceneSpec? {
        if case .proceduralScene(let scene) = content { return scene }
        return nil
    }
    init(spec: SceneSpec, prompt: String) {
        content = .proceduralScene(spec); self.prompt = prompt; formatVersion = 1
    }
    init(prompt: String) { content = .textOnly; self.prompt = prompt; formatVersion = 2 }
    init(neuralProjectID: UUID, revision: UUID, prompt: String) {
        content = .neuralProject(id: neuralProjectID, revision: revision)
        self.prompt = prompt; formatVersion = 2
    }
    private enum Keys: String, CodingKey { case schemaVersion, kind, spec, prompt, projectID, revision }
    private enum Kind: String, Codable { case proceduralScene, textOnly, neuralProject }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        prompt = try values.decode(String.self, forKey: .prompt)
        if formatVersion == 1 {
            content = .proceduralScene(try values.decode(SceneSpec.self, forKey: .spec))
        } else if formatVersion == 2 {
            switch try values.decode(Kind.self, forKey: .kind) {
            case .proceduralScene:
                content = .proceduralScene(try values.decode(SceneSpec.self, forKey: .spec))
            case .textOnly:
                guard !values.contains(.spec), !values.contains(.projectID), !values.contains(.revision) else {
                    throw ProjectStorageError.invalidMetadata
                }
                content = .textOnly
            case .neuralProject:
                guard !values.contains(.spec) else { throw ProjectStorageError.invalidMetadata }
                content = .neuralProject(id: try values.decode(UUID.self, forKey: .projectID),
                    revision: try values.decode(UUID.self, forKey: .revision))
            }
        } else { throw ProjectStorageError.unsupportedVersion }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(prompt, forKey: .prompt)
        if formatVersion == 1, case .proceduralScene(let spec) = content {
            try values.encode(spec, forKey: .spec)
            return
        }
        try values.encode(2, forKey: .schemaVersion)
        switch content {
        case .proceduralScene(let spec):
            try values.encode(Kind.proceduralScene, forKey: .kind); try values.encode(spec, forKey: .spec)
        case .textOnly: try values.encode(Kind.textOnly, forKey: .kind)
        case .neuralProject(let id, let revision):
            try values.encode(Kind.neuralProject, forKey: .kind)
            try values.encode(id, forKey: .projectID); try values.encode(revision, forKey: .revision)
        }
    }

    func validateForRestore() throws { try spec?.validate() }
}
