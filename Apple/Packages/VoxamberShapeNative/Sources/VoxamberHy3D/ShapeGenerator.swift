import Foundation
import CoreGraphics
import MLX

/// An explicit precision contract for high-fidelity Shape runtimes. The legacy
/// initializer below remains available for the mobile Q4/Q8 paths; callers that
/// select this API cannot request or fall back to a quantized checkpoint.
public enum ShapeWeightPrecision: Equatable, Sendable {
    case fp16Only
}

/// Required model capability for strict Shape construction.
public enum ShapeConditioningContract: Equatable, Sendable {
    /// 2mv: four canonical views through `DinoImageEncoderMV`.
    case multiView
    /// 2.1: one image through `SingleImageEncoder`. A multi-view checkpoint
    /// does not satisfy this and vice versa — the conditioning token layout
    /// differs, so a mismatch has to fail before any weight is mapped.
    case singleImage
}

/// Fail-closed errors raised before a strict Shape runtime can start.
public enum ShapeWeightLoadingError: Error, Equatable, LocalizedError, Sendable {
    case invalidSafetensorsHeader
    case quantizedArtifact
    case nonFP16Tensor(name: String, dtype: String)
    case missingConfiguration
    case invalidConfiguration
    case requiredMultiViewConfiguration
    case requiredSingleImageConfiguration
    case invalidRuntimeConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidSafetensorsHeader:
            return "The Shape checkpoint has an invalid safetensors header."
        case .quantizedArtifact:
            return "The Shape checkpoint contains quantized tensors or metadata."
        case .nonFP16Tensor(let name, let dtype):
            return "Shape tensor \(name) uses \(dtype), but strict FP16 requires F16."
        case .missingConfiguration:
            return "The Shape checkpoint is missing its required config.yaml."
        case .invalidConfiguration:
            return "The Shape config.yaml is incomplete or invalid."
        case .requiredMultiViewConfiguration:
            return "The Shape config.yaml does not declare multi-view conditioning."
        case .requiredSingleImageConfiguration:
            return "The Shape config.yaml does not declare single-image conditioning."
        case .invalidRuntimeConfiguration:
            return "The strict Shape runtime profile is invalid."
        }
    }
}

/// Header-only safetensors inspection. This rejects a Q4/Q8 payload before MLX
/// maps a multi-gigabyte checkpoint, while the post-load dtype check below
/// remains a second line of defence.
enum ShapeWeightHeaderPreflight {
    private static let maximumHeaderByteCount = 64 * 1_024 * 1_024

    static func validateFP16(at url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ShapeWeightLoadingError.invalidSafetensorsHeader
        }
        defer { try? handle.close() }

        let fileByteCount: UInt64
        do {
            fileByteCount = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw ShapeWeightLoadingError.invalidSafetensorsHeader
        }
        guard fileByteCount >= 8,
              let prefix = try? handle.read(upToCount: 8),
              prefix.count == 8 else {
            throw ShapeWeightLoadingError.invalidSafetensorsHeader
        }
        let headerByteCount = prefix.withUnsafeBytes { bytes in
            UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self))
        }
        guard headerByteCount > 0,
              headerByteCount <= UInt64(maximumHeaderByteCount),
              headerByteCount <= fileByteCount - 8,
              headerByteCount <= UInt64(Int.max),
              let header = try? handle.read(upToCount: Int(headerByteCount)),
              header.count == Int(headerByteCount),
              let root = try? JSONSerialization.jsonObject(with: header)
                as? [String: Any] else {
            throw ShapeWeightLoadingError.invalidSafetensorsHeader
        }

        if let rawMetadata = root["__metadata__"] {
            // safetensors defines metadata as a string-to-string map. Keeping
            // that contract exact also avoids asking Swift to describe an
            // arbitrary value while MLX may have live lazy arrays elsewhere.
            guard let metadata = rawMetadata as? [String: String] else {
                throw ShapeWeightLoadingError.invalidSafetensorsHeader
            }
            if containsQuantizationMetadata(metadata) {
                throw ShapeWeightLoadingError.quantizedArtifact
            }
        }

        let payloadByteCount = fileByteCount - 8 - headerByteCount
        var ranges = [(start: UInt64, end: UInt64)]()
        for (name, rawDescriptor) in root where name != "__metadata__" {
            if name.hasSuffix(".scales") || name.hasSuffix(".biases") {
                throw ShapeWeightLoadingError.quantizedArtifact
            }
            guard let descriptor = rawDescriptor as? [String: Any],
                  let dtype = descriptor["dtype"] as? String,
                  let shape = integerArray(descriptor["shape"]),
                  let offsets = integerArray(descriptor["data_offsets"]),
                  offsets.count == 2,
                  offsets[0] >= 0,
                  offsets[1] >= offsets[0] else {
                throw ShapeWeightLoadingError.invalidSafetensorsHeader
            }
            guard dtype.uppercased() == "F16" else {
                throw ShapeWeightLoadingError.nonFP16Tensor(
                    name: name,
                    dtype: dtype
                )
            }

            var elementCount = 1
            for dimension in shape {
                guard dimension >= 0 else {
                    throw ShapeWeightLoadingError.invalidSafetensorsHeader
                }
                let product = elementCount.multipliedReportingOverflow(
                    by: dimension
                )
                guard !product.overflow else {
                    throw ShapeWeightLoadingError.invalidSafetensorsHeader
                }
                elementCount = product.partialValue
            }
            let tensorBytes = elementCount.multipliedReportingOverflow(by: 2)
            guard !tensorBytes.overflow,
                  offsets[1] - offsets[0] == tensorBytes.partialValue,
                  UInt64(offsets[1]) <= payloadByteCount else {
                throw ShapeWeightLoadingError.invalidSafetensorsHeader
            }
            ranges.append((UInt64(offsets[0]), UInt64(offsets[1])))
        }
        guard !ranges.isEmpty else {
            throw ShapeWeightLoadingError.invalidSafetensorsHeader
        }
        ranges.sort { lhs, rhs in lhs.start < rhs.start }
        var cursor: UInt64 = 0
        for range in ranges {
            guard range.start == cursor else {
                throw ShapeWeightLoadingError.invalidSafetensorsHeader
            }
            cursor = range.end
        }
        guard cursor == payloadByteCount else {
            throw ShapeWeightLoadingError.invalidSafetensorsHeader
        }
    }

    private static func integerArray(_ value: Any?) -> [Int]? {
        guard let numbers = value as? [NSNumber] else { return nil }
        var result = [Int]()
        result.reserveCapacity(numbers.count)
        for number in numbers {
            let value = number.int64Value
            guard value >= Int64(Int.min), value <= Int64(Int.max),
                  number.doubleValue == Double(value) else {
                return nil
            }
            result.append(Int(value))
        }
        return result
    }

    private static func containsQuantizationMetadata(
        _ metadata: [String: String]
    ) -> Bool {
        metadata.contains { key, value in
            let normalizedKey = key.lowercased()
            let normalizedValue = value.lowercased()
            return normalizedKey == "bits"
                || normalizedKey == "group_size"
                || normalizedKey.contains("quant")
                || normalizedValue.contains("quantized")
                || normalizedValue == "q4"
                || normalizedValue == "q8"
        }
    }
}

/// High-level, app-facing entry point for 2mini and 2mv checkpoints. It turns
/// one or more canonical photos into a mesh entirely on-device (MLX) — no
/// Python, fixtures, or network at inference time.
public final class ShapeGenerator {
    public enum View: Int, CaseIterable, Sendable {
        case front = 0
        case left = 1
        case back = 2
        case right = 3
    }
    /// The FLUX-style denoiser, present only for 2mini / 2.0 / 2mv checkpoints.
    /// A 2.1 checkpoint drives `denoiser` alone.
    public let dit: DiT?
    /// Architecture-agnostic denoiser actually run by the sampler.
    public let denoiser: any ShapeDenoiser
    public let vae: VAE
    public let dino: DINOv2
    public let numLatents: Int
    public let supportsMultiView: Bool
    public let executionStrategy: ShapeExecutionStrategy

    /// Strict high-fidelity construction. This path accepts only a genuine F16
    /// safetensors payload and a complete multi-view config. It never calls the
    /// legacy quantize/packedBits machinery and always configures ordinary
    /// linear layers with `bits == 0`.
    public init(
        weightsURL: URL,
        weightPrecision: ShapeWeightPrecision,
        requiredConditioning: ShapeConditioningContract,
        numLatents: Int? = nil,
        cacheLimitMB: Int = 256,
        executionStrategy: ShapeExecutionStrategy = .throughput
    ) throws {
        guard cacheLimitMB > 0,
              cacheLimitMB <= Int.max / (1_024 * 1_024) else {
            throw ShapeWeightLoadingError.invalidRuntimeConfiguration
        }
        if let numLatents, numLatents <= 0 {
            throw ShapeWeightLoadingError.invalidRuntimeConfiguration
        }
        switch weightPrecision {
        case .fp16Only:
            try ShapeWeightHeaderPreflight.validateFP16(at: weightsURL)
        }
        let cfg = try Self.readStrictConfig(
            weightsURL,
            requiredConditioning: requiredConditioning
        )
        MLX.Memory.cacheLimit = cacheLimitMB * 1_024 * 1_024
        let weights = try loadArrays(url: weightsURL)
        try Self.validateStrictFP16(weights)

        let condPrefix = "conditioner.main_image_encoder.model."
        var dw: [String: MLXArray] = [:]
        var vw: [String: MLXArray] = [:]
        var nw: [String: MLXArray] = [:]
        for (key, value) in weights {
            if key.hasPrefix("model.") {
                dw[String(key.dropFirst(6))] = value
            } else if key.hasPrefix("vae.") {
                vw[String(key.dropFirst(4))] = value
            } else if key.hasPrefix(condPrefix) {
                nw[String(key.dropFirst(condPrefix.count))] = value
            }
        }
        let bits = 0
        let group = 64
        switch cfg.architecture {
        case .plain:
            self.dit = nil
            self.denoiser = DiTPlain(
                weights: dw,
                heads: cfg.heads,
                hidden: cfg.hidden,
                depth: cfg.depth,
                numMoELayers: cfg.numMoELayers,
                numExperts: cfg.numExperts,
                moeTopK: cfg.moeTopK,
                bits: bits,
                groupSize: group,
                moeTokenChunkSize: executionStrategy.moeTokenChunkSize,
                usesSparseMoERouting:
                    executionStrategy.usesSparseMoERouting
            )
        case .flux:
            let strictDiT = DiT(
                weights: dw,
                depth: cfg.depth,
                depthSingle: cfg.depthSingle,
                guidanceEmbed: cfg.guidanceEmbed,
                bits: bits,
                groupSize: group
            )
            self.dit = strictDiT
            self.denoiser = strictDiT
        }
        self.vae = VAE(weights: vw, scaleFactor: cfg.scaleFactor)
        self.dino = DINOv2(weights: nw,
                           heads: cfg.dinoHeads,
                           layers: cfg.dinoLayers,
                           feedForward: cfg.dinoUsesSwiGLU ? .swiGLU : .mlp,
                           bits: bits, groupSize: group)
        self.numLatents = numLatents ?? cfg.numLatents
        self.supportsMultiView = cfg.multiViewConditioner
        self.executionStrategy = executionStrategy
    }

    /// Load a single-file Shape checkpoint and build DiT + VAE + DINOv2.
    /// Weights stay in their on-disk dtype (fp16) — upcasting to fp32 would double resident memory
    /// (~3.6 GB -> ~7.6 GB) and OOM every iOS device. fp16 is also the reference activation dtype.
    /// `quantize`: 0 = fp16, or 4 / 8 for weights-only quantization of the bulk DiT + DINO linears
    /// (group size 64; VAE, norms, embedders + the projection/skip linears stay fp16). 4-bit cuts
    /// resident weights substantially; the exact ratio depends on DiT/VAE size.
    public init(weightsURL: URL, dtype: DType = .float16, quantize: Int = 0,
                configurationYAML: String? = nil, packedBits: Int = 0,
                numLatents: Int? = nil, cacheLimitMB: Int = 256,
                executionStrategy: ShapeExecutionStrategy = .throughput) throws {
        MLX.Memory.cacheLimit = cacheLimitMB * 1024 * 1024    // keep the buffer cache off the jetsam limit
        // Voxamber adaptation: the signed pack config can be supplied without
        // modifying the checkpoint directory or writing beside managed assets.
        let cfg = configurationYAML.map(Self.readConfigurationText) ?? Self.readConfig(weightsURL)
        let weights = try loadArrays(url: weightsURL)
        let condPrefix = "conditioner.main_image_encoder.model."
        var dw: [String: MLXArray] = [:], vw: [String: MLXArray] = [:], nw: [String: MLXArray] = [:]
        for (k, v) in weights {
            // Packed quantized matrices use UInt32 storage and must not be
            // cast back to fp16 while loading an offline mobile pack.
            let w = packedBits == 0 && v.dtype != dtype ? v.asType(dtype) : v
            if k.hasPrefix("model.") { dw[String(k.dropFirst(6))] = w }
            else if k.hasPrefix("vae.") { vw[String(k.dropFirst(4))] = w }
            else if k.hasPrefix(condPrefix) { nw[String(k.dropFirst(condPrefix.count))] = w }
        }
        let bits = (packedBits == 4 || packedBits == 8) ? packedBits
            : ((quantize == 4 || quantize == 8) ? quantize : 4)
        let group = 64
        if packedBits == 0 && (quantize == 4 || quantize == 8) {
            // The two architectures name their small, quantization-hostile
            // layers differently. `moe.gate` is 8x2048 — quantizing a router
            // buys nothing and perturbs expert selection.
            let ditSkip = (cfg?.architecture ?? .flux) == .plain
                ? ["x_embedder", "t_embedder", "final_layer", "skip_linear", "moe.gate"]
                : ["latent_in", "time_in", "cond_in", "guidance_in", "final_layer", "x_embedder"]
            dw = Self.quantizeWeights(dw, bits: quantize, group: group, skip: ditSkip)
            nw = Self.quantizeWeights(nw, bits: quantize, group: group, skip: ["embeddings"])
            eval(Array(dw.values)); eval(Array(nw.values))   // materialize the packed 4-bit, drop fp16
        }
        switch cfg?.architecture ?? .flux {
        case .plain:
            let plain = DiTPlain(
                weights: dw,
                heads: cfg?.heads ?? 16,
                hidden: cfg?.hidden ?? 2048,
                depth: cfg?.depth ?? 21,
                numMoELayers: cfg?.numMoELayers ?? 6,
                numExperts: cfg?.numExperts ?? 8,
                moeTopK: cfg?.moeTopK ?? 2,
                bits: bits,
                groupSize: group,
                moeTokenChunkSize: executionStrategy.moeTokenChunkSize,
                usesSparseMoERouting:
                    executionStrategy.usesSparseMoERouting
            )
            self.dit = nil
            self.denoiser = plain
        case .flux:
            let flux = DiT(weights: dw, depth: cfg?.depth ?? 8, depthSingle: cfg?.depthSingle ?? 16,
                           guidanceEmbed: cfg?.guidanceEmbed ?? false, bits: bits, groupSize: group)
            self.dit = flux
            self.denoiser = flux
        }
        // Audit fix (a): the ShapeVAE scale_factor is per-checkpoint (2mini 1.0188…, the whole 2.0
        // family 0.99909…, 2.1 1.00395…). It was previously hardcoded to the 2mini value, giving a
        // silent ~2% SDF-scale error on every non-mini model. Read it from config.yaml and pass it
        // through; fall back to the 2mini value when the config is absent.
        self.vae = VAE(weights: vw, scaleFactor: cfg?.scaleFactor ?? 1.0188137)
        self.dino = DINOv2(weights: nw,
                           heads: cfg?.dinoHeads ?? 24,
                           layers: cfg?.dinoLayers ?? 40,
                           feedForward: (cfg?.dinoUsesSwiGLU ?? true) ? .swiGLU : .mlp,
                           bits: bits, groupSize: group)
        self.numLatents = numLatents ?? cfg?.numLatents ?? 512
        self.supportsMultiView = cfg?.multiViewConditioner ?? false
        self.executionStrategy = executionStrategy
    }

    /// Which denoiser family a checkpoint declares. The two are not
    /// interchangeable: they share no weight keys.
    enum Architecture: Equatable, Sendable {
        /// `Hunyuan3DDiT` — FLUX-style double/single stream (2mini, 2.0, 2mv).
        case flux
        /// `HunYuanDiTPlain` — U-shaped MoE stack (2.1).
        case plain
    }

    struct ModelConfig {
        var architecture: Architecture = .flux
        let depth: Int
        let depthSingle: Int
        let guidanceEmbed: Bool
        let numLatents: Int
        let scaleFactor: Float
        let multiViewConditioner: Bool
        /// `plain` only: the config's own DiT geometry and MoE routing.
        var hidden: Int = 1_024
        var heads: Int = 16
        var numMoELayers: Int = 0
        var numExperts: Int = 0
        var moeTopK: Int = 0
        /// Conditioner geometry. The 2.x family uses DINOv2-giant with SwiGLU;
        /// 2.1 uses DINOv2-large with a plain MLP.
        var dinoHeads: Int = 24
        var dinoLayers: Int = 40
        var dinoUsesSwiGLU: Bool = true
    }

    /// Parse the per-model shape params from the checkpoint's sibling `config.yaml`
    /// (so mini / 2.0 / turbo variants all load correctly). Minimal key-scan — no YAML lib.
    static func readConfig(_ weightsURL: URL) -> ModelConfig? {
        let url = weightsURL.deletingLastPathComponent().appendingPathComponent("config.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return readConfigurationText(text)
    }

    static func readConfigurationText(_ text: String) -> ModelConfig? {
        if text.contains("HunYuanDiTPlain") { return readPlainConfig(text) }
        guard let d = configValue("depth", in: text).flatMap({ Int($0) }),
              let ds = configValue("depth_single_blocks", in: text)
                .flatMap({ Int($0) }),
              let nl = configValue("num_latents", in: text)
                .flatMap({ Int($0) }) else { return nil }
        // Audit fix (a): parse scale_factor; default to the 2mini value if the key is absent.
        let sf = configValue("scale_factor", in: text)
            .flatMap { Float($0) } ?? 1.0188137142395404
        return ModelConfig(depth: d, depthSingle: ds,
                           guidanceEmbed: configValue("guidance_embed", in: text)?
                            .lowercased() == "true",
                           numLatents: nl, scaleFactor: sf,
                           multiViewConditioner: text.contains("DinoImageEncoderMV"))
    }

    /// Hunyuan3D-2.1 (`HunYuanDiTPlain`). Two parsing traps in that config:
    /// the latent count is written as the YAML anchor `input_size: &num_latents
    /// 4096` (the later `num_latents:` line is an alias reference and will not
    /// parse as an integer), and `hidden_size` / `num_heads` also appear inside
    /// the DINO block — the model block comes first, so a first-match scan takes
    /// the right one, and the conditioner geometry is read from its own keys.
    static func readPlainConfig(_ text: String) -> ModelConfig? {
        guard let depth = configValue("depth", in: text).flatMap({ Int($0) }),
              let hidden = configValue("hidden_size", in: text)
                .flatMap({ Int($0) }),
              let heads = configValue("num_heads", in: text)
                .flatMap({ Int($0) }),
              let latents = configValue("input_size", in: text)
                .flatMap({ $0.split(separator: " ").last.map(String.init) })
                .flatMap({ Int($0) }),
              let scaleFactor = configValue("scale_factor", in: text)
                .flatMap({ Float($0) }),
              depth > 0, hidden > 0, heads > 0, latents > 0,
              hidden % heads == 0,
              scaleFactor.isFinite, scaleFactor > 0 else { return nil }
        return ModelConfig(
            architecture: .plain,
            depth: depth,
            // `plain` has no single-stream half; the field stays zero so a
            // FLUX-only reader cannot silently misuse this config.
            depthSingle: 0,
            guidanceEmbed: false,
            numLatents: latents,
            scaleFactor: scaleFactor,
            multiViewConditioner: false,
            hidden: hidden,
            heads: heads,
            numMoELayers: configValue("num_moe_layers", in: text)
                .flatMap({ Int($0) }) ?? 0,
            numExperts: configValue("num_experts", in: text)
                .flatMap({ Int($0) }) ?? 0,
            moeTopK: configValue("moe_top_k", in: text)
                .flatMap({ Int($0) }) ?? 0,
            dinoHeads: configValue("num_attention_heads", in: text)
                .flatMap({ Int($0) }) ?? 16,
            dinoLayers: configValue("num_hidden_layers", in: text)
                .flatMap({ Int($0) }) ?? 24,
            dinoUsesSwiGLU: configValue("use_swiglu_ffn", in: text)?
                .lowercased() != "false"
        )
    }

    static func readStrictConfig(
        _ weightsURL: URL,
        requiredConditioning: ShapeConditioningContract
    ) throws -> ModelConfig {
        let url = weightsURL.deletingLastPathComponent()
            .appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ShapeWeightLoadingError.missingConfiguration
        }
        if let text = try? String(contentsOf: url, encoding: .utf8),
           text.contains("HunYuanDiTPlain") {
            guard let config = readPlainConfig(text) else {
                throw ShapeWeightLoadingError.invalidConfiguration
            }
            try validate(config, against: requiredConditioning)
            return config
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let depth = configValue("depth", in: text).flatMap(Int.init),
              let depthSingle = configValue(
                "depth_single_blocks",
                in: text
              ).flatMap(Int.init),
              let numLatents = configValue("num_latents", in: text)
                .flatMap(Int.init),
              let scaleFactor = configValue("scale_factor", in: text)
                .flatMap(Float.init),
              let guidanceValue = configValue("guidance_embed", in: text)?
                .lowercased(),
              guidanceValue == "true" || guidanceValue == "false",
              depth > 0,
              depthSingle > 0,
              numLatents > 0,
              scaleFactor.isFinite,
              scaleFactor > 0 else {
            throw ShapeWeightLoadingError.invalidConfiguration
        }
        let config = ModelConfig(
            depth: depth,
            depthSingle: depthSingle,
            guidanceEmbed: guidanceValue == "true",
            numLatents: numLatents,
            scaleFactor: scaleFactor,
            multiViewConditioner: declaresMultiViewConditioner(in: text)
        )
        try validate(config, against: requiredConditioning)
        return config
    }

    private static func validate(
        _ config: ModelConfig,
        against contract: ShapeConditioningContract
    ) throws {
        switch contract {
        case .multiView:
            guard config.multiViewConditioner else {
                throw ShapeWeightLoadingError.requiredMultiViewConfiguration
            }
        case .singleImage:
            // A multi-view conditioner adds a per-view camera embedding and
            // concatenates four token blocks; feeding it one view is not the
            // same model, so this is a hard mismatch rather than a degradation.
            guard !config.multiViewConditioner else {
                throw ShapeWeightLoadingError.requiredSingleImageConfiguration
            }
        }
    }

    private static func configValue(
        _ key: String,
        in text: String
    ) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\(key):") {
                return line.dropFirst(key.count + 1)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func declaresMultiViewConditioner(in text: String) -> Bool {
        text.split(separator: "\n").contains { raw in
            let declaration = raw.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first?.trimmingCharacters(in: .whitespaces)
            return declaration == "type: DinoImageEncoderMV"
        }
    }

    private static func validateStrictFP16(
        _ weights: [String: MLXArray]
    ) throws {
        for (name, value) in weights {
            if name.hasSuffix(".scales") || name.hasSuffix(".biases") {
                throw ShapeWeightLoadingError.quantizedArtifact
            }
            guard value.dtype == .float16 else {
                throw ShapeWeightLoadingError.nonFP16Tensor(
                    name: name,
                    dtype: dtypeName(value.dtype)
                )
            }
        }
    }

    private static func dtypeName(_ dtype: DType) -> String {
        switch dtype {
        case .bool: "bool"
        case .uint8: "uint8"
        case .uint16: "uint16"
        case .uint32: "uint32"
        case .uint64: "uint64"
        case .int8: "int8"
        case .int16: "int16"
        case .int32: "int32"
        case .int64: "int64"
        case .float16: "float16"
        case .float32: "float32"
        case .bfloat16: "bfloat16"
        case .complex64: "complex64"
        case .float64: "float64"
        }
    }

    /// Quantize the 2-D linear weights of a sub-model in place, skipping any path in `skip` and any
    /// weight whose input dim isn't a multiple of the group size. Mirrors hy3dmlx.convert._quantize.
    static func quantizeWeights(_ d: [String: MLXArray], bits: Int, group: Int,
                                skip: [String]) -> [String: MLXArray] {
        var out = d
        for (k, v) in d where k.hasSuffix(".weight") && v.ndim == 2 && v.dim(1) % group == 0
            && !skip.contains(where: { k.contains($0) }) {
            let (wq, scales, biases) = quantized(v, groupSize: group, bits: bits)
            out[k] = wq
            out["\(k).scales"] = scales
            if let biases { out["\(k).biases"] = biases }
        }
        return out
    }

    public struct Progress: Sendable { public let stage: String; public let fraction: Float }

    /// Release cached Metal buffers after an entire model stage has completed.
    /// Callers should also release their `ShapeGenerator` reference before
    /// starting Paint so Shape and Paint weights never coexist.
    public static func releaseMemoryCache() {
        MLX.Memory.clearCache()
    }

    /// Full on-device pipeline: photo -> watertight mesh.
    /// `isCancelled` is polled through DINO layers/views, denoise steps, SDF
    /// chunks, Marching Cubes slices, and stage boundaries; returns nil if it
    /// fires.
    public func generate(image: CGImage, steps: Int = 30, guidance: Float = 5.0,
                         seed: UInt64 = 0, resolution: Int = 256, octree: Bool = true,
                         isCancelled: @escaping () -> Bool = { false },
                         onPreview: ((Mesh) -> Void)? = nil,
                         onProgress: ((Progress) -> Void)? = nil) -> Mesh? {
        generate(images: [.front: image], steps: steps, guidance: guidance,
                 seed: seed, resolution: resolution, octree: octree,
                 isCancelled: isCancelled, onPreview: onPreview,
                 onProgress: onProgress)
    }

    /// 1–4 canonical views -> watertight mesh. Views are sorted to Tencent's
    /// fixed front/left/back/right order regardless of dictionary order.
    public func generate(images: [View: CGImage], steps: Int = 30, guidance: Float = 5.0,
                         seed: UInt64 = 0, resolution: Int = 256, octree: Bool = true,
                         isCancelled: @escaping () -> Bool = { false },
                         onPreview: ((Mesh) -> Void)? = nil,
                         onProgress: ((Progress) -> Void)? = nil) -> Mesh? {
        try? generateCheckingCancellation(images: images, steps: steps, guidance: guidance,
            seed: seed, resolution: resolution, octree: octree, isCancelled: isCancelled,
            onPreview: onPreview, onProgress: onProgress)
    }

    /// The throwing GLB entry uses this directly. Legacy optional mesh APIs
    /// retain nil-on-failure compatibility without manufacturing a latent/mesh.
    private func generateCheckingCancellation(images: [View: CGImage], steps: Int, guidance: Float,
                          seed: UInt64, resolution: Int, octree: Bool,
                          isCancelled: @escaping () -> Bool,
                          onPreview: ((Mesh) -> Void)? = nil,
                          onProgress: ((Progress) -> Void)? = nil) throws -> Mesh? {
        try ShapeCheckedLoop.check(isCancelled)
        let ordered = images.sorted { $0.key.rawValue < $1.key.rawValue }
        guard !ordered.isEmpty, ordered.count <= 4 else { return nil }
        guard ordered.count == 1 || supportsMultiView else { return nil }
        let pixels = ordered.compactMap { Preprocess.dinoPixels(cgImage: $0.value) }
        guard pixels.count == ordered.count else { return nil }
        try ShapeCheckedLoop.check(isCancelled)
        onProgress?(.init(stage: "Conditioning \(ordered.count) view(s)", fraction: 0.05))
        // Turbo/distilled models embed guidance and skip CFG → conditional embedding only.
        let embed: MLXArray
        if supportsMultiView {
            guard let value = dino.multiView(
                pixels,
                viewIndices: ordered.map(\.key.rawValue),
                isCancelled: isCancelled
            ) else { try ShapeCheckedLoop.check(isCancelled); return nil }
            embed = value
        } else {
            guard let value = dino(
                pixels[0],
                isCancelled: isCancelled
            ) else { try ShapeCheckedLoop.check(isCancelled); return nil }
            embed = value
        }
        let cond = denoiser.guidanceEmbed ? embed
            : concatenated(
                [embed,
                 dino.unconditional(1, tokens: embed.dim(1), hidden: embed.dim(2))],
                axis: 0
            )
        eval(cond)
        try ShapeCheckedLoop.check(isCancelled)

        let pipe = Pipeline(
            denoiser: denoiser,
            vae: vae,
            serializesClassifierFreeGuidance:
                executionStrategy.serializesClassifierFreeGuidance
        )
        let noise = Sampler.noise(numLatents: numLatents, seed: seed)
        // Tencent's FlowMatching pipeline uses linspace(0, 1, steps) for
        // standard, Fast and Turbo checkpoints alike. `guidance_embed`
        // changes CFG execution, not the scheduler grid.
        let sigmas = Sampler.flowMatchSigmas(steps)
        // Decode a coarse preview from the in-progress latent at a few steps (a meshable
        // surface emerges partway through denoising; earlier steps are skipped when empty).
        let previewSteps: Set<Int> = onPreview == nil ? []
            : Set([0.4, 0.55, 0.7, 0.85].map { Int((Float(steps) * Float($0)).rounded()) })
        let lat = try pipe.denoiseCancellable(cond: cond, noise: noise, sigmas: sigmas, guidance: guidance,
                               guidanceEmbed: denoiser.guidanceEmbed, isCancelled: isCancelled) { i, n, curLat in
            onProgress?(.init(stage: "Denoising (\(i)/\(n))", fraction: 0.1 + 0.6 * Float(i) / Float(n)))
            if previewSteps.contains(i), let onPreview, !isCancelled(),
               let g = try? pipe.gridSDFOctree(
                    latents: curLat,
                    resolution: 48,
                    isCancelled: isCancelled
               ), let m = try? MarchingCubes.extract(
                    grid: g,
                    level: 0.0,
                    isCancelled: isCancelled
               ) {
                MLX.Memory.clearCache()
                if !m.vertices.isEmpty && !m.faces.isEmpty { onPreview(m) }
            }
        }
        try ShapeCheckedLoop.check(isCancelled)
        eval(lat); MLX.Memory.clearCache()        // release the 30-step denoise buffers before decode
        try ShapeCheckedLoop.check(isCancelled)

        onProgress?(.init(stage: "Decoding shape", fraction: 0.72))
        let grid: MLXArray
        do {
            grid = try octree
                ? pipe.gridSDFOctree(
                    latents: lat,
                    resolution: resolution,
                    isCancelled: isCancelled
                )
                : pipe.gridSDF(
                    latents: lat,
                    resolution: resolution,
                    isCancelled: isCancelled
                )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        eval(grid); MLX.Memory.clearCache()       // release decode buffers before marching cubes
        try ShapeCheckedLoop.check(isCancelled)

        onProgress?(.init(stage: "Building mesh", fraction: 0.9))
        let mesh: Mesh
        do {
            mesh = try MarchingCubes.extract(grid: grid, level: 0.0, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch { return nil }
        onProgress?(.init(stage: "Done", fraction: 1.0))
        try ShapeCheckedLoop.check(isCancelled)
        return mesh
    }

    /// Generate and write a `.glb`; returns vertex/face counts. `onRawMesh` is
    /// for host QA: it receives a value snapshot before legacy cleanup. The
    /// default nil performs no diagnostic I/O; the ordinary SDK passes nil.
    @discardableResult
    public func generateGLB(image: CGImage, to url: URL, steps: Int = 30, guidance: Float = 5.0,
                            seed: UInt64 = 0, resolution: Int = 256, octree: Bool = true,
                            cleanupPolicy: MeshCleanupPolicy = .legacyThreshold,
                            isCancelled: @escaping () -> Bool = { false },
                            onRawMesh: ((Mesh) throws -> Void)? = nil,
                            onProgress: ((Progress) -> Void)? = nil) throws -> (verts: Int, faces: Int) {
        guard let generated = try generateCheckingCancellation(images: [.front: image], steps: steps, guidance: guidance, seed: seed,
                                       resolution: resolution, octree: octree,
                                       isCancelled: isCancelled, onProgress: onProgress) else {
            throw NSError(domain: "Hy3DMLX", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "generation cancelled or image preprocessing failed"])
        }
        try ShapeCheckedLoop.check(isCancelled)
        let mesh = try ShapeMeshFinalizer.cleaned(generated,policy:cleanupPolicy,onRawMesh:onRawMesh)
        try ShapeCheckedLoop.check(isCancelled)
        try GLB.write(mesh, to: url, isCancelled: isCancelled)
        try ShapeCheckedLoop.check(isCancelled)
        return (mesh.vertices.count, mesh.faces.count)
    }

    @discardableResult
    public func generateGLB(images: [View: CGImage], to url: URL, steps: Int = 30,
                            guidance: Float = 5.0, seed: UInt64 = 0,
                            resolution: Int = 256, octree: Bool = true,
                            cleanupPolicy: MeshCleanupPolicy = .legacyThreshold,
                            isCancelled: @escaping () -> Bool = { false },
                            onRawMesh: ((Mesh) throws -> Void)? = nil,
                            onProgress: ((Progress) -> Void)? = nil) throws
        -> (verts: Int, faces: Int) {
        guard let generated = try generateCheckingCancellation(images: images, steps: steps, guidance: guidance,
                                       seed: seed, resolution: resolution, octree: octree,
                                       isCancelled: isCancelled, onProgress: onProgress) else {
            throw NSError(domain: "Hy3DMLX", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "multi-view generation cancelled or preprocessing failed"])
        }
        try ShapeCheckedLoop.check(isCancelled)
        let mesh = try ShapeMeshFinalizer.cleaned(generated,policy:cleanupPolicy,onRawMesh:onRawMesh)
        try ShapeCheckedLoop.check(isCancelled)
        try GLB.write(mesh, to: url, isCancelled: isCancelled)
        try ShapeCheckedLoop.check(isCancelled)
        return (mesh.vertices.count, mesh.faces.count)
    }
}
