import Foundation
import AppleSDXL

/// Structural admission only. The caller must verify the pinned asset checksum
/// before supplying this directory; directory names cannot establish model identity.
public enum SDXLResources {
    public static let modelRevision = "ef92c54fe816c826f5328709b545338518d08db7"
    public static let archiveBytes: Int64 = 3_052_964_832
    public static let archiveSHA256 = "0e6b8d0ae7a1990f0cd31b5bbc8de600c096e54369add395ef21042832424faa"
    public static let archiveURL = URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios/resolve/ef92c54fe816c826f5328709b545338518d08db7/coreml-stable-diffusion-xl-base-ios_split_einsum_compiled.zip")!

    public static func validateLayout(at directory: URL) throws {
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ImageBackendError.resourcesMustBeLocalDirectory }
        for name in ["TextEncoder.mlmodelc", "TextEncoder2.mlmodelc", "VAEDecoder.mlmodelc"] {
            try require(name, in: directory, isDirectory: true)
        }
        if exists("Unet.mlmodelc", in: directory, isDirectory: true) {
            // The official archive uses chunks, but a compiled single UNet is supported.
        } else {
            try require("UnetChunk1.mlmodelc", in: directory, isDirectory: true)
            try require("UnetChunk2.mlmodelc", in: directory, isDirectory: true)
        }
        for name in ["vocab.json", "merges.txt"] { try require(name, in: directory, isDirectory: false) }
        // The Apple initializer auto-discovers these. Do not silently add an
        // extra model or change the base-only resource/parameter contract.
        for name in ["UnetRefiner.mlmodelc", "UnetRefinerChunk1.mlmodelc",
                     "UnetRefinerChunk2.mlmodelc", "VAEEncoder.mlmodelc", "SafetyChecker.mlmodelc"] {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                throw ImageBackendError.unsupportedAuxiliaryModel(name)
            }
        }
    }

    static func validateTokenizer(at directory: URL, request: ImageRequest) throws {
        // Reject malformed assets before any Core ML model is instantiated.
        let vocabulary = try JSONDecoder().decode([String: Int].self,
            from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        guard let start = vocabulary["<|startoftext|>"], let end = vocabulary["<|endoftext|>"],
              vocabulary["!"] != nil, start >= 0, end >= 0, start != end,
              vocabulary.values.allSatisfy({ (0..<49_408).contains($0) }) else {
            throw ImageBackendError.invalidTokenizer
        }
        let tokenizer = try BPETokenizer(mergesAt: directory.appendingPathComponent("merges.txt"),
                                         vocabularyAt: directory.appendingPathComponent("vocab.json"))
        for prompt in [request.positivePrompt, request.negativePrompt] {
            try Task.checkCancellation()
            let tokens = tokenizer.tokenize(input: prompt).tokenIDs.count
            guard tokens <= 77 else { throw ImageBackendError.promptTooLong(actualTokens: tokens, maximum: 77) }
        }
    }

    private static func exists(_ name: String, in directory: URL, isDirectory expected: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path,
                                              isDirectory: &isDirectory) && isDirectory.boolValue == expected
    }

    private static func require(_ name: String, in directory: URL, isDirectory: Bool) throws {
        guard exists(name, in: directory, isDirectory: isDirectory) else {
            throw ImageBackendError.missingResource(name)
        }
    }
}
