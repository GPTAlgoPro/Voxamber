import Foundation

public enum ImageComputeUnits: Sendable { case cpuAndNeuralEngine, cpuAndGPU, all }
public enum ImageScheduler: Sendable { case dpmSolverMultistep, pndm }

public struct SDXLGenerationOptions: Sendable {
    public var steps: Int
    public var guidanceScale: Float
    public var reduceMemory: Bool
    public var computeUnits: ImageComputeUnits
    public var scheduler: ImageScheduler

    public init(steps: Int = 20, guidanceScale: Float = 7.5, reduceMemory: Bool = true,
                computeUnits: ImageComputeUnits = .cpuAndNeuralEngine,
                scheduler: ImageScheduler = .dpmSolverMultistep) {
        self.steps = steps; self.guidanceScale = guidanceScale; self.reduceMemory = reduceMemory
        self.computeUnits = computeUnits; self.scheduler = scheduler
    }
}

public enum ImageGenerationProgress: Sendable, Equatable {
    case preparingResources
    case denoising(completed: Int, total: Int)
    case encodingPNG
}

public enum ImageBackendError: Error, Sendable, Equatable {
    case invalidPrompt
    case invalidOptions
    case resourcesMustBeLocalDirectory
    case missingResource(String)
    case unsupportedAuxiliaryModel(String)
    case invalidTokenizer
    case promptTooLong(actualTokens: Int, maximum: Int)
    case noImageReturned
    case unexpectedImageSize(width: Int, height: Int)
    case pngEncodingFailed
}

struct ImageRequest: Sendable {
    let positivePrompt: String
    let negativePrompt: String
    let seed: UInt32
    let options: SDXLGenerationOptions

    func validate() throws {
        guard !positivePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              positivePrompt.utf8.count <= 16_384, negativePrompt.utf8.count <= 16_384 else {
            throw ImageBackendError.invalidPrompt
        }
        guard (1...100).contains(options.steps), options.guidanceScale.isFinite,
              (0...30).contains(options.guidanceScale) else { throw ImageBackendError.invalidOptions }
        // The pinned Apple PNDM initializer requires a preceding timestep and
        // otherwise force-unwraps an empty array at stepCount == 1.
        if options.scheduler == .pndm, options.steps < 2 { throw ImageBackendError.invalidOptions }
    }
}
