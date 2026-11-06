// Voxamber local-only candidate adaptation. Original MIT source is preserved separately.
import Foundation

public enum Flux2LocalResourceError: Error, Sendable {
    case unsupportedProfile, networkFallbackForbidden, missingRequiredFile(String)
}

public struct Flux2LocalResourcePaths: Sendable {
    public let transformerDirectory: URL
    public let textEncoderDirectory: URL
    public let vaeDirectory: URL

    public init(transformerDirectory: URL, textEncoderDirectory: URL, vaeDirectory: URL) {
        self.transformerDirectory = transformerDirectory
        self.textEncoderDirectory = textEncoderDirectory
        self.vaeDirectory = vaeDirectory
    }

    /// Layout check only. This cannot replace the outer package's exact SHA admission.
    public func validateLayout() throws {
        guard !FileManager.default.fileExists(atPath: vaeDirectory.appendingPathComponent("vae").path) else {
            throw Flux2LocalResourceError.missingRequiredFile("unexpected VAE/vae subtree")
        }
        let groups: [(URL, [String])] = [
            (transformerDirectory, ["0.safetensors", "1.safetensors", "model.safetensors.index.json"]),
            (textEncoderDirectory, ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]),
            (vaeDirectory, ["config.json", "diffusion_pytorch_model.safetensors"])
        ]
        for (root, files) in groups {
            guard root.isFileURL else { throw Flux2LocalResourceError.missingRequiredFile("non-file root") }
            for file in files {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw Flux2LocalResourceError.missingRequiredFile(file)
                }
            }
        }
    }
}
