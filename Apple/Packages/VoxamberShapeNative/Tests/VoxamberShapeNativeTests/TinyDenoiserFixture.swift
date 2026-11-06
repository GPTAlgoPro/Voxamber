import Foundation
import MLX
@testable import VoxamberHy3D

/// Deterministic synthetic CPU tensors, not trained/model weights or NN quality
/// evidence. The same fixture is evaluated against the pre-change binary first.
enum TinyDenoiserFixture {
    static func weights() -> [String: MLXArray] {
        let hidden = 8, heads = 2
        var weights: [String: MLXArray] = [:], ordinal = 0
        func tensor(_ name: String, _ shape: [Int], ones: Bool = false) {
            ordinal += 1
            let values = (0..<shape.reduce(1, *)).map { index -> Float in
                if ones { return 1 + Float((index + ordinal) % 3) * 0.01 }
                return Float((index * 13 + ordinal * 7) % 31 - 15) * 0.007
            }
            weights[name] = MLXArray(values).reshaped(shape)
        }
        func linear(_ name: String, output: Int, input: Int, bias: Bool = true) {
            tensor(name + ".weight", [output, input])
            if bias { tensor(name + ".bias", [output]) }
        }
        func norm(_ name: String) {
            tensor(name + ".weight", [hidden], ones: true)
            tensor(name + ".bias", [hidden])
        }
        linear("t_embedder.mlp.0", output: hidden, input: hidden)
        linear("t_embedder.mlp.2", output: hidden, input: hidden)
        linear("x_embedder", output: hidden, input: 2)
        for layer in 0..<3 {
            let p = "blocks.\(layer)"
            for number in 1...3 { norm(p + ".norm\(number)") }
            if layer == 2 {
                linear(p + ".skip_linear", output: hidden, input: hidden * 2)
                norm(p + ".skip_norm")
            }
            for attention in ["attn1", "attn2"] {
                for projection in ["to_q", "to_k", "to_v"] {
                    linear(p + ".\(attention).\(projection)", output: hidden, input: hidden, bias: false)
                }
                tensor(p + ".\(attention).q_norm.weight", [hidden / heads], ones: true)
                tensor(p + ".\(attention).k_norm.weight", [hidden / heads], ones: true)
                linear(p + ".\(attention).out_proj", output: hidden, input: hidden)
            }
            if layer == 2 {
                tensor(p + ".moe.gate.weight", [2, hidden])
                for expert in ["experts.0", "experts.1", "shared_experts"] {
                    linear(p + ".moe.\(expert).net.0.proj", output: hidden * 2, input: hidden)
                    linear(p + ".moe.\(expert).net.2", output: hidden, input: hidden * 2)
                }
            } else {
                linear(p + ".mlp.fc1", output: hidden * 4, input: hidden)
                linear(p + ".mlp.fc2", output: hidden, input: hidden * 4)
            }
        }
        norm("final_layer.norm_final")
        linear("final_layer.linear", output: 2, input: hidden)
        return weights
    }

    static func model(chunkSize: Int? = 3, sparse: Bool = false) -> DiTPlain {
        DiTPlain(weights: weights(), heads: 2, hidden: 8, depth: 3, numMoELayers: 1,
                 numExperts: 2, moeTopK: 1, bits: 4, groupSize: 64,
                 moeTokenChunkSize: chunkSize, usesSparseMoERouting: sparse)
    }

    static func inputs(batch: Int = 1) -> (x: MLXArray, t: MLXArray, condition: MLXArray) {
        let x = (0..<(batch * 7 * 2)).map { Float(($0 * 5) % 17 - 8) * 0.03 }
        let condition = (0..<(batch * 3 * 8)).map { Float(($0 * 7) % 23 - 11) * 0.02 }
        return (MLXArray(x).reshaped([batch, 7, 2]), MLXArray(Array(repeating: Float(0.35), count: batch)),
                MLXArray(condition).reshaped([batch, 3, 8]))
    }

    static func bytes(_ array: MLXArray) -> Data {
        eval(array)
        let values = array.asArray(Float.self)
        return values.withUnsafeBytes { Data($0) }
    }
}
