import XCTest
import Foundation
@testable import VoxamberFluxCandidate
import Flux2Core

final class LifecycleTests: XCTestCase {
    func testIdleUnloadDoesNotStartRuntime() async {
        let engine = FluxImageEngine()
        await engine.unload()
        let running = await engine.isRunning
        XCTAssertFalse(running)
    }

    func testCancellationAwaitsWorkerCleanupAndAllowsReload() async throws {
        let started = TestGate(), cleanup = TestGate(), completed = WorkerCounter()
        let engine = FluxImageEngine(worker: { _ in
            await started.release()
            do {
                try await Task.sleep(for: .seconds(30))
                return Data()
            } catch {
                // Simulated uninterruptible cleanup: no NN or Metal work.
                await cleanup.wait()
                await completed.increment()
                throw error
            }
        })
        let request = Task { try await engine.generate(positivePrompt: "fixed synthetic test", seed: 24301, modelRoot: URL(fileURLWithPath: "/unused")) }
        await started.wait()
        let unloading = Task { await engine.unload() }
        try await Task.sleep(for: .milliseconds(20))
        let before = await completed.count
        XCTAssertEqual(before, 0)
        await cleanup.release(); await unloading.value
        let after = await completed.count, running = await engine.isRunning
        XCTAssertEqual(after, 1); XCTAssertFalse(running)
        do { _ = try await request.value; XCTFail("cancelled request succeeded") } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        await engine.unload()
        let next = FluxImageEngine(worker: { _ in Data([1]) })
        let value = try await next.generate(positivePrompt: "fixed synthetic test", seed: 24301, modelRoot: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(value, Data([1]))
    }

    func testExternalCancellationWinsAfterWorkerReturnsSuccess() async throws {
        let started = TestGate(), finish = TestGate()
        let engine = FluxImageEngine(worker: { _ in
            await started.release(); await finish.wait(); return Data([1])
        })
        let request = Task { try await engine.generate(positivePrompt: "test", seed: 24301, modelRoot: URL(fileURLWithPath: "/unused")) }
        await started.wait(); request.cancel(); await finish.release()
        do { _ = try await request.value; XCTFail("cancelled caller accepted success") } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }

    func testConcurrentCandidateEnginesCannotOwnGlobalEncoderTogether() async throws {
        let lease = FluxCandidateRuntimeLease()
        let id = try await lease.acquire()
        do { _ = try await lease.acquire(); XCTFail("second owner admitted") } catch { XCTAssertEqual(error as? FluxCandidateError, .busy) }
        await lease.release(UUID())
        do { _ = try await lease.acquire(); XCTFail("unrelated release changed owner") } catch {}
        await lease.release(id)
        let second = try await lease.acquire(); await lease.release(second)
    }

    func testCoreRejectsWrongOrImplicitQuantizedVariantBeforeWeights() throws {
        let roots = Flux2LocalResourcePaths(transformerDirectory: URL(fileURLWithPath: "/missing/t"),
                                            textEncoderDirectory: URL(fileURLWithPath: "/missing/q"),
                                            vaeDirectory: URL(fileURLWithPath: "/missing/v"))
        XCTAssertThrowsError(try Flux2Pipeline(localResources: roots, model: .dev))
        XCTAssertThrowsError(try Flux2Pipeline(localResources: roots, model: .klein4B,
            quantization: .init(textEncoder: .mlx4bit, transformer: .int4)))
        let accepted = try Flux2Pipeline(localResources: roots, model: .klein4B,
            quantization: .init(textEncoder: .mlx4bit, transformer: .int4), transformerVariantOverride: .klein4B_4bit)
        XCTAssertFalse(accepted.hasRequiredModels)
    }

    func testLocalLayoutFailureDoesNotDownloadOrSelectCache() async throws {
        let roots = Flux2LocalResourcePaths(transformerDirectory: URL(fileURLWithPath: "/missing/t"),
                                            textEncoderDirectory: URL(fileURLWithPath: "/missing/q"),
                                            vaeDirectory: URL(fileURLWithPath: "/missing/v"))
        let pipeline = try Flux2Pipeline(localResources: roots, model: .klein4B,
            quantization: .init(textEncoder: .mlx4bit, transformer: .int4), transformerVariantOverride: .klein4B_4bit)
        do { try await pipeline.loadModels(); XCTFail("missing local model accepted") } catch is Flux2LocalResourceError {} catch { XCTFail("unexpected \(error)") }
    }

    func testPartialLoadThrowAwaitsCleanupThenLeaseCanBeReacquired() async throws {
        let scope = FluxCandidateRuntimeScope(), lease = FluxCandidateRuntimeLease(), cleaned = WorkerCounter()
        let id = try await lease.acquire()
        do {
            let _: Data = try await scope.run(operation: {
                scope.markTouched() // Synthetic partial model load, no MLX or weights.
                throw FluxCandidateError.invalidImage
            }, cleanup: {
                await cleaned.increment()
            })
            XCTFail("partial load error lost")
        } catch { XCTAssertEqual(error as? FluxCandidateError, .invalidImage) }
        let cleanupCount = await cleaned.count
        XCTAssertEqual(cleanupCount, 1)
        await lease.release(id)
        let next = try await lease.acquire(); await lease.release(next)
    }

    func testPurePreflightFailureDoesNotInitializeCleanupRuntime() async {
        let scope = FluxCandidateRuntimeScope(), cleaned = WorkerCounter()
        do {
            let _: Data = try await scope.run(operation: { throw FluxCandidateError.emptyPrompt },
                                             cleanup: { await cleaned.increment() })
            XCTFail("error lost")
        } catch {}
        let count = await cleaned.count
        XCTAssertEqual(count, 0)
    }
}

actor WorkerCounter {
    var count = 0
    func increment() { count += 1 }
}
