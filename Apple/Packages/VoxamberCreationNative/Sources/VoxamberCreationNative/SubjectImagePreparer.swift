import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

// Framing reference: Snap3D/Sources/Pipeline/SubjectIsolator.swift,
// SHA256 93f8c4bcec912e86fe891bf646d1302a207bd9ffb69a49ade23da02964ca6528.
// Adapt only native mask blending, top-row -> CI-bottom bounds, and separate
// translation/scale + explicit transparent canvas. No person/full-frame fallback.
public enum SubjectImagePreparer {
    public static func prepare(pngData: Data) async throws -> PreparedShapeReference {
        try Task.checkCancellation() // No Vision request/model on a cold cancellation.
        return try await runOwnedSubjectWorker { cancellation in
            let source = try decodePNG(pngData)
            try cancellation.check()
            let handle = ForegroundRequestHandle()
            cancellation.setRequestCancellation { handle.request.cancel() }
            defer { cancellation.clearRequestCancellation() }
            try cancellation.check()
            let handler = VNImageRequestHandler(cgImage: source, orientation: .up, options: [:])
            try handler.perform([handle.request])
            try cancellation.check()
            guard let observation = handle.request.results?.first,
                  !observation.allInstances.isEmpty else { throw CreationError.subjectNotFound }
            let maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler)
            try cancellation.check()
            return try prepareMasked(source: source, mask: CIImage(cvPixelBuffer: maskBuffer),
                                     method: "apple-vision-all-foreground-alpha-512")
        }
    }

    /// Pure native raster operation. An explicit synthetic mask can exercise
    /// geometry/alpha without starting Vision or claiming segmentation success.
    static func prepareMasked(source: CGImage, mask: CIImage,
                              method: String) throws -> PreparedShapeReference {
        try Task.checkCancellation()
        let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard source.width > 0, source.height > 0, source.width <= 4096, source.height <= 4096,
              mask.extent == extent else { throw CreationError.invalidReferenceImage }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let sourceImage = CIImage(cgImage: source)
        let transparent = CIImage(color: .clear).cropped(to: extent)
        let cutout = sourceImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
        let bounds = try alphaBounds(of: cutout, context: context, extent: extent)
        let side = max(bounds.width, bounds.height) / 0.85
        let square = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        let scale = 512 / side
        let canvas = CGRect(x: 0, y: 0, width: 512, height: 512)
        // Separate transforms ensure the crop origin is scaled too. Explicit
        // padding is required when the source subject touches an image edge.
        let framed = cutout
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .composited(over: CIImage(color: .clear).cropped(to: canvas))
            .cropped(to: canvas)
        try Task.checkCancellation()
        guard let image = context.createCGImage(framed, from: canvas, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw CreationError.invalidReferenceImage
        }
        let png = try encodePNG(image)
        try Task.checkCancellation()
        return PreparedShapeReference(pngData: png, sourceWidth: source.width, sourceHeight: source.height,
            foregroundBounds: [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)],
            method: method)
    }

    static func decodePNG(_ data: Data) throws -> CGImage {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type as String == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...4096).contains(width.intValue), (1...4096).contains(height.intValue),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096 else {
            throw CreationError.invalidReferenceImage
        }
        return image
    }

    private static func alphaBounds(of image: CIImage, context: CIContext, extent: CGRect) throws -> CGRect {
        let width = Int(extent.width), height = Int(extent.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &rgba, rowBytes: width * 4, bounds: extent,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var minX = width, maxX = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            if row % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<width where rgba[(row * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= minX, maxRow >= minRow else { throw CreationError.subjectNotFound }
        // CIContext bitmap rows start at the top, while CI coordinates start
        // at the bottom. Include every nonzero-alpha source pixel, not a
        // downsampled or thresholded proxy that could discard thin edges.
        return CGRect(x: minX, y: height - maxRow - 1,
                      width: maxX - minX + 1, height: maxRow - minRow + 1)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw CreationError.invalidReferenceImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CreationError.invalidReferenceImage }
        return buffer as Data
    }
}

private final class ForegroundRequestHandle: @unchecked Sendable {
    // Vision's cancellation API is called from the cancellation handler;
    // request execution/results remain confined to the single owned worker.
    let request = VNGenerateForegroundInstanceMaskRequest()
}

final class SubjectWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var requestCancel: (@Sendable () -> Void)?
    private var workerCancel: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }
    func setRequestCancellation(_ action: @escaping @Sendable () -> Void) {
        let invoke = lock.withLock { requestCancel = action; return cancelled }
        if invoke { action() }
    }
    func clearRequestCancellation() { lock.withLock { requestCancel = nil } }
    func setWorkerCancellation(_ action: @escaping @Sendable () -> Void) {
        let invoke = lock.withLock { workerCancel = action; return cancelled }
        if invoke { action() }
    }
    func clearWorkerCancellation() { lock.withLock { workerCancel = nil } }
    func cancel() {
        let actions: ((@Sendable () -> Void)?, (@Sendable () -> Void)?) = lock.withLock {
            if cancelled { return (nil, nil) }
            cancelled = true
            return (requestCancel, workerCancel)
        }
        actions.0?(); actions.1?()
    }
}

func runOwnedSubjectWorker(
    _ operation: @escaping @Sendable (SubjectWorkCancellation) throws -> PreparedShapeReference
) async throws -> PreparedShapeReference {
    try Task.checkCancellation()
    let cancellation = SubjectWorkCancellation()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try cancellation.check()
            return try operation(cancellation)
        }
        cancellation.setWorkerCancellation { worker.cancel() }
        defer { cancellation.clearWorkerCancellation() }
        do {
            let result = try await worker.value
            try cancellation.check()
            return result
        } catch {
            if Task.isCancelled || cancellation.isCancelled { throw CancellationError() }
            throw error
        }
    } onCancel: {
        cancellation.cancel()
    }
}
