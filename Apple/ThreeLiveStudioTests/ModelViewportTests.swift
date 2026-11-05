import XCTest
import SwiftUI
import RealityKit
import UIKit
import Observation
import CreationCore
import ThreeLiveNative
@testable import ThreeLiveStudio

@MainActor
final class ModelViewportTests: XCTestCase {
    private let firstURL = URL(fileURLWithPath: "/preview-test-first.usdz")
    private let secondURL = URL(fileURLWithPath: "/preview-test-second.usdz")

    func testCancellationDoesNotBecomeAFinalErrorAndAVisibleRetryCanLoad() async {
        var calls = 0
        let expected = Entity()
        let state = ModelPreviewLoadState { _ in
            calls += 1
            if calls == 1 { throw CancellationError() }
            return expected
        }
        await state.load(url: firstURL)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.entity)
        await state.load(url: firstURL)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertTrue(state.entity === expected)
        XCTAssertNil(state.errorMessage)
    }

    func testBridgedCancellationFromAnAssetLoaderIsAlsoNotAFinalError() async {
        let cancellation = CancellationError() as NSError
        let state = ModelPreviewLoadState { _ in
            throw NSError(domain: cancellation.domain, code: cancellation.code)
        }
        await state.load(url: firstURL)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertNil(state.errorMessage)
    }

    func testRealFailureRemainsVisibleAndSuccessfulRetryClearsIt() async {
        var calls = 0
        let expected = Entity()
        let state = ModelPreviewLoadState { _ in
            calls += 1
            if calls == 1 { throw CocoaError(.fileReadCorruptFile) }
            return expected
        }
        await state.load(url: firstURL)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertNotNil(state.errorMessage)
        await state.load(url: firstURL)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertTrue(state.entity === expected)
        XCTAssertNil(state.errorMessage)
    }

    func testCancelledTaskCannotPublishAnAssetThatFinishesLate() async throws {
        let gate = PreviewEntityGate()
        let state = ModelPreviewLoadState { _ in try await gate.load() }
        let task = Task { await state.load(url: firstURL) }
        try await waitUntil { gate.waiting }
        task.cancel()
        gate.finish(.success(Entity()))
        await task.value
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertNil(state.entity)
        XCTAssertNil(state.errorMessage)
    }

    func testSupersededSuccessAndFailureCannotOverwriteTheNewerURL() async throws {
        for oldFails in [false, true] {
            let gate = PreviewEntityGate()
            let newer = Entity()
            let state = ModelPreviewLoadState { url in
                if url == self.firstURL { return try await gate.load() }
                return newer
            }
            let old = Task { await state.load(url: firstURL) }
            try await waitUntil { gate.waiting }
            await state.load(url: secondURL)
            gate.finish(oldFails ? .failure(CocoaError(.fileReadCorruptFile)) : .success(Entity()))
            await old.value
            XCTAssertEqual(state.url, secondURL)
            XCTAssertEqual(state.phase, .ready)
            XCTAssertTrue(state.entity === newer)
            XCTAssertNil(state.errorMessage)
        }
    }

    func testAViewTaskLoadsAgainAfterDisappearanceInsteadOfKeepingCancellationAsAnError() async throws {
        var calls = 0
        let state = ModelPreviewLoadState { _ in
            calls += 1
            if calls == 1 { try await Task.sleep(for: .seconds(20)) }
            return Entity()
        }
        let visibility = PreviewVisibility()
        let host = UIHostingController(rootView: PreviewVisibilityHost(url: firstURL, state: state, visibility: visibility))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitUntil { calls == 1 && state.phase == .loading }
        visibility.visible = false
        try await waitUntil { state.phase == .cancelled }
        XCTAssertNil(state.errorMessage)
        visibility.visible = true
        try await waitUntil { calls == 2 && state.phase == .ready }
        XCTAssertNil(state.errorMessage)
    }

    func testActualNativeUSDZMountsInRealityViewAndKeepsTheExistingPreviewFit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PreviewUSDZ-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "mesh.usdz")
        let scene = SceneSpec(name: "Synthetic native preview", nodes: [
            SceneNode(id: "shape", primitive: .box, position: [0.2, 0.1, -0.3], size: [0.3, 0.2, 0.4])
        ])
        try ThreeLiveNative.exportUSDZ(SceneGenerator.generate(for: scene)).write(to: url)
        let state = ModelPreviewLoadState()
        let host = UIHostingController(rootView: ModelViewport(url: url, loadState: state)
            .frame(width: 300, height: 300).preferredColorScheme(.dark))
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitUntil { state.phase == .ready || state.phase == .failed }
        XCTAssertEqual(state.phase, .ready, state.errorMessage ?? "No load error")
        let entity = try XCTUnwrap(state.entity)
        try await waitUntil { entity.scene != nil }
        XCTAssertNotNil(entity.scene, "RealityView update must mount the actual native USDZ entity")
        let bounds = entity.visualBounds(relativeTo: nil)
        XCTAssertEqual(max(bounds.extents.x, bounds.extents.y, bounds.extents.z), 0.65, accuracy: 0.0001)
        XCTAssertEqual(bounds.center.x, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds.center.y, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds.center.z, 0, accuracy: 0.0001)
        XCTAssertNil(state.errorMessage)
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let capture = XCTAttachment(image: image)
        capture.name = "Actual-native-USDZ-mounted-preview"
        capture.lifetime = .keepAlways
        add(capture)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Preview lifecycle did not settle", file: file, line: line)
        if !predicate() { throw PreviewTestError.timeout }
    }
}

private enum PreviewTestError: Error { case timeout }

@MainActor
private final class PreviewEntityGate {
    private var continuation: CheckedContinuation<Entity, Error>?
    var waiting: Bool { continuation != nil }
    func load() async throws -> Entity { try await withCheckedThrowingContinuation { continuation = $0 } }
    func finish(_ result: Result<Entity, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor @Observable
private final class PreviewVisibility { var visible = true }

@MainActor
private struct PreviewVisibilityHost: View {
    let url: URL
    let state: ModelPreviewLoadState
    @Bindable var visibility: PreviewVisibility
    var body: some View {
        if visibility.visible { ModelViewport(url: url, loadState: state).frame(width: 300, height: 300) }
        else { Text("Hidden preview") }
    }
}
