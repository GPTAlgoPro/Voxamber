import Foundation
import VoxamberShapeNative

/// CPU-only preparation on the caller's owned background task. Every edit is
/// baked from the immutable original archive, never from a previously baked edit.
enum NeuralEditPreparation {
    static func prepare(assets: ProjectAssets, recipe: NeuralEditRecipe,
                        temporary: URL, permit: PublicationPermit) throws -> NeuralPublicationInput {
        try permit.check(); try recipe.validate()
        guard case .neuralMesh(let source) = assets.project.content,
              let baseURL = assets.baseMeshURL, let pngURL = assets.sourcePNGURL else {
            throw ProjectStorageError.invalidMetadata
        }
        try source.validate()
        let archive = try ProjectFileIO.readSmall(baseURL, limit: NeuralArtifactLimits.maximumGLBBytes)
        try permit.check()
        let base = try ShapeMeshArchive.read(data: archive)
        let sdkRecipe = try JSONDecoder().decode(ShapeEditRecipe.self, from: JSONEncoder().encode(recipe))
        let edit = try ShapeMeshEditor.export(base: base, recipe: sdkRecipe, baseArchiveData: archive,
                                             isCancelled: { Task.isCancelled || permit.state != .active })
        try permit.check()
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let glb = temporary.appending(path: "model.glb"), usdz = temporary.appending(path: "model.usdz")
        try edit.glbData.write(to: glb, options: .atomic)
        try permit.check()
        try edit.usdzData.write(to: usdz, options: .atomic)
        let evidence = try JSONDecoder().decode(NeuralEditEvidence.self,
                                               from: JSONEncoder().encode(edit.validationReceipt))
        let original = source.provenance
        let provenance = NeuralPipelineProvenance(pipelineID: original.pipelineID,
            method: .meshTransformOrMaterialEdit, imageStage: original.imageStage, shapeStage: original.shapeStage,
            preparedPNG_SHA256: original.preparedPNG_SHA256, generatedAt: original.generatedAt,
            physicalScaleKnown: original.physicalScaleKnown, parentRevision: assets.project.revision,
            intentStage: original.intentStage, intentBrief: original.intentBrief)
        let statistics = NeuralMeshStatistics(vertexCount: edit.mesh.vertexCount,
            triangleCount: edit.mesh.triangleCount, meshCount: 1,
            boundsMinimum: edit.boundsMinimum, boundsMaximum: edit.boundsMaximum)
        let record = try NeuralEditRecord(parentRevision: assets.project.revision, recipe: recipe, evidence: evidence)
        try permit.check()
        return NeuralPublicationInput(name: assets.project.name, prompt: assets.project.prompt,
            files: .init(glb: glb, usdz: usdz, baseMesh: baseURL, sourcePNG: pngURL,
                         referencePNG: assets.referencePNGURL),
            statistics: statistics, baseStatistics: source.baseStatistics, provenance: provenance,
            generationEvidence: source.generationEvidence, editRecord: record)
    }
}
