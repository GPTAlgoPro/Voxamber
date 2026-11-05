import Foundation
import MLX

/// `HunYuanDiTPlain` — the Hunyuan3D-2.1 shape denoiser — in MLX Swift.
///
/// Structurally unrelated to ``DiT``: instead of FLUX double/single streams it
/// is a flat stack of `depth` blocks (self-attention → cross-attention → FFN)
/// with a U-shaped skip connection between the first and last halves, and a
/// mixture-of-experts feed-forward in the trailing `numMoELayers` blocks.
///
/// Two upstream quirks are reproduced deliberately; "fixing" either one puts the
/// weights out of contract:
///
/// 1. `Attention`/`CrossAttention` concatenate the projections and then reshape
///    the fused tensor to `[.., heads, n * headDim]` before splitting. That is
///    not a plain q/k/v split — it permutes slices across heads — but training
///    and inference upstream share this code, so the weights are trained for it.
/// 2. Every feed-forward uses `nn.GELU()` (exact erf), not the tanh
///    approximation the FLUX-style ``DiT`` MLPs use.
public struct DiTPlain: ShapeDenoiser {
    let w: [String: MLXArray]
    let heads: Int
    let hidden: Int
    let depth: Int
    let numMoELayers: Int
    let numExperts: Int
    let moeTopK: Int
    let bits: Int
    let groupSize: Int
    let moeTokenChunkSize: Int?
    let usesSparseMoERouting: Bool

    /// 2.1 ships no distilled guidance-embedded variant; the sampler always runs
    /// classifier-free guidance over a duplicated batch.
    public var guidanceEmbed: Bool { false }

    public init(
        weights: [String: MLXArray],
        heads: Int = 16,
        hidden: Int = 2048,
        depth: Int = 21,
        numMoELayers: Int = 6,
        numExperts: Int = 8,
        moeTopK: Int = 2,
        bits: Int = 4,
        groupSize: Int = 64,
        moeTokenChunkSize: Int? = nil,
        usesSparseMoERouting: Bool = false
    ) {
        w = weights
        self.heads = heads
        self.hidden = hidden
        self.depth = depth
        self.numMoELayers = numMoELayers
        self.numExperts = numExperts
        self.moeTopK = moeTopK
        self.bits = bits
        self.groupSize = groupSize
        self.moeTokenChunkSize = moeTokenChunkSize
        self.usesSparseMoERouting = usesSparseMoERouting
    }

    private var headDim: Int { hidden / heads }

    private func g(_ k: String) -> MLXArray { w[k]! }

    private func lin(_ x: MLXArray, _ p: String) -> MLXArray {
        let wk = "\(p).weight"
        if let s = w["\(wk).scales"], let b = w["\(wk).biases"] {
            return Layers.qlinear(x, g(wk), scales: s, biases: b, bias: w["\(p).bias"],
                                  bits: bits, groupSize: groupSize)
        }
        return Layers.linear(x, g(wk), w["\(p).bias"])
    }

    /// Affine LayerNorm, eps 1e-6 everywhere in this model.
    private func ln(_ x: MLXArray, _ p: String) -> MLXArray {
        Layers.layerNorm(x, g("\(p).weight"), g("\(p).bias"), eps: 1e-6)
    }

    /// `nn.RMSNorm(head_dim, elementwise_affine=True, eps=1e-6)` over the head dim.
    private func rms(_ x: MLXArray, _ p: String) -> MLXArray {
        Layers.rmsNorm(x, g("\(p).weight"), eps: 1e-6)
    }

    /// `Timesteps(num_channels: hidden, downscale_freq_shift: 0, scale: 1,
    /// max_period: 10000)` — note `[sin, cos]` order and that the pipeline hands
    /// this a timestep already divided by `num_train_timesteps`, i.e. in [0, 1].
    func timestepFrequencies(_ t: MLXArray) -> MLXArray {
        let half = hidden / 2
        let exponent = -Float(log(10_000.0))
            * MLXArray(0 ..< half).asType(.float32) / Float(half)
        let freqs = exp(exponent)
        let args = t.asType(.float32).reshaped([t.dim(0), 1])
            * freqs.reshaped([1, half])
        return concatenated([sin(args), cos(args)], axis: -1)
    }

    /// Self-attention. `to_q/to_k/to_v` carry no bias (`qkv_bias: false`);
    /// `out_proj` does.
    private func attention(_ x: MLXArray, _ p: String) -> MLXArray {
        let B = x.dim(0), N = x.dim(1), hd = headDim
        let q = lin(x, "\(p).to_q")
        let k = lin(x, "\(p).to_k")
        let v = lin(x, "\(p).to_v")
        // Upstream's fused reshape — see the type comment. Slices, never an Int
        // subscript: MLXArray[Int] lowers to a gather with a 0-d index and trips
        // Metal API Validation.
        let fused = concatenated([q, k, v], axis: -1)
            .reshaped([1, B * N, heads, 3 * hd])
        let parts = split(fused, parts: 3, axis: -1)
        let qh = rms(parts[0].reshaped([B, N, heads, hd]), "\(p).q_norm")
            .transposed(0, 2, 1, 3)
        let kh = rms(parts[1].reshaped([B, N, heads, hd]), "\(p).k_norm")
            .transposed(0, 2, 1, 3)
        let vh = parts[2].reshaped([B, N, heads, hd]).transposed(0, 2, 1, 3)
        let o = Layers.sdpa(qh, kh, vh).transposed(0, 2, 1, 3)
            .reshaped([B, N, hidden])
        return lin(o, "\(p).out_proj")
    }

    /// Cross-attention against the DINO tokens. Only `k`/`v` go through the
    /// fused reshape upstream; `q` is reshaped straight.
    private func crossAttention(
        _ x: MLXArray,
        _ y: MLXArray,
        _ p: String
    ) -> MLXArray {
        let B = x.dim(0), s1 = x.dim(1), s2 = y.dim(1), hd = headDim
        let q = lin(x, "\(p).to_q").reshaped([B, s1, heads, hd])
        let fused = concatenated([lin(y, "\(p).to_k"), lin(y, "\(p).to_v")], axis: -1)
            .reshaped([1, B * s2, heads, 2 * hd])
        let kv = split(fused, parts: 2, axis: -1)
        let qh = rms(q, "\(p).q_norm").transposed(0, 2, 1, 3)
        let kh = rms(kv[0].reshaped([B, s2, heads, hd]), "\(p).k_norm")
            .transposed(0, 2, 1, 3)
        let vh = kv[1].reshaped([B, s2, heads, hd]).transposed(0, 2, 1, 3)
        let o = Layers.sdpa(qh, kh, vh).transposed(0, 2, 1, 3)
            .reshaped([B, s1, hidden])
        return lin(o, "\(p).out_proj")
    }

    /// The dense block FFN: `fc2(gelu(fc1(x)))`, width * 4 inner.
    private func mlp(_ x: MLXArray, _ p: String) -> MLXArray {
        lin(Layers.geluErf(lin(x, "\(p).fc1")), "\(p).fc2")
    }

    /// A diffusers `FeedForward(activation_fn: "gelu")`: `net.0.proj` → GELU →
    /// `net.2`. Used for both the routed experts and the shared expert.
    private func expertFeedForward(_ x: MLXArray, _ p: String) -> MLXArray {
        guard let chunkSize = moeTokenChunkSize,
              x.ndim == 2,
              x.dim(0) > chunkSize else {
            return lin(
                Layers.geluErf(lin(x, "\(p).net.0.proj")),
                "\(p).net.2"
            )
        }
        var chunks = [MLXArray]()
        chunks.reserveCapacity((x.dim(0) + chunkSize - 1) / chunkSize)
        var start = 0
        while start < x.dim(0) {
            let end = Swift.min(start + chunkSize, x.dim(0))
            let output = lin(
                Layers.geluErf(
                    lin(x[start ..< end], "\(p).net.0.proj")
                ),
                "\(p).net.2"
            )
            eval(output)
            chunks.append(output)
            MLX.Memory.clearCache()
            start = end
        }
        return concatenated(chunks, axis: 0)
    }

    /// Top-k routed MoE. Upstream leaves `norm_topk_prob` off, so the routing
    /// weights are the raw softmax scores of the selected experts.
    ///
    /// The dense reference evaluates every expert and masks. A separately
    /// gated sparse strategy buckets the router's selected tokens on the host
    /// and runs batched expert matrices; production remains on this reference
    /// path until the sparse candidate passes the same geometry fixtures.
    private func moe(_ x: MLXArray, _ p: String) -> MLXArray {
        let channels = x.dim(-1)
        let flat = x.reshaped([-1, channels])
        let gateWeight = g("\(p).gate.weight").asType(.float32)
        let scores = softmax(
            matmul(flat.asType(.float32), gateWeight.transposed(1, 0)),
            axis: -1
        )
        // `torch.topk(..., sorted=False)`: membership is all that matters.
        let order = argPartition(-scores, kth: moeTopK - 1, axis: -1)
        let chosen = split(order, indices: [moeTopK], axis: -1)[0]
        if usesSparseMoERouting {
            return sparseMoE(
                originalShape: x.shape,
                flat: flat,
                scores: scores,
                chosen: chosen,
                prefix: p
            )
        }
        let threshold = takeAlong(scores, chosen, axis: -1)
            .min(axis: -1, keepDims: true)
        let routing = scores * (scores .>= threshold).asType(scores.dtype)
        let perExpert = split(routing, parts: numExperts, axis: -1)

        var routed: MLXArray?
        for expert in 0 ..< numExperts {
            let term = expertFeedForward(flat, "\(p).experts.\(expert)")
                * perExpert[expert].asType(flat.dtype)
            if moeTokenChunkSize != nil {
                eval(term)
                if let current = routed {
                    let accumulated = current + term
                    eval(accumulated)
                    routed = accumulated
                } else {
                    routed = term
                }
                MLX.Memory.clearCache()
            } else {
                routed = routed.map { $0 + term } ?? term
            }
        }
        let shared = expertFeedForward(flat, "\(p).shared_experts")
        let out = routed.map { $0 + shared } ?? shared
        return out.reshaped(x.shape)
    }

    /// Top-2 routing with one host synchronization per MoE layer. Token IDs are
    /// grouped by expert, so each selected expert executes a batched FFN and
    /// scatters its weighted rows back into the dense output. This avoids both
    /// the eight full-token expert passes above and the pathological M=1
    /// gather-matmul shape of the earlier sparse probe.
    private func sparseMoE(
        originalShape: [Int],
        flat: MLXArray,
        scores: MLXArray,
        chosen: MLXArray,
        prefix p: String
    ) -> MLXArray {
        let tokenCount = flat.dim(0)
        let channels = flat.dim(1)
        let hostChoices = chosen.asType(.int32)
        eval(hostChoices)
        let choices = hostChoices.asArray(Int32.self)
        var buckets = [[Int32]](repeating: [], count: numExperts)
        for token in 0 ..< tokenCount {
            for rank in 0 ..< moeTopK {
                let expert = Int(choices[token * moeTopK + rank])
                if buckets.indices.contains(expert) {
                    buckets[expert].append(Int32(token))
                }
            }
        }

        var routed = MLXArray.zeros(
            [tokenCount, channels],
            dtype: flat.dtype
        )
        for expert in 0 ..< numExperts where !buckets[expert].isEmpty {
            let indices = MLXArray(buckets[expert])
            let selected = flat.take(indices, axis: 0)
            let expertScores = split(
                scores.take(indices, axis: 0),
                parts: numExperts,
                axis: -1
            )[expert]
            let values = expertFeedForward(
                selected,
                "\(p).experts.\(expert)"
            ) * expertScores.asType(flat.dtype)
            eval(values)
            let rowIndices = broadcast(
                indices.expandedDimensions(axis: 1),
                to: [indices.dim(0), channels]
            )
            let dense = putAlong(
                MLXArray.zeros(
                    [tokenCount, channels],
                    dtype: flat.dtype
                ),
                rowIndices,
                values: values,
                axis: 0
            )
            let accumulated = routed + dense
            eval(accumulated)
            routed = accumulated
            MLX.Memory.clearCache()
        }
        let shared = expertFeedForward(flat, "\(p).shared_experts")
        let output = routed + shared
        return output.reshaped(originalShape)
    }

    private func usesMoE(_ layer: Int) -> Bool { depth - layer <= numMoELayers }

    private func block(
        _ input: MLXArray,
        skip: MLXArray?,
        cond: MLXArray,
        _ i: Int
    ) -> MLXArray {
        let p = "blocks.\(i)"
        var x = input
        if let skip {
            x = ln(
                lin(concatenated([skip, x], axis: -1), "\(p).skip_linear"),
                "\(p).skip_norm"
            )
        }
        x = x + attention(ln(x, "\(p).norm1"), "\(p).attn1")
        x = x + crossAttention(ln(x, "\(p).norm2"), cond, "\(p).attn2")
        let h = ln(x, "\(p).norm3")
        return x + (usesMoE(i) ? moe(h, "\(p).moe") : mlp(h, "\(p).mlp"))
    }

    public func callAsFunction(
        _ x: MLXArray,
        _ t: MLXArray,
        _ cond: MLXArray,
        guidance: MLXArray? = nil
    ) -> MLXArray {
        // Upstream casts the fp32 frequency embedding to the weight dtype before
        // the MLP. Bias tensors stay unquantized, so they carry the dtype even
        // for a Q4/Q8 pack.
        let dtype = g("t_embedder.mlp.0.bias").dtype
        let te = timestepFrequencies(t).asType(dtype)
        let c = lin(Layers.geluErf(lin(te, "t_embedder.mlp.0")), "t_embedder.mlp.2")
            .expandedDimensions(axis: 1)                       // [B, 1, hidden]
        var h = concatenated([c, lin(x, "x_embedder")], axis: 1)

        var skips: [MLXArray] = []
        skips.reserveCapacity(depth / 2)
        for i in 0 ..< depth {
            let skip = i > depth / 2 ? skips.removeLast() : nil
            h = block(h, skip: skip, cond: cond, i)
            if i < depth / 2 { skips.append(h) }
        }

        h = ln(h, "final_layer.norm_final")
        h = split(h, indices: [1], axis: 1)[1]                  // drop the time token
        return lin(h, "final_layer.linear")
    }
}
