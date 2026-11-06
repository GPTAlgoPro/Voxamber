import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VoxamberCreationNative

@Suite struct SubjectImagePreparerTests {
    @Test func explicitMaskBoundsUseCoreImageBottomLeftAndIncludeAllIslands() throws {
        let extent = CGRect(x: 0, y: 0, width: 40, height: 24)
        let source = try cgImage(CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.4)), extent)
        let mask = unionMask(extent, [CGRect(x: 2, y: 18, width: 4, height: 2),
                                      CGRect(x: 35, y: 1, width: 1, height: 1)])
        let result = try SubjectImagePreparer.prepareMasked(source: source, mask: mask, method: "synthetic-explicit-mask")
        #expect(result.foregroundBounds == [2,1,34,19])
        #expect(result.sourceWidth == 40 && result.sourceHeight == 24)
        #expect(result.method == "synthetic-explicit-mask")
        let output = try SubjectImagePreparer.decodePNG(result.pngData)
        #expect(output.width == 512 && output.height == 512)
        let bounds = try pixelBounds(output)
        #expect(abs(bounds.midX - 256) <= 1.5 && abs(bounds.midY - 256) <= 1.5)
        // Upsampling a one-pixel island keeps a nonzero-alpha filter fringe;
        // do not demand a nominal 435px box by trimming those soft edges.
        #expect(max(bounds.width, bounds.height) >= 400)
        #expect(bounds.minX > 20 && bounds.maxX < 492 && bounds.minY > 20 && bounds.maxY < 492)
    }

    @Test func edgeTouchingThinSubjectIsNotClippedOrLostOnTransparentPadding() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 80)
        let source = try cgImage(CIImage(color: CIColor(red: 1, green: 0.25, blue: 0)), extent)
        let result = try SubjectImagePreparer.prepareMasked(source: source,
            mask: unionMask(extent, [CGRect(x: 0, y: 0, width: 1, height: 80)]), method: "synthetic-edge-mask")
        #expect(result.foregroundBounds == [0,0,1,80])
        let output = try SubjectImagePreparer.decodePNG(result.pngData)
        #expect(output.width == 512 && output.height == 512)
        let bounds = try pixelBounds(output)
        #expect(bounds.height >= 430 && bounds.width >= 5)
        #expect(bounds.minY > 20 && bounds.maxY < 492)
        let data = rgba(output)
        #expect(data[3] == 0 && data[(512 * 512 - 1) * 4 + 3] == 0)
    }

    @Test func sourceAlphaAndSoftMaskRemainAlphaInsteadOfWhiteFlattening() throws {
        let extent = CGRect(x: 0, y: 0, width: 40, height: 40)
        let source = try cgImage(CIImage(color: CIColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 0.5)), extent)
        let soft = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            .cropped(to: CGRect(x: 8, y: 8, width: 24, height: 24))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let result = try SubjectImagePreparer.prepareMasked(source: source, mask: soft, method: "synthetic-soft-mask")
        let output = try SubjectImagePreparer.decodePNG(result.pngData)
        let pixels = rgba(output)
        let middle = (256 * 512 + 256) * 4
        #expect(pixels[middle + 3] > 0 && pixels[middle + 3] < 128)
        #expect(pixels[3] == 0)
        #expect(pixels[middle] > pixels[middle + 1] * 2)
        #expect(output.alphaInfo != .none && output.alphaInfo != .noneSkipFirst && output.alphaInfo != .noneSkipLast)
    }

    @Test func asymmetricColorsKeepVerticalOrientationAndOriginalPNGUnchanged() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)
        let red = CIImage(color: .red).cropped(to: CGRect(x: 4, y: 35, width: 8, height: 10))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 4, y: 3, width: 8, height: 10))
        let source = try cgImage(red.composited(over: blue).composited(over: CIImage(color: .clear).cropped(to: extent)), extent)
        let original = try png(source), before = original
        let mask = unionMask(extent, [CGRect(x: 4, y: 35, width: 8, height: 10), CGRect(x: 4, y: 3, width: 8, height: 10)])
        let result = try SubjectImagePreparer.prepareMasked(source: try SubjectImagePreparer.decodePNG(original), mask: mask,
                                                           method: "synthetic-orientation-mask")
        #expect(original == before && result.pngData != original)
        #expect(result.sourceWidth == 64 && result.sourceHeight == 48)
        let pixels = rgba(try SubjectImagePreparer.decodePNG(result.pngData))
        var redY: [Int] = [], blueY: [Int] = []
        for row in 0..<512 {
            for x in 0..<512 {
                let i = (row * 512 + x) * 4
                guard pixels[i + 3] > 128 else { continue }
                if pixels[i] > 200 && pixels[i + 2] < 30 { redY.append(511 - row) }
                if pixels[i + 2] > 200 && pixels[i] < 30 { blueY.append(511 - row) }
            }
        }
        #expect(redY.count > 100 && blueY.count > 100)
        #expect(try #require(redY.min()) > #require(blueY.max()))
    }

    @Test func emptyOrMisalignedMaskThrowsAndNeverReturnsFullFrameFallback() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 24)
        let source = try cgImage(CIImage(color: .green), extent)
        #expect(throws: CreationError.subjectNotFound) {
            try SubjectImagePreparer.prepareMasked(source: source, mask: CIImage(color: .black).cropped(to: extent),
                                                   method: "synthetic-empty-mask")
        }
        #expect(throws: CreationError.invalidReferenceImage) {
            try SubjectImagePreparer.prepareMasked(source: source,
                mask: CIImage(color: .white).cropped(to: CGRect(x: 1, y: 0, width: 32, height: 24)),
                method: "synthetic-wrong-frame")
        }
    }

    @Test func coldCancellationWinsBeforeInvalidPNGAndBeforeVisionCreation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SubjectImagePreparer.prepare(pngData: Data())
        }
        do { _ = try await task.value; Issue.record("Cold cancellation returned prepared data") }
        catch is CancellationError { }
        catch { Issue.record("Expected cancellation before PNG/Vision, got \(error)") }
    }

    @Test func cancellationSignalsRequestAndWaitsForOwnedWorker() async {
        let entered = AsyncStream<Void>.makeStream()
        let state = SubjectCancellationEvents()
        let task = Task {
            defer { state.finish() }
            return try await runOwnedSubjectWorker { cancellation in
                cancellation.setRequestCancellation { state.cancelRequest() }
                entered.continuation.yield(()); entered.continuation.finish()
                guard state.release.wait(timeout: .now() + 5) == .success else { throw SubjectTestError.timeout }
                try cancellation.check()
                throw SubjectTestError.unexpectedCompletion
            }
        }
        for await _ in entered.stream { break }
        task.cancel()
        #expect(state.snapshot.requestCancelCount == 1)
        #expect(state.snapshot.finished == false)
        state.release.signal()
        do { _ = try await task.value; Issue.record("Cancellation returned data") }
        catch is CancellationError { }
        catch { Issue.record("Expected cancellation, got \(error)") }
        #expect(state.snapshot.finished)
    }
}

private enum SubjectTestError: Error { case timeout, unexpectedCompletion }
private final class SubjectCancellationEvents: @unchecked Sendable {
    struct Snapshot { var requestCancelCount = 0; var finished = false }
    private let lock = NSLock()
    private var state = Snapshot()
    let release = DispatchSemaphore(value: 0)
    var snapshot: Snapshot { lock.withLock { state } }
    func cancelRequest() { lock.withLock { state.requestCancelCount += 1 } }
    func finish() { lock.withLock { state.finished = true } }
}

private func cgImage(_ image: CIImage, _ extent: CGRect) throws -> CGImage {
    try #require(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: extent,
        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
}
private func unionMask(_ extent: CGRect, _ rects: [CGRect]) -> CIImage {
    rects.reduce(CIImage(color: .black).cropped(to: extent)) { current, rect in
        CIImage(color: .white).cropped(to: rect).composited(over: current)
    }.cropped(to: extent)
}
private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    CIContext(options: [.useSoftwareRenderer: true]).render(CIImage(cgImage: image), toBitmap: &bytes,
        rowBytes: image.width * 4, bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return bytes
}
private func pixelBounds(_ image: CGImage) throws -> CGRect {
    let bytes = rgba(image), width = image.width, height = image.height
    var minX = width, maxX = -1, minRow = height, maxRow = -1
    for row in 0..<height {
        for x in 0..<width where bytes[(row * width + x) * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minRow = min(minRow, row); maxRow = max(maxRow, row)
        }
    }
    try #require(maxX >= minX && maxRow >= minRow)
    return CGRect(x: minX, y: height - maxRow - 1, width: maxX - minX + 1, height: maxRow - minRow + 1)
}
private func png(_ image: CGImage) throws -> Data {
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return buffer as Data
}
