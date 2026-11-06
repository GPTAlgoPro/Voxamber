import Foundation
import CryptoKit

public enum CreationImageBackend: String, Codable, Sendable {
    case sdxl = "apple-sdxl"
    case klein4B = "flux2-klein4b-q4"

    /// App-owned contract identity; a mismatched installed group cannot be
    /// reported as the model that actually generated a reference image.
    public var modelContractID: String {
        switch self { case .sdxl: "sdxl-base-ios-coreml"; case .klein4B: "flux2-klein4b-int4" }
    }

    public func receipt(requestedSeed: UInt64) -> CreationImageStageReceipt {
        switch self {
        case .sdxl:
            return .init(backend: self, modelContractID: modelContractID,
                modelRevision: "ef92c54fe816c826f5328709b545338518d08db7",
                componentRevisions: ["compiledSDXL": "ef92c54fe816c826f5328709b545338518d08db7"],
                runtimeVersion: "AppleSDXL-ea2805dc+CLIP-3bee281", seed: UInt64(UInt32(truncatingIfNeeded: requestedSeed)),
                width: 768, height: 768, steps: 20, guidance: 7.5,
                parameters: ["scheduler": "dpmSolverMultistep", "reduceMemory": "true",
                    "textAndUNetCompute": "cpuAndNeuralEngine", "vaeCompute": "cpuAndGPU",
                    "vaeScale": "0.13025", "tokenizerPolicy": "openai-clip-3bee281-native-v1"])
        case .klein4B:
            return .init(backend: self, modelContractID: modelContractID,
                modelRevision: "860e87183ceb29e39627c0612ebd66d8ea66e68c",
                componentRevisions: ["transformer": "860e87183ceb29e39627c0612ebd66d8ea66e68c",
                    "textEncoder": "480ec45ecf06ae3c061e4ef11345d05c7fdb02f1",
                    "smallVAE": "a3efc24f613ef42d9428af62fdbd6f5fd8856c4a"],
                runtimeVersion: "Flux2Core-57ad4818-local-v1-MLX0.32.3", seed: requestedSeed,
                width: 512, height: 512, steps: 4, guidance: 1,
                parameters: ["transformerVariant": "klein4B_4bit", "textEncoder": "Qwen3-4B-affineQ4-group64",
                    "vae": "smallDecoder-fullF32", "memoryProfile": "conservative", "cacheTrimSteps": "1",
                    "residency": "TE-unload-DiT+VAE-unloadDiT-decode", "promptUpsampling": "false"])
        }
    }
}

/// Source configuration and exact selected model identities for a completed
/// image stage. It is not a visual-quality, metric-scale or phone-memory claim.
public struct CreationImageStageReceipt: Codable, Sendable, Equatable {
    public let backend: CreationImageBackend
    public let modelContractID: String
    public let modelRevision: String
    public let componentRevisions: [String: String]
    public let runtimeVersion: String
    public let seed: UInt64
    public let width: Int
    public let height: Int
    public let steps: Int
    public let guidance: Double
    public let parameters: [String: String]

    /// Seed is stored separately and does not alter the fixed configuration ID.
    public var configurationSHA256: String {
        get throws {
            struct Configuration: Encodable {
                let backend: CreationImageBackend
                let components: [String: String]
                let runtime: String
                let width: Int; let height: Int; let steps: Int; let guidance: Double
                let parameters: [String: String]
            }
            let value = Configuration(backend: backend, components: componentRevisions, runtime: runtimeVersion,
                width: width, height: height, steps: steps, guidance: guidance, parameters: parameters)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
