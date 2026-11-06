import Foundation
import CryptoKit
import simd

func fileSHA(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }

@main enum ProjectionCLI {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        if args.count==3,args[1]=="--dual-material-smoke" {
            try await DualMaterialProbe.runSmall(output:URL(fileURLWithPath:args[2],isDirectory:true));return
        }
        if args.count==5,args[1]=="--dual-material-large" {
            try await DualMaterialProbe.runLarge(source:URL(fileURLWithPath:args[2]),reference:URL(fileURLWithPath:args[3]),output:URL(fileURLWithPath:args[4],isDirectory:true));return
        }
        if args.count==3,args[1]=="--texture-smoke" {
            try await TextureCompatibilityProbe.run(output:URL(fileURLWithPath:args[2],isDirectory:true))
            return
        }
        if args.count==4,args[1]=="--quicklook-smoke" {
            try await QuickLookColorProbe.run(url:URL(fileURLWithPath:args[2]),output:URL(fileURLWithPath:args[3],isDirectory:true))
            return
        }
        guard args.count==4 else { throw CocoaError(.fileReadInvalidFileName) }
        let source=URL(fileURLWithPath:args[1]),image=URL(fileURLWithPath:args[2]),output=URL(fileURLWithPath:args[3],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:output.path) else { throw CocoaError(.fileWriteFileExists) }
        let baseData=try Data(contentsOf:source),png=try Data(contentsOf:image)
        guard fileSHA(baseData)=="42ea594bf5247fda74848ef2e958b27e09cee3d2d45529a61e0b0636ddcc2251",
              fileSHA(png)=="1bcadef55c9795d68cbce576cf57eabd7d6b7b87a22ba048c6fba8f7ca6521ae" else { throw CocoaError(.fileReadCorruptFile) }
        let start=Date(),mesh=try GLBMesh(data:baseData)
        guard mesh.vertexCount==200370,mesh.triangleCount==400772 else { throw ProjectionError.invalidGeometry }
        let reference=try ReferenceRaster(png:png)
        print("CPU projection: fixed geometry \(mesh.vertexCount) vertices / \(mesh.triangleCount) triangles")
        let projected=try SingleViewProjector.project(positions:mesh.positions,indices:mesh.indices,reference:reference)
        print("CPU projection: \(projected.coloredVertices) image-colored vertices, \(mesh.vertexCount-projected.coloredVertices) neutral unknown vertices")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let glb=try mesh.exporting(colors:projected.colors),glbURL=output.appendingPathComponent("projected.glb")
        try glb.write(to:glbURL,options:.withoutOverwriting)
        let reopened=try GLBMesh(data:glb)
        guard reopened.positionBytes==mesh.positionBytes,reopened.indexBytes==mesh.indexBytes,
              try reopened.colors()==projected.colors else { throw ProjectionError.nativeReadbackFailed }
        print("GLB COLOR_0 and original geometry bytes read back exactly")
        let usdzURL=output.appendingPathComponent("projected.usdz")
        let p3=try VertexColorUSDZ.export(mesh:mesh,colors:projected.colors,to:usdzURL)
        let (scene,native)=try NativeReadback.validate(url:usdzURL,original:mesh,p3Colors:p3)
        print("USDZ native geometry and vertex colors read back")
        let snapshots=try NativeReadback.views(scene:scene,mesh:mesh,output:output)
        guard try Data(contentsOf:source)==baseData,try Data(contentsOf:image)==png else { throw CocoaError(.fileReadCorruptFile) }
        let report:[String:Any]=["kind":"CPU single-view reference-color projection, not multi-view or PBR reconstruction",
            "vertexCount":mesh.vertexCount,"triangleCount":mesh.triangleCount,"baseGLBSHA256":fileSHA(baseData),
            "referencePNGSHA256":fileSHA(png),"newFoundationModels":0,"neuralCallsDuringThisPostprocess":0,
            "coloredVertices":projected.coloredVertices,"neutralUnknownVertices":mesh.vertexCount-projected.coloredVertices,
            "frontVisibleVertices":projected.frontVisibleVertices,"occupiedDepthPixels":projected.occupiedDepthPixels,
            "visibility":"Continuous projected ray/triangle closest depth; 128x128 acceleration bins, only Double numerical tolerance, no physical-thickness tolerance",
            "neutralLinearRec709RGBA":[0.18,0.18,0.18,1],"referenceAlphaBoundsXYWH":[projected.referenceBounds.minX,projected.referenceBounds.minY,projected.referenceBounds.width,projected.referenceBounds.height],
            "cameraAssumption":["direction":"+Z toward bboxcenter, Yup","distance":projected.cameraDistance,"fieldOfViewDegrees":42,"alphaBoxFit":"uniform, inset1pixel; not calibrated training/image camera"],
            "positionsAndIndexBytesUnchanged":true,"vertexCountWindingTopologyUnchanged":true,"baseFilesUnmodified":true,
            "GLBCOLOR0ExactFloatReadback":true,"GLBVertexColorSpace":"linear Rec709","USDZVertexColorSpace":"lin_p3d65_scene via native CoreGraphics basis conversion",
            "nativeUSDZReadback":native,"nativeViews":snapshots,"GLBSHA256":fileSHA(glb),"USDZSHA256":fileSHA(try Data(contentsOf:usdzURL)),
            "seconds":Date().timeIntervalSince(start),"unknownBackObserved":false,"physicalMetresEstablished":false,
            "limitations":["Single-image camera/DINO alignment is approximate; no correspondence calibration.","Reference lighting is baked into RGB, not recovered albedo/PBR.","Back/occluded/mask-missing vertices remain neutral; interpolation can transition at shared silhouette vertices.","No topology repair, geometry movement or new neural model; strict input is still not watertight."]]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"),options:.atomic)
        print("CPU PROJECTION COMPLETE \(projected.coloredVertices)/\(mesh.vertexCount) vertices; native USDZ and two geometry views verified")
    }
}
