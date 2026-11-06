import Foundation
import SceneKit
import simd

@MainActor enum DualMaterialNativeProbe {
    static func validate(url:URL,mesh:GLBMesh,selection:FaceTextureSelection)throws->(SCNScene,[String:Any]) {
        let scene=try SCNScene(url:url,options:nil)
        var nodes:[SCNNode]=[]
        scene.rootNode.enumerateHierarchy{node,_ in if node.geometry != nil{nodes.append(node)}}
        var received=[String:Int](),materialRecords:[[String:Any]]=[]
        for node in nodes {
            guard let geometry=node.geometry,let source=geometry.sources(for:.vertex).first else{throw ProjectionError.nativeReadbackFailed}
            let points=try NativeReadback.floats(source,expectedComponents:3)
            let sourceIndex=geometry.sources.firstIndex(where:{$0 === source}) ?? 0
            let positionChannel=geometry.geometrySourceChannels?[sourceIndex].intValue ?? 0
            for (elementIndex,element) in geometry.elements.enumerated() where element.primitiveCount>0 {
                guard !geometry.materials.isEmpty,element.primitiveType == .triangles else{throw ProjectionError.nativeReadbackFailed}
                let material=geometry.materials[elementIndex%geometry.materials.count]
                let name=material.name ?? ""
                let key:String,faces:[Int]
                if name.contains("ReferenceImage") {key="ReferenceImage";faces=selection.imageFaces}
                else if name.contains("UnknownNeutral"){key="UnknownNeutral";faces=selection.neutralFaces}
                else{throw ProjectionError.nativeReadbackDetails("Native subset material name unrecognized: \(name)")}
                guard received[key]==nil,element.primitiveCount==faces.count,positionChannel<element.indicesChannelCount else{throw ProjectionError.nativeReadbackFailed}
                for (index,face) in faces.enumerated() {
                    for corner in 0..<3 {
                        let cornerIndex=index*3+corner
                        let entry=element.hasInterleavedIndicesChannels ? cornerIndex*element.indicesChannelCount+positionChannel : positionChannel*element.primitiveCount*3+cornerIndex
                        let offset=entry*element.bytesPerIndex
                        guard offset+element.bytesPerIndex<=element.data.count else{throw ProjectionError.nativeReadbackFailed}
                        let vertex:Int
                        if element.bytesPerIndex==4{vertex=Int(element.data.u32(offset))}
                        else if element.bytesPerIndex==2{vertex=element.data.withUnsafeBytes{Int($0.loadUnaligned(fromByteOffset:offset,as:UInt16.self).littleEndian)}}
                        else{throw ProjectionError.nativeReadbackFailed}
                        guard vertex*3+2<points.count else{throw ProjectionError.nativeReadbackFailed}
                        let world=node.simdWorldTransform*SIMD4(points[vertex*3],points[vertex*3+1],points[vertex*3+2],1)
                        let original=Int(mesh.indices[face*3+corner])
                        guard world==SIMD4(mesh.positions[original*3],mesh.positions[original*3+1],mesh.positions[original*3+2],1) else{throw ProjectionError.nativeReadbackFailed}
                    }
                }
                received[key]=faces.count
                materialRecords.append(["name":name,"role":key,"triangles":faces.count,
                    "positionIndexChannel":positionChannel,"indicesChannelCount":element.indicesChannelCount,
                    "interleavedIndexChannels":element.hasInterleavedIndicesChannels,
                    "diffuseContentType":material.diffuse.contents.map{String(describing:type(of:$0))} ?? "nil"])
            }
        }
        guard received["ReferenceImage",default:0]==selection.imageFaces.count,
              received["UnknownNeutral",default:0]==selection.neutralFaces.count,
              received.values.reduce(0,+)==mesh.triangleCount else{throw ProjectionError.nativeReadbackFailed}
        return(scene,["nativeDirectSCNURLWorldCoordinatesOrderWindingExact":true,
            "nativeFacePartitionCounts":received,"nativeMaterialRecords":materialRecords,
            "everyOriginalFaceAccountedForExactlyOnce":true,"rendererMaterialOverrides":false])
    }
}

@MainActor enum DualMaterialProbe {
    static func runSmall(output:URL) async throws {
        let mesh=try smallMesh(),png=try TextureCompatibilityProbe.texturePNG()
        let uv=[SIMD2<Float>(0.1,0.1),SIMD2(0.9,0.1),SIMD2(0.9,0.9),SIMD2(0.1,0.9)]
        let selection=FaceTextureSelection(imageFaces:[0],neutralFaces:[1],maskRejected:1,occluded:0,projectedDegenerate:0,pairTests:0)
        try await export(mesh:mesh,uv:uv,png:png,selection:selection,output:output,kind:"synthetic-dual-material-two-triangle-rectangle",extra:[:])
    }

    static func runLarge(source:URL,reference:URL,output:URL) async throws {
        let sourceData=try Data(contentsOf:source),png=try Data(contentsOf:reference)
        guard fileSHA(sourceData)=="42ea594bf5247fda74848ef2e958b27e09cee3d2d45529a61e0b0636ddcc2251",
              fileSHA(png)=="1bcadef55c9795d68cbce576cf57eabd7d6b7b87a22ba048c6fba8f7ca6521ae" else{throw CocoaError(.fileReadCorruptFile)}
        let mesh=try GLBMesh(data:sourceData),raster=try ReferenceRaster(png:png),start=Date()
        try DualMaterialTextureExporter.admit(vertices:mesh.vertexCount,triangles:mesh.triangleCount)
        let projected=try SingleViewProjector.project(positions:mesh.positions,indices:mesh.indices,reference:raster)
        let selection=try FaceTextureSelector.select(screen:projected.screenVertices,indices:mesh.indices,reference:raster)
        let uv=projected.screenVertices.map{SIMD2(Float($0.x/Double(raster.width)),Float($0.y/Double(raster.height)))}
        func area(_ face:Int)->Double {
            func p(_ corner:Int)->SIMD3<Double>{let i=Int(mesh.indices[face*3+corner])*3;return SIMD3(Double(mesh.positions[i]),Double(mesh.positions[i+1]),Double(mesh.positions[i+2]))}
            return simd_length(simd_cross(p(1)-p(0),p(2)-p(0)))/2
        }
        let allArea=(0..<mesh.triangleCount).reduce(0){$0+area($1)},imageArea=selection.imageFaces.reduce(0){$0+area($1)}
        let extra:[String:Any]=["baseStrictGLBSHA256":fileSHA(sourceData),"sourceReferencePNGSHA256":fileSHA(png),
            "maskRejectedFaces":selection.maskRejected,"occludedFaces":selection.occluded,
            "projectedDegenerateFaces":selection.projectedDegenerate,"continuousOverlapPairTests":selection.pairTests,
            "imageFaceFraction":Double(selection.imageFaces.count)/Double(mesh.triangleCount),
            "imageWorldSurfaceAreaFraction":imageArea/allArea,"imageWorldSurfaceArea":imageArea,"allWorldSurfaceArea":allArea,
            "selectionSeconds":Date().timeIntervalSince(start),"cameraDirectionAssumed":"+Z toward bbox center, Y up; uncalibrated",
            "maskCriterion":"Entire projected bounding rectangle plus bilinear footprint has alpha>=254; conservative false negatives allowed",
            "occlusionCriterion":"Projected triangle intersection and inverse-depth extrema, numerical tolerances only; internal blockers reject the whole face",
            "photographyLightingBakedIntoRGB":true,"unknownBackReconstructed":false,"newFoundationModels":0]
        try await export(mesh:mesh,uv:uv,png:png,selection:selection,output:output,kind:"actual-strict-neural-mesh-single-reference-dual-material",extra:extra)
        guard try Data(contentsOf:source)==sourceData,try Data(contentsOf:reference)==png else{throw CocoaError(.fileReadCorruptFile)}
    }

    private static func export(mesh:GLBMesh,uv:[SIMD2<Float>],png:Data,selection:FaceTextureSelection,output:URL,kind:String,extra:[String:Any]) async throws {
        guard !FileManager.default.fileExists(atPath:output.path) else{throw CocoaError(.fileWriteFileExists)}
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let start=Date(),glb=try DualMaterialTextureExporter.glb(mesh:mesh,uv:uv,png:png,selection:selection)
        let glbURL=output.appendingPathComponent("dual-material.glb"),usdzURL=output.appendingPathComponent("dual-material.usdz")
        try glb.write(to:glbURL,options:.withoutOverwriting)
        let glbProof=try DualMaterialTextureExporter.validateGLB(try Data(contentsOf:glbURL),against:mesh,png:png)
        try DualMaterialTextureExporter.usdz(mesh:mesh,uv:uv,png:png,selection:selection,to:usdzURL)
        let(scene,native)=try DualMaterialNativeProbe.validate(url:usdzURL,mesh:mesh,selection:selection)
        let views=try NativeReadback.views(scene:scene,mesh:mesh,output:output)
        var report=extra
        report.merge(["kind":kind,"NNCalls":0,"vertices":mesh.vertexCount,"triangles":mesh.triangleCount,
            "imageFaces":selection.imageFaces.count,"neutralFaces":selection.neutralFaces.count,
            "sourceVertexMap":"identity, original positions shared, no expansion","sourceTriangleMapLocation":"GLB each primitive extras.sourceTriangleMap",
            "GLBReadback":glbProof,"nativeUSDZReadback":native,"GLBSHA256":fileSHA(glb),
            "USDZSHA256":fileSHA(try Data(contentsOf:usdzURL)),"referencePNGSHA256":fileSHA(png),"nativeViews":views,
            "limits":["maximumVertices":2_000_000,"maximumTriangles":4_000_000,"maximumGLBBytes":256_000_000,"maximumUSDZBytes":512_000_000],
            "secondsBeforeQuickLook":Date().timeIntervalSince(start),"atlasUsed":false,"unknownMaterialSamplesImageOrAtlas":false,
            "productionOrPhoneTested":false,"PBRReconstruction":false]){_,new in new}
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("dual-material-result.json"),options:.withoutOverwriting)
        try await QuickLookColorProbe.run(url:usdzURL,output:output.appendingPathComponent("quicklook",isDirectory:true),sourceKind:kind)
        print("Dual-material native probe completed; acceptance requires reviewing the separate actual images/QuickLook result")
    }

    private static func smallMesh()throws->GLBMesh {
        let p:[Float]=[-0.6,-0.5,0,0.6,-0.5,0,0.6,0.5,0,-0.6,0.5,0],f:[UInt32]=[0,1,2,0,2,3]
        var binary=Data();for v in p{binary.appendLE(v.bitPattern)};for i in f{binary.appendLE(i)}
        let doc:[String:Any]=["asset":["version":"2.0"],"buffers":[["byteLength":binary.count]],
            "bufferViews":[["buffer":0,"byteOffset":0,"byteLength":48],["buffer":0,"byteOffset":48,"byteLength":24]],
            "accessors":[["bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-0.6,-0.5,0],"max":[0.6,0.5,0]],
                ["bufferView":1,"componentType":5125,"count":6,"type":"SCALAR"]],
            "meshes":[["primitives":[["attributes":["POSITION":0],"indices":1,"mode":4]]]],"nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0]
        var json=try JSONSerialization.data(withJSONObject:doc,options:[.sortedKeys]);while !json.count.isMultiple(of:4){json.append(32)}
        var data=Data();data.appendLE(UInt32(0x46546c67));data.appendLE(UInt32(2));data.appendLE(UInt32(28+json.count+binary.count))
        data.appendLE(UInt32(json.count));data.appendLE(UInt32(0x4e4f534a));data.append(json)
        data.appendLE(UInt32(binary.count));data.appendLE(UInt32(0x004e4942));data.append(binary)
        return try GLBMesh(data:data)
    }
}
