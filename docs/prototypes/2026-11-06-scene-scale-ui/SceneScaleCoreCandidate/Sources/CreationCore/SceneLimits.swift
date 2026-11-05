import Foundation

/// SI modeling limits. These are scene-contract choices, not device-RAM limits.
/// A parameter-valid scene must also survive world-space Float mesh validation.
public enum SceneLimits {
    public static let minimumDimensionMetres: Double = 0.001
    public static let maximumDimensionMetres: Double = 100
    public static let minimumDimension = Float(minimumDimensionMetres)
    public static let maximumDimension = Float(maximumDimensionMetres)
    public static let maximumPositionMagnitude: Float = 1_000
    public static let maximumOffsetMagnitude: Float = 1_000
    public static let dimensionRange: ClosedRange<Float> = minimumDimension...maximumDimension
    public static let positionRange: ClosedRange<Float> = -maximumPositionMagnitude...maximumPositionMagnitude
    public static let offsetRange: ClosedRange<Float> = -maximumOffsetMagnitude...maximumOffsetMagnitude
    public static let rotationRange: ClosedRange<Float> = -360...360
    public static let materialRange: ClosedRange<Float> = 0...1

    // Accept both the nominal SI decimal and the existing Float snapshot form.
    public static let schemaMinimumDimension = min(minimumDimensionMetres, Double(minimumDimension))
    public static let maximumNodes = 32
    public static let maximumResponseBytes = 262_144
    public static let maximumProfilePoints = 64
    public static let maximumMeshVertices = 1_024
    public static let maximumMeshTriangles = 2_048
    public static let maximumRenderedVertices = 20_000
    public static let maximumRenderedIndices = 80_000
}
