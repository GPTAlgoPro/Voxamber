import XCTest
import CreationCore
@testable import ThreeLiveStudio

@MainActor
final class StudioCancellationTests: XCTestCase {
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
}
