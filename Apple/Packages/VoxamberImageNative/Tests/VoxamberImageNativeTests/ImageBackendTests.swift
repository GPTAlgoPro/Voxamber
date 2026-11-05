import Foundation
import CoreGraphics
import ImageIO
import Testing
import AppleSDXL
@testable import VoxamberImageNative

@Suite struct ImageBackendTests {
    @Test func nativeBPEMergesAndBothXLPadConventions() throws {
        let directory = try fixtureResources()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try BPETokenizer(mergesAt: directory.appendingPathComponent("merges.txt"),
                                     vocabularyAt: directory.appendingPathComponent("vocab.json"))
        let second = try BPETokenizer(mergesAt: directory.appendingPathComponent("merges.txt"),
                                      vocabularyAt: directory.appendingPathComponent("vocab.json"), padToken: "!")
        #expect(first.tokenize(input: "RED box", minCount: 7).tokenIDs == [49406,100,101,49407,49407,49407,49407])
        #expect(second.tokenize(input: "RED box", minCount: 7).tokenIDs == [49406,100,101,49407,0,0,0])
    }

    @Test func malformedVocabularyThrowsInsteadOfUpstreamForceTryTrap() throws {
        let directory = try fixtureResources()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("vocab.json"))
        #expect(throws: DecodingError.self) {
            try BPETokenizer(mergesAt: directory.appendingPathComponent("merges.txt"),
                             vocabularyAt: directory.appendingPathComponent("vocab.json"))
        }
    }

    @Test func structuralResourceAdmissionRequiresBothChunksAndRejectsExtraModels() throws {
        let directory = try fixtureResources()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SDXLResources.validateLayout(at: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("UnetChunk2.mlmodelc"))
        #expect(throws: ImageBackendError.missingResource("UnetChunk2.mlmodelc")) {
            try SDXLResources.validateLayout(at: directory)
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Unet.mlmodelc"), withIntermediateDirectories: false)
        try SDXLResources.validateLayout(at: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("UnetRefiner.mlmodelc"), withIntermediateDirectories: false)
        #expect(throws: ImageBackendError.unsupportedAuxiliaryModel("UnetRefiner.mlmodelc")) {
            try SDXLResources.validateLayout(at: directory)
        }
    }

    @Test func tokenLimitRejectsTruncationAndOptionsPreserveSDXLScaleSeedAndPrompts() throws {
        let directory = try fixtureResources()
        defer { try? FileManager.default.removeItem(at: directory) }
        let long = ImageRequest(positivePrompt: Array(repeating: "red", count: 76).joined(separator: " "),
                                negativePrompt: "", seed: 93, options: .init())
        #expect(throws: ImageBackendError.promptTooLong(actualTokens: 78, maximum: 77)) {
            try SDXLResources.validateTokenizer(at: directory, request: long)
        }
        let request = ImageRequest(positivePrompt: "red box", negativePrompt: "cropped", seed: 93,
                                   options: .init(steps: 20, guidanceScale: 6))
        let config = AppleSDXLDriver.configuration(for: request)
        #expect(config.prompt == "red box" && config.negativePrompt == "cropped")
        #expect(config.seed == 93 && config.stepCount == 20 && config.imageCount == 1)
        #expect(config.targetSize == 768 && config.originalSize == 768)
        #expect(config.decoderScaleFactor == 0.13025)
        #expect(config.startingImage == nil)
    }

    @Test func missingResourcesThrowBeforeAnyDriverOrCoreMLLoad() async {
        let events = DriverEvents()
        let engine = ImageEngine(makeDriver: { _, _ in events.created(); return FailureDriver(events: events) })
        do {
            _ = try await engine.generate(positivePrompt: "red box", seed: 1,
                resourcesURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            Issue.record("Missing model directory must fail")
        } catch let error as ImageBackendError { #expect(error == .resourcesMustBeLocalDirectory) }
        catch { Issue.record("Unexpected error \(error)") }
        #expect(events.snapshot.created == 0 && events.snapshot.loaded == 0)
    }

    @Test func schedulerStepAdmissionPreventsPinnedPNDMEmptyArrayTrap() throws {
        let invalid = ImageRequest(positivePrompt: "red box", negativePrompt: "", seed: 1,
                                   options: .init(steps: 1, scheduler: .pndm))
        #expect(throws: ImageBackendError.invalidOptions) { try invalid.validate() }
        let validPNDM = ImageRequest(positivePrompt: "red box", negativePrompt: "", seed: 1,
                                     options: .init(steps: 2, scheduler: .pndm))
        try validPNDM.validate()
        #expect(PNDMScheduler(stepCount: 2).timeSteps.count == 3)
        let validDPM = ImageRequest(positivePrompt: "red box", negativePrompt: "", seed: 1,
                                    options: .init(steps: 1))
        try validDPM.validate()
        #expect(DPMSolverMultistepScheduler(stepCount: 1).timeSteps.count == 1)
    }

    @Test func invalidPromptAndNonfiniteOptionsNeverCreateDriver() async throws {
        let directory = try fixtureResources()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = DriverEvents()
        let engine = ImageEngine(makeDriver: { _, _ in events.created(); return FailureDriver(events: events) })
        do { _ = try await engine.generate(positivePrompt: "   ", seed: 1, resourcesURL: directory); Issue.record("Empty prompt accepted") }
        catch let error as ImageBackendError { #expect(error == .invalidPrompt) }
        do { _ = try await engine.generate(positivePrompt: "red", seed: 1, resourcesURL: directory,
                                          options: .init(guidanceScale: .nan)); Issue.record("NaN accepted") }
        catch let error as ImageBackendError { #expect(error == .invalidOptions) }
        #expect(events.snapshot.created == 0)
    }

    @Test func failedLoadAlwaysUnloadsAndDoesNotReturnAnImage() async throws {
        let directory = try fixtureResources()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = DriverEvents()
        let engine = ImageEngine(makeDriver: { _, _ in events.created(); return FailureDriver(events: events) })
        do { _ = try await engine.generate(positivePrompt: "red box", seed: 1, resourcesURL: directory); Issue.record("Load failure returned image") }
        catch DriverTestError.loadFailed { }
        catch { Issue.record("Unexpected error \(error)") }
        #expect(events.snapshot.created == 1 && events.snapshot.loaded == 1 && events.snapshot.unloaded == 1)
    }

    @Test func precancelledTaskDoesNotEvenAdmitResources() async {
        let engine = ImageEngine()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.generate(positivePrompt: "red box", seed: 1,
                resourcesURL: URL(fileURLWithPath: "/missing-model-resources"))
        }
        do { _ = try await task.value; Issue.record("Cancelled task returned an image") }
        catch is CancellationError { }
        catch { Issue.record("Expected cancellation, got \(error)") }
    }

    @Test func cancellationBridgesToStepBooleanAndAwaitsUnload() async throws {
        let directory = try fixtureResources()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = DriverEvents()
        let started = AsyncStream<Void>.makeStream()
        let engine = ImageEngine(makeDriver: { _, _ in
            events.created()
            return CancellingDriver(events: events, started: started.continuation)
        })
        let task = Task { try await engine.generate(positivePrompt: "red box", seed: 1, resourcesURL: directory) }
        for await _ in started.stream { break }
        task.cancel()
        events.release.signal()
        do { _ = try await task.value; Issue.record("Cancelled operation returned an image") }
        catch is CancellationError { }
        catch { Issue.record("Expected cancellation, got \(error)") }
        #expect(events.snapshot.cancelBoolean == false)
        #expect(events.snapshot.unloaded == 1)
    }

    @Test func PNGEncodingIsNativeImageIOFormatOnlyNotAnInferenceTest() throws {
        let bytes = Data([UInt8](repeating: 127, count: 2 * 2 * 4))
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try PNGEncoder.encode(image)
        #expect(Array(png.prefix(8)) == [137,80,78,71,13,10,26,10])
        let decoded = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(result.width == 2 && result.height == 2)
    }
}

private enum DriverTestError: Error { case loadFailed, timeout }

private final class DriverEvents: @unchecked Sendable {
    struct Snapshot { var created = 0; var loaded = 0; var unloaded = 0; var cancelBoolean: Bool? }
    private let lock = NSLock()
    private var state = Snapshot()
    let release = DispatchSemaphore(value: 0)
    var snapshot: Snapshot { lock.withLock { state } }
    func created() { lock.withLock { state.created += 1 } }
    func loaded() { lock.withLock { state.loaded += 1 } }
    func unloaded() { lock.withLock { state.unloaded += 1 } }
    func continued(_ value: Bool) { lock.withLock { state.cancelBoolean = value } }
}

private struct FailureDriver: SDXLPipelineDriver {
    let events: DriverEvents
    func loadResources() throws { events.loaded(); throw DriverTestError.loadFailed }
    func unloadResources() { events.unloaded() }
    func generate(request: ImageRequest, shouldContinue: (Int, Int) -> Bool) throws -> [CGImage?] {
        throw DriverTestError.loadFailed
    }
}

private struct CancellingDriver: SDXLPipelineDriver {
    let events: DriverEvents
    let started: AsyncStream<Void>.Continuation
    func loadResources() { events.loaded() }
    func unloadResources() { events.unloaded() }
    func generate(request: ImageRequest, shouldContinue: (Int, Int) -> Bool) throws -> [CGImage?] {
        started.yield(()); started.finish()
        guard events.release.wait(timeout: .now() + 5) == .success else { throw DriverTestError.timeout }
        events.continued(shouldContinue(1, 20))
        return [] // No fake generated image; cancellation must be thrown by the owner.
    }
}

private func fixtureResources() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxamber-image-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    for name in ["TextEncoder.mlmodelc", "TextEncoder2.mlmodelc", "VAEDecoder.mlmodelc", "UnetChunk1.mlmodelc", "UnetChunk2.mlmodelc"] {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    let vocabulary = ["<|startoftext|>":49406, "<|endoftext|>":49407, "!":0, "red</w>":100, "box</w>":101]
    try JSONEncoder().encode(vocabulary).write(to: directory.appendingPathComponent("vocab.json"))
    try Data("#version: 0.2\nr e\nre d</w>\nb o\nbo x</w>\n".utf8).write(to: directory.appendingPathComponent("merges.txt"))
    return directory
}
