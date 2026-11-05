import XCTest
@testable import VoxamberCreationNative

final class CreationIntentTests: XCTestCase {
    func testDescriptionIsLanguageOnlyWithoutATypeWhitelistOrGeometryFallback() throws {
        let raw = #"{"positivePrompt":"an irregular musical instrument with flowing curves"}"#
        let value = try CreationIntentDecoder.decode(raw, sourcePrompt: "自由造型")
        XCTAssertEqual(value.positivePrompt, "an irregular musical instrument with flowing curves")
        XCTAssertEqual(value.title, "自由造型")
    }

    func testMissingForeignAndControlCharacterFieldsAreRejected() {
        for raw in [
            #"{}"#,
            #"{"positivePrompt":"a lamp","nodes":[]}"#,
            #"{"positivePrompt":"a lamp","positivePrompt":"duplicate"}"#,
            #"{"positivePrompt":"a\nlamp"}"#
        ] { XCTAssertThrowsError(try CreationIntentDecoder.decode(raw, sourcePrompt: "原描述")) }
    }

    func testOverlongVisualBriefIsRejectedWithoutSilentlyDroppingIntent() {
        let raw = "{\"positivePrompt\":\"" + String(repeating: "a", count: 181) + "\"}"
        XCTAssertThrowsError(try CreationIntentDecoder.decode(raw, sourcePrompt: "原描述"))
    }

    func testChineseVisualBriefAndInventedNegativeListAreRejected() {
        for raw in [
            #"{"positivePrompt":"蓝色贝壳形花瓶"}"#,
            #"{"positivePrompt":"a blue shell vase with a gold rim","negativePrompt":"gold, shell, vase"}"#
        ] { XCTAssertThrowsError(try CreationIntentDecoder.decode(raw, sourcePrompt: "原描述")) }
    }

    func testCanceledColdOperationDoesNotLoadAnyModel() async {
        let engine = NativeCreationEngine()
        let missing = URL(fileURLWithPath: "/nonexistent-voxamber-test")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.generate(prompt: "任意造型", seed: 1,
                resources: .init(intentModelDirectory: missing, imageModelDirectory: missing, shapeModelFile: missing))
        }
        do { _ = try await task.value; XCTFail("Canceled before resource loading") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation before filesystem/model access") }
        await engine.unload()
        let running = await engine.isRunning
        XCTAssertFalse(running)
    }
}
