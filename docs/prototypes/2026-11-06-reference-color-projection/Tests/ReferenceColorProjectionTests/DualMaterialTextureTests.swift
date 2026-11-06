import Foundation
import Testing
import simd
import ModelIO
@testable import ReferenceColorProjection

@Suite struct DualMaterialTextureTests {
    private var selection:FaceTextureSelection {
        .init(imageFaces:[1],neutralFaces:[0],maskRejected:1,occluded:0,projectedDegenerate:0,pairTests:0)
    }
    @Test func groupedPrimitivesKeepEveryOriginalTriangleThroughTheExplicitMap() throws {
        let mesh=try fixture(),png=try TextureCompatibilityProbe.texturePNG(),uv=[SIMD2<Float>(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)]
        let data=try DualMaterialTextureExporter.glb(mesh:mesh,uv:uv,png:png,selection:selection)
        let proof=try DualMaterialTextureExporter.validateGLB(data,against:mesh,png:png)
        #expect(proof["everyOriginalTriangleWorldCoordinatesOrderWindingExact"] as? Bool==true)
        #expect(proof["wholeActiveIndexBufferBytesUnchangedClaimed"] as? Bool==false)
        let length=Int(data.u32(12)),object=try #require(JSONSerialization.jsonObject(with:data.subdata(in:20..<(20+length))) as? [String:Any])
        let primitives=try #require((object["meshes"] as? [[String:Any]])?.first?["primitives"] as? [[String:Any]])
        #expect((primitives[0]["extras"] as? [String:Any])?["sourceTriangleMap"] as? [Int]==[1])
        #expect((primitives[1]["extras"] as? [String:Any])?["sourceTriangleMap"] as? [Int]==[0])
    }
    @Test func swappedSerializedWindingIsRejected() throws {
        let mesh=try fixture(),png=try TextureCompatibilityProbe.texturePNG(),uv=[SIMD2<Float>](repeating:SIMD2(0.5,0.5),count:4)
        var data=try DualMaterialTextureExporter.glb(mesh:mesh,uv:uv,png:png,selection:selection)
        let length=Int(data.u32(12)),object=try #require(JSONSerialization.jsonObject(with:data.subdata(in:20..<(20+length))) as? [String:Any])
        let primitive=try #require(((object["meshes"] as? [[String:Any]])?.first?["primitives"] as? [[String:Any]])?.first)
        let accessors=try #require(object["accessors"] as? [[String:Any]]),views=try #require(object["bufferViews"] as? [[String:Any]])
        let id=try #require(primitive["indices"] as? Int),view=views[try #require(accessors[id]["bufferView"] as? Int)]
        let offset=28+length+(try #require(view["byteOffset"] as? Int))
        let first=data.subdata(in:(offset+4)..<(offset+8)),second=data.subdata(in:(offset+8)..<(offset+12))
        data.replaceSubrange((offset+4)..<(offset+8),with:second);data.replaceSubrange((offset+8)..<(offset+12),with:first)
        #expect(throws:ProjectionError.self){try DualMaterialTextureExporter.validateGLB(data,against:mesh,png:png)}
    }
    @Test func missingOrDuplicateFaceMappingIsRejected() throws {
        let bad=FaceTextureSelection(imageFaces:[0],neutralFaces:[0],maskRejected:0,occluded:0,projectedDegenerate:0,pairTests:0)
        #expect(throws:ProjectionError.self){try DualMaterialTextureExporter.validatePartition(bad,triangles:2)}
        #expect(throws:ProjectionError.self){try DualMaterialTextureExporter.validatePartition(selection,triangles:3)}
    }
    @Test func resourceCapsAreHardUpperBoundsWithoutAllocatingHugeFixtures() throws {
        try DualMaterialTextureExporter.admit(vertices:2_000_000,triangles:4_000_000,glbBytes:256_000_000,usdzBytes:512_000_000)
        #expect(throws:ProjectionError.self){try DualMaterialTextureExporter.admit(vertices:2_000_001,triangles:1)}
        #expect(throws:ProjectionError.self){try DualMaterialTextureExporter.admit(vertices:3,triangles:4_000_001)}
        #expect(throws:ProjectionError.self){try DualMaterialTextureExporter.admit(vertices:3,triangles:1,glbBytes:256_000_001)}
        #expect(throws:ProjectionError.self){try DualMaterialTextureExporter.admit(vertices:3,triangles:1,usdzBytes:512_000_001)}
    }
    @Test func realNativeCPUParserReadsBothGeomSubsetMaterialsAndOriginalTriangleCount() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("dual-material-cpu-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("native.usdz"),mesh=try fixture()
        let uv=[SIMD2<Float>(0.1,0.1),SIMD2(0.9,0.1),SIMD2(0.9,0.9),SIMD2(0.1,0.9)]
        try DualMaterialTextureExporter.usdz(mesh:mesh,uv:uv,png:TextureCompatibilityProbe.texturePNG(),selection:selection,to:url)
        let asset=MDLAsset(url:url),meshes=asset.childObjects(of:MDLMesh.self) as? [MDLMesh] ?? []
        let native=try #require(meshes.first),submeshes=try #require(native.submeshes as? [MDLSubmesh])
        #expect(meshes.count==1 && submeshes.count==2)
        #expect(submeshes.reduce(0){$0+$1.indexCount}==6)
        #expect(Set(submeshes.compactMap{$0.material?.name})==Set(["ReferenceImage","UnknownNeutral"]))
    }

    private func fixture() throws -> GLBMesh {
        let points:[Float]=[0,0,0,1,0,0,1,1,0,0,1,0],faces:[UInt32]=[0,1,2,0,2,3]
        var binary=Data();for p in points{binary.appendLE(p.bitPattern)};for i in faces{binary.appendLE(i)}
        let object:[String:Any]=["asset":["version":"2.0"],"buffers":[["byteLength":binary.count]],
            "bufferViews":[["buffer":0,"byteOffset":0,"byteLength":48],["buffer":0,"byteOffset":48,"byteLength":24]],
            "accessors":[["bufferView":0,"componentType":5126,"count":4,"type":"VEC3"],["bufferView":1,"componentType":5125,"count":6,"type":"SCALAR"]],
            "meshes":[["primitives":[["attributes":["POSITION":0],"indices":1,"mode":4]]]],"nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0]
        var json=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);while !json.count.isMultiple(of:4){json.append(32)}
        var data=Data();data.appendLE(UInt32(0x46546c67));data.appendLE(UInt32(2));data.appendLE(UInt32(28+json.count+binary.count))
        data.appendLE(UInt32(json.count));data.appendLE(UInt32(0x4e4f534a));data.append(json)
        data.appendLE(UInt32(binary.count));data.appendLE(UInt32(0x004e4942));data.append(binary)
        return try GLBMesh(data:data)
    }
}
