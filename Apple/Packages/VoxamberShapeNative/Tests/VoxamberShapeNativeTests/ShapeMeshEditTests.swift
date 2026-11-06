import Foundation
import XCTest
import simd
import SceneKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import VoxamberShapeNative

final class ShapeMeshEditTests:XCTestCase {
    func testTransformOrderAndInverseTransposeNormalsAreBakedInBothArtifacts() throws {
        let base=try triangle(customNormals:true),archive=try ShapeMeshArchive.encode(base)
        let recipe=try ShapeEditRecipe(translationXYZ:[10,-2,5],rotationXYZdegrees:[90,0,90],positiveScaleXYZ:[2,3,4])
        let result=try ShapeMeshEditor.export(base:base,recipe:recipe,baseArchiveData:archive)
        let expected:[Float]=[10,0,5,10,-2,8,14,-2,5]
        for (a,b) in zip(result.mesh.positions,expected){XCTAssertEqual(a,b,accuracy:1e-6)}
        let normal=simd_normalize(SIMD3<Double>(0.25,0.5,1.0/3.0))
        for i in 0..<3 {XCTAssertEqual(Double(result.mesh.normals[i]),normal[i],accuracy:1e-6)}
        let decoded=try decodeGLB(result.glbData)
        XCTAssertEqual(decoded.positions,result.mesh.positions);XCTAssertEqual(decoded.normals,result.mesh.normals)
        let usda=try usda(result.usdzData)
        XCTAssertEqual(try vectors(usda,marker:"point3f[] points = ["),result.mesh.positions)
        XCTAssertEqual(try vectors(usda,marker:"normal3f[] normals = ["),result.mesh.normals)
        XCTAssertEqual(result.mesh.indices,base.indices)
        XCTAssertEqual(result.validationReceipt.baseMeshSHA256,HunyuanShape21Configuration.digest(archive))
        XCTAssertFalse(result.validationReceipt.actualNeuralWeightsUsed)
    }

    func testInvalidTransformMaterialAndDecodedRecipeAreRejected() throws {
        for scale:[Double] in [[1,0,1],[1,-1,1],[1,Double.infinity,1],[1,1]] {
            XCTAssertThrowsError(try ShapeEditRecipe(positiveScaleXYZ:scale))
        }
        XCTAssertThrowsError(try ShapeEditRecipe(translationXYZ:[.nan,0,0]))
        XCTAssertThrowsError(try ShapeWholeMaterial(rgba:[1,0,0],metallic:0,roughness:0.5))
        XCTAssertThrowsError(try ShapeWholeMaterial(rgba:[1,0,0,1],metallic:1.1,roughness:0.5))
        let invalid=Data(#"{"formatVersion":2,"translationXYZ":[0,0,0],"rotationXYZdegrees":[0,0,0],"positiveScaleXYZ":[1,1,1]}"#.utf8)
        let decoded=try JSONDecoder().decode(ShapeEditRecipe.self,from:invalid)
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:triangle(),recipe:decoded))
    }

    func testFloatCollapseAndCoordinateRangeRejectWithoutChangingBase() throws {
        let base=try triangle(),before=try ShapeMeshArchive.encode(base)
        let collapse=try ShapeEditRecipe(translationXYZ:[1000,1000,1000],positiveScaleXYZ:[1e-6,1e-6,1e-6])
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:base,recipe:collapse)) {guard case ShapeEditError.floatDegeneration=$0 else{return XCTFail("Expected explicit Float degeneration")}}
        let huge=try ShapeEditRecipe(translationXYZ:[2_000_000,0,0])
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:base,recipe:huge)) {guard case ShapeEditError.outputOutOfRange=$0 else{return XCTFail("Expected explicit output bound")}}
        XCTAssertEqual(try ShapeMeshArchive.encode(base),before)
    }

    func testDegenerateBaseAndWrongBaseArchiveReject() throws {
        let bad=try ShapeMeshBuffers(positions:[0,0,0,1,0,0,2,0,0],normals:[0,0,1,0,0,1,0,0,1],indices:[0,1,2])
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:bad,recipe:.init()))
        let valid=try triangle(),other=try ShapeMeshBuffers(positions:[0,0,0,2,0,0,0,2,0],normals:valid.normals,indices:valid.indices)
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:valid,recipe:.init(),baseArchiveData:ShapeMeshArchive.encode(other)))
        let normalMismatch=try ShapeMeshBuffers(positions:valid.positions,normals:[1,0,0,1,0,0,1,0,0],indices:valid.indices)
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:normalMismatch,recipe:.init(),baseArchiveData:ShapeMeshArchive.encode(valid)))
    }

    func testCancellationStopsCPUWorkAndPreservesSource() throws {
        let base=try triangle(),archive=try ShapeMeshArchive.encode(base)
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:base,recipe:.init(),isCancelled:{true})) {XCTAssertTrue($0 is CancellationError)}
        var checks=0
        XCTAssertThrowsError(try ShapeMeshEditor.export(base:base,recipe:.init(),isCancelled:{checks+=1;return checks>=3})) {XCTAssertTrue($0 is CancellationError)}
        XCTAssertEqual(try ShapeMeshArchive.encode(base),archive)
    }

    func testDenseGeometryMaterialRoundTripsActualGLBAndUSDZWithBaseHashUnchanged() throws {
        // Synthetic known geometry; this is an edit/export test, not NN success.
        let side=393;var positions:[Float]=[]
        for y in 0..<side {for x in 0..<side{positions += [Float(x)/Float(side-1),Float(y)/Float(side-1),0]}}
        var indices:[UInt32]=[]
        for y in 0..<(side-1){for x in 0..<(side-1){let a=UInt32(y*side+x),b=a+1,c=a+UInt32(side),d=c+1;indices += [a,b,d,a,d,c]}}
        let ns=try ShapeAssetExporter.vertexNormals(vertices:positions,faces:indices).flatMap{[$0.0,$0.1,$0.2]}
        let base=try ShapeMeshBuffers(positions:positions,normals:ns,indices:indices),archive=try ShapeMeshArchive.encode(base)
        let digest=HunyuanShape21Configuration.digest(archive)
        let material=try ShapeWholeMaterial(rgba:[0.12,0.34,0.56,0.7],metallic:0.27,roughness:0.63)
        let recipe=try ShapeEditRecipe(translationXYZ:[0.3,-0.2,0.4],rotationXYZdegrees:[10,20,30],positiveScaleXYZ:[1.2,0.8,1.5],wholeMaterial:material)
        let result=try ShapeMeshEditor.export(base:base,recipe:recipe,baseArchiveData:archive)
        XCTAssertEqual(result.mesh.vertexCount,154449);XCTAssertEqual(result.mesh.triangleCount,307328)
        XCTAssertEqual(result.mesh.indices,indices);XCTAssertEqual(try ShapeMeshArchive.encode(base),archive)
        XCTAssertEqual(result.validationReceipt.baseMeshSHA256,digest)
        let decoded=try decodeGLB(result.glbData)
        XCTAssertEqual(decoded.positions,result.mesh.positions);XCTAssertEqual(decoded.normals,result.mesh.normals)
        let materials=try XCTUnwrap(decoded.json["materials"] as? [[String:Any]])
        let pbr=try XCTUnwrap(materials[0]["pbrMetallicRoughness"] as? [String:Any])
        let rgba=try XCTUnwrap(pbr["baseColorFactor"] as? [Double]);for(a,b)in zip(rgba,material.rgba){XCTAssertEqual(a,b,accuracy:1e-6)}
        XCTAssertEqual(try XCTUnwrap(pbr["metallicFactor"] as? Double),material.metallic,accuracy:1e-6)
        XCTAssertEqual(try XCTUnwrap(pbr["roughnessFactor"] as? Double),material.roughness,accuracy:1e-6)
        let usda=try usda(result.usdzData)
        XCTAssertEqual(try vectors(usda,marker:"point3f[] points = ["),result.mesh.positions)
        XCTAssertEqual(try vectors(usda,marker:"normal3f[] normals = ["),result.mesh.normals)
        XCTAssertTrue(usda.contains("rel material:binding = </Model/Looks/WholeMaterial>"))
        XCTAssertTrue(usda.contains("colorSpace = \"lin_p3d65_scene\""))
        XCTAssertTrue(usda.contains("float inputs:opacity = 0.7"));XCTAssertTrue(usda.contains("float inputs:metallic = 0.27"));XCTAssertTrue(usda.contains("float inputs:roughness = 0.63"))
        let nativeFolder=FileManager.default.temporaryDirectory.appending(path:"MeshEditNative-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:nativeFolder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:nativeFolder)}
        let nativeURL=nativeFolder.appending(path:"edited.usdz");try result.usdzData.write(to:nativeURL)
        let nativeScene=try SCNScene(url:nativeURL)
        var bound:SCNMaterial?
        nativeScene.rootNode.enumerateHierarchy { node,_ in if bound==nil{bound=node.geometry?.firstMaterial} }
        let boundMaterial=try XCTUnwrap(bound)
        XCTAssertEqual(boundMaterial.lightingModel,.physicallyBased)
        XCTAssertEqual(try XCTUnwrap(boundMaterial.metalness.contents as? NSNumber).doubleValue,material.metallic,accuracy:1e-5)
        XCTAssertEqual(try XCTUnwrap(boundMaterial.roughness.contents as? NSNumber).doubleValue,material.roughness,accuracy:1e-5)
        let opacityFactor=try XCTUnwrap(boundMaterial.transparent.contents as? NSNumber).doubleValue
        XCTAssertEqual(boundMaterial.transparency*opacityFactor,material.rgba[3],accuracy:1e-5)
        #if canImport(AppKit)
        let cgSpace=try XCTUnwrap(CGColorSpace(name:CGColorSpace.extendedLinearSRGB))
        let linearSpace=try XCTUnwrap(NSColorSpace(cgColorSpace:cgSpace))
        let sourceColor=try XCTUnwrap(boundMaterial.diffuse.contents as? NSColor)
        let color=try XCTUnwrap(sourceColor.usingColorSpace(linearSpace))
        XCTAssertEqual(Double(color.redComponent),material.rgba[0],accuracy:1e-5)
        XCTAssertEqual(Double(color.greenComponent),material.rgba[1],accuracy:1e-5)
        XCTAssertEqual(Double(color.blueComponent),material.rgba[2],accuracy:1e-5)
        #endif
        if let path=ProcessInfo.processInfo.environment["VOXAMBER_SHAPE_EDIT_TEST_OUTPUT"] {
            let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try archive.write(to:folder.appending(path:"base.glb"),options:.atomic)
            try result.glbData.write(to:folder.appending(path:"edited.glb"),options:.atomic)
            try result.usdzData.write(to:folder.appending(path:"edited.usdz"),options:.atomic)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(recipe).write(to:folder.appending(path:"recipe.json"),options:.atomic)
            try encoder.encode(result.validationReceipt).write(to:folder.appending(path:"edit-receipt.json"),options:.atomic)
        }
    }

    private func triangle(customNormals:Bool=false)throws->ShapeMeshBuffers {
        let a=Float(1/sqrt(3.0)),n:[Float]=customNormals ? [a,a,a,a,a,a,a,a,a] : [0,0,1,0,0,1,0,0,1]
        return try .init(positions:customNormals ? [1,0,0,0,1,0,0,0,1] : [1,0,0,0,1,0,0,0,0],normals:n,indices:[0,1,2])
    }
    private func u32(_ data:Data,_ offset:Int)->UInt32{data.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))}}
    private func decodeGLB(_ data:Data)throws->(json:[String:Any],positions:[Float],normals:[Float]) {
        let length=Int(u32(data,12)),json=try XCTUnwrap(JSONSerialization.jsonObject(with:data.subdata(in:20..<20+length)) as? [String:Any])
        let accessors=try XCTUnwrap(json["accessors"] as? [[String:Any]]),views=try XCTUnwrap(json["bufferViews"] as? [[String:Any]])
        XCTAssertEqual(accessors.count,3);XCTAssertEqual(views.count,3)
        func values(_ i:Int)throws->[Float]{let view=views[try XCTUnwrap(accessors[i]["bufferView"] as? Int)],count=try XCTUnwrap(accessors[i]["count"] as? Int)*3,offset=28+length+(view["byteOffset"] as? Int ?? 0);return (0..<count).map{Float(bitPattern:u32(data,offset+$0*4))}}
        return(json,try values(1),try values(2))
    }
    private func usda(_ data:Data)throws->String {
        let name=data.withUnsafeBytes{UInt16(littleEndian:$0.loadUnaligned(fromByteOffset:26,as:UInt16.self))},extra=data.withUnsafeBytes{UInt16(littleEndian:$0.loadUnaligned(fromByteOffset:28,as:UInt16.self))}
        let start=30+Int(name)+Int(extra),length=Int(u32(data,22))
        return try XCTUnwrap(String(data:data.subdata(in:start..<start+length),encoding:.utf8))
    }
    private func vectors(_ source:String,marker:String)throws->[Float] {
        let start=try XCTUnwrap(source.range(of:marker)),tail=source[start.upperBound...],end=try XCTUnwrap(tail.firstIndex(of:"]"))
        let text=tail[..<end].replacingOccurrences(of:"(",with:"").replacingOccurrences(of:")",with:"")
        return try text.split(separator:",").map{try XCTUnwrap(Float($0.trimmingCharacters(in:.whitespacesAndNewlines)))}
    }
}
