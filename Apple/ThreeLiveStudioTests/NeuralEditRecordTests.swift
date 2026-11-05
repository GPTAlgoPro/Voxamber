import CryptoKit
import Foundation
import XCTest
#if canImport(ThreeLiveStudio)
@testable import ThreeLiveStudio
import VoxamberShapeNative
#else
@testable import NeuralEditRecordHarness
#endif

/// Actual high-density CPU exporter bytes/receipt, never neural generation.
/// Positive origin-policy tests use explicitly simulated true metadata solely
/// to exercise invariants. The actual edit receipt always remains false.
@MainActor final class NeuralEditRecordTests: XCTestCase {
    func testActualSDKDenseRecipeReceiptAndArtifactsMapWithoutFieldLoss() throws {
        let f = try fixture()
        try f.evidence.validate(recipe: f.recipe)
        XCTAssertFalse(f.evidence.actualNeuralWeightsUsed)
        XCTAssertEqual(f.evidence.vertexCount, 154_449)
        XCTAssertEqual(f.evidence.triangleCount, 307_328)
        XCTAssertEqual(f.evidence.indexCount, 921_984)
        XCTAssertEqual(try f.recipe.sha256, f.evidence.recipeSHA256)
        XCTAssertEqual(try canonicalObject(f.recipeData), try canonicalObject(JSONEncoder().encode(f.recipe)))
        XCTAssertEqual(try canonicalObject(f.evidenceData), try canonicalObject(JSONEncoder().encode(f.evidence)))
        XCTAssertEqual(digest(f.base), f.evidence.baseMeshSHA256)
        XCTAssertEqual(digest(f.glb), f.evidence.glbSHA256)
        XCTAssertEqual(digest(f.usdz), f.evidence.usdzSHA256)
        XCTAssertEqual(Int64(f.glb.count), f.evidence.glbByteCount)
        XCTAssertEqual(Int64(f.usdz.count), f.evidence.usdzByteCount)
        let record = try NeuralEditRecord(parentRevision: UUID(), recipe: f.recipe, evidence: f.evidence)
        XCTAssertEqual(try JSONDecoder().decode(NeuralEditRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testEditedDescriptorRoundTripRetainsSimulatedOriginAndSeparateCPUReceipt() throws {
        let f = try fixture()
        let descriptor = try f.descriptor(simulatedNeuralOrigin: true)
        try descriptor.validate(requireEditRecord: true)
        let restored = try JSONDecoder().decode(NeuralProjectDescriptor.self, from: JSONEncoder().encode(descriptor))
        try restored.validate(requireEditRecord: true)
        XCTAssertEqual(restored, descriptor)
        XCTAssertTrue(restored.generationEvidence.actualNeuralWeightsUsed, "Simulated origin metadata is preserved, never replaced by CPU evidence")
        XCTAssertFalse(try XCTUnwrap(restored.editEvidence).actualNeuralWeightsUsed)
        XCTAssertEqual(restored.generationEvidence.glbSHA256, digest(f.base))
        XCTAssertEqual(restored.artifact(.baseMesh)?.relativePath, "base.glb")
        XCTAssertNotEqual(restored.artifact(.baseMesh)?.sha256, restored.artifact(.glb)?.sha256)
        XCTAssertEqual(restored.provenance.parentRevision, f.parent)
    }

    func testCPUFixtureCannotClaimActualNeuralOriginByAddingEditRecord() throws {
        let descriptor = try fixture().descriptor(simulatedNeuralOrigin: false)
        XCTAssertThrowsError(try descriptor.validate(requireEditRecord: true))
    }

    func testLegacyV2WithoutOptionalEditFieldsStillDecodesButNewEditNeedsEvidence() throws {
        let f = try fixture()
        let legacyEdit = try f.descriptor(simulatedNeuralOrigin: true, includeEdit: false)
        let data = try JSONEncoder().encode(legacyEdit)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["editRecipe"]); XCTAssertNil(object["editEvidence"])
        let restored = try JSONDecoder().decode(NeuralProjectDescriptor.self, from: data)
        try restored.validate()
        XCTAssertThrowsError(try restored.validate(requireEditRecord: true))
        let source = try f.descriptor(simulatedNeuralOrigin: false, includeEdit: false, sourceOnly: true)
        try source.validate(requireEditRecord: true)
        XCTAssertEqual(try JSONDecoder().decode(NeuralProjectDescriptor.self, from: JSONEncoder().encode(source)), source)
    }

    func testTamperedEditEvidenceAndRecipeAreRejected() throws {
        let descriptor = try fixture().descriptor(simulatedNeuralOrigin: true)
        let raw = try object(descriptor)
        let mutations: [(String, Any)] = [
            ("version", 2), ("method", "neural-generation"), ("baseMeshFormatID", "fake"),
            ("baseMeshFormatVersion", 1), ("baseMeshSHA256", String(repeating: "a", count: 64)),
            ("recipeSHA256", String(repeating: "b", count: 64)), ("renderGeometryLayoutVersion", 1),
            ("vertexCount", 154_448), ("triangleCount", 307_327), ("indexCount", 921_983),
            ("glbSHA256", String(repeating: "c", count: 64)), ("usdzSHA256", String(repeating: "d", count: 64)),
            ("glbByteCount", 1), ("usdzByteCount", 1), ("boundsMinimum", [0, 0, 0]),
            ("topologyPreserved", false), ("normalsInverseTransposeNormalized", false),
            ("wholeMaterialApplied", false), ("baseUnchanged", false), ("actualNeuralWeightsUsed", true)
        ]
        for (key, value) in mutations {
            var changed = raw; var evidence = try XCTUnwrap(changed["editEvidence"] as? [String: Any])
            evidence[key] = value; changed["editEvidence"] = evidence
            let candidate = try JSONDecoder().decode(NeuralProjectDescriptor.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try candidate.validate(requireEditRecord: true), key)
        }
        var changed = raw; var recipe = try XCTUnwrap(changed["editRecipe"] as? [String: Any])
        recipe["translationXYZ"] = [1, 2, 3]; changed["editRecipe"] = recipe
        let candidate = try JSONDecoder().decode(NeuralProjectDescriptor.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertThrowsError(try candidate.validate(requireEditRecord: true))
    }

    func testParentMissingMismatchedOrOrphanedEditFieldsReject() throws {
        let f = try fixture(), descriptor = try f.descriptor(simulatedNeuralOrigin: true)
        let record = try NeuralEditRecord(parentRevision: f.parent, recipe: f.recipe, evidence: f.evidence)
        try record.validate(parentRevision: f.parent)
        XCTAssertThrowsError(try record.validate(parentRevision: nil))
        XCTAssertThrowsError(try record.validate(parentRevision: UUID()))
        let raw = try object(descriptor)
        for key in ["editRecipe", "editEvidence"] {
            var changed = raw; changed.removeValue(forKey: key)
            let candidate = try JSONDecoder().decode(NeuralProjectDescriptor.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try candidate.validate(requireEditRecord: true))
        }
        var changed = raw; var provenance = try XCTUnwrap(changed["provenance"] as? [String: Any])
        provenance.removeValue(forKey: "parentRevision"); changed["provenance"] = provenance
        let noParent = try JSONDecoder().decode(NeuralProjectDescriptor.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertThrowsError(try noParent.validate(requireEditRecord: true))
        changed = raw; provenance = try XCTUnwrap(changed["provenance"] as? [String: Any])
        provenance["method"] = "imageToShape"; changed["provenance"] = provenance
        let wrongMethod = try JSONDecoder().decode(NeuralProjectDescriptor.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertThrowsError(try wrongMethod.validate(requireEditRecord: true))
    }

    func testInvalidMaterialTransformAndRecipeVersionReject() throws {
        XCTAssertThrowsError(try NeuralEditRecipe(positiveScaleXYZ: [1, 0, 1]))
        XCTAssertThrowsError(try NeuralEditRecipe(translationXYZ: [0, 1]))
        XCTAssertThrowsError(try NeuralEditRecipe(rotationXYZdegrees: [.infinity, 0, 0]))
        XCTAssertThrowsError(try NeuralWholeMaterial(rgba: [0, 0, 0], metallic: 0, roughness: 1))
        XCTAssertThrowsError(try NeuralWholeMaterial(rgba: [0, 0, 0, 1], metallic: -0.1, roughness: 1))
        XCTAssertThrowsError(try NeuralWholeMaterial(rgba: [0, .nan, 0, 1], metallic: 0, roughness: 1))
        var raw = try object(fixture().recipe); raw["formatVersion"] = 2
        let version = try JSONDecoder().decode(NeuralEditRecipe.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try version.validate())
        raw["formatVersion"] = 1; raw["translationXYZ"] = [false, 0, 0]
        XCTAssertThrowsError(try JSONDecoder().decode(NeuralEditRecipe.self, from: JSONSerialization.data(withJSONObject: raw)))
    }

    private static var cached: Fixture?
    private func fixture() throws -> Fixture {
        if let cached = Self.cached { return cached }
        let result: Fixture
        #if canImport(ThreeLiveStudio)
        // Actual SDK CPU export, no neural weights/model initialization.
        let side = 393
        var positions = [Float](); var indices = [UInt32]()
        for y in 0..<side { for x in 0..<side { positions += [Float(x)/Float(side-1), Float(y)/Float(side-1), 0] } }
        for y in 0..<(side-1) { for x in 0..<(side-1) {
            let a = UInt32(y*side+x), b = a+1, c = a+UInt32(side), d = c+1
            indices += [a,b,d,a,d,c]
        } }
        // Base restore derives the exact canonical normal buffer used by editor.
        let initial = try ShapeMeshBuffers(positions: positions, normals: Array(repeating: [Float(0),0,1], count: side*side).flatMap { $0 }, indices: indices)
        let archive = try ShapeMeshArchive.encode(initial)
        let base = try ShapeMeshArchive.read(data: archive)
        let material = try ShapeWholeMaterial(rgba: [0.12,0.34,0.56,0.7], metallic: 0.27, roughness: 0.63)
        let recipe = try ShapeEditRecipe(translationXYZ: [0.3,-0.2,0.4], rotationXYZdegrees: [10,20,30], positiveScaleXYZ: [1.2,0.8,1.5], wholeMaterial: material)
        let edit = try ShapeMeshEditor.export(base: base, recipe: recipe, baseArchiveData: archive)
        result = try Fixture(base: archive, glb: edit.glbData, usdz: edit.usdzData,
                             recipeData: JSONEncoder().encode(recipe), evidenceData: JSONEncoder().encode(edit.validationReceipt))
        #else
        guard let directory = ProcessInfo.processInfo.environment["NEURAL_EDIT_FIXTURE_ROOT"] else {
            throw XCTSkip("Provide existing actual SDK CPU fixture; no substitute geometry is manufactured")
        }
        let root = URL(fileURLWithPath: directory)
        result = try Fixture(base: Data(contentsOf: root.appending(path: "base.glb")),
            glb: Data(contentsOf: root.appending(path: "edited.glb")), usdz: Data(contentsOf: root.appending(path: "edited.usdz")),
            recipeData: Data(contentsOf: root.appending(path: "recipe.json")), evidenceData: Data(contentsOf: root.appending(path: "edit-receipt.json")))
        #endif
        Self.cached = result; return result
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func canonicalObject(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
    }

    private struct Fixture {
        let base: Data, glb: Data, usdz: Data, recipeData: Data, evidenceData: Data
        let recipe: NeuralEditRecipe, evidence: NeuralEditEvidence
        let parent = UUID()
        init(base: Data, glb: Data, usdz: Data, recipeData: Data, evidenceData: Data) throws {
            self.base = base; self.glb = glb; self.usdz = usdz; self.recipeData = recipeData; self.evidenceData = evidenceData
            recipe = try JSONDecoder().decode(NeuralEditRecipe.self, from: recipeData)
            evidence = try JSONDecoder().decode(NeuralEditEvidence.self, from: evidenceData)
        }
        func descriptor(simulatedNeuralOrigin: Bool, includeEdit: Bool = true, sourceOnly: Bool = false) throws -> NeuralProjectDescriptor {
            let baseHash = digest(base), sourceHash = String(repeating: "e", count: 64)
            let renderGLB = sourceOnly ? base : glb
            let renderHash = digest(renderGLB)
            let origin = NeuralGenerationEvidence(version: 1, baseMeshFormatID: "org.khronos.gltf.binary", baseMeshFormatVersion: 2,
                geometryLayoutVersion: 1, vertexCount: evidence.vertexCount, triangleCount: evidence.triangleCount, indexCount: evidence.indexCount,
                glbByteCount: Int64(base.count), usdzByteCount: Int64(usdz.count), glbSHA256: baseHash, usdzSHA256: digest(usdz),
                baseMeshUsesUnchangedGLB: true, nativeGeometryValidated: true, usdNativeImporterOpened: true,
                actualNeuralWeightsUsed: simulatedNeuralOrigin)
            let artifacts: [ArtifactReference] = [
                .init(role: .glb, relativePath: "model.glb", byteCount: Int64(renderGLB.count), sha256: renderHash, formatID: "org.khronos.gltf.binary", formatVersion: 2),
                .init(role: .usdz, relativePath: "model.usdz", byteCount: Int64(usdz.count), sha256: digest(usdz), formatID: "com.pixar.universal-scene-description-mobile", formatVersion: 1),
                .init(role: .baseMesh, relativePath: sourceOnly ? "model.glb" : "base.glb", byteCount: Int64(base.count), sha256: baseHash, formatID: "org.khronos.gltf.binary", formatVersion: 2),
                .init(role: .sourcePNG, relativePath: "source.png", byteCount: 100, sha256: sourceHash, formatID: "public.png", formatVersion: 1)]
            let stage = NeuralStageProvenance(modelID: "synthetic-metadata-only", modelRevision: "no-neural-weights-ran",
                modelManifestSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64), runtimeVersion: "CPU-fixture", seed: 0)
            let provenance = NeuralPipelineProvenance(pipelineID: "synthetic-contract-only", method: sourceOnly ? .syntheticGeometryValidation : .meshTransformOrMaterialEdit,
                imageStage: nil, shapeStage: stage, preparedPNG_SHA256: sourceHash, generatedAt: Date(timeIntervalSince1970: 0),
                physicalScaleKnown: false, parentRevision: sourceOnly ? nil : parent)
            let baseStats = NeuralMeshStatistics(vertexCount: evidence.vertexCount, triangleCount: evidence.triangleCount, meshCount: 1,
                boundsMinimum: [0,0,0], boundsMaximum: [1,1,0])
            let renderStats = sourceOnly ? baseStats : NeuralMeshStatistics(vertexCount: evidence.vertexCount, triangleCount: evidence.triangleCount,
                meshCount: 1, boundsMinimum: evidence.boundsMinimum, boundsMaximum: evidence.boundsMaximum)
            return NeuralProjectDescriptor(geometryLayoutVersion: 1, artifacts: artifacts, statistics: renderStats, baseStatistics: baseStats,
                provenance: provenance, generationEvidence: origin, geometryContract: NeuralArtifactLimits.sourceContract,
                editRecipe: includeEdit ? recipe : nil, editEvidence: includeEdit ? evidence : nil)
        }
        private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
}
