import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VoxamberShapeNative
import XCTest
@testable import ThreeLiveStudio

/// Small real CPU-exported files exercise storage policy. The origin receipt's
/// positive flags are explicitly simulated metadata, never neural-run evidence.
@MainActor final class ProjectStoreNeuralOriginTests: XCTestCase {
    func testActualPreparationPublishReloadAndSecondEditUseOriginalBase() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let origin = try mesh(fixture.original.project)
        let recipe = try NeuralEditRecipe(translationXYZ: [0.1,0.2,0.3], positiveScaleXYZ: [1.2,0.8,1.5],
            wholeMaterial: NeuralWholeMaterial(rgba: [0.2,0.3,0.4,1], metallic: 0.1, roughness: 0.7))
        var current = fixture.original
        var firstRenderHash: String?
        for iteration in 1...2 {
            let parent = current.project.revision, permit = PublicationPermit()
            let input = try NeuralEditPreparation.prepare(assets: current, recipe: recipe,
                temporary: fixture.directory.appending(path: "prepared-\(iteration)"), permit: permit)
            let saved = try await fixture.store.publishNeural(input, replacing: current.project, permit: permit)
            current = try await fixture.store.load(saved.project)
            let edited = try mesh(current.project)
            XCTAssertEqual(edited.editRecipe, recipe)
            XCTAssertEqual(edited.provenance.parentRevision, parent)
            XCTAssertEqual(edited.generationEvidence, origin.generationEvidence)
            XCTAssertEqual(edited.provenance.generatedAt, origin.provenance.generatedAt)
            XCTAssertEqual(edited.provenance.physicalScaleKnown, origin.provenance.physicalScaleKnown)
            XCTAssertEqual(edited.statistics.boundsMinimum, [0.1,0.2,0.3])
            XCTAssertEqual(edited.statistics.boundsMaximum, [1.3,1.0,0.3])
            for role in [NeuralArtifactRole.baseMesh, .sourcePNG, .referencePNG] {
                XCTAssertEqual(edited.artifact(role)?.sha256, origin.artifact(role)?.sha256)
            }
            if let firstRenderHash {
                // Applying the same absolute recipe to an already edited project
                // must produce the same real geometry, not compound its transform.
                XCTAssertEqual(current.project.glbSHA256, firstRenderHash)
            } else { firstRenderHash = current.project.glbSHA256 }
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(current.baseMeshURL)),
                       try Data(contentsOf: XCTUnwrap(fixture.original.baseMeshURL)))
    }

    func testEditPreservesAuthoritativeOriginBaseAndReference() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = try fixture.editInput(parent: fixture.original.project)
        let oldBase = try Data(contentsOf: XCTUnwrap(fixture.original.baseMeshURL))
        let saved = try await fixture.store.publishNeural(input, replacing: fixture.original.project,
                                                         permit: PublicationPermit())
        let old = try mesh(fixture.original.project), edited = try mesh(saved.project)
        XCTAssertEqual(edited.generationEvidence, old.generationEvidence)
        XCTAssertFalse(try XCTUnwrap(edited.editEvidence).actualNeuralWeightsUsed)
        XCTAssertEqual(edited.provenance.shapeStage, old.provenance.shapeStage)
        XCTAssertEqual(edited.provenance.generatedAt, old.provenance.generatedAt)
        XCTAssertEqual(edited.provenance.physicalScaleKnown, old.provenance.physicalScaleKnown)
        XCTAssertEqual(edited.provenance.parentRevision, fixture.original.project.revision)
        for role in [NeuralArtifactRole.baseMesh, .sourcePNG, .referencePNG] {
            XCTAssertEqual(edited.artifact(role)?.sha256, old.artifact(role)?.sha256)
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.baseMeshURL)), oldBase)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fixture.original.baseMeshURL)), oldBase)
        XCTAssertNotEqual(saved.project.revision, fixture.original.project.revision)
    }

    func testForgedOldWithSameIdentityCannotReplaceDiskOrigin() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let old = fixture.original.project, original = try mesh(old), p = original.provenance
        let forgedStage = NeuralStageProvenance(modelID: "forged-source", modelRevision: "not-the-disk-origin",
            modelManifestSHA256: String(repeating: "7", count: 64), configurationSHA256: String(repeating: "8", count: 64),
            runtimeVersion: "CPU-policy-fixture", seed: p.shapeStage.seed)
        let forgedProvenance = NeuralPipelineProvenance(pipelineID: p.pipelineID, method: p.method,
            imageStage: p.imageStage, shapeStage: forgedStage, preparedPNG_SHA256: p.preparedPNG_SHA256,
            generatedAt: p.generatedAt, physicalScaleKnown: p.physicalScaleKnown, parentRevision: p.parentRevision,
            intentStage: p.intentStage, intentBrief: p.intentBrief)
        let forgedDescriptor = NeuralProjectDescriptor(geometryLayoutVersion: original.geometryLayoutVersion,
            artifacts: original.artifacts, statistics: original.statistics, baseStatistics: original.baseStatistics,
            provenance: forgedProvenance, generationEvidence: original.generationEvidence,
            geometryContract: original.geometryContract)
        let forged = CreationProject(id: old.id, revision: old.revision, createdAt: old.createdAt,
            updatedAt: old.updatedAt, name: old.name, content: .neuralMesh(forgedDescriptor), prompt: old.prompt,
            glbSHA256: old.glbSHA256, usdzSHA256: old.usdzSHA256)
        try forged.validateMetadata()
        XCTAssertEqual(forged.id, old.id); XCTAssertEqual(forged.revision, old.revision)
        let before = try fixture.pointerBytes()
        // Input agrees with the forged caller snapshot, so comparing only those
        // two values would incorrectly authorize a changed generation source.
        let input = try fixture.editInput(parent: forged)
        do {
            _ = try await fixture.store.publishNeural(input, replacing: forged, permit: PublicationPermit())
            XCTFail("The disk origin must override a caller's same-revision forgery")
        } catch ProjectStorageError.invalidMetadata {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try fixture.pointerBytes(), before)
        let restored = try await fixture.store.load(old)
        XCTAssertEqual(try mesh(restored.project).provenance, original.provenance)
        XCTAssertFalse(try fixture.hasPendingRevision())
    }

    func testEditCannotInventPhysicalCalibrationOrRewriteGenerationTime() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = try fixture.editInput(parent: fixture.original.project), p = input.provenance
        let before = try fixture.pointerBytes()
        for changeScale in [true, false] {
            let changed = NeuralPipelineProvenance(pipelineID: p.pipelineID, method: p.method,
                imageStage: p.imageStage, shapeStage: p.shapeStage, preparedPNG_SHA256: p.preparedPNG_SHA256,
                generatedAt: changeScale ? p.generatedAt : p.generatedAt.addingTimeInterval(1),
                physicalScaleKnown: changeScale ? true : p.physicalScaleKnown, parentRevision: p.parentRevision,
                intentStage: p.intentStage, intentBrief: p.intentBrief)
            let candidate = NeuralPublicationInput(name: input.name, prompt: input.prompt, files: input.files,
                statistics: input.statistics, baseStatistics: input.baseStatistics, provenance: changed,
                generationEvidence: input.generationEvidence, editRecord: input.editRecord)
            do {
                _ = try await fixture.store.publishNeural(candidate, replacing: fixture.original.project,
                                                         permit: PublicationPermit())
                XCTFail(changeScale ? "CPU edits cannot calibrate physical scale" : "Generation time is immutable origin")
            } catch ProjectStorageError.invalidMetadata {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(try fixture.pointerBytes(), before)
            XCTAssertFalse(try fixture.hasPendingRevision())
        }
    }

    func testEditStillRejectsStaleAndDeletedRevisions() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = try fixture.editInput(parent: fixture.original.project)
        let saved = try await fixture.store.publishNeural(input, replacing: fixture.original.project,
                                                         permit: PublicationPermit())
        let currentPointer = try fixture.pointerBytes()
        do {
            _ = try await fixture.store.publishNeural(input, replacing: fixture.original.project,
                                                     permit: PublicationPermit())
            XCTFail("An edit cannot replace a newer revision")
        } catch ProjectStorageError.staleRevision {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try fixture.pointerBytes(), currentPointer)
        let next = try fixture.editInput(parent: saved.project)
        try await fixture.store.remove(saved.project)
        do {
            _ = try await fixture.store.publishNeural(next, replacing: saved.project, permit: PublicationPermit())
            XCTFail("An edit cannot recreate a deleted project")
        } catch ProjectStorageError.staleRevision {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.projectDirectory.path))
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "NeuralOriginPolicy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let initial = try ShapeMeshBuffers(positions: [0,0,0, 1,0,0, 0,1,0],
                normals: [0,0,1, 0,0,1, 0,0,1], indices: [0,1,2])
            let baseData = try ShapeMeshArchive.encode(initial), base = try ShapeMeshArchive.read(data: baseData)
            let identity = try ShapeMeshEditor.export(base: base, recipe: ShapeEditRecipe(), baseArchiveData: baseData)
            let glb = directory.appending(path: "source.glb"), usdz = directory.appending(path: "source.usdz")
            let png = directory.appending(path: "source.png"), reference = directory.appending(path: "reference.png")
            try baseData.write(to: glb); try identity.usdzData.write(to: usdz)
            try pngData(side: 512).write(to: png); try pngData(side: 768).write(to: reference)
            let statistics = try NeuralProjectValidator.inspectGLB(glb, baseGeometry: true)
            let stage = NeuralStageProvenance(modelID: "simulated-policy-origin", modelRevision: "no-neural-model-ran",
                modelManifestSHA256: String(repeating: "1", count: 64), configurationSHA256: String(repeating: "2", count: 64),
                runtimeVersion: "CPU-policy-fixture", seed: 123)
            let provenance = NeuralPipelineProvenance(pipelineID: "CPU-policy-regression-only", method: .imageToShape,
                imageStage: nil, shapeStage: stage, preparedPNG_SHA256: digest(try Data(contentsOf: png)),
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000), physicalScaleKnown: false, parentRevision: nil)
            // Deliberately simulated positive origin metadata reaches edit policy;
            // the files above are actual CPU exports, and no neural model ran.
            let origin = NeuralGenerationEvidence(version: 1, baseMeshFormatID: "org.khronos.gltf.binary", baseMeshFormatVersion: 2,
                geometryLayoutVersion: 1, vertexCount: 3, triangleCount: 1, indexCount: 3,
                glbByteCount: Int64(baseData.count), usdzByteCount: Int64(identity.usdzData.count),
                glbSHA256: digest(baseData), usdzSHA256: digest(identity.usdzData), baseMeshUsesUnchangedGLB: true,
                nativeGeometryValidated: true, usdNativeImporterOpened: true, actualNeuralWeightsUsed: true)
            let store = ProjectStore(root: directory.appending(path: "projects"))
            let input = NeuralPublicationInput(name: "CPU origin policy fixture", prompt: "Synthetic metadata only; no neural model ran",
                files: .init(glb: glb, usdz: usdz, baseMesh: glb, sourcePNG: png, referencePNG: reference),
                statistics: statistics, baseStatistics: statistics, provenance: provenance, generationEvidence: origin)
            let original = try await store.publishNeural(input, replacing: nil, permit: PublicationPermit())
            return Fixture(directory: directory, store: store, original: original)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private func mesh(_ project: CreationProject) throws -> NeuralProjectDescriptor {
        guard case .neuralMesh(let descriptor) = project.content else { throw ProjectStorageError.invalidMetadata }
        return descriptor
    }
    private func pngData(side: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProjectStorageError.invalidArtifact }
        return data as Data
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private struct Fixture {
        let directory: URL, store: ProjectStore, original: ProjectAssets
        var projectDirectory: URL { directory.appending(path: "projects/" + original.project.id.uuidString) }
        func pointerBytes() throws -> Data { try Data(contentsOf: projectDirectory.appending(path: "project.json")) }
        func hasPendingRevision() throws -> Bool {
            try FileManager.default.contentsOfDirectory(atPath: projectDirectory.path).contains { $0.hasPrefix(".pending-") }
        }
        func editInput(parent: CreationProject) throws -> NeuralPublicationInput {
            guard case .neuralMesh(let originalMesh) = parent.content, let baseURL = original.baseMeshURL,
                  let pngURL = original.sourcePNGURL else { throw ProjectStorageError.invalidMetadata }
            let baseData = try Data(contentsOf: baseURL), base = try ShapeMeshArchive.read(data: baseData)
            let recipe = try ShapeEditRecipe(translationXYZ: [0.1,0.2,0.3], positiveScaleXYZ: [1.2,0.8,1.5],
                wholeMaterial: ShapeWholeMaterial(rgba: [0.2,0.3,0.4,1], metallic: 0.1, roughness: 0.7))
            let exported = try ShapeMeshEditor.export(base: base, recipe: recipe, baseArchiveData: baseData)
            let glb = directory.appending(path: UUID().uuidString + ".glb"), usdz = directory.appending(path: UUID().uuidString + ".usdz")
            try exported.glbData.write(to: glb); try exported.usdzData.write(to: usdz)
            let storedRecipe = try JSONDecoder().decode(NeuralEditRecipe.self, from: JSONEncoder().encode(recipe))
            let evidence = try JSONDecoder().decode(NeuralEditEvidence.self, from: JSONEncoder().encode(exported.validationReceipt))
            let record = try NeuralEditRecord(parentRevision: parent.revision, recipe: storedRecipe, evidence: evidence)
            let p = originalMesh.provenance
            let provenance = NeuralPipelineProvenance(pipelineID: p.pipelineID, method: .meshTransformOrMaterialEdit,
                imageStage: p.imageStage, shapeStage: p.shapeStage, preparedPNG_SHA256: p.preparedPNG_SHA256,
                generatedAt: p.generatedAt, physicalScaleKnown: p.physicalScaleKnown, parentRevision: parent.revision,
                intentStage: p.intentStage, intentBrief: p.intentBrief)
            return NeuralPublicationInput(name: parent.name, prompt: parent.prompt,
                files: .init(glb: glb, usdz: usdz, baseMesh: baseURL, sourcePNG: pngURL, referencePNG: original.referencePNGURL),
                statistics: try NeuralProjectValidator.inspectGLB(glb), baseStatistics: originalMesh.baseStatistics,
                provenance: provenance, generationEvidence: originalMesh.generationEvidence, editRecord: record)
        }
    }
}
