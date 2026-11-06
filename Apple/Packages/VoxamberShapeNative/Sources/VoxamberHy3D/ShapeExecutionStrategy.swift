/// Controls memory-versus-throughput choices that do not change a Shape
/// checkpoint's mathematical contract. In particular, this never changes the
/// checkpoint-defined latent count, layer geometry, or quantization.
public struct ShapeExecutionStrategy: Equatable, Sendable {
    /// Runs conditional and unconditional classifier-free-guidance passes one
    /// after the other instead of duplicating the latent batch. This trades
    /// throughput for a smaller live activation set.
    public let serializesClassifierFreeGuidance: Bool

    /// Maximum number of flattened tokens sent through one MoE expert FFN.
    /// `nil` preserves the full-matrix throughput path.
    public let moeTokenChunkSize: Int?

    /// Evaluates only the tokens selected by the router for each expert. The
    /// selected tokens are bucketed on the host once per MoE layer, then each
    /// expert still receives one reasonably sized matrix multiply rather than
    /// thousands of one-token gathers.
    public let usesSparseMoERouting: Bool

    public init(
        serializesClassifierFreeGuidance: Bool = false,
        moeTokenChunkSize: Int? = nil,
        usesSparseMoERouting: Bool = false
    ) {
        self.serializesClassifierFreeGuidance =
            serializesClassifierFreeGuidance
        if let moeTokenChunkSize, moeTokenChunkSize > 0 {
            self.moeTokenChunkSize = moeTokenChunkSize
        } else {
            self.moeTokenChunkSize = nil
        }
        self.usesSparseMoERouting = usesSparseMoERouting
    }

    /// Existing desktop behavior and the numerical reference for A/B runs.
    public static let throughput = ShapeExecutionStrategy()

    /// Candidate for memory-constrained Apple silicon. A caller still has to
    /// pass its device admission gate; this strategy is not evidence that a
    /// model fits a particular iPhone.
    public static func constrainedMemory(
        moeTokenChunkSize: Int = 512
    ) -> ShapeExecutionStrategy {
        ShapeExecutionStrategy(
            serializesClassifierFreeGuidance: true,
            moeTokenChunkSize: moeTokenChunkSize
        )
    }

    public static func sparseConstrainedMemory(
        moeTokenChunkSize: Int = 512
    ) -> ShapeExecutionStrategy {
        ShapeExecutionStrategy(
            serializesClassifierFreeGuidance: true,
            moeTokenChunkSize: moeTokenChunkSize,
            usesSparseMoERouting: true
        )
    }
}
