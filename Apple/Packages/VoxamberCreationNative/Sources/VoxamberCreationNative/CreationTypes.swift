import Foundation
import VoxamberShapeNative

public enum CreationPhase: String, Codable, Sendable {
    case interpreting, drawingReference, preparingSubject, generatingShape, complete
}

public struct CreationProgress: Sendable {
    public let phase: CreationPhase
    public let completedSteps: Int?
    public let totalSteps: Int?
    public let fraction: Float?

    public init(phase: CreationPhase, completedSteps: Int? = nil, totalSteps: Int? = nil, fraction: Float? = nil) {
        self.phase = phase; self.completedSteps = completedSteps
        self.totalSteps = totalSteps; self.fraction = fraction
    }
}

/// Model directories must have been installed from the application's pinned,
/// checksum-verified asset contracts. Layout alone is not weight identity.
public struct CreationResources: Sendable {
    public let intentModelDirectory: URL
    public let imageModelDirectory: URL
    public let shapeModelFile: URL

    public init(intentModelDirectory: URL, imageModelDirectory: URL, shapeModelFile: URL) {
        self.intentModelDirectory = intentModelDirectory
        self.imageModelDirectory = imageModelDirectory
        self.shapeModelFile = shapeModelFile
    }
}

public struct CreationIntent: Codable, Sendable, Equatable {
    public let title: String
    public let positivePrompt: String
    public let negativePrompt: String

    public init(title: String, positivePrompt: String, negativePrompt: String) {
        self.title = title; self.positivePrompt = positivePrompt; self.negativePrompt = negativePrompt
    }
}

public struct PreparedShapeReference: Sendable {
    /// 512² PNG retaining foreground alpha. White is composited by DINO, not
    /// flattened here, so alpha bounding-box conditioning remains meaningful.
    public let pngData: Data
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// Source-pixel bounds in Core Image's bottom-left coordinate convention.
    public let foregroundBounds: [Double]
    public let method: String

    public init(pngData: Data, sourceWidth: Int, sourceHeight: Int,
                foregroundBounds: [Double], method: String) {
        self.pngData = pngData; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.foregroundBounds = foregroundBounds; self.method = method
    }
}

public struct NativeCreationResult: Sendable {
    public let intent: CreationIntent
    public let referencePNG: Data
    public let preparedReference: PreparedShapeReference
    public let shape: ShapeResult
    public let seed: UInt64
    public let stageSeconds: [String: Double]
}

public enum CreationError: Error, Sendable, Equatable {
    case busy
    case invalidRequest
    case invalidIntent
    case resourcesUnavailable
    case subjectNotFound
    case invalidReferenceImage
}
