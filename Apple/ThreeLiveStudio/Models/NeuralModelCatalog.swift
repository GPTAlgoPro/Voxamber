import CryptoKit
import Foundation

enum NeuralModelGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    case intent, image, shape
    var id: String { rawValue }
    var manifestName: String {
        switch self { case .intent: "IntentQwen08"; case .image: "ImageSDXL"; case .shape: "ShapeHunyuan21" }
    }
}

/// Source URLs are provenance. Runtime network transport uses Apple-hosted packs only.
/// In particular the shape reference identifies FP16 upstream, not a public Q4 download.
struct NeuralModelManifest: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        let path: String
        let byteCount: Int64
        let sha256: String
        let sourceURL: URL?
    }
    struct ApplePack: Codable, Sendable, Equatable {
        let assetPackID: String
        let modelRootRelativePath: String
        let available: Bool
        let contractRelativePath: String
    }
    let formatVersion: Int
    let group: NeuralModelGroup
    let id: String
    let displayName: String
    let identityStatus: String
    let sourceReferenceURL: URL
    let apple: ApplePack
    let files: [File]

    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    /// Deterministic content identity, independent of Apple publication state/JSON whitespace.
    var pinIdentity: String {
        get throws {
            struct Pins: Encodable { let formatVersion: Int; let group: NeuralModelGroup; let id: String; let files: [File] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Pins(formatVersion: formatVersion, group: group, id: id,
                                             files: files.sorted { $0.path < $1.path }))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    var localManifest: LocalModelManifest {
        // VerifiedModelStore's local-copy API requires an HTTPS provenance URL;
        // this catalog deliberately never invokes its HTTP install API.
        LocalModelManifest(id: id, files: files.map {
            ModelFile(path: $0.path, url: $0.sourceURL ?? sourceReferenceURL,
                      byteCount: $0.byteCount, sha256: $0.sha256)
        })
    }
    func validate() throws {
        let allowedID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard formatVersion == 1, !id.isEmpty, id.utf8.count <= 100,
              !id.hasPrefix("."), !id.contains(".."), id.unicodeScalars.allSatisfy(allowedID.contains),
              sourceReferenceURL.scheme == "https", sourceReferenceURL.host != nil,
              !files.isEmpty, files.count <= 256,
              !apple.assetPackID.isEmpty, apple.assetPackID.utf8.count <= 100,
              apple.assetPackID.unicodeScalars.allSatisfy(allowedID.contains),
              Self.safePath(apple.modelRootRelativePath), Self.safePath(apple.contractRelativePath),
              apple.modelRootRelativePath == "models/" + id else { throw NeuralModelError.invalidCatalog }
        var paths = Set<String>(); var total: Int64 = 0
        for file in files {
            let key = file.path.precomposedStringWithCanonicalMapping.lowercased()
            guard Self.safePath(file.path), paths.insert(key).inserted,
                  file.byteCount > 0, file.byteCount <= 16 * 1024 * 1024 * 1024,
                  file.sha256.utf8.count == 64,
                  file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  file.sourceURL == nil || (file.sourceURL?.scheme == "https" && file.sourceURL?.host != nil)
            else { throw NeuralModelError.invalidCatalog }
            total += file.byteCount
        }
        guard total <= 64 * 1024 * 1024 * 1024 else { throw NeuralModelError.invalidCatalog }
    }
    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") && !path.contains("\\")
        && !path.contains("%") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func loadAll(bundle: Bundle = .main) throws -> [NeuralModelManifest] {
        let manifests = try NeuralModelGroup.allCases.map { group in
            guard let url = bundle.url(forResource: group.manifestName, withExtension: "json", subdirectory: "NeuralModels")
                ?? bundle.url(forResource: group.manifestName, withExtension: "json") else { throw NeuralModelError.invalidCatalog }
            let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try manifest.validate()
            guard manifest.group == group else { throw NeuralModelError.invalidCatalog }
            return manifest
        }
        guard let deliveryURL = bundle.url(forResource: "NeuralModelDelivery", withExtension: "json") else {
            return manifests
        }
        let delivery = try JSONDecoder().decode(NeuralModelDelivery.self, from: Data(contentsOf: deliveryURL))
        return try delivery.applying(to: manifests)
    }
}

/// Publication is separate from frozen model/pack contracts. Turning on a
/// processed download must not rewrite their approved byte identities.
struct NeuralModelDelivery: Codable, Sendable {
    struct Pack: Codable, Sendable {
        let group: NeuralModelGroup
        let modelID: String
        let assetPackID: String
        let modelPinIdentitySHA256: String
        let serverState: String
        let version: String?
    }
    let schemaVersion: Int
    let bundleID: String
    let platform: String
    let packs: [Pack]

    func applying(to manifests: [NeuralModelManifest]) throws -> [NeuralModelManifest] {
        guard schemaVersion == 1, bundleID == "com.kaisun.voxamber", platform == "IOS",
              manifests.count == NeuralModelGroup.allCases.count,
              Set(manifests.map(\.group)).count == manifests.count,
              packs.count == manifests.count, Set(packs.map(\.group)).count == packs.count else {
            throw NeuralModelError.invalidCatalog
        }
        return try manifests.map { manifest in
            guard let delivery = packs.first(where: { $0.group == manifest.group }),
                  delivery.modelID == manifest.id, delivery.assetPackID == manifest.apple.assetPackID,
                  delivery.modelPinIdentitySHA256 == (try manifest.pinIdentity),
                  ["COMPLETE", "PENDING"].contains(delivery.serverState) else {
                throw NeuralModelError.invalidCatalog
            }
            let published = delivery.serverState == "COMPLETE"
            if published {
                guard let version = delivery.version, let number = Int(version), number > 0 else {
                    throw NeuralModelError.invalidCatalog
                }
            }
            return NeuralModelManifest(formatVersion: manifest.formatVersion, group: manifest.group,
                id: manifest.id, displayName: manifest.displayName, identityStatus: manifest.identityStatus,
                sourceReferenceURL: manifest.sourceReferenceURL,
                apple: .init(assetPackID: manifest.apple.assetPackID,
                    modelRootRelativePath: manifest.apple.modelRootRelativePath, available: published,
                    contractRelativePath: manifest.apple.contractRelativePath), files: manifest.files)
        }
    }
}

enum NeuralModelError: LocalizedError, Sendable {
    case invalidCatalog, notPublished, busy, notReady
    var errorDescription: String? {
        switch self {
        case .invalidCatalog: "新模型资源清单不完整或无效，请更新 App。"
        case .notPublished: "这组新模型尚未提供 Apple 下载，可先从“文件”导入完整资源文件夹。"
        case .busy: "模型资源正在处理，请稍候。"
        case .notReady: "三组新模型尚未全部校验完成。"
        }
    }
}

struct NeuralImportRoots: Sendable {
    var intent: URL?
    var image: URL?
    var shape: URL?
    init(intent: URL? = nil, image: URL? = nil, shape: URL? = nil) {
        self.intent = intent; self.image = image; self.shape = shape
    }
    subscript(group: NeuralModelGroup) -> URL? {
        switch group { case .intent: intent; case .image: image; case .shape: shape }
    }
}

struct NeuralStoreCheck: Sendable {
    let directories: [NeuralModelGroup: URL]
    let errors: [NeuralModelGroup: String]
    var ready: Bool { NeuralModelGroup.allCases.allSatisfy { directories[$0] != nil } }
}

/// Pure file preparation, independent of MLX/CoreML. Exact hashes are checked on
/// every installation check; legacy 4B directories are never admitted.
actor NeuralAssetStore {
    let manifests: [NeuralModelGroup: NeuralModelManifest]
    private let store: VerifiedModelStore
    private var operating = false
    init(root: URL, manifests: [NeuralModelManifest]) throws {
        guard manifests.count == NeuralModelGroup.allCases.count,
              Set(manifests.map(\.group)).count == manifests.count,
              Set(manifests.map(\.id)).count == manifests.count,
              Set(manifests.map(\.apple.assetPackID)).count == manifests.count else { throw NeuralModelError.invalidCatalog }
        for manifest in manifests { try manifest.validate() }
        self.manifests = Dictionary(uniqueKeysWithValues: manifests.map { ($0.group, $0) })
        store = VerifiedModelStore(root: root)
    }
    func checkInstallation() async throws -> NeuralStoreCheck {
        guard !operating else { throw NeuralModelError.busy }
        operating = true; defer { operating = false }
        var directories: [NeuralModelGroup: URL] = [:]; var errors: [NeuralModelGroup: String] = [:]
        for group in NeuralModelGroup.allCases {
            try Task.checkCancellation()
            guard let manifest = manifests[group] else { throw NeuralModelError.invalidCatalog }
            do { directories[group] = try await store.verifyInstalled(manifest: manifest.localManifest) }
            catch is CancellationError { throw CancellationError() }
            catch { errors[group] = error.localizedDescription }
        }
        try Task.checkCancellation()
        return NeuralStoreCheck(directories: directories, errors: errors)
    }
    func importGroup(_ group: NeuralModelGroup, from directory: URL,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard !operating else { throw NeuralModelError.busy }
        guard let manifest = manifests[group] else { throw NeuralModelError.invalidCatalog }
        operating = true; defer { operating = false }
        return try await store.importDirectory(directory, manifest: manifest.localManifest, progress: progress)
    }
}
