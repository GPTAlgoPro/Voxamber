import Foundation

/// How a Shape checkpoint's tensors are named once it is packed for this repo,
/// and which of them a quantizing pack must leave in fp16.
///
/// Every Shape pack here is a single safetensors file with three trees:
/// `model.` (denoiser), `vae.` (shape VAE) and
/// `conditioner.main_image_encoder.model.` (image encoder) — that is what
/// `ShapeGenerator` splits on when it loads. The 2.x family ships exactly that
/// layout upstream. Hunyuan3D-2.1 does not: it publishes the denoiser, the VAE
/// and the image encoder as three separate files under their own prefixes, so
/// the pack step has to rewrite them into the one namespace.
public enum ShapePackLayout {
    public enum MergeError: Error, Equatable, LocalizedError {
        case unrecognizedPrefix(String)

        public var errorDescription: String? {
            switch self {
            case .unrecognizedPrefix(let key):
                "Tensor \(key) is not part of any known Hunyuan3D-2.1 tree."
            }
        }
    }

    public enum MergedKey: Equatable {
        /// Rewritten into the packed namespace.
        case keep(String)
        /// Deliberately dropped: the runtime decodes latents to a mesh and
        /// never encodes a point cloud, so the VAE's encoder half is dead
        /// weight (227 MB of a 655 MB file). The pack is reproducible from the
        /// pinned source if an encoding path ever needs it.
        case dropUnusedVAEEncoder
    }

    /// Source prefix → packed prefix, longest match first so the two `vae.`
    /// rules cannot be shadowed by the general one.
    private static let rewrites: [(source: String, packed: String)] = [
        ("dit.", "model."),
        ("image_encoder.", "conditioner.main_image_encoder.model."),
        ("vae.", "vae."),
    ]

    private static let droppedPrefixes = ["vae.encoder.", "vae.pre_kl."]

    public static func mergedKey(for key: String) throws -> MergedKey {
        if droppedPrefixes.contains(where: key.hasPrefix) {
            return .dropUnusedVAEEncoder
        }
        for rewrite in rewrites where key.hasPrefix(rewrite.source) {
            return .keep(rewrite.packed + key.dropFirst(rewrite.source.count))
        }
        throw MergeError.unrecognizedPrefix(key)
    }

    /// Substrings that keep a linear layer in fp16 during packing.
    ///
    /// FLUX-family (`Hunyuan3DDiT`) names: the embedders and the final
    /// projection. `HunYuanDiTPlain` names them differently and adds two of its
    /// own — the U-shape's `skip_linear`, and `moe.gate`, an 8x2048 router where
    /// quantization buys nothing and perturbing a score flips which experts a
    /// token is sent to.
    public static let fluxQuantizationSkips = [
        "latent_in", "time_in", "cond_in", "guidance_in",
        "final_layer", "x_embedder", "embeddings",
    ]

    public static let plainQuantizationSkips = [
        "x_embedder", "t_embedder", "final_layer", "skip_linear",
        "moe.gate", "embeddings",
    ]

    /// A packed 2.1 checkpoint is the only one with a MoE router, so its own
    /// keys say which skip list applies — no separate flag to keep in sync.
    public static func quantizationSkips(
        forPackedKeys keys: some Sequence<String>
    ) -> [String] {
        keys.contains { $0.hasSuffix(".moe.gate.weight") }
            ? plainQuantizationSkips
            : fluxQuantizationSkips
    }

    /// Only the denoiser and the conditioner have quantized-linear dispatch at
    /// runtime; the VAE is plain fp16 matmuls, so packing it would shrink the
    /// file into something that cannot be loaded.
    public static func isQuantizable(
        packedKey: String,
        rank: Int,
        innerDimension: Int,
        groupSize: Int,
        skips: [String]
    ) -> Bool {
        let quantizableTree = packedKey.hasPrefix("model.")
            || packedKey.hasPrefix("conditioner.main_image_encoder.model.")
        return quantizableTree
            && packedKey.hasSuffix(".weight")
            && rank == 2
            && innerDimension % groupSize == 0
            && !skips.contains(where: packedKey.contains)
    }
}
