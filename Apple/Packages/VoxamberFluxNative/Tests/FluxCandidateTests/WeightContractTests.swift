import XCTest
import Foundation
import FluxTextEncoders
import MLX
import MLXNN

final class WeightContractTests: XCTestCase {
    private var complete: [String: FixedWeightSpecification] {
        ["linear.weight": .init(shape: [2, 8], storage: "U32"),
         "linear.scales": .init(shape: [2, 1], storage: "FLOAT"),
         "linear.biases": .init(shape: [2, 1], storage: "FLOAT"),
         "norm.weight": .init(shape: [2], storage: "FLOAT")]
    }

    func testPackedGroup64Q4AndFullCoverageAccepted() throws {
        try FixedWeightAdmission.requireAffineQ4(complete)
        try FixedWeightAdmission.validate(model: complete, checkpoint: complete)
    }

    func testFloatingCheckpointCannotFallbackToOnLoadQuantization() {
        var wrong = complete; wrong["linear.weight"] = .init(shape: [2, 64], storage: "FLOAT")
        XCTAssertThrowsError(try FixedWeightAdmission.requireAffineQ4(wrong))
    }

    func testMissingWeightAndNormAreRejectedBeforeUpdate() {
        for key in ["linear.weight", "linear.biases", "norm.weight"] {
            var missing = complete; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try FixedWeightAdmission.validate(model: complete, checkpoint: missing)) {
                XCTAssertEqual($0 as? FixedWeightAdmissionError, .missing(key))
            }
        }
    }

    func testWrongShapeAndStorageRejected() {
        var wrong = complete; wrong["linear.weight"] = .init(shape: [2, 16], storage: "U32")
        XCTAssertThrowsError(try FixedWeightAdmission.validate(model: complete, checkpoint: wrong))
        XCTAssertThrowsError(try FixedWeightAdmission.requireAffineQ4(wrong))
        wrong = complete; wrong["linear.weight"] = .init(shape: [2, 8], storage: "FLOAT")
        XCTAssertThrowsError(try FixedWeightAdmission.validate(model: complete, checkpoint: wrong))
    }

    func testOnlyExplicitTiedHeadMissingExceptionLeavesNormRequired() throws {
        var model = complete; model["lm_head.weight"] = .init(shape: [2, 8], storage: "U32")
        try FixedWeightAdmission.validate(model: model, checkpoint: complete, missingExceptions: ["lm_head.weight", "lm_head.scales", "lm_head.biases"])
        var missing = complete; missing.removeValue(forKey: "norm.weight")
        XCTAssertThrowsError(try FixedWeightAdmission.validate(model: model, checkpoint: missing, missingExceptions: ["lm_head.weight", "lm_head.scales", "lm_head.biases"]))
    }

    func testActualTinyModuleMissingWeightNormAndWrongShape() throws {
        // Metadata only: no forward pass, eval, foundation weights or neural generation.
        let module = TinyWeightModule()
        let expected = Dictionary(uniqueKeysWithValues: module.parameters().flattened().map {
            ($0.0, FixedWeightSpecification(shape: $0.1.shape, storage: "FLOAT"))
        })
        XCTAssertEqual(Set(expected.keys), ["linear.weight", "norm.weight"])
        for key in expected.keys {
            var incomplete = expected; incomplete.removeValue(forKey: key)
            XCTAssertThrowsError(try FixedWeightAdmission.validate(model: expected, checkpoint: incomplete))
        }
        var wrong = expected; wrong["linear.weight"] = .init(shape: [3, 2], storage: "FLOAT")
        XCTAssertThrowsError(try FixedWeightAdmission.validate(model: expected, checkpoint: wrong))
    }

    @MainActor
    func testActualLocalLoadBoundaryLeavesMainActorBeforeMissingFileRejection() async {
        let ledger = ThreadLedger()
        do {
            try await FluxTextEncoders.shared.loadKleinModelLocalOnly(variant: .klein4B,
                from: "/voxamber-synthetic-missing-model", onBoundary: { ledger.record($0) })
            XCTFail("missing local resource accepted")
        } catch {}
        XCTAssertEqual(ledger.values, [false])
    }
}

private final class TinyWeightModule: Module {
    let linear: Linear
    let norm: MLXNN.RMSNorm
    override init() {
        linear = Linear(2, 2, bias: false)
        norm = MLXNN.RMSNorm(dimensions: 2)
        super.init()
    }
}

private final class ThreadLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Bool] = []
    func record(_ isMain: Bool) { lock.lock(); entries.append(isMain); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return entries }
}
