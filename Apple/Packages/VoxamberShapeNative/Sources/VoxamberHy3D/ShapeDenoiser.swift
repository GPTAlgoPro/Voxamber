import Foundation
import MLX

/// The Shape stage runs two different denoiser families that share one sampler
/// loop: the FLUX-style double/single stream `DiT` (2mini / 2.0 / 2mv) and the
/// U-shaped `DiTPlain` with MoE feed-forwards (2.1). `Pipeline` only needs the
/// forward call and whether the checkpoint embeds guidance instead of running
/// classifier-free guidance, so that is all this protocol exposes.
public protocol ShapeDenoiser {
    /// `true` for distilled checkpoints that take the guidance value as a token
    /// and therefore run one forward per step instead of a duplicated CFG batch.
    var guidanceEmbed: Bool { get }

    /// - Parameters:
    ///   - x: latents `[B, N, in_channels]`
    ///   - t: timestep per batch element, already normalised to `[0, 1]`
    ///   - cond: conditioning tokens `[B, L, context_dim]`
    ///   - guidance: guidance value for `guidanceEmbed` checkpoints, else `nil`
    func callAsFunction(
        _ x: MLXArray,
        _ t: MLXArray,
        _ cond: MLXArray,
        guidance: MLXArray?
    ) -> MLXArray
}
