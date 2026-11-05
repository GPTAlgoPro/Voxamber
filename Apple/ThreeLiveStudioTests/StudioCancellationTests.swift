import XCTest
import UIKit
import CreationCore
import ThreeLiveNative
@testable import ThreeLiveStudio

@MainActor
final class StudioCancellationTests: XCTestCase {
    func testAIIdleTimerLeaseRestoresSettingAndRejectsStaleCompletion() {
        let timer = FakeIdleTimer(disabled: false)
        let lease = GenerationIdleTimerLease(client: timer.client)
        let first = UUID(), second = UUID()
        lease.begin(for: first)
        XCTAssertTrue(timer.disabled)
        lease.begin(for: second)
        lease.end(for: second)
        XCTAssertTrue(timer.disabled, "A different operation cannot steal or end the admitted lease")
        lease.end(for: first)
        XCTAssertFalse(timer.disabled)
        lease.begin(for: second)
        lease.end(for: first)
        XCTAssertTrue(timer.disabled, "A delayed old completion must not restore a newer operation's idle timer")
        lease.end(for: second)
        lease.end(for: second)
        XCTAssertFalse(timer.disabled)
        XCTAssertEqual(timer.writes, [true, false, true, false])
    }

    func testAIIdleTimerLeasePreservesPreviouslyDisabledSetting() {
        let timer = FakeIdleTimer(disabled: true)
        let lease = GenerationIdleTimerLease(client: timer.client)
        let id = UUID()
        lease.begin(for: id)
        lease.end(for: id)
        XCTAssertTrue(timer.disabled, "Finish must restore the setting that existed before generation")
        XCTAssertEqual(timer.writes, [true, true])
    }

    func testManualGenerationAndUninstalledAIDoNotAcquireIdleTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StudioIdleTimer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let timer = FakeIdleTimer(disabled: false)
        let model = StudioModel(store: ProjectStore(root: root), idleTimer: timer.client)
        model.generate(usingAI: true)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.tab, .models)
        XCTAssertTrue(timer.writes.isEmpty, "Opening model installation does not start an AI operation")
        model.generate(usingAI: false)
        try await waitUntil { !model.busy }
        XCTAssertEqual(model.stage, "已完成")
        XCTAssertTrue(timer.writes.isEmpty, "Fast native parameter generation does not change auto-lock")
        model.generate(usingAI: false)
        model.cancel()
        try await waitUntil { !model.busy }
        XCTAssertEqual(model.stage, "已取消")
        XCTAssertFalse(timer.disabled)
        XCTAssertTrue(timer.writes.isEmpty)
    }

    func testIdleStopDoesNotInventAStoppingState() {
        let model = StudioModel()
        model.stage = "已完成"
        model.cancel(reason: .background)
        XCTAssertEqual(model.stage, "已完成")
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.stopReason)
    }

    func testCancellingAnOwnedGenerationSettlesAndPreservesPublishedAssets() async throws {
        let model = StudioModel()
        model.sceneSpec = .robot
        model.generate(usingAI: false)
        XCTAssertTrue(model.busy)
        model.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.stage, "已取消")
        XCTAssertNil(model.assets)
        XCTAssertEqual(model.stopReason, .user)
        XCTAssertLessThan(try XCTUnwrap(model.lastStopLatency), 3)
    }

    func testBackgroundCleanupBlocksRetryUntilUnloadAndPreservesSavedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StudioCleanup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ControlledUnload()
        defer { gate.release() }
        let platform = FakeBackgroundTasks()
        let store = ProjectStore(root: root)
        let model = StudioModel(models: ModelManager(unloadRuntime: { await gate.run() }),
                                store: store, backgroundTasks: platform.client)
        let meshes = try SceneGenerator.generate(for: .chair)
        let originalGLB = try ThreeLiveNative.exportGLB(meshes)
        let saved = try await store.publish(spec: .chair, prompt: "保留作品", glb: originalGLB,
            usdz: ThreeLiveNative.exportUSDZ(meshes), replacing: nil)
        model.assets = saved
        model.sceneSpec = .robot
        model.generate(usingAI: false)
        model.enterBackground()
        try await waitUntil { gate.callCount == 1 }

        XCTAssertTrue(model.isCleaningUp)
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.models.busy)
        XCTAssertTrue(model.models.isUnloading)
        XCTAssertFalse(model.models.loaded)
        XCTAssertNil(model.lastStopLatency, "The stop receipt must wait for model cleanup")
        XCTAssertEqual(model.assets?.project, saved.project)
        XCTAssertEqual(try Data(contentsOf: saved.glbURL), originalGLB)
        _ = try await store.load(saved.project)

        let stoppingStage = model.stage
        model.generate(usingAI: false)
        XCTAssertEqual(model.stopReason, .background, "A blocked retry must not reset the owned stop")
        XCTAssertEqual(model.stage, stoppingStage)
        model.handleMemoryPressure()
        model.enterBackground()
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertEqual(platform.beginCount, 1)
        XCTAssertEqual(platform.endCount, 0)

        gate.release()
        try await waitUntil { !model.busy }
        XCTAssertFalse(model.isCleaningUp)
        XCTAssertFalse(model.models.busy)
        XCTAssertEqual(platform.endCount, 1)
        XCTAssertEqual(model.stage, "已取消")
        XCTAssertNotNil(model.lastStopLatency)

        model.generate(usingAI: false)
        XCTAssertTrue(model.busy)
        try await waitUntil { !model.busy }
        XCTAssertEqual(model.stage, "已完成")
        XCTAssertNotEqual(model.assets?.project.revision, saved.project.revision)
        XCTAssertEqual(try Data(contentsOf: saved.glbURL), originalGLB,
                       "A successful retry must preserve the previously published revision")
    }

    func testMemoryCleanupGetsOneLeaseWhenBackgroundedAndExpirationEndsItOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StudioMemoryCleanup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ControlledUnload()
        defer { gate.release() }
        let platform = FakeBackgroundTasks()
        let model = StudioModel(models: ModelManager(unloadRuntime: { await gate.run() }),
                                store: ProjectStore(root: root), backgroundTasks: platform.client)
        model.generate(usingAI: false)
        model.handleMemoryPressure(.critical)
        try await waitUntil { gate.callCount == 1 }
        XCTAssertEqual(platform.beginCount, 0)
        model.enterBackground()
        model.enterBackground()
        model.handleMemoryPressure()
        XCTAssertEqual(platform.beginCount, 1)
        XCTAssertEqual(gate.callCount, 1)
        platform.expire()
        XCTAssertEqual(platform.endCount, 1, "Expiration must end the assertion synchronously")
        XCTAssertTrue(model.busy, "Ending the assertion does not pretend model cleanup completed")
        XCTAssertNil(model.lastStopLatency)
        platform.expire()
        XCTAssertEqual(platform.endCount, 1)
        model.generate(usingAI: false)
        XCTAssertEqual(model.stopReason, .memoryPressure)
        gate.release()
        try await waitUntil { !model.busy }
        XCTAssertEqual(platform.endCount, 1, "Normal completion after expiration must not end it twice")
        XCTAssertNotNil(model.lastStopLatency)
    }

    func testLeaseAlsoEndsOnceWhenExpirationIsSynchronousDuringBegin() {
        let platform = FakeBackgroundTasks()
        platform.expireDuringBegin = true
        var expirationCount = 0
        let lease = BackgroundTaskLease(client: platform.client) { expirationCount += 1 }
        XCTAssertEqual(expirationCount, 1)
        XCTAssertEqual(platform.endCount, 1)
        lease.end()
        lease.end()
        XCTAssertEqual(platform.endCount, 1)
    }

    func testModelUnloadCoalescesAndPrepareCannotTreatItAsALoadedModel() async throws {
        let gate = ControlledUnload()
        defer { gate.release() }
        let model = ModelManager(unloadRuntime: { await gate.run() })
        let first = Task {
            await model.unload()
            XCTAssertFalse(model.isUnloading, "The owner must observe finalized state on return")
        }
        try await waitUntil { gate.callCount == 1 }
        let second = Task {
            await model.unload()
            XCTAssertFalse(model.isUnloading, "A joining caller must observe finalized state on return")
        }
        await Task.yield()
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.isUnloading)
        XCTAssertFalse(model.loaded)
        do {
            try await model.prepare()
            XCTFail("Prepare must reject admission during model release")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("模型正在处理"))
        }
        XCTAssertEqual(gate.callCount, 1)
        gate.release()
        await first.value
        await second.value
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.isUnloading)
        XCTAssertFalse(model.loaded)
    }

    func testEveryUnloadCallerObservesFinalStateAtItsOwnReturn() async throws {
        let gate = ControlledUnload()
        defer { gate.release() }
        let model = ModelManager(unloadRuntime: { await gate.run() })
        let owner = Task(priority: .background) {
            await model.unload()
            return (isUnloading: model.isUnloading, busy: model.busy)
        }
        try await waitUntil { gate.callCount == 1 }
        var enteredJoiners = 0
        let joiners = (0..<7).map { _ in
            Task(priority: .userInitiated) {
                enteredJoiners += 1
                await model.unload()
                // Capture immediately, before awaiting the owner or another
                // caller can hide a premature return from this invocation.
                return (isUnloading: model.isUnloading, busy: model.busy)
            }
        }
        try await waitUntil { enteredJoiners == joiners.count }
        XCTAssertTrue(model.isUnloading)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(gate.callCount, 1)
        gate.release()
        for joiner in joiners {
            let state = await joiner.value
            XCTAssertFalse(state.isUnloading)
            XCTAssertFalse(state.busy)
        }
        let ownerState = await owner.value
        XCTAssertFalse(ownerState.isUnloading)
        XCTAssertFalse(ownerState.busy)
        XCTAssertEqual(gate.callCount, 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Lifecycle transition did not settle", file: file, line: line)
        if !condition() { throw LifecycleTestError.timeout }
    }
}

private enum LifecycleTestError: Error { case timeout }

@MainActor
private final class FakeIdleTimer {
    private(set) var disabled: Bool
    private(set) var writes: [Bool] = []

    init(disabled: Bool) { self.disabled = disabled }

    var client: IdleTimerClient {
        IdleTimerClient(isDisabled: { [self] in disabled }, setDisabled: { [self] value in
            disabled = value
            writes.append(value)
        })
    }
}

@MainActor
private final class ControlledUnload {
    private(set) var callCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func run() async {
        callCount += 1
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
private final class FakeBackgroundTasks {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    var expireDuringBegin = false
    private var expiration: (@MainActor @Sendable () -> Void)?

    var client: BackgroundTaskClient {
        BackgroundTaskClient(begin: { [self] callback in
            beginCount += 1
            expiration = callback
            if expireDuringBegin { callback() }
            return UIBackgroundTaskIdentifier(rawValue: beginCount)
        }, end: { [self] _ in endCount += 1 })
    }

    func expire() { expiration?() }
}
