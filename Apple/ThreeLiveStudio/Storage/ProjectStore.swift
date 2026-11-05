import Foundation
import CryptoKit
import CreationCore

struct CreationProject: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let revision: UUID
    let createdAt: Date
    let updatedAt: Date
    let specification: SceneSpec
    var sceneSpec: SceneSpec? { specification }
    let prompt: String
    let glbSHA256: String
    let usdzSHA256: String
    let schemaVersion: Int
    var name: String { specification.name }
}

struct ProjectAssets: Sendable {
    let project: CreationProject
    let glbURL: URL
    let usdzURL: URL
}

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

actor ProjectStore {
    let root: URL
    private let thumbnails: ProjectThumbnailService
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(root: URL = URL.documentsDirectory.appending(path: "Creations"),
         thumbnails: ProjectThumbnailService = .shared) {
        self.root = root
        self.thumbnails = thumbnails
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func list() throws -> [CreationProject] {
        try ensureRoot()
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return folders.compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil else { return nil }
            if let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for child in children where child.lastPathComponent.hasPrefix(".pending-") {
                    try? FileManager.default.removeItem(at: child)
                }
            }
            guard
                  let data = try? Data(contentsOf: folder.appending(path: "project.json")),
                  let project = try? decoder.decode(CreationProject.self, from: data),
                  project.schemaVersion == 1,
                  project.id.uuidString == folder.lastPathComponent else { return nil }
            return project
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func publish(spec: SceneSpec, prompt: String, glb: Data, usdz: Data,
                 replacing old: CreationProject?) throws -> ProjectAssets {
        try Task.checkCancellation()
        try spec.validate()
        guard glb.starts(with: [0x67, 0x6c, 0x54, 0x46]), usdz.starts(with: [0x50, 0x4b]) else {
            throw StudioError.message("生成的模型文件不完整，请重试。")
        }
        try ensureRoot()
        let id = old?.id ?? UUID()
        let revision = UUID()
        let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".pending-" + revision.uuidString, directoryHint: .isDirectory)
        let destination = directory.appending(path: revision.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try glb.write(to: staging.appending(path: "model.glb"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try usdz.write(to: staging.appending(path: "model.usdz"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let now = Date()
        let project = CreationProject(id: id, revision: revision, createdAt: old?.createdAt ?? now,
            updatedAt: now, specification: spec, prompt: prompt, glbSHA256: digest(glb),
            usdzSHA256: digest(usdz), schemaVersion: 1)
        try encoder.encode(project).write(to: staging.appending(path: "revision.json"), options: .atomic)
        guard digest(try Data(contentsOf: staging.appending(path: "model.glb"))) == project.glbSHA256,
              digest(try Data(contentsOf: staging.appending(path: "model.usdz"))) == project.usdzSHA256 else {
            throw StudioError.message("保存校验失败，之前的作品已保留。")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        // Publishing this small pointer is the transaction's only commit point.
        do {
            try encoder.encode(project).write(to: directory.appending(path: "project.json"), options: .atomic)
        } catch {
            let pointer = directory.appending(path: "project.json")
            let committed = (try? decoder.decode(CreationProject.self, from: Data(contentsOf: pointer)))?.revision == revision
            if !committed { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        return assets(for: project)
    }

    func load(_ project: CreationProject) throws -> ProjectAssets {
        try project.specification.validate()
        let value = assets(for: project)
        guard digest(try Data(contentsOf: value.glbURL)) == project.glbSHA256,
              digest(try Data(contentsOf: value.usdzURL)) == project.usdzSHA256 else {
            throw StudioError.message("作品文件校验失败。参数仍保留，可重新生成。")
        }
        return value
    }

    func thumbnail(for project: CreationProject) async throws -> Data {
        try await thumbnails.thumbnail(for: ProjectThumbnailSource(projectID: project.id, revision: project.revision,
            fileDigest: project.usdzSHA256, fileURL: assets(for: project).usdzURL))
    }

    func reduceThumbnailMemory() async {
        await thumbnails.reduceMemory()
    }

    func remove(_ project: CreationProject) async throws {
        try FileManager.default.removeItem(at: root.appending(path: project.id.uuidString))
        await thumbnails.invalidate(projectID: project.id)
    }

    func saveDraft(spec: SceneSpec, prompt: String) throws {
        try Task.checkCancellation()
        try ensureRoot()
        try encoder.encode(Draft(spec: spec, prompt: prompt)).write(to: root.appending(path: "draft.json"), options: .atomic)
    }

    func loadDraft() -> Draft? {
        guard let data = try? Data(contentsOf: root.appending(path: "draft.json")),
              let draft = try? decoder.decode(Draft.self, from: data),
              (try? draft.spec.validate()) != nil else { return nil }
        return draft
    }

    struct Draft: Codable, Sendable { let spec: SceneSpec; let prompt: String }

    private func assets(for project: CreationProject) -> ProjectAssets {
        let folder = root.appending(path: project.id.uuidString).appending(path: project.revision.uuidString)
        return ProjectAssets(project: project, glbURL: folder.appending(path: "model.glb"), usdzURL: folder.appending(path: "model.usdz"))
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
