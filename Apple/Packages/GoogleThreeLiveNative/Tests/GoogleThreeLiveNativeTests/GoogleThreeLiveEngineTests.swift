import Foundation
import CryptoKit
import XCTest
@testable import GoogleThreeLiveNative

/// Scripted operations exercise production adapter ownership/order only.
/// They do not execute the SDK, a model, scene code or a geometry generator.
final class GoogleThreeLiveEngineTests: XCTestCase {
    private let scriptedGLB = Data("scripted-GLB-byte-identity-only".utf8)
    private var officialRawUSDZ: Data { Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters)! }

    func testExactSourceExecutesOnceAndItsSameGLBIsTranscoded() async throws {
        let calls = Calls(), glb = scriptedGLB, raw = officialRawUSDZ
        let engine = GoogleThreeLiveEngine(compiler: .init(
            compileGLB: { source in _ = await calls.source(source); return glb },
            glbToUSDZ: { data in await calls.transcode(data); return raw }))
        let source = "\n// 原始源码 e\u{301}\nconst r = Math.random();\nscene.add(mesh);\n"
        let result = try await engine.compile(source: source)
        let recorded = await calls.snapshot()
        XCTAssertEqual(recorded.sources, [source]); XCTAssertEqual(recorded.transcodes, [glb])
        XCTAssertEqual(result.source, source); XCTAssertEqual(result.glb, glb)
        XCTAssertEqual(result.sourceSHA256, sha(Data(source.utf8)))
        XCTAssertEqual(result.glbSHA256, sha(glb)); XCTAssertEqual(result.officialUSDZSHA256, sha(raw))
        XCTAssertEqual(result.usdzSHA256, sha(result.usdz)); XCTAssertTrue(result.metadataRepairApplied)
        XCTAssertNotEqual(result.usdz, raw)
        XCTAssertEqual(result.sdkVersion, "1.2.3")
        XCTAssertEqual(result.sdkSourceRevision, "c0ff24b628795286a175f1a71611673df5dbc05d")
        let running = await engine.isRunning; XCTAssertFalse(running)
    }

    func testPreflightRejectsEmptyNULAndUTF8ByteLimitBeforeAnyCompilerCall() async {
        let calls = Calls(), glb = scriptedGLB, raw = officialRawUSDZ
        let engine = GoogleThreeLiveEngine(compiler: .init(
            compileGLB: { source in _ = await calls.source(source); return glb },
            glbToUSDZ: { data in await calls.transcode(data); return raw }))
        let oversized = String(repeating: "界", count: 350_000)
        for (source, expected) in [("", GoogleThreeLiveEngineError.emptySource), ("A\0B", .embeddedNUL(byteOffset: 1)),
                                   (oversized, .sourceTooLarge(byteCount: 1_050_000))] {
            do { _ = try await engine.compile(source: source); XCTFail("Invalid source reached compiler") }
            catch { XCTAssertEqual(error as? GoogleThreeLiveEngineError, expected) }
        }
        let recorded = await calls.snapshot(); XCTAssertTrue(recorded.sources.isEmpty); XCTAssertTrue(recorded.transcodes.isEmpty)
    }

    func testNativeDiagnosticsPropagateWithoutFallbackOrSecondSourceExecution() async {
        let calls = Calls(), glb = scriptedGLB
        let engine = GoogleThreeLiveEngine(compiler: .init(
            compileGLB: { source in _ = await calls.source(source); return glb },
            glbToUSDZ: { data in await calls.transcode(data); throw ScriptedFailure.nativeDiagnostic }))
        do { _ = try await engine.compile(source: "scene.add(mesh);"); XCTFail("Native failure was hidden") }
        catch { XCTAssertEqual(error as? ScriptedFailure, .nativeDiagnostic) }
        let recorded = await calls.snapshot(); XCTAssertEqual(recorded.sources.count, 1); XCTAssertEqual(recorded.transcodes, [glb])
        let running = await engine.isRunning; XCTAssertFalse(running)
    }

    func testBusyAndCancelJoinUninterruptibleCompileThenAllowRetry() async throws {
        let calls = Calls(), gate = NativeGate(), glb = scriptedGLB, raw = officialRawUSDZ
        defer { gate.release() }
        let engine = GoogleThreeLiveEngine(compiler: .init(
            compileGLB: { source in
                let number = await calls.source(source)
                if number == 1 { await gate.holdIgnoringCancellation() }
                return glb
            }, glbToUSDZ: { data in await calls.transcode(data); return raw }))
        let first = Task { try await engine.compile(source: "first();") }
        await fulfillment(of: [gate.entered], timeout: 2)
        do { _ = try await engine.compile(source: "overlap();"); XCTFail("Overlap was admitted") }
        catch { XCTAssertEqual(error as? GoogleThreeLiveEngineError, .busy) }
        let stopping = Task { await engine.cancelAndWait() }
        await fulfillment(of: [gate.cancelled], timeout: 2)
        let during = await engine.isRunning; XCTAssertTrue(during)
        let beforeReturn = await calls.snapshot(); XCTAssertTrue(beforeReturn.transcodes.isEmpty)
        gate.release(); await stopping.value
        switch await first.result {
        case .success: XCTFail("Cancelled compile returned a result")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let idle = await engine.isRunning; XCTAssertFalse(idle)
        let retry = try await engine.compile(source: "retry();")
        XCTAssertEqual(retry.source, "retry();")
        let recorded = await calls.snapshot(); XCTAssertEqual(recorded.sources, ["first();", "retry();"])
        XCTAssertEqual(recorded.transcodes, [glb])
    }

    func testCancellationAlsoJoinsUninterruptibleTranscode() async {
        let gate = NativeGate(), glb = scriptedGLB, raw = officialRawUSDZ
        defer { gate.release() }
        let engine = GoogleThreeLiveEngine(compiler: .init(compileGLB: { _ in glb },
            glbToUSDZ: { _ in await gate.holdIgnoringCancellation(); return raw }))
        let work = Task { try await engine.compile(source: "scene.add(mesh);") }
        await fulfillment(of: [gate.entered], timeout: 2)
        let stopping = Task { await engine.cancelAndWait() }
        await fulfillment(of: [gate.cancelled], timeout: 2)
        let during = await engine.isRunning; XCTAssertTrue(during)
        gate.release(); await stopping.value
        switch await work.result {
        case .success: XCTFail("Cancelled transcode returned a result")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let idle = await engine.isRunning; XCTAssertFalse(idle)
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private enum ScriptedFailure: Error, Equatable { case nativeDiagnostic }
    private actor Calls {
        var sources: [String] = [], transcodes: [Data] = []
        func source(_ value: String) -> Int { sources.append(value); return sources.count }
        func transcode(_ value: Data) { transcodes.append(value) }
        func snapshot() -> (sources: [String], transcodes: [Data]) { (sources, transcodes) }
    }
    private final class NativeGate: @unchecked Sendable {
        let entered = XCTestExpectation(description: "scripted native call entered")
        let cancelled = XCTestExpectation(description: "actual owned Task cancellation reached native seam")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false, cancellationObserved = false
        func holdIgnoringCancellation() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    let resumeNow = released
                    if !resumeNow { self.continuation = continuation }
                    lock.unlock()
                    entered.fulfill()
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                self.lock.lock(); let first = !self.cancellationObserved; self.cancellationObserved = true; self.lock.unlock()
                if first { self.cancelled.fulfill() }
            }
        }
        func release() {
            lock.lock(); released = true; let waiting = continuation; continuation = nil; lock.unlock()
            waiting?.resume()
        }
    }
    // Actual verified v1.2.3 smoke USDZ, SHA834a8e98ec2af76688be848a1c4575d0efcfa05636481e345c9570f0f5c9dd55.
    private static let fixture = """
UEsDBBQAAAAAAAAAAAAghRImmwcAAJsHAAAKABgAbW9kZWwudXNkYYYZFAAAAAAAAAAAAAAAAAAAAAAAAAAAACN1c2RhIDEuMAoo
CmRlZmF1bHRQcmltID0gIlJvb3QiCm1ldGVyc1BlclVuaXQgPSAxLjAKdXBBeGlzID0gIlkiCikKCmRlZiBYZm9ybSAiUm9vdCIg
KApraW5kID0gImNvbXBvbmVudCIKKQp7CmRlZiBTY29wZSAiTWF0ZXJpYWxzIgp7CmRlZiBNYXRlcmlhbCAiTWF0ZXJpYWxfMCIK
ewpkZWYgU2hhZGVyICJQQlJTaGFkZXIiCnsKdW5pZm9ybSB0b2tlbiBpbmZvOmlkID0gIlVzZFByZXZpZXdTdXJmYWNlIgpjb2xv
cjNmIGlucHV0czpkaWZmdXNlQ29sb3IgPSAoMC42NjY2NywgMC4xMzMzMywgMC4xMzMzMykKZmxvYXQgaW5wdXRzOm1ldGFsbGlj
ID0gMC4xCmZsb2F0IGlucHV0czpyb3VnaG5lc3MgPSAwLjcKdG9rZW4gb3V0cHV0czpzdXJmYWNlCn0KdG9rZW4gb3V0cHV0czpz
dXJmYWNlLmNvbm5lY3QgPSA8L1Jvb3QvTWF0ZXJpYWxzL01hdGVyaWFsXzAvUEJSU2hhZGVyLm91dHB1dHM6c3VyZmFjZT4KfQp9
CmRlZiBTY29wZSAiTWVzaGVzIgp7CmRlZiBNZXNoICJuYXRpdmVfY29tcGlsZXJfc21va2UiCnsKZmxvYXQzW10gZXh0ZW50ID0g
WygtMC4xLCAwLCAtMC4xKSwgKDAuMSwgMC4yLCAwLjEpXQppbnRbXSBmYWNlVmVydGV4Q291bnRzID0gWzMsIDMsIDMsIDMsIDMs
IDMsIDMsIDMsIDMsIDMsIDMsIDNdCmludFtdIGZhY2VWZXJ0ZXhJbmRpY2VzID0gWzAsIDEsIDIsIDAsIDIsIDMsIDQsIDUsIDYs
IDQsIDYsIDcsIDgsIDksIDEwLCA4LCAxMCwgMTEsIDEyLCAxMywgMTQsIDEyLCAxNCwgMTUsIDE2LCAxNywgMTgsIDE2LCAxOCwg
MTksIDIwLCAyMSwgMjIsIDIwLCAyMiwgMjNdCnBvaW50M2ZbXSBwb2ludHMgPSBbKC0wLjEsIDAsIDAuMSksICgwLjEsIDAsIDAu
MSksICgwLjEsIDAuMiwgMC4xKSwgKC0wLjEsIDAuMiwgMC4xKSwgKDAuMSwgMCwgLTAuMSksICgtMC4xLCAwLCAtMC4xKSwgKC0w
LjEsIDAuMiwgLTAuMSksICgwLjEsIDAuMiwgLTAuMSksICgtMC4xLCAwLjIsIDAuMSksICgwLjEsIDAuMiwgMC4xKSwgKDAuMSwg
MC4yLCAtMC4xKSwgKC0wLjEsIDAuMiwgLTAuMSksICgtMC4xLCAwLCAtMC4xKSwgKDAuMSwgMCwgLTAuMSksICgwLjEsIDAsIDAu
MSksICgtMC4xLCAwLCAwLjEpLCAoMC4xLCAwLCAwLjEpLCAoMC4xLCAwLCAtMC4xKSwgKDAuMSwgMC4yLCAtMC4xKSwgKDAuMSwg
MC4yLCAwLjEpLCAoLTAuMSwgMCwgLTAuMSksICgtMC4xLCAwLCAwLjEpLCAoLTAuMSwgMC4yLCAwLjEpLCAoLTAuMSwgMC4yLCAt
MC4xKV0Kbm9ybWFsM2ZbXSBub3JtYWxzID0gWygwLCAwLCAxLjApLCAoMCwgMCwgMS4wKSwgKDAsIDAsIDEuMCksICgwLCAwLCAx
LjApLCAoMCwgMCwgLTEuMCksICgwLCAwLCAtMS4wKSwgKDAsIDAsIC0xLjApLCAoMCwgMCwgLTEuMCksICgwLCAxLjAsIDApLCAo
MCwgMS4wLCAwKSwgKDAsIDEuMCwgMCksICgwLCAxLjAsIDApLCAoMCwgLTEuMCwgMCksICgwLCAtMS4wLCAwKSwgKDAsIC0xLjAs
IDApLCAoMCwgLTEuMCwgMCksICgxLjAsIDAsIDApLCAoMS4wLCAwLCAwKSwgKDEuMCwgMCwgMCksICgxLjAsIDAsIDApLCAoLTEu
MCwgMCwgMCksICgtMS4wLCAwLCAwKSwgKC0xLjAsIDAsIDApLCAoLTEuMCwgMCwgMCldICgKaW50ZXJwb2xhdGlvbiA9ICJ2ZXJ0
ZXgiCikKdGV4Q29vcmQyZltdIHByaW12YXJzOnN0ID0gWygwLCAxLjApLCAoMS4wLCAxLjApLCAoMS4wLCAwKSwgKDAsIDApLCAo
MCwgMS4wKSwgKDEuMCwgMS4wKSwgKDEuMCwgMCksICgwLCAwKSwgKDAsIDEuMCksICgxLjAsIDEuMCksICgxLjAsIDApLCAoMCwg
MCksICgwLCAxLjApLCAoMS4wLCAxLjApLCAoMS4wLCAwKSwgKDAsIDApLCAoMCwgMS4wKSwgKDEuMCwgMS4wKSwgKDEuMCwgMCks
ICgwLCAwKSwgKDAsIDEuMCksICgxLjAsIDEuMCksICgxLjAsIDApLCAoMCwgMCldICgKaW50ZXJwb2xhdGlvbiA9ICJ2ZXJ0ZXgi
CikKcmVsIG1hdGVyaWFsOmJpbmRpbmcgPSA8L1Jvb3QvTWF0ZXJpYWxzL01hdGVyaWFsXzA+Cn0KfQp9ClBLAQIUABQAAAAAAAAA
AAAghRImmwcAAJsHAAAKAAAAAAAAAAAAAAAAAAAAAABtb2RlbC51c2RhUEsFBgAAAAABAAEAOAAAANsHAAAAAA==
"""
}
