import Foundation
import XCTest
import CreationCore
import ThreeLiveNative

final class FreeformExportTests: XCTestCase {
    func testArbitraryMeshesLatheAndConcaveExtrusionExportThroughBothNativeFormats() throws {
        for primitive in [SceneNode.Primitive.mesh,.lathe,.extrusion] {
            let node=SceneNode.defaultNode(primitive:primitive,id:"freeform")
            let meshes=try SceneGenerator.generate(for:.init(name:"Freeform",nodes:[node]))
            let glb=try ThreeLiveNative.exportGLB(meshes)
            let usdz=try ThreeLiveNative.exportUSDZ(meshes)
            func read(_ data:Data,_ offset:Int,_ count:Int)->Int {
                (0..<count).reduce(0){$0 | Int(data[offset+$1]) << ($1*8)}
            }
            let jsonLength=read(glb,12,4)
            let json=try XCTUnwrap(JSONSerialization.jsonObject(with:glb[20..<(20+jsonLength)]) as? [String:Any])
            let exported=try XCTUnwrap(json["meshes"] as? [[String:Any]])
            XCTAssertEqual(exported.count,meshes.count)
            let payloadStart=30+read(usdz,26,2)+read(usdz,28,2)
            XCTAssertEqual(payloadStart%64,0)
            let text=try XCTUnwrap(String(data:usdz[payloadStart..<(payloadStart+read(usdz,18,4))],encoding:.utf8))
            XCTAssertTrue(text.contains("MaterialBindingAPI"))
            XCTAssertTrue(text.contains("subdivisionScheme = \"none\""))
            if let directory=ProcessInfo.processInfo.environment["THREELIVE_NATIVE_EVIDENCE_DIR"] {
                let url=URL(fileURLWithPath:directory,isDirectory:true)
                try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                try glb.write(to:url.appending(path:"freeform-"+primitive.rawValue+".glb"),options:.atomic)
                try usdz.write(to:url.appending(path:"freeform-"+primitive.rawValue+".usdz"),options:.atomic)
            }
        }
    }
}
