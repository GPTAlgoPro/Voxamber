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

    /// A protocol requirement so existential sampler calls dynamically reach
    /// the architecture's interior checkpoints, rather than an extension-only
    /// default. A currently executing MLX evaluation cannot be preempted.
    func forwardCancellable(
        _ x: MLXArray,
        _ t: MLXArray,
        _ cond: MLXArray,
        guidance: MLXArray?,
        isCancelled: () -> Bool
    ) throws -> MLXArray
}

public extension ShapeDenoiser {
    func forwardCancellable(_ x: MLXArray, _ t: MLXArray, _ cond: MLXArray,
                            guidance: MLXArray?, isCancelled: () -> Bool) throws -> MLXArray {
        try ShapeCheckedLoop.check(isCancelled)
        let result = callAsFunction(x, t, cond, guidance: guidance)
        try ShapeCheckedLoop.check(isCancelled)
        return result
    }
}

/// The actual synchronous traversal used by MoE chunk/expert execution. Its
/// generic bodies let CPU tests observe admission without inventing a second
/// scheduler. It adds no MLX evaluation, cache clearing, or synchronization.
enum ShapeCheckedLoop {
    static func check(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    static func forEach<Indices: Sequence>(_ indices: Indices, check: () throws -> Void,
                                          body: (Indices.Element) throws -> Void) rethrows {
        for index in indices {
            try check()
            try body(index)
            try check()
        }
    }

    static func chunks<T>(rowCount: Int, chunkSize: Int, check: () throws -> Void,
                          make: (Range<Int>) throws -> T, afterAppend: () -> Void) rethrows -> [T] {
        precondition(rowCount >= 0 && chunkSize > 0)
        var chunks: [T] = []
        chunks.reserveCapacity((rowCount + chunkSize - 1) / chunkSize)
        var start = 0
        while start < rowCount {
            try check()
            let end = Swift.min(start + chunkSize, rowCount)
            let value = try make(start..<end)
            chunks.append(value)
            afterAppend()
            try check()
            start = end
        }
        return chunks
    }
}
