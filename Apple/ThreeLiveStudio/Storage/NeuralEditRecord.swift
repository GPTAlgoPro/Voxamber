import CryptoKit
import Foundation

/// Same wire fields and linear Rec.709 RGBA semantics as ShapeWholeMaterial.
/// Foundation-only storage DTO; no inference/export dependency is imported.
struct NeuralWholeMaterial: Codable, Sendable, Equatable {
    let rgba: [Double]
    let metallic: Double
    let roughness: Double

    init(rgba: [Double], metallic: Double, roughness: Double) throws {
        self.rgba = rgba; self.metallic = metallic; self.roughness = roughness
        try validate()
    }
    func validate() throws {
        guard rgba.count == 4, rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              metallic.isFinite, (0...1).contains(metallic),
              roughness.isFinite, (0...1).contains(roughness) else { throw ProjectStorageError.invalidMetadata }
    }
}

/// Same encoded fields as ShapeEditRecipe. Normative order is S -> Rx -> Ry -> Rz -> T.
/// This record is a recipe, never a claim that neural weights were run again.
struct NeuralEditRecipe: Codable, Sendable, Equatable {
    let formatVersion: Int
    let translationXYZ: [Double]
    let rotationXYZdegrees: [Double]
    let positiveScaleXYZ: [Double]
    let wholeMaterial: NeuralWholeMaterial?

    init(translationXYZ: [Double] = [0, 0, 0], rotationXYZdegrees: [Double] = [0, 0, 0],
         positiveScaleXYZ: [Double] = [1, 1, 1], wholeMaterial: NeuralWholeMaterial? = nil) throws {
        formatVersion = 1; self.translationXYZ = translationXYZ; self.rotationXYZdegrees = rotationXYZdegrees
        self.positiveScaleXYZ = positiveScaleXYZ; self.wholeMaterial = wholeMaterial
        try validate()
    }
    func validate() throws {
        guard formatVersion == 1, translationXYZ.count == 3, rotationXYZdegrees.count == 3,
              positiveScaleXYZ.count == 3, translationXYZ.allSatisfy(\.isFinite),
              rotationXYZdegrees.allSatisfy(\.isFinite),
              positiveScaleXYZ.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ProjectStorageError.invalidMetadata }
        try wholeMaterial?.validate()
    }
    /// Identical JSONEncoder .sortedKeys convention to ShapeMeshEditor.export.
    var sha256: String {
        get throws {
            try validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// One-to-one serialization mirror of ShapeEditValidationReceipt. This is
/// runtime integrity evidence, not a signature or proof of neural origin.
struct NeuralEditEvidence: Codable, Sendable, Equatable {
    let version: Int
    let method: String
    let baseMeshFormatID: String
    let baseMeshFormatVersion: Int
    let baseMeshSHA256: String
    let recipeSHA256: String
    let renderGeometryLayoutVersion: Int
    let vertexCount: Int
    let triangleCount: Int
    let indexCount: Int
    let glbByteCount: Int64
    let usdzByteCount: Int64
    let glbSHA256: String
    let usdzSHA256: String
    let boundsMinimum: [Float]
    let boundsMaximum: [Float]
    let topologyPreserved: Bool
    let normalsInverseTransposeNormalized: Bool
    let wholeMaterialApplied: Bool
    let baseUnchanged: Bool
    let actualNeuralWeightsUsed: Bool

    func validate(recipe: NeuralEditRecipe) throws {
        try recipe.validate()
        guard version == 1, method == "cpu-mesh-transform-material",
              baseMeshFormatID == "org.khronos.gltf.binary", baseMeshFormatVersion == 2,
              renderGeometryLayoutVersion == 2,
              ArtifactReference.isSHA256(baseMeshSHA256), ArtifactReference.isSHA256(recipeSHA256),
              recipeSHA256 == (try recipe.sha256),
              ArtifactReference.isSHA256(glbSHA256), ArtifactReference.isSHA256(usdzSHA256),
              (3...NeuralArtifactLimits.maximumVertices).contains(vertexCount),
              (1...NeuralArtifactLimits.maximumTriangles).contains(triangleCount),
              indexCount == triangleCount * 3, indexCount <= NeuralArtifactLimits.maximumIndices,
              glbByteCount > 0, glbByteCount <= NeuralArtifactLimits.maximumGLBBytes,
              usdzByteCount > 0, usdzByteCount <= NeuralArtifactLimits.maximumUSDZBytes,
              topologyPreserved, normalsInverseTransposeNormalized, baseUnchanged,
              wholeMaterialApplied == (recipe.wholeMaterial != nil), !actualNeuralWeightsUsed else {
            throw ProjectStorageError.invalidMetadata
        }
        try NeuralMeshStatistics(vertexCount: vertexCount, triangleCount: triangleCount, meshCount: 1,
                                 boundsMinimum: boundsMinimum, boundsMaximum: boundsMaximum).validate()
        // Same model-coordinate output bounds as the CPU exporter. These are
        // not physical metres. Float subtraction mirrors the SDK's extent gate.
        guard boundsMinimum.allSatisfy({ abs(Double($0)) <= 1_000_000 }),
              boundsMaximum.allSatisfy({ abs(Double($0)) <= 1_000_000 }),
              zip(boundsMinimum, boundsMaximum).allSatisfy({ let extent = $1 - $0; return extent.isFinite && Double(extent) <= 1_000_000 })
        else { throw ProjectStorageError.invalidMetadata }
    }

    func validate(recipe: NeuralEditRecipe, artifacts: [ArtifactReference],
                  statistics: NeuralMeshStatistics, baseStatistics: NeuralMeshStatistics,
                  generationEvidence: NeuralGenerationEvidence) throws {
        try validate(recipe: recipe)
        let base = artifacts.first { $0.role == .baseMesh }
        let glb = artifacts.first { $0.role == .glb }
        let usdz = artifacts.first { $0.role == .usdz }
        guard baseMeshSHA256 == base?.sha256, baseMeshSHA256 == generationEvidence.glbSHA256,
              vertexCount == statistics.vertexCount, triangleCount == statistics.triangleCount,
              vertexCount == baseStatistics.vertexCount, triangleCount == baseStatistics.triangleCount,
              vertexCount == generationEvidence.vertexCount, triangleCount == generationEvidence.triangleCount,
              indexCount == generationEvidence.indexCount,
              glbSHA256 == glb?.sha256, glbByteCount == glb?.byteCount,
              usdzSHA256 == usdz?.sha256, usdzByteCount == usdz?.byteCount,
              boundsMinimum == statistics.boundsMinimum, boundsMaximum == statistics.boundsMaximum else {
            throw ProjectStorageError.invalidMetadata
        }
    }
}

/// Operation-local wrapper binds an exported edit to its actual revision
/// parent. Descriptor persists recipe/evidence plus provenance.parentRevision.
struct NeuralEditRecord: Codable, Sendable, Equatable {
    let parentRevision: UUID
    let recipe: NeuralEditRecipe
    let evidence: NeuralEditEvidence

    init(parentRevision: UUID, recipe: NeuralEditRecipe, evidence: NeuralEditEvidence) throws {
        self.parentRevision = parentRevision; self.recipe = recipe; self.evidence = evidence
        try evidence.validate(recipe: recipe)
    }
    func validate(parentRevision expected: UUID?) throws {
        guard parentRevision == expected else { throw ProjectStorageError.invalidMetadata }
        try evidence.validate(recipe: recipe)
    }
}
