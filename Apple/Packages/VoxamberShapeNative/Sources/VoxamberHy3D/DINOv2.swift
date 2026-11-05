import Foundation
import MLX

/// DINOv2-giant conditioner (ViT + SwiGLU) in MLX Swift. Functional port of hy3dmlx/models/dinov2.py.
/// Input: NHWC pixel values [1,518,518,3], already resized + ImageNet-normalized.
/// Weights are the `conditioner.main_image_encoder.model.` subtree (prefix stripped to `model.`...
/// here keys are stripped to the bare `embeddings.* / encoder.layer.* / layernorm.*`).
public struct DINOv2 {
    /// DINOv2-giant (the 2.0 family conditioner) uses a SwiGLU feed-forward;
    /// DINOv2-large (the 2.1 conditioner, `use_swiglu_ffn: false`) uses the
    /// plain `fc1 -> GELU -> fc2` block instead.
    public enum FeedForward: Sendable {
        case swiGLU
        case mlp
    }

    let w: [String: MLXArray]
    let heads: Int
    let layers: Int
    let patchW: MLXArray   // [out, kh, kw, in] for MLX conv2d
    let patch: Int
    let bits: Int
    let groupSize: Int

    let feedForward: FeedForward

    public init(weights: [String: MLXArray], heads: Int = 24, layers: Int = 40, patch: Int = 14,
                feedForward: FeedForward = .swiGLU,
                bits: Int = 4, groupSize: Int = 64) {
        self.w = weights; self.heads = heads; self.layers = layers; self.patch = patch
        self.feedForward = feedForward
        self.bits = bits; self.groupSize = groupSize
        // safetensors stores NCHW [out,in,kh,kw]; MLX conv2d wants [out,kh,kw,in]
        self.patchW = weights["embeddings.patch_embeddings.projection.weight"]!.transposed(0, 2, 3, 1)
    }

    private func g(_ k: String) -> MLXArray { w[k]! }
    private func lin(_ x: MLXArray, _ p: String) -> MLXArray {
        let wk = "\(p).weight"
        if let s = w["\(wk).scales"], let b = w["\(wk).biases"] {
            return Layers.qlinear(x, g(wk), scales: s, biases: b, bias: w["\(p).bias"],
                                  bits: bits, groupSize: groupSize)
        }
        return Layers.linear(x, g(wk), w["\(p).bias"])
    }
    private func ln(_ x: MLXArray, _ p: String) -> MLXArray {
        Layers.layerNorm(x, g("\(p).weight"), g("\(p).bias"), eps: 1e-6)
    }

    private func attn(_ x: MLXArray, _ p: String) -> MLXArray {
        let B = x.dim(0), N = x.dim(1)
        func h(_ t: MLXArray) -> MLXArray { t.reshaped([B, N, heads, -1]).transposed(0, 2, 1, 3) }
        let q = h(lin(x, "\(p).attention.query"))
        let k = h(lin(x, "\(p).attention.key"))
        let v = h(lin(x, "\(p).attention.value"))
        let o = Layers.sdpa(q, k, v).transposed(0, 2, 1, 3).reshaped([B, N, -1])
        return lin(o, "\(p).output.dense")
    }

    private func swiglu(_ x: MLXArray, _ p: String) -> MLXArray {
        let hpair = split(lin(x, "\(p).weights_in"), parts: 2, axis: -1)
        return lin(Layers.silu(hpair[0]) * hpair[1], "\(p).weights_out")
    }

    /// HF Dinov2 `Dinov2MLP`: `hidden_act: gelu` is the exact erf GELU.
    private func gluFreeMLP(_ x: MLXArray, _ p: String) -> MLXArray {
        lin(Layers.geluErf(lin(x, "\(p).fc1")), "\(p).fc2")
    }

    private func mlpBlock(_ x: MLXArray, _ p: String) -> MLXArray {
        switch feedForward {
        case .swiGLU: swiglu(x, p)
        case .mlp: gluFreeMLP(x, p)
        }
    }

    /// pixels NHWC [B,518,518,3] -> last_hidden_state [B,1370,1536]
    public func callAsFunction(_ pixels: MLXArray) -> MLXArray {
        callAsFunctionImpl(
            pixels,
            materializeLayerBoundaries: false,
            isCancelled: { false }
        )!
    }

    /// Cancellable DINO encoding used by the app-facing Shape runtime. Each
    /// transformer layer is materialized before the next cancellation check so
    /// MLX lazy evaluation cannot collapse all 40 layers into one long,
    /// uninterruptible `eval`. The legacy overload above preserves its original
    /// lazy graph for existing CLI callers.
    public func callAsFunction(
        _ pixels: MLXArray,
        isCancelled: () -> Bool
    ) -> MLXArray? {
        callAsFunctionImpl(
            pixels,
            materializeLayerBoundaries: true,
            isCancelled: isCancelled
        )
    }

    private func callAsFunctionImpl(
        _ pixels: MLXArray,
        materializeLayerBoundaries: Bool,
        isCancelled: () -> Bool
    ) -> MLXArray? {
        if isCancelled() { return nil }
        let B = pixels.dim(0)
        var p = conv2d(pixels, patchW, stride: IntOrPair(patch))             // [B,37,37,hidden]
        p = p + g("embeddings.patch_embeddings.projection.bias")
        let hidden = p.dim(-1)
        p = p.reshaped([B, p.dim(1) * p.dim(2), hidden])                     // [B,1369,hidden]
        let cls = broadcast(g("embeddings.cls_token"), to: [B, 1, hidden])
        var x = concatenated([cls, p], axis: 1) + g("embeddings.position_embeddings")
        if materializeLayerBoundaries {
            eval(x)
            if isCancelled() { return nil }
        }
        for i in 0 ..< layers {
            if isCancelled() { return nil }
            let lp = "encoder.layer.\(i)"
            x = x + g("\(lp).layer_scale1.lambda1") * attn(ln(x, "\(lp).norm1"), "\(lp).attention")
            x = x + g("\(lp).layer_scale2.lambda1") * mlpBlock(ln(x, "\(lp).norm2"), "\(lp).mlp")
            if materializeLayerBoundaries {
                eval(x)
            }
            if isCancelled() { return nil }
        }
        if isCancelled() { return nil }
        return ln(x, "layernorm")
    }

    /// Hunyuan3D-2mv adds a fixed sinusoidal camera-view embedding to every
    /// DINO token before concatenating the views. Indices follow Tencent's
    /// contract: front=0, left=1, back=2, right=3.
    public func callAsFunction(_ pixels: MLXArray, viewIndex: Int) -> MLXArray {
        let encoded = callAsFunction(pixels)
        let hidden = encoded.dim(2)
        let values = Self.viewEmbedding(index: viewIndex, hidden: hidden)
        let embedding = MLXArray(values, [1, 1, hidden])
        return encoded + embedding
    }

    public func callAsFunction(
        _ pixels: MLXArray,
        viewIndex: Int,
        isCancelled: () -> Bool
    ) -> MLXArray? {
        guard let encoded = callAsFunction(
            pixels,
            isCancelled: isCancelled
        ), !isCancelled() else { return nil }
        let hidden = encoded.dim(2)
        let values = Self.viewEmbedding(index: viewIndex, hidden: hidden)
        let embedding = MLXArray(values, [1, 1, hidden])
        return encoded + embedding
    }

    static func viewEmbedding(index: Int, hidden: Int) -> [Float] {
        precondition(hidden % 2 == 0)
        let half = hidden / 2
        var values = [Float](repeating: 0, count: hidden)
        for i in 0 ..< half {
            let omega = 1.0 / pow(10_000.0, Double(i) / Double(half))
            let phase = Double(index) * omega
            values[i] = Float(sin(phase))
            values[half + i] = Float(cos(phase))
        }
        return values
    }

    /// Encode views one at a time to bound the DINO activation peak, then
    /// concatenate only the compact token outputs for the Shape DiT.
    public func multiView(_ pixels: [MLXArray], viewIndices: [Int]) -> MLXArray {
        precondition(!pixels.isEmpty && pixels.count == viewIndices.count)
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(pixels.count)
        for (image, index) in zip(pixels, viewIndices) {
            let value = callAsFunction(image, viewIndex: index)
            eval(value)
            outputs.append(value)
            MLX.Memory.clearCache()
        }
        return concatenated(outputs, axis: 1)
    }

    public func multiView(
        _ pixels: [MLXArray],
        viewIndices: [Int],
        isCancelled: () -> Bool
    ) -> MLXArray? {
        precondition(!pixels.isEmpty && pixels.count == viewIndices.count)
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(pixels.count)
        for (image, index) in zip(pixels, viewIndices) {
            guard !isCancelled(), let value = callAsFunction(
                image,
                viewIndex: index,
                isCancelled: isCancelled
            ) else { return nil }
            eval(value)
            if isCancelled() { return nil }
            outputs.append(value)
            MLX.Memory.clearCache()
        }
        if isCancelled() { return nil }
        return concatenated(outputs, axis: 1)
    }

    public func unconditional(_ batch: Int, tokens: Int = 1370, hidden: Int = 1536) -> MLXArray {
        MLXArray.zeros([batch, tokens, hidden])
    }
}
