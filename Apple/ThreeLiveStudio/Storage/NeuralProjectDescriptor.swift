import Foundation

/// Mirrors the public ShapeArtifactLimits of VoxamberShapeNative, layout 1.
/// These are independent of SceneSpec/ThreeLiveNative procedural budgets.
enum NeuralArtifactLimits {
    static let sourceContract = "VoxamberShapeNative.ShapeArtifactLimits/layout1"
    static let maximumVertices = 2_000_000
    static let maximumTriangles = 4_000_000
    static let maximumIndices = 12_000_000
    static let maximumGLBBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumUSDZBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumPNGBytes: Int64 = 32 * 1_024 * 1_024
}

enum NeuralArtifactRole: String, Codable, CaseIterable, Sendable { case glb, usdz, baseMesh, sourcePNG, referencePNG }

struct ArtifactReference: Codable, Sendable, Equatable {
    let role: NeuralArtifactRole
    let relativePath: String
    let byteCount: Int64
    let sha256: String
    let formatID: String
    let formatVersion: Int

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func validate() throws {
        let allowed: Set<String>
        let limit: Int64
        let format: String
        let version: Int
        switch role {
        case .glb: allowed = ["model.glb"]; limit = NeuralArtifactLimits.maximumGLBBytes; format = "org.khronos.gltf.binary"; version = 2
        case .baseMesh: allowed = ["base.glb", "model.glb"]; limit = NeuralArtifactLimits.maximumGLBBytes; format = "org.khronos.gltf.binary"; version = 2
        case .usdz: allowed = ["model.usdz"]; limit = NeuralArtifactLimits.maximumUSDZBytes; format = "com.pixar.universal-scene-description-mobile"; version = 1
        case .sourcePNG: allowed = ["source.png"]; limit = NeuralArtifactLimits.maximumPNGBytes; format = "public.png"; version = 1
        case .referencePNG: allowed = ["reference.png"]; limit = NeuralArtifactLimits.maximumPNGBytes; format = "public.png"; version = 1
        }
        guard allowed.contains(relativePath), byteCount > 0, byteCount <= limit,
              Self.isSHA256(sha256), formatID == format, formatVersion == version else {
            throw ProjectStorageError.invalidArtifact
        }
    }
}

struct NeuralMeshStatistics: Codable, Sendable, Equatable {
    let vertexCount: Int
    let triangleCount: Int
    let meshCount: Int
    let boundsMinimum: [Float]
    let boundsMaximum: [Float]

    func validate() throws {
        guard (3...NeuralArtifactLimits.maximumVertices).contains(vertexCount),
              (1...NeuralArtifactLimits.maximumTriangles).contains(triangleCount), meshCount == 1,
              triangleCount <= NeuralArtifactLimits.maximumIndices / 3,
              boundsMinimum.count == 3, boundsMaximum.count == 3,
              boundsMinimum.allSatisfy(\.isFinite), boundsMaximum.allSatisfy(\.isFinite),
              zip(boundsMinimum, boundsMaximum).allSatisfy({ $0 <= $1 }),
              zip(boundsMinimum, boundsMaximum).contains(where: { $0 < $1 }) else {
            throw ProjectStorageError.invalidArtifact
        }
    }
}

struct NeuralStageProvenance: Codable, Sendable, Equatable {
    let modelID: String
    let modelRevision: String
    let modelManifestSHA256: String
    let configurationSHA256: String
    let runtimeVersion: String
    let seed: UInt64

    func validate() throws {
        guard Self.identifier(modelID), Self.identifier(modelRevision), Self.identifier(runtimeVersion),
              ArtifactReference.isSHA256(modelManifestSHA256), ArtifactReference.isSHA256(configurationSHA256) else {
            throw ProjectStorageError.invalidMetadata
        }
    }
    static func identifier(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("/") && s.utf8.count <= 2_048 && !s.contains("://") && !s.contains("@") &&
            !s.contains("\\") && !s.contains("\n") && !s.contains("\r")
    }
}

struct NeuralPipelineProvenance: Codable, Sendable, Equatable {
    enum Method: String, Codable, Sendable {
        case textToImageToShape, imageToShape, meshTransformOrMaterialEdit
        /// Explicitly identifies host contract fixtures, never a neural success.
        case syntheticGeometryValidation
    }
    let pipelineID: String
    let method: Method
    let imageStage: NeuralStageProvenance?
    let shapeStage: NeuralStageProvenance
    let preparedPNG_SHA256: String
    let generatedAt: Date
    let physicalScaleKnown: Bool
    let parentRevision: UUID?
    let intentStage: NeuralIntentStageProvenance?
    let intentBrief: NeuralIntentBrief?

    init(pipelineID: String, method: Method, imageStage: NeuralStageProvenance?,
         shapeStage: NeuralStageProvenance, preparedPNG_SHA256: String, generatedAt: Date,
         physicalScaleKnown: Bool, parentRevision: UUID?, intentStage: NeuralIntentStageProvenance? = nil,
         intentBrief: NeuralIntentBrief? = nil) {
        self.pipelineID = pipelineID; self.method = method; self.imageStage = imageStage; self.shapeStage = shapeStage
        self.preparedPNG_SHA256 = preparedPNG_SHA256; self.generatedAt = generatedAt
        self.physicalScaleKnown = physicalScaleKnown; self.parentRevision = parentRevision
        self.intentStage = intentStage; self.intentBrief = intentBrief
    }

    func validate() throws {
        guard NeuralStageProvenance.identifier(pipelineID), ArtifactReference.isSHA256(preparedPNG_SHA256),
              generatedAt.timeIntervalSince1970.isFinite,
              method != .textToImageToShape || imageStage != nil else { throw ProjectStorageError.invalidMetadata }
        try imageStage?.validate(); try shapeStage.validate(); try intentStage?.validate(); try intentBrief?.validate()
        guard intentStage == nil || intentBrief != nil else { throw ProjectStorageError.invalidMetadata }
    }
}

struct NeuralProjectDescriptor: Codable, Sendable, Equatable {
    let geometryLayoutVersion: Int
    let artifacts: [ArtifactReference]
    let statistics: NeuralMeshStatistics
    let baseStatistics: NeuralMeshStatistics
    let provenance: NeuralPipelineProvenance
    let generationEvidence: NeuralGenerationEvidence
    /// Geometry layout 1 contains source positions/indices. Normals are derived
    /// by the SDK; it does not promise storage of arbitrary custom normal edits.
    let geometryContract: String
    let editRecipe: NeuralEditRecipe?
    let editEvidence: NeuralEditEvidence?

    init(geometryLayoutVersion: Int, artifacts: [ArtifactReference], statistics: NeuralMeshStatistics,
         baseStatistics: NeuralMeshStatistics, provenance: NeuralPipelineProvenance,
         generationEvidence: NeuralGenerationEvidence, geometryContract: String,
         editRecipe: NeuralEditRecipe? = nil, editEvidence: NeuralEditEvidence? = nil) {
        self.geometryLayoutVersion = geometryLayoutVersion; self.artifacts = artifacts
        self.statistics = statistics; self.baseStatistics = baseStatistics; self.provenance = provenance
        self.generationEvidence = generationEvidence; self.geometryContract = geometryContract
        self.editRecipe = editRecipe; self.editEvidence = editEvidence
    }

    func artifact(_ role: NeuralArtifactRole) -> ArtifactReference? { artifacts.first { $0.role == role } }

    /// Existing V2 revisions without edit fields remain readable. New publication
    /// must pass requireEditRecord:true; present records are always fully checked.
    func validate(requireEditRecord: Bool = false) throws {
        let roles = Set(artifacts.map(\.role)), required: Set<NeuralArtifactRole> = [.glb, .usdz, .baseMesh, .sourcePNG]
        guard geometryLayoutVersion == 1, geometryContract == NeuralArtifactLimits.sourceContract,
              (4...5).contains(artifacts.count), roles.count == artifacts.count,
              roles.isSuperset(of: required), roles.isSubset(of: Set(NeuralArtifactRole.allCases)) else {
            throw ProjectStorageError.invalidMetadata
        }
        for item in artifacts { try item.validate() }
        for group in Dictionary(grouping: artifacts, by: \.relativePath).values {
            guard Set(group.map(\.sha256)).count == 1, Set(group.map(\.byteCount)).count == 1 else {
                throw ProjectStorageError.invalidMetadata
            }
        }
        try statistics.validate(); try baseStatistics.validate(); try provenance.validate()
        try generationEvidence.validate()
        guard (editRecipe == nil) == (editEvidence == nil),
              provenance.method == .meshTransformOrMaterialEdit || editRecipe == nil else {
            throw ProjectStorageError.invalidMetadata
        }
        guard artifact(.sourcePNG)?.sha256 == provenance.preparedPNG_SHA256,
              generationEvidence.glbSHA256 == artifact(.baseMesh)?.sha256,
              generationEvidence.vertexCount == baseStatistics.vertexCount,
              generationEvidence.triangleCount == baseStatistics.triangleCount,
              generationEvidence.glbByteCount == artifact(.baseMesh)?.byteCount,
              provenance.method == .syntheticGeometryValidation || generationEvidence.actualNeuralWeightsUsed else {
            throw ProjectStorageError.invalidMetadata
        }
        if provenance.method != .meshTransformOrMaterialEdit {
            guard generationEvidence.glbSHA256 == artifact(.glb)?.sha256,
                  generationEvidence.usdzSHA256 == artifact(.usdz)?.sha256,
                  generationEvidence.usdzByteCount == artifact(.usdz)?.byteCount else {
                throw ProjectStorageError.invalidMetadata
            }
        } else {
            guard provenance.parentRevision != nil else { throw ProjectStorageError.invalidMetadata }
            if let editRecipe, let editEvidence {
                try editEvidence.validate(recipe: editRecipe, artifacts: artifacts, statistics: statistics,
                                          baseStatistics: baseStatistics, generationEvidence: generationEvidence)
            } else if requireEditRecord { throw ProjectStorageError.invalidMetadata }
        }
    }
}

/// File URLs are operation-local inputs and are never encoded into a project.
struct NeuralPublicationFiles: Sendable {
    let glb: URL
    let usdz: URL
    let baseMesh: URL
    let sourcePNG: URL
    let referencePNG: URL?
    init(glb: URL, usdz: URL, baseMesh: URL, sourcePNG: URL, referencePNG: URL? = nil) {
        self.glb = glb; self.usdz = usdz; self.baseMesh = baseMesh; self.sourcePNG = sourcePNG; self.referencePNG = referencePNG
    }
}

struct NeuralIntentStageProvenance: Codable, Sendable, Equatable {
    let modelID: String
    let modelRevision: String
    let configurationSHA256: String
    func validate() throws {
        guard NeuralStageProvenance.identifier(modelID), NeuralStageProvenance.identifier(modelRevision),
              ArtifactReference.isSHA256(configurationSHA256) else { throw ProjectStorageError.invalidMetadata }
    }
}

/// Exact normalized model input, retained only in the private project metadata.
/// Image stage seed is the actual UInt32 value widened losslessly in imageStage;
/// shapeStage retains its actual UInt64 seed. This is their requested seed.
struct NeuralIntentBrief: Codable, Sendable, Equatable {
    let title: String
    let positiveEnglish: String
    let negativeEnglish: String
    let requestedSeed: UInt64
    func validate() throws {
        guard !title.isEmpty, title.utf8.count <= 4_096, !positiveEnglish.isEmpty,
              positiveEnglish.utf8.count <= 65_536, negativeEnglish.utf8.count <= 65_536 else {
            throw ProjectStorageError.invalidMetadata
        }
    }
}

struct NeuralPublicationInput: Sendable {
    let name: String
    let prompt: String
    let files: NeuralPublicationFiles
    let statistics: NeuralMeshStatistics
    let baseStatistics: NeuralMeshStatistics
    let provenance: NeuralPipelineProvenance
    let generationEvidence: NeuralGenerationEvidence
    let editRecord: NeuralEditRecord?

    init(name: String, prompt: String, files: NeuralPublicationFiles, statistics: NeuralMeshStatistics,
         baseStatistics: NeuralMeshStatistics, provenance: NeuralPipelineProvenance,
         generationEvidence: NeuralGenerationEvidence, editRecord: NeuralEditRecord? = nil) {
        self.name = name; self.prompt = prompt; self.files = files; self.statistics = statistics
        self.baseStatistics = baseStatistics; self.provenance = provenance
        self.generationEvidence = generationEvidence; self.editRecord = editRecord
    }
}

/// Same serialized fields as the Shape SDK's actual ShapeValidationReceipt.
/// This is traceable runtime evidence, not a signature or a quality score.
struct NeuralGenerationEvidence: Codable, Sendable, Equatable {
    let version: Int
    let baseMeshFormatID: String
    let baseMeshFormatVersion: Int
    let geometryLayoutVersion: Int
    let vertexCount: Int
    let triangleCount: Int
    let indexCount: Int
    let glbByteCount: Int64
    let usdzByteCount: Int64
    let glbSHA256: String
    let usdzSHA256: String
    let baseMeshUsesUnchangedGLB: Bool
    let nativeGeometryValidated: Bool
    let usdNativeImporterOpened: Bool
    let actualNeuralWeightsUsed: Bool

    func validate() throws {
        guard version == 1, baseMeshFormatID == "org.khronos.gltf.binary", baseMeshFormatVersion == 2,
              geometryLayoutVersion == 1, baseMeshUsesUnchangedGLB,
              nativeGeometryValidated, usdNativeImporterOpened,
              (3...NeuralArtifactLimits.maximumVertices).contains(vertexCount),
              (1...NeuralArtifactLimits.maximumTriangles).contains(triangleCount),
              indexCount == triangleCount * 3, indexCount <= NeuralArtifactLimits.maximumIndices,
              glbByteCount > 0, glbByteCount <= NeuralArtifactLimits.maximumGLBBytes,
              usdzByteCount > 0, usdzByteCount <= NeuralArtifactLimits.maximumUSDZBytes,
              ArtifactReference.isSHA256(glbSHA256), ArtifactReference.isSHA256(usdzSHA256) else {
            throw ProjectStorageError.invalidMetadata
        }
    }
}
