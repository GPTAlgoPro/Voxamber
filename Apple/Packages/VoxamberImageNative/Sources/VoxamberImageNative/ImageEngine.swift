import Foundation
import CoreGraphics
import CoreML
import ImageIO
import UniformTypeIdentifiers
import AppleSDXL

/// The driver is owned only by the actor's synchronous generation scope.
/// Tests may inject failure/cancellation drivers; the public initializer always
/// uses Apple's real model pipeline. No test driver returns a generated image.
protocol SDXLPipelineDriver {
    func loadResources() throws
    func generate(request: ImageRequest, shouldContinue: (Int, Int) -> Bool) throws -> [CGImage?]
    func unloadResources()
}

public actor ImageEngine {
    private let makeDriver: @Sendable (URL, SDXLGenerationOptions) throws -> any SDXLPipelineDriver

    public init() { makeDriver = { try AppleSDXLDriver(resourcesAt: $0, options: $1) } }

    init(makeDriver: @escaping @Sendable (URL, SDXLGenerationOptions) throws -> any SDXLPipelineDriver) {
        self.makeDriver = makeDriver
    }

    /// Prompts must already express the user's intent in English. Produces one
    /// actual 768x768 PNG. Cancel the calling Task; completion waits for the
    /// current synchronous Core ML prediction and resource cleanup.
    public func generate(positivePrompt: String, negativePrompt: String = "", seed: UInt32,
                         resourcesURL: URL, options: SDXLGenerationOptions = .init(),
                         onProgress: @Sendable (ImageGenerationProgress) -> Void = { _ in }) async throws -> Data {
        try Task.checkCancellation()
        let pngData: Data = try autoreleasepool {
            let request = ImageRequest(positivePrompt: positivePrompt, negativePrompt: negativePrompt,
                                       seed: seed, options: options)
            try request.validate()
            try SDXLResources.validateLayout(at: resourcesURL)
            try SDXLResources.validateTokenizer(at: resourcesURL, request: request)
            try Task.checkCancellation()
            onProgress(.preparingResources)
            let driver = try makeDriver(resourcesURL, options)
            defer { driver.unloadResources() }
            try Task.checkCancellation()
            try driver.loadResources()
            try Task.checkCancellation()
            let images = try driver.generate(request: request) { completed, total in
                guard !Task.isCancelled else { return false }
                onProgress(.denoising(completed: completed, total: total))
                return !Task.isCancelled
            }
            try Task.checkCancellation()
            guard images.count == 1, let image = images[0] else { throw ImageBackendError.noImageReturned }
            guard image.width == 768, image.height == 768 else {
                throw ImageBackendError.unexpectedImageSize(width: image.width, height: image.height)
            }
            onProgress(.encodingPNG)
            let data = try PNGEncoder.encode(image)
            try Task.checkCancellation()
            return data
        }
        try Task.checkCancellation()
        return pngData
    }
}

struct AppleSDXLDriver: SDXLPipelineDriver {
    let pipeline: StableDiffusionXLPipeline

    init(resourcesAt directory: URL, options: SDXLGenerationOptions) throws {
        let configuration = MLModelConfiguration()
        switch options.computeUnits {
        case .cpuAndNeuralEngine: configuration.computeUnits = .cpuAndNeuralEngine
        case .cpuAndGPU: configuration.computeUnits = .cpuAndGPU
        case .all: configuration.computeUnits = .all
        }
        pipeline = try StableDiffusionXLPipeline(resourcesAt: directory,
            configuration: configuration, reduceMemory: options.reduceMemory)
    }

    func loadResources() throws { try pipeline.loadResources() }
    func unloadResources() { pipeline.unloadResources() }

    func generate(request: ImageRequest, shouldContinue: (Int, Int) -> Bool) throws -> [CGImage?] {
        let configuration = Self.configuration(for: request)
        return try pipeline.generateImages(configuration: configuration) { progress in
            // Never access progress.currentImages: that would load/decode a VAE
            // during denoising and raise the memory high-water mark.
            shouldContinue(progress.step + 1, progress.stepCount)
        }
    }

    static func configuration(for request: ImageRequest) -> PipelineConfiguration {
        var configuration = PipelineConfiguration(prompt: request.positivePrompt)
        configuration.negativePrompt = request.negativePrompt
        configuration.seed = request.seed
        configuration.stepCount = request.options.steps
        configuration.guidanceScale = request.options.guidanceScale
        configuration.imageCount = 1
        configuration.originalSize = 768
        configuration.targetSize = 768
        configuration.encoderScaleFactor = 0.13025
        configuration.decoderScaleFactor = 0.13025
        configuration.schedulerType = request.options.scheduler == .dpmSolverMultistep
            ? .dpmSolverMultistepScheduler : .pndmScheduler
        return configuration
    }
}

enum PNGEncoder {
    static func encode(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageBackendError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageBackendError.pngEncodingFailed }
        return buffer as Data
    }
}
