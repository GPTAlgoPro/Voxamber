// Pure metadata checks for the isolated Klein4B affine-Q4 candidate.
import Foundation

public struct FixedWeightSpecification: Sendable, Equatable {
    public let shape: [Int]
    public let storage: String // "U32" or "FLOAT"; float16/bfloat16/float32 are compatible.
    public init(shape: [Int], storage: String) { self.shape = shape; self.storage = storage }
}

public enum FixedWeightAdmissionError: Error, Equatable, Sendable {
    case notAffineQ4, incompleteQuantization(String), missing(String), extra(String), shape(String), storage(String)
}

public enum FixedWeightAdmission {
    public static func requireAffineQ4(_ weights: [String: FixedWeightSpecification]) throws {
        let packed = weights.filter { $0.value.storage == "U32" }
        guard !packed.isEmpty else { throw FixedWeightAdmissionError.notAffineQ4 }
        for (key, value) in packed {
            guard key.hasSuffix(".weight"), value.shape.count == 2 else { throw FixedWeightAdmissionError.incompleteQuantization(key) }
            let base = String(key.dropLast(7))
            guard let scales = weights[base + ".scales"], let biases = weights[base + ".biases"],
                  scales.storage == "FLOAT", biases.storage == "FLOAT", scales.shape == biases.shape,
                  scales.shape.count == 2, scales.shape[0] == value.shape[0], value.shape[0] > 0,
                  scales.shape[1] > 0, value.shape[1] > 0,
                  !value.shape[1].multipliedReportingOverflow(by: 8).overflow,
                  !scales.shape[1].multipliedReportingOverflow(by: 64).overflow,
                  value.shape[1] * 8 == scales.shape[1] * 64 else {
                throw FixedWeightAdmissionError.incompleteQuantization(key)
            }
        }
        for (key, value) in weights {
            if key.hasSuffix(".scales") || key.hasSuffix(".biases") {
                guard weights[String(key.dropLast(7)) + ".weight"]?.storage == "U32" else {
                    throw FixedWeightAdmissionError.incompleteQuantization(key)
                }
            }
            if key.hasSuffix(".weight"), value.shape.count == 2, value.storage != "U32" {
                throw FixedWeightAdmissionError.notAffineQ4
            }
        }
    }

    public static func validate(model: [String: FixedWeightSpecification],
                                checkpoint: [String: FixedWeightSpecification],
                                missingExceptions: Set<String> = []) throws {
        for key in checkpoint.keys.sorted() {
            guard let expected = model[key] else { throw FixedWeightAdmissionError.extra(key) }
            guard expected.shape == checkpoint[key]!.shape else { throw FixedWeightAdmissionError.shape(key) }
            guard expected.storage == checkpoint[key]!.storage else { throw FixedWeightAdmissionError.storage(key) }
        }
        for key in model.keys.sorted() where checkpoint[key] == nil && !missingExceptions.contains(key) {
            throw FixedWeightAdmissionError.missing(key)
        }
    }
}
