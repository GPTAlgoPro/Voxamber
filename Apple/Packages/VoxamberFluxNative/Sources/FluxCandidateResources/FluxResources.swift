import Foundation
import CryptoKit
import Darwin

public enum FluxResourceError: Error, Equatable, Sendable {
    case malformedManifest, unsafePath, missingOrUnsafeFile(String), identityChanged(String)
    case sizeMismatch(String), hashMismatch(String), unexpectedPayload(String)
}

public struct FluxResourceManifest: Decodable, Sendable {
    public struct File: Decodable, Sendable {
        public let component: String
        public let repository: String
        public let revision: String
        public let path: String
        public let byteCount: Int64
        public let sha256: String

        public var relativePath: String {
            let folder = ["transformer": "Transformer", "textEncoder": "Qwen3", "vae": "VAE"][component] ?? "INVALID"
            return folder + "/" + path
        }
    }
    public let files: [File]

    public static func pinned() throws -> Self {
        guard let url = Bundle.module.url(forResource: "flux2-manifest", withExtension: "json") else {
            throw FluxResourceError.malformedManifest
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.files.count == 14,
              Set(manifest.files.map(\.relativePath)).count == 14 else { throw FluxResourceError.malformedManifest }
        return manifest
    }
}

struct FluxFileIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}

public struct VerifiedFluxResources: Sendable {
    public let root: URL
    public let transformerDirectory: URL
    public let textEncoderDirectory: URL
    public let vaeDirectory: URL
    let files: [FluxResourceManifest.File]
    let identities: [String: FluxFileIdentity]

    /// Rechecks identity at generation boundaries. Exact whole SHA admission precedes this.
    public func assertUnchanged() throws {
        let rootFD = try FluxResourceVerifier.openRoot(root)
        defer { close(rootFD) }
        for file in files {
            let fd = try FluxResourceVerifier.openFile(rootFD: rootFD, relativePath: file.relativePath)
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, identities[file.relativePath] == FluxFileIdentity(info) else {
                throw FluxResourceError.identityChanged(file.relativePath)
            }
        }
        try FluxResourceVerifier.assertPayloadInventory(root: root)
    }
}

public enum FluxResourceVerifier {
    public static func verify(root: URL) throws -> VerifiedFluxResources {
        try verify(root: root, manifest: .pinned())
    }

    static func verify(root: URL, manifest: FluxResourceManifest) throws -> VerifiedFluxResources {
        try Task.checkCancellation()
        let rootFD = try openRoot(root)
        defer { close(rootFD) }
        var identities: [String: FluxFileIdentity] = [:]
        var known = Set<String>()
        for file in manifest.files {
            guard file.byteCount > 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }),
                  known.insert(file.relativePath).inserted else { throw FluxResourceError.malformedManifest }
            try Task.checkCancellation()
            let fd = try openFile(rootFD: rootFD, relativePath: file.relativePath)
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
                throw FluxResourceError.missingOrUnsafeFile(file.relativePath)
            }
            guard before.st_size == file.byteCount else { throw FluxResourceError.sizeMismatch(file.relativePath) }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            var bytes: Int64 = 0
            while true {
                try Task.checkCancellation()
                let count = read(fd, &buffer, buffer.count)
                guard count >= 0 else { throw FluxResourceError.missingOrUnsafeFile(file.relativePath) }
                if count == 0 { break }
                bytes += Int64(count)
                hasher.update(data: Data(buffer.prefix(count)))
            }
            guard bytes == file.byteCount else { throw FluxResourceError.sizeMismatch(file.relativePath) }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == file.sha256.lowercased() else { throw FluxResourceError.hashMismatch(file.relativePath) }
            var after = stat()
            guard fstat(fd, &after) == 0, FluxFileIdentity(before) == FluxFileIdentity(after) else {
                throw FluxResourceError.identityChanged(file.relativePath)
            }
            identities[file.relativePath] = FluxFileIdentity(after)
        }
        // A foreign tensor in a selected directory could otherwise be loaded by upstream's directory scan.
        try assertPayloadInventory(root: root)
        return VerifiedFluxResources(root: root,
            transformerDirectory: root.appendingPathComponent("Transformer/transformer"),
            textEncoderDirectory: root.appendingPathComponent("Qwen3"),
            vaeDirectory: root.appendingPathComponent("VAE"), files: manifest.files, identities: identities)
    }

    static func assertPayloadInventory(root: URL) throws {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("VAE/vae").path) else {
            throw FluxResourceError.unexpectedPayload("VAE/vae")
        }
        for (folder, expected) in [("Transformer/transformer", Set(["0.safetensors", "1.safetensors"])),
                                    ("Qwen3", Set(["model.safetensors"])),
                                    ("VAE", Set(["diffusion_pytorch_model.safetensors"]))] {
            let url = root.appendingPathComponent(folder)
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: url.path) }
            catch { throw FluxResourceError.missingOrUnsafeFile(folder) }
            guard Set(names.filter { $0.hasSuffix(".safetensors") }) == expected else {
                throw FluxResourceError.unexpectedPayload(folder)
            }
        }
    }

    static func openRoot(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw FluxResourceError.unsafePath }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FluxResourceError.missingOrUnsafeFile("root") }
        return fd
    }

    static func openFile(rootFD: Int32, relativePath: String) throws -> Int32 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, !relativePath.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FluxResourceError.unsafePath
        }
        var directory = dup(rootFD)
        guard directory >= 0 else { throw FluxResourceError.missingOrUnsafeFile(relativePath) }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw FluxResourceError.missingOrUnsafeFile(relativePath) }
            close(directory); directory = next
        }
        let fd = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FluxResourceError.missingOrUnsafeFile(relativePath) }
        return fd
    }
}
