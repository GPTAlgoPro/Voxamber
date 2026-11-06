import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SceneKit
import ModelIO
import simd

/// A single, synthetic 3-vertex format probe. This is not a mesh UV unwrapper.
@MainActor enum TextureCompatibilityProbe {
    static let positions:[Float]=[0,0,0,1.2,0,0,0.15,0.9,0]
    static let indices:[UInt32]=[0,1,2]
    static let usdUV:[Float]=[0.1,0.1,0.9,0.2,0.2,0.9]

    static func run(output: URL) async throws {
        guard !FileManager.default.fileExists(atPath:output.path) else {throw CocoaError(.fileWriteFileExists)}
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let png=try texturePNG(),baseData=try glb(png:nil),data=try glb(png:png)
        let base=try GLBMesh(data:baseData),textured=try GLBMesh(data:data)
        guard base.positionBytes==textured.positionBytes,base.indexBytes==textured.indexBytes,
              base.positions==positions,base.indices==indices else {throw ProjectionError.invalidGeometry}
        try baseData.write(to:output.appendingPathComponent("synthetic-base.glb"),options:.withoutOverwriting)
        try data.write(to:output.appendingPathComponent("synthetic-textured-triangle.glb"),options:.withoutOverwriting)
        let embedded=try embeddedPNG(textured)
        guard embedded==png else {throw ProjectionError.invalidImage}
        let textureDirectory=output.appendingPathComponent("textures",isDirectory:true)
        try FileManager.default.createDirectory(at:textureDirectory,withIntermediateDirectories:false)
        let textureURL=textureDirectory.appendingPathComponent("fixture.png")
        try png.write(to:textureURL,options:.withoutOverwriting)
        let stage=output.appendingPathComponent("Textured.usda")
        try usdSource().write(to:stage,atomically:false,encoding:.utf8)
        let usdz=output.appendingPathComponent("synthetic-textured-triangle.usdz")
        try USDZArchiveWriter.write(entries:[.init(archivePath:"Textured.usda",sourceURL:stage),
            .init(archivePath:"fixture.png",sourceURL:textureURL)],to:usdz)
        let scene=try SCNScene(url:usdz,options:nil)
        var geometryNodes:[SCNNode]=[]
        scene.rootNode.enumerateHierarchy {node,_ in if node.geometry != nil {geometryNodes.append(node)}}
        guard geometryNodes.count==1,let nativeNode=geometryNodes.first,let geometry=nativeNode.geometry,
              let p=geometry.sources(for:.vertex).first,
              try NativeReadback.floats(p,expectedComponents:3)==positions else {throw ProjectionError.nativeReadbackFailed}
        for index in 0..<3 {
            let world=nativeNode.simdWorldTransform*SIMD4(positions[index*3],positions[index*3+1],positions[index*3+2],1)
            guard world==SIMD4(positions[index*3],positions[index*3+1],positions[index*3+2],1) else {throw ProjectionError.nativeReadbackFailed}
        }
        let positionSourceIndex=geometry.sources.firstIndex(where:{$0 === p}) ?? 0
        let positionChannel=geometry.geometrySourceChannels?[positionSourceIndex].intValue ?? 0
        let nativeIndices=try geometry.elements.flatMap {element -> [UInt32] in
            guard element.primitiveType == .triangles,element.bytesPerIndex==2 || element.bytesPerIndex==4 else {throw ProjectionError.nativeReadbackFailed}
            guard positionChannel<element.indicesChannelCount else {throw ProjectionError.nativeReadbackFailed}
            return (0..<(element.primitiveCount*3)).map {index in
                let entry=element.hasInterleavedIndicesChannels ? index*element.indicesChannelCount+positionChannel : positionChannel*element.primitiveCount*3+index
                let offset=entry*element.bytesPerIndex
                return element.bytesPerIndex==4 ? element.data.u32(offset) : element.data.withUnsafeBytes{UInt32($0.loadUnaligned(fromByteOffset:offset,as:UInt16.self).littleEndian)}
            }
        }
        guard nativeIndices==indices,let uv=geometry.sources(for:.texcoord).first else {throw ProjectionError.nativeReadbackFailed}
        let nativeUV=try NativeReadback.floats(uv,expectedComponents:2)
        let diffuse=geometry.materials.first?.diffuse.contents
        let nativeAsset=MDLAsset(url:usdz)
        let mdlMeshes=nativeAsset.childObjects(of:MDLMesh.self) as? [MDLMesh] ?? []
        let mdlMaterial=(mdlMeshes.first?.submeshes?.firstObject as? MDLSubmesh)?.material
        let property=mdlMaterial?.property(with:.baseColor)
        let nativeTexturePresent=property?.textureSamplerValue?.texture != nil
        let views=try NativeReadback.views(scene:scene,mesh:base,output:output)
        let report:[String:Any]=["condition":"Synthetic asymmetric RGB image embedded as a real native UV texture, not a viewport overlay",
            "NNCalls":0,"newFoundationModels":0,"vertices":3,"triangles":1,
            "sourceVertexMap":[0,1,2],"vertexExpansionNeededForThisSingleTriangle":false,
            "eachOriginalTriangleWorldCoordinatesOrderAndWindingExactlyPreserved":true,
            "GLBPositionAndIndexBytesUnchangedForThisSmallFixtureOnly":true,
            "USDZUsesFaceVaryingUV":true,"USDZOriginalPointsAndFaceIndicesUnchanged":true,
            "USDZCanonicalBottomLeftUV":usdUV,"nativeSCNReadbackUV":nativeUV,
            "nativeSCNGeometrySourceChannels":geometry.geometrySourceChannels ?? [],
            "nativeSCNPositionIndexChannel":positionChannel,
            "GLBTopLeftUVVEqualsOneMinusUSDV":true,"embeddedGLBPNGExactSHA256":fileSHA(embedded),
            "sourcePNGSHA256":fileSHA(png),"baseGLBSHA256":fileSHA(baseData),"GLBSHA256":fileSHA(data),
            "USDZSHA256":fileSHA(try Data(contentsOf:usdz)),"nativeSCNTextureContentPresent":diffuse != nil,
            "nativeSCNTextureContentType":diffuse.map{String(describing:type(of:$0))} ?? "nil",
            "nativeMDLBaseColorTextureLoaded":nativeTexturePresent,"nativeViews":views,
            "referenceMeshOrVaseReprocessed":false,"productionRealityKitOrPhoneTested":false,
            "limits":["Only one synthetic triangle; no general atlas, unwrapping, seam handling or large-mesh texture quality is implemented.",
                "General GLB UV seams can require vertex expansion. Future validation must compare per-original-triangle world coordinates/order/winding using a sourceVertexMap, rather than promise unchanged buffers.",
                "A standard texture material is used; this synthetic RGB fixture is not learned PBR or a neural result."]]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("texture-result.json"),options:.withoutOverwriting)
        try await QuickLookColorProbe.run(url:usdz,output:output.appendingPathComponent("quicklook",isDirectory:true))
        guard try Data(contentsOf:output.appendingPathComponent("synthetic-base.glb"))==baseData else {throw CocoaError(.fileReadCorruptFile)}
        print("Synthetic native UV texture probe completed; read texture-result.json and the separate QuickLook observation")
    }

    nonisolated static func texturePNG() throws -> Data {
        var pixels=[UInt8](repeating:255,count:64*64*4)
        for row in 0..<64 {
            for x in 0..<64 {
                let rgb:[UInt8]=row<24 ? [255,0,0] : (x<38 ? [0,255,0] : [0,0,255])
                for axis in 0..<3 {pixels[(row*64+x)*4+axis]=rgb[axis]}
            }
        }
        guard let provider=CGDataProvider(data:Data(pixels) as CFData),let space=CGColorSpace(name:CGColorSpace.sRGB),
              let image=CGImage(width:64,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,space:space,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,
                decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw ProjectionError.invalidImage}
        let data=NSMutableData()
        guard let writer=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {throw ProjectionError.invalidImage}
        CGImageDestinationAddImage(writer,image,nil)
        guard CGImageDestinationFinalize(writer) else {throw ProjectionError.invalidImage}
        return data as Data
    }

    private static func glb(png: Data?) throws -> Data {
        var bytes=Data()
        for value in positions {bytes.appendLE(value.bitPattern)}
        for _ in 0..<3 {for value:Float in [0,0,1] {bytes.appendLE(value.bitPattern)}}
        for index in 0..<3 {bytes.appendLE(usdUV[index*2].bitPattern);bytes.appendLE((1-usdUV[index*2+1]).bitPattern)}
        for value in indices {bytes.appendLE(value)}
        var views:[[String:Any]]=[["buffer":0,"byteOffset":0,"byteLength":36,"target":34962],
            ["buffer":0,"byteOffset":36,"byteLength":36,"target":34962],
            ["buffer":0,"byteOffset":72,"byteLength":24,"target":34962],
            ["buffer":0,"byteOffset":96,"byteLength":12,"target":34963]]
        var primitive:[String:Any]=["attributes":["POSITION":0,"NORMAL":1,"TEXCOORD_0":2],"indices":3,"mode":4]
        var object:[String:Any]=["asset":["version":"2.0","generator":"isolated CPU native texture compatibility probe"],
            "accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1.2,0.9,0]],
                ["bufferView":1,"componentType":5126,"count":3,"type":"VEC3"],
                ["bufferView":2,"componentType":5126,"count":3,"type":"VEC2"],
                ["bufferView":3,"componentType":5125,"count":3,"type":"SCALAR"]],
            "nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0]
        if let png {
            views.append(["buffer":0,"byteOffset":bytes.count,"byteLength":png.count]);bytes.append(png)
            primitive["material"]=0
            object["images"]=[["bufferView":4,"mimeType":"image/png"]]
            object["samplers"]=[["magFilter":9729,"minFilter":9729,"wrapS":33071,"wrapT":33071]]
            object["textures"]=[["source":0,"sampler":0]]
            object["materials"]=[["doubleSided":true,"alphaMode":"OPAQUE","pbrMetallicRoughness":["baseColorFactor":[1,1,1,1],"baseColorTexture":["index":0,"texCoord":0],"metallicFactor":0,"roughnessFactor":0.7]]]
        }
        object["bufferViews"]=views;object["buffers"]=[["byteLength":bytes.count]]
        object["meshes"]=[["primitives":[primitive]]]
        while !bytes.count.isMultiple(of:4) {bytes.append(0)}
        var json=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);while !json.count.isMultiple(of:4){json.append(32)}
        var result=Data();result.appendLE(UInt32(0x46546c67));result.appendLE(UInt32(2));result.appendLE(UInt32(28+json.count+bytes.count))
        result.appendLE(UInt32(json.count));result.appendLE(UInt32(0x4e4f534a));result.append(json)
        result.appendLE(UInt32(bytes.count));result.appendLE(UInt32(0x004e4942));result.append(bytes)
        return result
    }

    private static func embeddedPNG(_ mesh: GLBMesh) throws -> Data {
        guard let images=mesh.document["images"] as? [[String:Any]],images.count==1,images[0]["mimeType"] as? String=="image/png",
              let id=images[0]["bufferView"] as? Int,let views=mesh.document["bufferViews"] as? [[String:Any]],views.indices.contains(id),
              let offset=views[id]["byteOffset"] as? Int,let length=views[id]["byteLength"] as? Int else {throw ProjectionError.invalidImage}
        return mesh.binary.subdata(in:offset..<(offset+length))
    }

    private static func usdSource() -> String {
        """
        #usda 1.0
        (defaultPrim = "Model"
         upAxis = "Y"
         metersPerUnit = 1)
        def Xform "Model" {
          def Mesh "Triangle" (prepend apiSchemas = ["MaterialBindingAPI"]) {
            rel material:binding = </Model/Looks/Textured>
            uniform token subdivisionScheme = "none"
            uniform bool doubleSided = true
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0,1,2]
            point3f[] points = [(0,0,0),(1.2,0,0),(0.15,0.9,0)]
            normal3f[] normals = [(0,0,1),(0,0,1),(0,0,1)] (interpolation = "vertex")
            texCoord2f[] primvars:st = [(0.1,0.1),(0.9,0.2),(0.2,0.9)] (interpolation = "faceVarying")
          }
          def Scope "Looks" {
            def Material "Textured" {
              token outputs:surface.connect = </Model/Looks/Textured/Surface.outputs:surface>
              def Shader "Surface" {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor.connect = </Model/Looks/Textured/Texture.outputs:rgb>
                float inputs:metallic = 0
                float inputs:roughness = 0.7
                float inputs:opacity = 1
                token outputs:surface
              }
              def Shader "UV" {
                uniform token info:id = "UsdPrimvarReader_float2"
                string inputs:varname = "st"
                float2 outputs:result
              }
              def Shader "Texture" {
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @fixture.png@
                float2 inputs:st.connect = </Model/Looks/Textured/UV.outputs:result>
                token inputs:sourceColorSpace = "sRGB"
                token inputs:wrapS = "clamp"
                token inputs:wrapT = "clamp"
                float3 outputs:rgb
              }
            }
          }
        }
        """
    }
}
