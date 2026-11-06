import CryptoKit
import Foundation
import MLX
import XCTest
@testable import VoxamberHy3D

/// CPU scheduling/numerical contracts only. No trained weights or real model
/// generation is loaded, and these checks do not establish device stop latency.
final class DenoiserCancellationTests: XCTestCase {
    func testProductionChunkTraversalStopsAfterCurrentEvaluationAndClear() {
        var cancelled = false, events: [String] = []
        expectCancellation {
            _ = try ShapeCheckedLoop.chunks(rowCount: 8, chunkSize: 3,
                check: { try ShapeCheckedLoop.check { cancelled } },
                make: { range in events.append("make:\(range)"); events.append("eval"); return range },
                afterAppend: { events.append("clear"); cancelled = true })
        }
        XCTAssertEqual(events, ["make:0..<3", "eval", "clear"])
    }

    func testProductionExpertAndNestedChunkAdmissionCannotStartNextExpert() {
        var cancelled = false, events: [String] = []
        expectCancellation {
            try ShapeCheckedLoop.forEach(0..<8, check: { try ShapeCheckedLoop.check { cancelled } }) { expert in
                events.append("expert:\(expert)")
                _ = try ShapeCheckedLoop.chunks(rowCount: 7, chunkSize: 3,
                    check: { try ShapeCheckedLoop.check { cancelled } },
                    make: { range in events.append("chunk:\(range)"); return range },
                    afterAppend: { events.append("clear"); cancelled = true })
            }
        }
        XCTAssertEqual(events, ["expert:0", "chunk:0..<3", "clear"])
    }

    func testSuccessfulProductionTraversalKeepsChunkAndExpertOrderIncludingTail() throws {
        var events: [String] = []
        ShapeCheckedLoop.forEach(0..<2, check: {}) { expert in
            events.append("expert:\(expert)")
            let ranges = ShapeCheckedLoop.chunks(rowCount: 7, chunkSize: 3, check: {},
                make: { range in events.append("eval:\(range)"); return range },
                afterAppend: { events.append("clear") })
            XCTAssertEqual(ranges, [0..<3, 3..<6, 6..<7])
        }
        XCTAssertEqual(events, ["expert:0", "eval:0..<3", "clear", "eval:3..<6", "clear", "eval:6..<7", "clear",
                                "expert:1", "eval:0..<3", "clear", "eval:3..<6", "clear", "eval:6..<7", "clear"])
    }

    func testPreCancelledTraversalHasNoWorkAndFinalChunkCancellationDoesNotReturnArray() {
        var work = 0
        expectCancellation {
            _ = try ShapeCheckedLoop.chunks(rowCount: 7, chunkSize: 3,
                check: { try ShapeCheckedLoop.check { true } }, make: { _ in work += 1; return 1 }, afterAppend: {})
        }
        XCTAssertEqual(work, 0)
        var cancelled = false
        expectCancellation {
            _ = try ShapeCheckedLoop.chunks(rowCount: 2, chunkSize: 3,
                check: { try ShapeCheckedLoop.check { cancelled } }, make: { _ in work += 1; return 1 },
                afterAppend: { cancelled = true })
        }
        XCTAssertEqual(work, 1)
    }

    func testExistentialProtocolDispatchUsesActualCancellableOverride() throws {
        Device.withDefaultDevice(.cpu) {
            let state = RecordingState(), denoiser: any ShapeDenoiser = RecordingDenoiser(state: state, mode: .throwMarker)
            let i = TinyDenoiserFixture.inputs()
            do {
                _ = try denoiser.forwardCancellable(i.x, i.t, i.condition, guidance: nil, isCancelled: { false })
                XCTFail("Protocol extension static dispatch must not bypass the override")
            } catch Marker.reachedOverride {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(state.cancellableCalls, 1); XCTAssertEqual(state.legacyCalls, 0)
        }
    }

    func testPreCancelledPlainForwardDoesNotReadMissingWeights() {
        Device.withDefaultDevice(.cpu) {
            let i = TinyDenoiserFixture.inputs(), empty = DiTPlain(weights: [:], heads: 2, hidden: 8, depth: 3)
            expectCancellation {
                _ = try empty.forwardCancellable(i.x, i.t, i.condition, guidance: nil, isCancelled: { true })
            }
        }
    }

    func testActualExpertMatrixPathPollsInsideChunkedEvaluation() {
        Device.withDefaultDevice(.cpu) {
            let model = TinyDenoiserFixture.model(chunkSize: 3)
            let x = MLXArray((0..<64).map { Float($0 % 7) * 0.01 }).reshaped([8, 8])
            var checks = 0
            expectCancellation {
                _ = try model.expertFeedForward(x, "blocks.2.moe.experts.0", check: {
                    checks += 1
                    // Entry, first chunk admission, then a chunk boundary. This
                    // exercises the real lin/GELU/lin/eval path with CPU tensors.
                    if checks == 3 { throw CancellationError() }
                })
            }
            XCTAssertEqual(checks, 3)
        }
    }

    func testTinyCPUFalseForwardMatchesLegacyAndActualPreChangeGoldenBitwise() throws {
        let expected = try golden()
        try Device.withDefaultDevice(.cpu) {
            for (name, chunk, sparse) in [("denseUnchunked", Int?.none, false), ("denseChunked", Int?(3), false), ("sparseChunked", Int?(3), true)] {
                let model = TinyDenoiserFixture.model(chunkSize: chunk, sparse: sparse), i = TinyDenoiserFixture.inputs()
                let old = TinyDenoiserFixture.bytes(model(i.x, i.t, i.condition))
                let current = TinyDenoiserFixture.bytes(try model.forwardCancellable(i.x, i.t, i.condition,
                                                                                   guidance: nil, isCancelled: { false }))
                XCTAssertEqual(current, old, name)
                XCTAssertEqual(digest(current), expected[name], name)
            }
        }
    }

    func testTinyCPUBatchedAndSerializedCFGMatchActualPreChangeGoldenBitwise() throws {
        let expected = try golden()
        try Device.withDefaultDevice(.cpu) {
            for serial in [false, true] {
                let i = TinyDenoiserFixture.inputs(), condition = TinyDenoiserFixture.inputs(batch: 2).condition
                let pipeline = Pipeline(denoiser: TinyDenoiserFixture.model(),
                    vae: VAE(weights: [:], heads: 2, width: 8, layers: 0), serializesClassifierFreeGuidance: serial)
                let sigmas = MLXArray([Float(0), 0.3, 0.7])
                let old = TinyDenoiserFixture.bytes(pipeline.denoise(cond: condition, noise: i.x, sigmas: sigmas, guidance: 2))
                let current = TinyDenoiserFixture.bytes(try pipeline.denoiseCancellable(cond: condition, noise: i.x,
                    sigmas: sigmas, guidance: 2, isCancelled: { false }))
                XCTAssertEqual(current, old)
                XCTAssertEqual(digest(current), expected[serial ? "serializedCFG" : "batchedCFG"])
            }
        }
    }

    func testSerializedCFGDoesNotStartUnconditionalOrPublishProgressAfterCancellation() throws {
        Device.withDefaultDevice(.cpu) {
            let state = RecordingState(), i = TinyDenoiserFixture.inputs()
            let pipeline = Pipeline(denoiser: RecordingDenoiser(state: state, mode: .cancelOnReturn),
                vae: VAE(weights: [:], heads: 2, width: 8, layers: 0), serializesClassifierFreeGuidance: true)
            var progress = 0
            expectCancellation {
                _ = try pipeline.denoiseCancellable(cond: TinyDenoiserFixture.inputs(batch: 2).condition,
                    noise: i.x, sigmas: MLXArray([Float(0), 0.3, 0.7]), isCancelled: { state.cancelled },
                    progress: { _, _, _ in progress += 1 })
            }
            XCTAssertEqual(state.cancellableCalls, 1); XCTAssertEqual(state.legacyCalls, 0)
            XCTAssertEqual(progress, 0)
        }
    }

    func testProgressCancellationThrowsInsteadOfReturningPartialLatents() throws {
        Device.withDefaultDevice(.cpu) {
            let state = RecordingState(), i = TinyDenoiserFixture.inputs()
            let pipeline = Pipeline(denoiser: RecordingDenoiser(state: state, mode: .identity),
                vae: VAE(weights: [:], heads: 2, width: 8, layers: 0), serializesClassifierFreeGuidance: true)
            var steps: [Int] = []
            expectCancellation {
                _ = try pipeline.denoiseCancellable(cond: TinyDenoiserFixture.inputs(batch: 2).condition,
                    noise: i.x, sigmas: MLXArray([Float(0), 0.3, 0.7]), isCancelled: { state.cancelled },
                    progress: { step, _, _ in steps.append(step); state.cancelled = true })
            }
            XCTAssertEqual(steps, [1]); XCTAssertEqual(state.cancellableCalls, 2)
        }
    }

    private func golden() throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "TinyDenoiserBeforeCancellation", withExtension: "json", subdirectory: "Fixtures"))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(data["device"] as? String, "CPU")
        XCTAssertEqual(data["trainedWeightsUsed"] as? Bool, false)
        XCTAssertEqual(data["beforeProductionCancellationChanges"] as? Bool, true)
        let rows = try XCTUnwrap(data["cases"] as? [[String: Any]])
        return try Dictionary(uniqueKeysWithValues: rows.map { (try XCTUnwrap($0["case"] as? String), try XCTUnwrap($0["sha256"] as? String)) })
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func expectCancellation(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body(); XCTFail("Expected CancellationError", file: file, line: line) }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    private enum Marker: Error { case reachedOverride }
    private final class RecordingState { var cancellableCalls = 0; var legacyCalls = 0; var cancelled = false }
    private struct RecordingDenoiser: ShapeDenoiser {
        enum Mode { case throwMarker, cancelOnReturn, identity }
        let state: RecordingState; let mode: Mode
        var guidanceEmbed: Bool { false }
        func callAsFunction(_ x: MLXArray, _ t: MLXArray, _ cond: MLXArray, guidance: MLXArray?) -> MLXArray {
            state.legacyCalls += 1; return x
        }
        func forwardCancellable(_ x: MLXArray, _ t: MLXArray, _ cond: MLXArray,
                                guidance: MLXArray?, isCancelled: () -> Bool) throws -> MLXArray {
            state.cancellableCalls += 1
            if mode == .throwMarker { throw Marker.reachedOverride }
            if mode == .cancelOnReturn { state.cancelled = true }
            return x
        }
    }
}
