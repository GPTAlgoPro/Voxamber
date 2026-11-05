import XCTest
import CreationCore
@testable import ThreeLiveStudio

@MainActor
final class MemoryPressureTests: XCTestCase {
    func testWarningWithProcessHeadroomReclaimsWithoutCancellingOwnedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MemoryWarning-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = FakeProcessMemory(available: 1_024 * 1_024 * 1_024)
        let model = StudioModel(store: ProjectStore(root: root), memoryPressure: memory.client,
                                monitorCriticalMemory: false)
        model.generate(usingAI: false)
        XCTAssertTrue(model.busy)
        model.handleMemoryPressure()
        XCTAssertEqual(model.lastMemoryAction, .reclaimAndContinue)
        XCTAssertNil(model.stopReason, "An advisory warning must not invent a cancellation")
        try await settle(model)
        XCTAssertEqual(memory.reclaims, 1)
        XCTAssertEqual(model.stage, "已完成")
        XCTAssertNotNil(model.assets)
    }

    func testWarningChecksHeadroomAgainAfterCacheReclaim() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MemoryRecovered-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = FakeProcessMemory(available: 64 * 1_024 * 1_024)
        memory.availableAfterReclaim = 512 * 1_024 * 1_024
        let model = StudioModel(store: ProjectStore(root: root), memoryPressure: memory.client,
                                monitorCriticalMemory: false)
        model.generate(usingAI: false)
        model.handleMemoryPressure()
        XCTAssertEqual(model.lastMemoryAction, .reclaimAndContinue)
        XCTAssertNil(model.stopReason)
        try await settle(model)
        XCTAssertNotNil(model.assets)
    }

    func testWarningAtActualProcessLimitStillCancelsAndSettles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MemoryLimit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = FakeProcessMemory(available: 0)
        let model = StudioModel(store: ProjectStore(root: root), memoryPressure: memory.client,
                                monitorCriticalMemory: false)
        model.generate(usingAI: false)
        model.handleMemoryPressure()
        XCTAssertEqual(model.lastMemoryAction, .cancelAndUnload)
        XCTAssertEqual(model.stopReason, .memoryPressure)
        try await settle(model)
        XCTAssertEqual(model.stage, "已取消")
        XCTAssertNil(model.assets)
    }

    func testCriticalPressureCancelsEvenWithReportedHeadroom() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MemoryCritical-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = FakeProcessMemory(available: 2 * 1_024 * 1_024 * 1_024)
        let model = StudioModel(store: ProjectStore(root: root), memoryPressure: memory.client,
                                monitorCriticalMemory: false)
        model.generate(usingAI: false)
        model.handleMemoryPressure(.critical)
        XCTAssertEqual(model.lastMemoryAction, .cancelAndUnload)
        XCTAssertEqual(model.stopReason, .memoryPressure)
        try await settle(model)
        XCTAssertEqual(model.stage, "已取消")
    }

    func testIdleWarningReleasesRuntimeWithoutInventingAStoppedGeneration() async throws {
        let memory = FakeProcessMemory(available: 1_024 * 1_024 * 1_024)
        let model = StudioModel(memoryPressure: memory.client, monitorCriticalMemory: false)
        model.stage = "已完成"
        model.handleMemoryPressure()
        XCTAssertEqual(model.lastMemoryAction, .unloadIdleModel)
        try await settle(model)
        XCTAssertEqual(model.stage, "已完成")
        XCTAssertNil(model.stopReason)
    }

    func testPendingWarningCannotOverwriteLaterCriticalDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MemoryPriority-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = FakeProcessMemory(available: 1_024 * 1_024 * 1_024)
        let gate = ReclaimGate()
        memory.gate = gate
        let model = StudioModel(store: ProjectStore(root: root), memoryPressure: memory.client,
                                monitorCriticalMemory: false)
        model.generate(usingAI: false)
        model.handleMemoryPressure(.warning)
        model.handleMemoryPressure(.critical)
        XCTAssertEqual(model.lastMemoryAction, .cancelAndUnload)
        XCTAssertEqual(model.stopReason, .memoryPressure)
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.release()
        try await settle(model)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.lastMemoryAction, .cancelAndUnload)
        let data = try Data(contentsOf: URL.documentsDirectory.appending(path: "Measurements/last-memory-pressure.json"))
        let record = try JSONDecoder().decode(MemoryPressureRecord.self, from: data)
        XCTAssertEqual(record.severity, .critical)
        XCTAssertEqual(record.action, .cancelAndUnload)
    }

    private func settle(_ model: StudioModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.isCleaningUp)
    }
}

@MainActor
private final class FakeProcessMemory {
    var available: UInt64
    var availableAfterReclaim: UInt64?
    private(set) var reclaims = 0
    var gate: ReclaimGate?
    init(available: UInt64) { self.available = available }
    var client: MemoryPressureClient {
        MemoryPressureClient(snapshot: { [self] in
            AppMemorySnapshot(availableProcessBytes: available, physicalFootprintBytes: 3_000_000_000,
                physicalMemoryBytes: 12_000_000_000, thermalState: 0,
                mlxActiveBytes: 2_300_000_000, mlxCacheBytes: reclaims == 0 ? 32_000_000 : 0)
        }, reclaimUnusedCache: { [self] in
            reclaims += 1
            if let gate { await gate.wait() }
            if let availableAfterReclaim { available = availableAfterReclaim }
            return nil
        })
    }
}

private actor ReclaimGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
