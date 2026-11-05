import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SceneKit
import XCTest
import CreationCore
import ThreeLiveNative
#if canImport(ThreeLiveStudio)
@testable import ThreeLiveStudio
import VoxamberShapeNative
#else
@testable import StorageV2NativeChecks
import ShapeArchiveWriterChecks
#endif

/// Actual synthetic files exercise the production Store. They are not neural
/// generations and never enter the user's library or restore deleted projects.
@MainActor final class ProjectStoreV2Tests: XCTestCase {
    func testV1EightAndTwelveNodeProjectsAreNeverRewrittenByListOpenOrRestart() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(root: dir.appending(path: "projects"))
        for count in [8,12] {
            let spec = SceneSpec(name: "Legacy synthetic \(count)", nodes: (0..<count).map {
                SceneNode.defaultNode(primitive: .box, id: "n\($0)", position: [Float($0)*0.05,0.2,0])
            })
            let files = try legacyFiles(spec)
            _ = try await store.publish(spec: spec, prompt: "Synthetic old representation; method not inferred", glb: files.0, usdz: files.1, replacing: nil)
        }
        // The original V1 writer had no lock file. Simulate its exact directory
        // shape and verify that read-only access does not add one later.
        for project in try await store.list() {
            try FileManager.default.removeItem(at: dir.appending(path: "projects/\(project.id.uuidString)/.publication.lock"))
        }
        let before = try inventory(dir)
        let reopened = ProjectStore(root: dir.appending(path: "projects"))
        let projects = try await reopened.list(); XCTAssertEqual(projects.count,2)
        XCTAssertEqual(Set(projects.map(\.schemaVersion)),[1])
        XCTAssertEqual(Set(projects.compactMap { $0.sceneSpec?.nodes.count }),[8,12])
        for project in projects {
            _ = try await reopened.load(project)
            let pointer = dir.appending(path:"projects/\(project.id.uuidString)/project.json")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:pointer)) as? [String:Any])
            XCTAssertNotNil(json["specification"]); XCTAssertNil(json["content"]); XCTAssertNil(json["name"])
        }
        XCTAssertEqual(try inventory(dir),before)
    }

    func testMixedV1AndNeuralV2ReopenWithTrueBasePNGAndNoSceneSpec() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let store=ProjectStore(root:dir.appending(path:"projects"));let old=try legacyFiles(.lamp)
        _=try await store.publish(spec:.lamp,prompt:"legacy fixture",glb:old.0,usdz:old.1,replacing:nil)
        let input=try fixture(in:dir.appending(path:"input"))
        let saved=try await store.publishNeural(input,replacing:nil,permit:PublicationPermit())
        XCTAssertEqual(saved.project.schemaVersion,2);XCTAssertNil(saved.project.sceneSpec);XCTAssertNil(saved.project.specification)
        XCTAssertEqual(saved.project.name,input.name)
        let reopened=ProjectStore(root:dir.appending(path:"projects"));let projects=try await reopened.list()
        XCTAssertEqual(projects.count,2);let loaded=try await reopened.load(saved.project)
        XCTAssertEqual(try hash(XCTUnwrap(loaded.baseMeshURL)),try hash(input.files.baseMesh))
        XCTAssertEqual(try hash(XCTUnwrap(loaded.sourcePNGURL)),input.provenance.preparedPNG_SHA256)
        XCTAssertEqual(loaded.project,saved.project)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:saved.glbURL.deletingLastPathComponent().appending(path:"revision.json"))) as? [String:Any])
        XCTAssertNil(json["specification"])
        let content=try XCTUnwrap(json["content"] as? [String:Any]);XCTAssertEqual(content["kind"] as? String,"neuralMesh");XCTAssertNil(content["scene"])
    }

    func testLargeActualSyntheticGeometryIsNotReducedToProceduralExporterCaps() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let input=try fixture(in:dir.appending(path:"input"),gridSide:393)
        XCTAssertEqual(input.statistics.vertexCount,154_449);XCTAssertEqual(input.statistics.triangleCount,307_328)
        let store=ProjectStore(root:dir.appending(path:"projects"))
        let saved=try await store.publishNeural(input,replacing:nil,permit:PublicationPermit())
        let loaded=try await store.load(saved.project)
        guard case .neuralMesh(let mesh)=loaded.project.content else{return XCTFail("No real mesh descriptor")}
        XCTAssertEqual(mesh.statistics,input.statistics);XCTAssertEqual(mesh.baseStatistics,input.baseStatistics)
        XCTAssertEqual(try hash(loaded.glbURL),try hash(input.files.glb));XCTAssertEqual(try hash(loaded.usdzURL),try hash(input.files.usdz))
        XCTAssertFalse(mesh.generationEvidence.actualNeuralWeightsUsed)
        XCTAssertEqual(mesh.provenance.method,.syntheticGeometryValidation)
    }

    func testIndependentStorageCapsExactlyMatchAuditedPublicShapeSDKContract() {
        XCTAssertEqual(NeuralArtifactLimits.maximumVertices,ShapeArtifactLimits.maximumVertices)
        XCTAssertEqual(NeuralArtifactLimits.maximumTriangles,ShapeArtifactLimits.maximumTriangles)
        XCTAssertEqual(NeuralArtifactLimits.maximumIndices,ShapeArtifactLimits.maximumIndices)
        XCTAssertEqual(NeuralArtifactLimits.maximumGLBBytes,Int64(ShapeArtifactLimits.maximumGLBBytes))
        XCTAssertEqual(NeuralArtifactLimits.maximumUSDZBytes,Int64(ShapeArtifactLimits.maximumUSDZBytes))
        XCTAssertEqual(NeuralArtifactLimits.maximumPNGBytes,Int64(ShapeArtifactLimits.maximumInputPNGBytes))
    }

    func testOptionalIntentBriefOriginalReferenceAndActualStageSeedsRoundTrip() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let input=try fixture(in:dir.appending(path:"input")),reference=dir.appending(path:"input/reference-768.png")
        try pngData(side:768).write(to:reference)
        let seed=UInt64.max-7,imageSeed=UInt64(UInt32(truncatingIfNeeded:seed)),stage=input.provenance.shapeStage
        let shape=NeuralStageProvenance(modelID:stage.modelID,modelRevision:stage.modelRevision,modelManifestSHA256:stage.modelManifestSHA256,configurationSHA256:stage.configurationSHA256,runtimeVersion:stage.runtimeVersion,seed:seed)
        let image=NeuralStageProvenance(modelID:"fixture/image",modelRevision:"fixed",modelManifestSHA256:String(repeating:"3",count:64),configurationSHA256:String(repeating:"4",count:64),runtimeVersion:"host-fixture",seed:imageSeed)
        let brief=NeuralIntentBrief(title:"Exact normalized title",positiveEnglish:"A blue whale, curved tail; clean background.",negativeEnglish:"blur, text, watermark",requestedSeed:seed)
        let p=input.provenance
        let provenance=NeuralPipelineProvenance(pipelineID:p.pipelineID,method:p.method,imageStage:image,shapeStage:shape,preparedPNG_SHA256:p.preparedPNG_SHA256,generatedAt:p.generatedAt,physicalScaleKnown:false,parentRevision:nil,intentStage:.init(modelID:"fixture/intent",modelRevision:"fixed",configurationSHA256:String(repeating:"5",count:64)),intentBrief:brief)
        let enriched=NeuralPublicationInput(name:input.name,prompt:input.prompt,files:.init(glb:input.files.glb,usdz:input.files.usdz,baseMesh:input.files.baseMesh,sourcePNG:input.files.sourcePNG,referencePNG:reference),statistics:input.statistics,baseStatistics:input.baseStatistics,provenance:provenance,generationEvidence:input.generationEvidence)
        let store=ProjectStore(root:dir.appending(path:"projects"));let saved=try await store.publishNeural(enriched,replacing:nil,permit:PublicationPermit())
        let loaded=try await store.load(saved.project)
        guard case .neuralMesh(let descriptor)=loaded.project.content else{return XCTFail("Missing mesh")}
        XCTAssertEqual(descriptor.artifacts.count,5);XCTAssertEqual(descriptor.provenance.intentBrief,brief)
        XCTAssertEqual(descriptor.provenance.imageStage?.seed,imageSeed);XCTAssertEqual(descriptor.provenance.shapeStage.seed,seed)
        XCTAssertFalse(descriptor.provenance.physicalScaleKnown)
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(loaded.referencePNGURL)),try Data(contentsOf:reference))
    }

    func testPointerWriterErrorAfterAtomicRenameAndCancellationStillReturnsSavedCommit() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let permit=PublicationPermit(),files=try legacyFiles(.lamp)
        let store=ProjectStore(root:dir.appending(path:"projects"),pointerWriter:{data,url in
            try data.write(to:url,options:.atomic)
            withUnsafeCurrentTask{$0?.cancel()}
            throw CocoaError(.fileWriteUnknown)
        })
        let task=Task{let saved=try await store.publish(spec:.lamp,prompt:"Post-commit error fixture",glb:files.0,usdz:files.1,replacing:nil,permit:permit);return(saved,Task.isCancelled)}
        let(saved,cancelled)=try await task.value
        XCTAssertTrue(cancelled);XCTAssertEqual(permit.state,.committed);XCTAssertFalse(permit.revoke())
        _=try await store.load(saved.project)
        let listed=try await store.list();XCTAssertEqual(listed,[saved.project])
    }

    func testActualGLBIndicesDegeneracyAndDeclaredStatisticsFailClosed() throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let input=try fixture(in:dir.appending(path:"input")),original=try Data(contentsOf:input.files.glb)
        let jsonLength=original.withUnsafeBytes{Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:12,as:UInt32.self)))}
        let binary=28+jsonLength
        var badIndex=original;var outOfRange=UInt32.max.littleEndian
        withUnsafeBytes(of:&outOfRange){badIndex.replaceSubrange(binary..<(binary+4),with:$0)}
        try badIndex.write(to:input.files.glb)
        XCTAssertThrowsError(try NeuralProjectValidator.inspectGLB(input.files.glb))
        var flat=original
        // Index data precedes POSITION in SDK layout 1; collapse the first face.
        let positions=binary+input.statistics.triangleCount*3*4
        let first=flat.subdata(in:positions..<(positions+12))
        flat.replaceSubrange((positions+12)..<(positions+24),with:first)
        flat.replaceSubrange((positions+24)..<(positions+36),with:first)
        try flat.write(to:input.files.glb)
        XCTAssertThrowsError(try NeuralProjectValidator.inspectGLB(input.files.glb))
        try original.write(to:input.files.glb)
        let wrong=NeuralMeshStatistics(vertexCount:input.statistics.vertexCount+1,triangleCount:input.statistics.triangleCount,meshCount:1,boundsMinimum:input.statistics.boundsMinimum,boundsMaximum:input.statistics.boundsMaximum)
        XCTAssertThrowsError(try NeuralProjectValidator.inspect(.init(name:input.name,prompt:input.prompt,files:input.files,statistics:wrong,baseStatistics:input.baseStatistics,provenance:input.provenance,generationEvidence:input.generationEvidence)))
    }

    func testRenderNormalsAndPBRRemainSeparateFromStrictRestorableBaseLayout() throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let positions:[SIMD3<Float>]=[[0,0,0],[1,0,0],[0,0,1]],indices:[UInt32]=[0,2,1]
        let base=dir.appending(path:"base.glb"),render=dir.appending(path:"render.glb")
        try writeGLB(positions:positions,indices:indices,to:base)
        let baseHash=try hash(base)
        let material:[String:Any]=["pbrMetallicRoughness":["baseColorFactor":[0.2,0.4,0.8,1.0],"metallicFactor":0.25,"roughnessFactor":0.6]]
        try writeGLB(positions:positions,indices:indices,to:render,normals:Array(repeating:[0,1,0],count:3),material:material)
        let baseStats=try NeuralProjectValidator.inspectGLB(base,baseGeometry:true)
        XCTAssertEqual(try NeuralProjectValidator.inspectGLB(render),baseStats)
        XCTAssertThrowsError(try NeuralProjectValidator.inspectGLB(render,baseGeometry:true))
        XCTAssertEqual(try hash(base),baseHash,"Render validation never mutates the base")
        try writeGLB(positions:positions,indices:indices,to:render,normals:Array(repeating:[0,1,0],count:3),material:material,permuteAccessors:true)
        XCTAssertEqual(try NeuralProjectValidator.inspectGLB(render),baseStats,"Render attribute semantic indices are not hard-coded")
        try writeGLB(positions:positions,indices:indices,to:render,normals:Array(repeating:[0,1,0],count:2),material:material)
        XCTAssertThrowsError(try NeuralProjectValidator.inspectGLB(render))
        try writeGLB(positions:positions,indices:indices,to:render,normals:[[0,1,0],[.nan,0,0],[0,1,0]],material:material)
        XCTAssertThrowsError(try NeuralProjectValidator.inspectGLB(render))
    }

    func testRenderPBRRejectsOutOfRangeBooleanAndTextureClaims() throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let positions:[SIMD3<Float>]=[[0,0,0],[1,0,0],[0,0,1]],file=dir.appending(path:"render.glb")
        let invalid:[[String:Any]]=[
            ["baseColorFactor":[1.1,0,0,1]], ["baseColorFactor":[0,0,1]],
            ["metallicFactor":true], ["roughnessFactor":-0.01],
            ["baseColorTexture":["index":0]]
        ]
        for pbr in invalid {
            try writeGLB(positions:positions,indices:[0,2,1],to:file,normals:Array(repeating:[0,1,0],count:3),material:["pbrMetallicRoughness":pbr])
            XCTAssertThrowsError(try NeuralProjectValidator.inspectGLB(file))
        }
    }

    func testOversizedSparseArtifactFailsBeforeAllocatingOrReadingItsContents() throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let file=dir.appending(path:"too-large.glb");FileManager.default.createFile(atPath:file.path,contents:Data([1]))
        let handle=try FileHandle(forWritingTo:file);try handle.truncate(atOffset:UInt64(NeuralArtifactLimits.maximumGLBBytes+1));try handle.close()
        XCTAssertThrowsError(try ProjectFileIO.fingerprint(file,limit:NeuralArtifactLimits.maximumGLBBytes))
    }

    func testSyntheticEvidenceCannotAccidentallyBecomeANeuralGenerationClaim() throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let input=try fixture(in:dir.appending(path:"input")),p=input.provenance
        let mislabeled=NeuralPipelineProvenance(pipelineID:p.pipelineID,method:.imageToShape,imageStage:nil,shapeStage:p.shapeStage,preparedPNG_SHA256:p.preparedPNG_SHA256,generatedAt:p.generatedAt,physicalScaleKnown:false,parentRevision:nil)
        XCTAssertThrowsError(try NeuralProjectValidator.inspect(.init(name:input.name,prompt:input.prompt,files:input.files,statistics:input.statistics,baseStatistics:input.baseStatistics,provenance:mislabeled,generationEvidence:input.generationEvidence)))
    }

    func testStaleReplacementAndDeletedIdentityCannotBeRepublished() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let store=ProjectStore(root:dir.appending(path:"projects"));let files=try legacyFiles(.chair)
        let first=try await store.publish(spec:.chair,prompt:"old",glb:files.0,usdz:files.1,replacing:nil)
        let second=try await store.publish(spec:.chair,prompt:"new",glb:files.0,usdz:files.1,replacing:first.project)
        let before=try inventory(dir)
        do{_=try await store.publish(spec:.chair,prompt:"stale",glb:files.0,usdz:files.1,replacing:first.project);XCTFail("Stale revision must fail")}catch{XCTAssertFalse(error is CancellationError)}
        XCTAssertEqual(try inventory(dir),before)
        try await store.remove(second.project)
        let input=try fixture(in:dir.appending(path:"input"))
        do{_=try await store.publishNeural(input,replacing:second.project,permit:PublicationPermit());XCTFail("Deleted identity must fail")}catch{XCTAssertFalse(error is CancellationError)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appending(path:"projects/\(second.project.id.uuidString)").path))
        let remaining=try await store.list();XCTAssertTrue(remaining.isEmpty)
    }

    func testRevocationAtActualCommitBoundaryKeepsOldPointerAndCleansOnlyNewRevision() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let base=ProjectStore(root:dir.appending(path:"projects"));let files=try legacyFiles(.robot)
        let saved=try await base.publish(spec:.robot,prompt:"retained",glb:files.0,usdz:files.1,replacing:nil)
        let before=try inventory(dir.appending(path:"projects"));let permit=PublicationPermit()
        let store=ProjectStore(root:dir.appending(path:"projects"),publicationObserver:{phase in
            if case .readyToCommit=phase{permit.revoke()}
        })
        let input=try fixture(in:dir.appending(path:"input"))
        do{_=try await store.publishNeural(input,replacing:saved.project,permit:permit);XCTFail("Revoked publication must fail")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(try inventory(dir.appending(path:"projects")),before)
        _=try await base.load(saved.project);XCTAssertEqual(permit.state,.revoked)
    }

    func testCancellationAfterCommitCannotLieAboutSavedResult() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let permit=PublicationPermit(),flag=LockedFlag()
        let store=ProjectStore(root:dir.appending(path:"projects"),publicationObserver:{phase in
            if case .committed=phase{
                flag.set(permit.revoke())
                withUnsafeCurrentTask{$0?.cancel()}
            }
        })
        let input=try fixture(in:dir.appending(path:"input"))
        let task=Task{try await store.publishNeural(input,replacing:nil,permit:permit)}
        let saved=try await task.value
        XCTAssertEqual(flag.value,false);XCTAssertEqual(permit.state,.committed)
        let listed=try await store.list();XCTAssertEqual(listed,[saved.project]);_=try await store.load(saved.project)
    }

    func testAnotherStoreListCannotDeleteLiveStaging() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let root=dir.appending(path:"projects"),base=ProjectStore(root:root),files=try legacyFiles(.lamp)
        let old=try await base.publish(spec:.lamp,prompt:"old",glb:files.0,usdz:files.1,replacing:nil)
        let gate=PublicationGate()
        let writer=ProjectStore(root:root,publicationObserver:{phase in if case .stagedFilesValidated=phase{gate.wait()}})
        let task=Task.detached{try await writer.publish(spec:.lamp,prompt:"replacement",glb:files.0,usdz:files.1,replacing:old.project)}
        defer{gate.release()}
        for _ in 0..<200{if gate.started{break};try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(gate.started)
        let folder=root.appending(path:old.project.id.uuidString)
        let pending=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".pending-")}
        XCTAssertEqual(pending.count,1)
        let listed=try await base.list();XCTAssertEqual(listed,[old.project])
        XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(pending.first).path))
        gate.release();let new=try await task.value;XCTAssertNotEqual(new.project.revision,old.project.revision)
    }

    func testUnknownVersionsAndUnsafeArtifactReferencesRemainUnmodified() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let store=ProjectStore(root:dir.appending(path:"projects")),files=try legacyFiles(.lamp)
        let saved=try await store.publish(spec:.lamp,prompt:"legacy",glb:files.0,usdz:files.1,replacing:nil)
        let pointer=saved.glbURL.deletingLastPathComponent().deletingLastPathComponent().appending(path:"project.json")
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:pointer)) as? [String:Any]);object["schemaVersion"]=999
        let future=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys);try future.write(to:pointer,options:.atomic)
        let listed=try await store.list();XCTAssertTrue(listed.isEmpty);XCTAssertEqual(try Data(contentsOf:pointer),future)
        XCTAssertTrue(FileManager.default.fileExists(atPath:saved.glbURL.path))
        let input=try fixture(in:dir.appending(path:"input"));let descriptor=try NeuralProjectValidator.inspect(input)
        let valid=CreationProject(id:UUID(),revision:UUID(),createdAt:Date(),updatedAt:Date(),name:input.name,content:.neuralMesh(descriptor),prompt:input.prompt,glbSHA256:descriptor.artifact(.glb)!.sha256,usdzSHA256:descriptor.artifact(.usdz)!.sha256)
        var encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(valid)) as? [String:Any])
        var content=try XCTUnwrap(encoded["content"] as? [String:Any]),mesh=try XCTUnwrap(content["mesh"] as? [String:Any]),artifacts=try XCTUnwrap(mesh["artifacts"] as? [[String:Any]])
        artifacts[0]["relativePath"]="../other/model.glb";mesh["artifacts"]=artifacts;content["mesh"]=mesh;encoded["content"]=content
        XCTAssertThrowsError(try JSONDecoder().decode(CreationProject.self,from:JSONSerialization.data(withJSONObject:encoded)))
    }

    func testSymlinksAndHeadersWithoutActualGeometryAreRejected() throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let input=try fixture(in:dir.appending(path:"input"));let link=dir.appending(path:"linked.glb")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:input.files.glb)
        let linked=NeuralPublicationInput(name:input.name,prompt:input.prompt,files:.init(glb:link,usdz:input.files.usdz,baseMesh:input.files.baseMesh,sourcePNG:input.files.sourcePNG),statistics:input.statistics,baseStatistics:input.baseStatistics,provenance:input.provenance,generationEvidence:input.generationEvidence)
        XCTAssertThrowsError(try NeuralProjectValidator.inspect(linked))
        try Data("glTF\u{02}\0\0\0".utf8).write(to:input.files.glb)
        XCTAssertThrowsError(try NeuralProjectValidator.inspect(input))
    }

    func testRealCopiedHashesAndUSDA_CRCDetectTampering() async throws {
        let dir=temporary();defer{try?FileManager.default.removeItem(at:dir)}
        let input=try fixture(in:dir.appending(path:"input")),store=ProjectStore(root:dir.appending(path:"projects"))
        let saved=try await store.publishNeural(input,replacing:nil,permit:PublicationPermit())
        var bytes=try Data(contentsOf:saved.usdzURL)
        let start=try XCTUnwrap(bytes.range(of:Data("points = [".utf8))).upperBound
        let coordinate=try XCTUnwrap(bytes[start...].firstIndex(where:{(48...57).contains($0)}))
        bytes[coordinate] = bytes[coordinate] == 53 ? 52 : 53
        try bytes.write(to:saved.usdzURL)
        do{_=try await store.load(saved.project);XCTFail("Changed bytes must fail")}catch{}
        let projects=try await store.list();XCTAssertEqual(projects,[saved.project])
        // Update only the synthetic evidence's file hash so validation really
        // reaches the stale stored CRC, instead of failing a previous SHA check.
        let e=input.generationEvidence
        let changed=NeuralGenerationEvidence(version:e.version,baseMeshFormatID:e.baseMeshFormatID,baseMeshFormatVersion:e.baseMeshFormatVersion,geometryLayoutVersion:e.geometryLayoutVersion,vertexCount:e.vertexCount,triangleCount:e.triangleCount,indexCount:e.indexCount,glbByteCount:e.glbByteCount,usdzByteCount:e.usdzByteCount,glbSHA256:e.glbSHA256,usdzSHA256:try hash(saved.usdzURL),baseMeshUsesUnchangedGLB:e.baseMeshUsesUnchangedGLB,nativeGeometryValidated:e.nativeGeometryValidated,usdNativeImporterOpened:e.usdNativeImporterOpened,actualNeuralWeightsUsed:false)
        XCTAssertThrowsError(try NeuralProjectValidator.inspect(.init(name:input.name,prompt:input.prompt,files:.init(glb:input.files.glb,usdz:saved.usdzURL,baseMesh:input.files.baseMesh,sourcePNG:input.files.sourcePNG),statistics:input.statistics,baseStatistics:input.baseStatistics,provenance:input.provenance,generationEvidence:changed)))
    }

    private func temporary()->URL{FileManager.default.temporaryDirectory.appending(path:"VoxamberStorageV2-"+UUID().uuidString)}
    private func legacyFiles(_ scene:SceneSpec)throws->(Data,Data){let m=try SceneGenerator.generate(for:scene);return(try ThreeLiveNative.exportGLB(m),try ThreeLiveNative.exportUSDZ(m))}
    private func pngData(side:Int)throws->Data{
        let pixels=Data(repeating:200,count:side*side*4),provider=try XCTUnwrap(CGDataProvider(data:pixels as CFData))
        let image=try XCTUnwrap(CGImage(width:side,height:side,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:side*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil));CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination));return data as Data
    }
    private func hash(_ file:URL)throws->String{SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()}
    private func inventory(_ root:URL)throws->[String:String]{
        guard FileManager.default.fileExists(atPath:root.path) else{return[:]}
        let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        let prefix=root.path.hasSuffix("/") ? root.path : root.path+"/"
        return try Dictionary(uniqueKeysWithValues:e.compactMap{$0 as? URL}.filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true}.map{(String($0.path.dropFirst(prefix.count)),try hash($0))})
    }

    private func fixture(in directory:URL,gridSide:Int?=nil)throws->NeuralPublicationInput{
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let positions:[SIMD3<Float>],indices:[UInt32]
        if let n=gridSide{
            positions=(0..<(n*n)).map{SIMD3(Float($0 % n)*0.005,0,Float($0/n)*0.005)}
            var faces:[UInt32]=[];faces.reserveCapacity((n-1)*(n-1)*6)
            for y in 0..<(n-1){for x in 0..<(n-1){let a=UInt32(y*n+x),b=a+1,c=a+UInt32(n),d=c+1;faces += [a,c,b,b,c,d]}}
            indices=faces
        }else{
            positions=[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],[-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]]
            indices=[0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,0,4,7,0,7,3,1,2,6,1,6,5]
        }
        let glb=directory.appending(path:"shape.glb"),usdz=directory.appending(path:"shape.usdz"),png=directory.appending(path:"prepared.png")
        try writeGLB(positions:positions,indices:indices,to:glb)
        let usda=directory.appending(path:"Model.usda")
        FileManager.default.createFile(atPath:usda.path,contents:nil);let file=try FileHandle(forWritingTo:usda);defer{try?file.close()}
        try file.write(contentsOf:Data("#usda 1.0\n(\n defaultPrim = \"Mesh\"\n metersPerUnit = 1\n upAxis = \"Y\"\n)\ndef Mesh \"Mesh\" {\n point3f[] points = [".utf8))
        var text="";for(i,p)in positions.enumerated(){if i>0{text += ","};text += "(\(p.x),\(p.y),\(p.z))";if text.utf8.count>65536{try file.write(contentsOf:Data(text.utf8));text=""}}
        text += "]\n int[] faceVertexCounts = [";for i in 0..<(indices.count/3){if i>0{text += ","};text += "3";if text.utf8.count>65536{try file.write(contentsOf:Data(text.utf8));text=""}}
        text += "]\n int[] faceVertexIndices = [";for(i,v)in indices.enumerated(){if i>0{text += ","};text += String(v);if text.utf8.count>65536{try file.write(contentsOf:Data(text.utf8));text=""}}
        text += "]\n uniform token subdivisionScheme = \"none\"\n}\n";try file.write(contentsOf:Data(text.utf8));try file.close()
        try USDZArchiveWriter.write(entries:[.init(archivePath:"Model.usda",sourceURL:usda)],to:usdz)
        // Actual Apple importer opens this synthetic container, without rendering.
        let imported=try SCNScene(url:usdz,options:nil);var geometry=false;imported.rootNode.enumerateHierarchy{node,_ in if node.geometry != nil{geometry=true}};XCTAssertTrue(geometry)
        let pixels=Data(repeating:200,count:512*512*4),provider=try XCTUnwrap(CGDataProvider(data:pixels as CFData))
        let image=try XCTUnwrap(CGImage(width:512,height:512,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:2048,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let output=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil));CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination));try(output as Data).write(to:png)
        let stats=NeuralMeshStatistics(vertexCount:positions.count,triangleCount:indices.count/3,meshCount:1,boundsMinimum:(0..<3).map{axis in positions.map{$0[axis]}.min()!},boundsMaximum:(0..<3).map{axis in positions.map{$0[axis]}.max()!})
        let shape=NeuralStageProvenance(modelID:"fixture/synthetic-geometry",modelRevision:"cpu-v1",modelManifestSHA256:String(repeating:"1",count:64),configurationSHA256:String(repeating:"2",count:64),runtimeVersion:"host-native-fixture",seed:0)
        let provenance=NeuralPipelineProvenance(pipelineID:"fixture.storage-v2",method:.syntheticGeometryValidation,imageStage:nil,shapeStage:shape,preparedPNG_SHA256:try hash(png),generatedAt:Date(),physicalScaleKnown:false,parentRevision:nil)
        let evidence=NeuralGenerationEvidence(version:1,baseMeshFormatID:"org.khronos.gltf.binary",baseMeshFormatVersion:2,geometryLayoutVersion:1,vertexCount:stats.vertexCount,triangleCount:stats.triangleCount,indexCount:indices.count,glbByteCount:Int64(try Data(contentsOf:glb).count),usdzByteCount:Int64(try Data(contentsOf:usdz).count),glbSHA256:try hash(glb),usdzSHA256:try hash(usdz),baseMeshUsesUnchangedGLB:true,nativeGeometryValidated:true,usdNativeImporterOpened:geometry,actualNeuralWeightsUsed:false)
        return .init(name:"Synthetic mesh storage fixture",prompt:"CPU contract only; no neural model called",files:.init(glb:glb,usdz:usdz,baseMesh:glb,sourcePNG:png),statistics:stats,baseStatistics:stats,provenance:provenance,generationEvidence:evidence)
    }

    private func writeGLB(positions:[SIMD3<Float>],indices:[UInt32],to url:URL,
                          normals:[SIMD3<Float>]?=nil,material:[String:Any]?=nil,permuteAccessors:Bool=false)throws{
        var binary=Data();for var i in indices.map(\.littleEndian){withUnsafeBytes(of:&i){binary.append(contentsOf:$0)}}
        let offset=binary.count;for p in positions{for axis in 0..<3{var value=p[axis].bitPattern.littleEndian;withUnsafeBytes(of:&value){binary.append(contentsOf:$0)}}}
        var views:[[String:Any]]=[["buffer":0,"byteOffset":0,"byteLength":offset],["buffer":0,"byteOffset":offset,"byteLength":positions.count*12]]
        var accessors:[[String:Any]]=[["bufferView":0,"componentType":5125,"count":indices.count,"type":"SCALAR"],["bufferView":1,"componentType":5126,"count":positions.count,"type":"VEC3"]]
        var attributes:[String:Any]=["POSITION":1]
        if let normals {
            let normalOffset=binary.count
            for n in normals {for axis in 0..<3 {var value=n[axis].bitPattern.littleEndian;withUnsafeBytes(of:&value){binary.append(contentsOf:$0)}}}
            views.append(["buffer":0,"byteOffset":normalOffset,"byteLength":normals.count*12]);accessors.append(["bufferView":2,"componentType":5126,"count":normals.count,"type":"VEC3"]);attributes["NORMAL"]=2
        }
        var primitive:[String:Any]=["attributes":attributes,"indices":0]
        if permuteAccessors, normals != nil {
            accessors=[accessors[1],accessors[2],accessors[0]]
            primitive["attributes"]=["POSITION":0,"NORMAL":1];primitive["indices"]=2
        }
        if material != nil {primitive["material"]=0}
        var object:[String:Any]=["asset":["version":"2.0"],"buffers":[["byteLength":binary.count]],"bufferViews":views,"accessors":accessors,"meshes":[["primitives":[primitive]]],"nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0]
        if let material {object["materials"]=[material]}
        var json=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys);while json.count%4 != 0{json.append(32)}
        var data=Data();func word(_ x:UInt32){var value=x.littleEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}}
        word(0x46546c67);word(2);word(UInt32(28+json.count+binary.count));word(UInt32(json.count));word(0x4e4f534a);data.append(json);word(UInt32(binary.count));word(0x004e4942);data.append(binary);try data.write(to:url)
    }
}

private final class LockedFlag:@unchecked Sendable{private let lock=NSLock();private var stored:Bool?;var value:Bool?{lock.withLock{stored}};func set(_ value:Bool){lock.withLock{stored=value}}}
private final class PublicationGate:@unchecked Sendable{
    private let lock=NSLock(),semaphore=DispatchSemaphore(value:0);private var entered=false
    var started:Bool{lock.withLock{entered}}
    func wait(){lock.withLock{entered=true};_=semaphore.wait(timeout:.now()+10)}
    func release(){semaphore.signal()}
}
