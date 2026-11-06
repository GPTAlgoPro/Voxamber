import Foundation
import simd

enum DualMaterialTextureExporter {
    static let maximumVertices=2_000_000,maximumTriangles=4_000_000
    static let maximumGLBBytes=256_000_000,maximumUSDZBytes=512_000_000

    static func admit(vertices:Int,triangles:Int,glbBytes:Int=0,usdzBytes:Int=0) throws {
        guard vertices>=3,vertices<=maximumVertices,triangles>0,triangles<=maximumTriangles,
              glbBytes>=0,glbBytes<=maximumGLBBytes,usdzBytes>=0,usdzBytes<=maximumUSDZBytes else {
            throw ProjectionError.invalidGeometry
        }
    }
    static func validatePartition(_ selection:FaceTextureSelection,triangles:Int) throws {
        guard selection.imageFaces.count+selection.neutralFaces.count==triangles else {throw ProjectionError.invalidGeometry}
        var seen=[Bool](repeating:false,count:triangles)
        for face in selection.imageFaces+selection.neutralFaces {
            guard face>=0,face<triangles,!seen[face] else {throw ProjectionError.invalidGeometry}
            seen[face]=true
        }
    }

    static func glb(mesh:GLBMesh,uv:[SIMD2<Float>],png:Data,selection:FaceTextureSelection) throws -> Data {
        try admit(vertices:mesh.vertexCount,triangles:mesh.triangleCount)
        try validatePartition(selection,triangles:mesh.triangleCount)
        guard uv.count==mesh.vertexCount,uv.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}),
              png.count<16*1024*1024 else {throw ProjectionError.invalidImage}
        var json=mesh.document,binary=mesh.binary
        var views=json["bufferViews"] as! [[String:Any]],accessors=json["accessors"] as! [[String:Any]]
        let originalMeshes=json["meshes"] as! [[String:Any]],originalPrimitives=originalMeshes[0]["primitives"] as! [[String:Any]]
        var attributes=originalPrimitives[0]["attributes"] as! [String:Int]
        attributes.removeValue(forKey:"COLOR_0")
        func appendView(_ bytes:Data,target:Int?=nil)->Int {
            while !binary.count.isMultiple(of:4){binary.append(0)}
            var view:[String:Any]=["buffer":0,"byteOffset":binary.count,"byteLength":bytes.count]
            if let target{view["target"]=target}
            let id=views.count;views.append(view);binary.append(bytes);return id
        }
        var normals=Data()
        for (index,value) in VertexColorUSDZ.normals(mesh).enumerated() {
            if index.isMultiple(of:4096){try Task.checkCancellation()}
            for axis in 0..<3 {normals.appendLE(value[axis].bitPattern)}
        }
        let normalView=appendView(normals,target:34962),normalID=accessors.count
        accessors.append(["bufferView":normalView,"componentType":5126,"count":mesh.vertexCount,"type":"VEC3"])
        attributes["NORMAL"]=normalID
        var coordinates=Data()
        for value in uv {coordinates.appendLE(value.x.bitPattern);coordinates.appendLE((1-value.y).bitPattern)}
        let uvView=appendView(coordinates,target:34962),uvID=accessors.count
        accessors.append(["bufferView":uvView,"componentType":5126,"count":mesh.vertexCount,"type":"VEC2"])
        attributes["TEXCOORD_0"]=uvID
        var primitives:[[String:Any]]=[]
        for (faces,material) in [(selection.imageFaces,0),(selection.neutralFaces,1)] where !faces.isEmpty {
            var indices=Data()
            for face in faces {for corner in 0..<3 {indices.appendLE(mesh.indices[face*3+corner])}}
            let view=appendView(indices,target:34963),id=accessors.count
            accessors.append(["bufferView":view,"componentType":5125,"count":faces.count*3,"type":"SCALAR"])
            primitives.append(["attributes":attributes,"indices":id,"mode":4,"material":material,
                "extras":["sourceTriangleMap":faces,"sourceVertexMapIsIdentity":true]])
        }
        let imageView=appendView(png)
        json["bufferViews"]=views;json["accessors"]=accessors
        json["buffers"]=[["byteLength":binary.count]];json["meshes"]=[["primitives":primitives]]
        json["images"]=[["bufferView":imageView,"mimeType":"image/png"]]
        json["textures"]=[["source":0,"sampler":0]]
        json["samplers"]=[["magFilter":9729,"minFilter":9729,"wrapS":33071,"wrapT":33071]]
        json["materials"]=[
            ["name":"ReferenceImage","doubleSided":true,"alphaMode":"OPAQUE","pbrMetallicRoughness":["baseColorFactor":[1,1,1,1],"baseColorTexture":["index":0,"texCoord":0],"metallicFactor":0,"roughnessFactor":0.7]],
            ["name":"UnknownNeutral","doubleSided":true,"alphaMode":"OPAQUE","pbrMetallicRoughness":["baseColorFactor":[0.18,0.18,0.18,1],"metallicFactor":0,"roughnessFactor":0.7]]]
        json["extras"]=["projection":"single-view image/unknown-neutral face partition","sourceVertexMapIsIdentity":true,
            "originalIndexBytesUnchangedClaimed":false,"sourceTriangleCount":mesh.triangleCount]
        var jsonData=try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys])
        while !jsonData.count.isMultiple(of:4){jsonData.append(32)}
        while !binary.count.isMultiple(of:4){binary.append(0)}
        let count=28+jsonData.count+binary.count
        try admit(vertices:mesh.vertexCount,triangles:mesh.triangleCount,glbBytes:count)
        var result=Data();result.appendLE(UInt32(0x46546c67));result.appendLE(UInt32(2));result.appendLE(UInt32(count))
        result.appendLE(UInt32(jsonData.count));result.appendLE(UInt32(0x4e4f534a));result.append(jsonData)
        result.appendLE(UInt32(binary.count));result.appendLE(UInt32(0x004e4942));result.append(binary)
        return result
    }

    /// Reopen actual active primitives and use the serialized sourceTriangleMap
    /// to prove every original corner coordinate, triangle order and winding.
    static func validateGLB(_ data:Data,against mesh:GLBMesh,png:Data) throws -> [String:Any] {
        guard data.count>=28,Int(data.u32(8))==data.count else{throw ProjectionError.invalidGLB}
        let length=Int(data.u32(12)),header=20+length
        guard header+8<=data.count,let json=try JSONSerialization.jsonObject(with:data.subdata(in:20..<header)) as? [String:Any],
              let meshes=json["meshes"] as? [[String:Any]],let primitives=meshes.first?["primitives"] as? [[String:Any]],
              let accessors=json["accessors"] as? [[String:Any]],let views=json["bufferViews"] as? [[String:Any]] else {throw ProjectionError.invalidGLB}
        let binary=data.subdata(in:(header+8)..<data.count)
        func accessor(_ id:Int)->Data {
            let a=accessors[id],v=views[a["bufferView"] as! Int]
            let offset=(v["byteOffset"] as? Int ?? 0)+(a["byteOffset"] as? Int ?? 0)
            let components=a["type"] as! String=="VEC3" ? 3 : 1
            return binary.subdata(in:offset..<(offset+(a["count"] as! Int)*components*4))
        }
        var seen=[Bool](repeating:false,count:mesh.triangleCount),visited=0
        for primitive in primitives {
            guard let attributes=primitive["attributes"] as? [String:Int],let positionID=attributes["POSITION"],
                  let indexID=primitive["indices"] as? Int,let extra=primitive["extras"] as? [String:Any],
                  let map=extra["sourceTriangleMap"] as? [Int] else {throw ProjectionError.invalidGLB}
            let points=accessor(positionID),indices=accessor(indexID)
            guard points==mesh.positionBytes,indices.count==map.count*12 else {throw ProjectionError.nativeReadbackFailed}
            for (index,face) in map.enumerated() {
                guard face>=0,face<mesh.triangleCount,!seen[face] else {throw ProjectionError.nativeReadbackFailed}
                seen[face]=true;visited+=1
                for corner in 0..<3 {
                    let actual=Int(indices.u32((index*3+corner)*4)),original=Int(mesh.indices[face*3+corner])
                    guard actual<mesh.vertexCount,actual==original else {throw ProjectionError.nativeReadbackFailed}
                    for axis in 0..<3 {
                        guard points.u32((actual*3+axis)*4)==mesh.positions[original*3+axis].bitPattern else {throw ProjectionError.nativeReadbackFailed}
                    }
                }
            }
        }
        guard visited==mesh.triangleCount,seen.allSatisfy({$0}),let images=json["images"] as? [[String:Any]],
              let imageView=images.first?["bufferView"] as? Int else{throw ProjectionError.nativeReadbackFailed}
        let image=views[imageView],offset=image["byteOffset"] as! Int,size=image["byteLength"] as! Int
        guard binary.subdata(in:offset..<(offset+size))==png else{throw ProjectionError.invalidImage}
        return ["activePrimitiveCount":primitives.count,"originalTriangleMapOneToOne":true,
            "everyOriginalTriangleWorldCoordinatesOrderWindingExact":true,"originalPositionBufferBytesIdentical":true,
            "wholeActiveIndexBufferBytesUnchangedClaimed":false,"sourceVertexMap":"identity, no expansion needed for this projection",
            "embeddedPNGExact":true]
    }

    static func usdz(mesh:GLBMesh,uv:[SIMD2<Float>],png:Data,selection:FaceTextureSelection,to url:URL) throws {
        try admit(vertices:mesh.vertexCount,triangles:mesh.triangleCount)
        try validatePartition(selection,triangles:mesh.triangleCount)
        guard uv.count==mesh.vertexCount,png.count<16*1024*1024 else{throw ProjectionError.invalidImage}
        let directory=url.deletingLastPathComponent(),stage=directory.appendingPathComponent("DualMaterial.usda"),image=directory.appendingPathComponent("reference.png")
        try png.write(to:image,options:.withoutOverwriting)
        let sink=try BoundedProjectionSink(stage,limit:maximumUSDZBytes-png.count-128*1024)
        try sink.append("""
        #usda 1.0
        (defaultPrim = "Model"
         upAxis = "Y"
         metersPerUnit = 1)
        def Xform "Model" {
          def Mesh "Geometry" (prepend apiSchemas = ["MaterialBindingAPI"]) {
            rel material:binding = </Model/Looks/UnknownNeutral>
            uniform token subdivisionScheme = "none"
            uniform bool doubleSided = true
            uniform token subsetFamily:materialBind:familyType = "partition"
            int[] faceVertexCounts = [
        """)
        for face in 0..<mesh.triangleCount{try sink.append(face==0 ? "3" : ",3")}
        try sink.append("]\nint[] faceVertexIndices = [")
        for (i,value) in mesh.indices.enumerated(){try sink.append(i==0 ? String(value) : ",\(value)")}
        try sink.append("]\npoint3f[] points = [")
        for i in 0..<mesh.vertexCount {
            let value="(\(mesh.positions[i*3]),\(mesh.positions[i*3+1]),\(mesh.positions[i*3+2]))"
            try sink.append(i==0 ? value : ","+value)
        }
        try sink.append("]\nnormal3f[] normals = [")
        for (i,n) in VertexColorUSDZ.normals(mesh).enumerated(){let value="(\(n.x),\(n.y),\(n.z))";try sink.append(i==0 ? value : ","+value)}
        try sink.append("] (interpolation = \"vertex\")\ntexCoord2f[] primvars:st = [")
        for (i,index) in mesh.indices.enumerated(){let p=uv[Int(index)],value="(\(p.x),\(p.y))";try sink.append(i==0 ? value : ","+value)}
        try sink.append("] (interpolation = \"faceVarying\")\n")
        for (name,faces) in [("ReferenceImage",selection.imageFaces),("UnknownNeutral",selection.neutralFaces)] where !faces.isEmpty {
            try sink.append("def GeomSubset \"\(name)Faces\" (prepend apiSchemas = [\"MaterialBindingAPI\"]) {\nuniform token elementType = \"face\"\nuniform token familyName = \"materialBind\"\nint[] indices = [")
            for (i,face) in faces.enumerated(){try sink.append(i==0 ? String(face) : ",\(face)")}
            try sink.append("]\nrel material:binding = </Model/Looks/\(name)>\n}\n")
        }
        try sink.append("}\ndef Scope \"Looks\" {\n")
        let gray=try LinearP3Converter().convert(SIMD4(0.18,0.18,0.18,1))
        try sink.append("""
        def Material "UnknownNeutral" {
          token outputs:surface.connect = </Model/Looks/UnknownNeutral/Surface.outputs:surface>
          def Shader "Surface" {
            uniform token info:id = "UsdPreviewSurface"
            color3f inputs:diffuseColor = (\(gray.x),\(gray.y),\(gray.z)) (colorSpace = "lin_p3d65_scene")
            float inputs:metallic = 0
            float inputs:roughness = 0.7
            token outputs:surface
          }
        }
        def Material "ReferenceImage" {
          token outputs:surface.connect = </Model/Looks/ReferenceImage/Surface.outputs:surface>
          def Shader "Surface" {
            uniform token info:id = "UsdPreviewSurface"
            color3f inputs:diffuseColor.connect = </Model/Looks/ReferenceImage/Texture.outputs:rgb>
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
            asset inputs:file = @reference.png@
            float2 inputs:st.connect = </Model/Looks/ReferenceImage/UV.outputs:result>
            token inputs:sourceColorSpace = "sRGB"
            token inputs:wrapS = "clamp"
            token inputs:wrapT = "clamp"
            float3 outputs:rgb
          }
        }
        }
        }
        """)
        try sink.finish()
        try USDZArchiveWriter.write(entries:[.init(archivePath:"DualMaterial.usda",sourceURL:stage),.init(archivePath:"reference.png",sourceURL:image)],to:url)
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max
        try admit(vertices:mesh.vertexCount,triangles:mesh.triangleCount,usdzBytes:size)
    }
}

private final class BoundedProjectionSink {
    let file:FileHandle,limit:Int
    var bytes=0,buffer=""
    init(_ url:URL,limit:Int)throws {
        guard !FileManager.default.fileExists(atPath:url.path),FileManager.default.createFile(atPath:url.path,contents:nil) else{throw CocoaError(.fileWriteFileExists)}
        file=try FileHandle(forWritingTo:url);self.limit=limit
    }
    func append(_ text:String)throws {
        guard text.utf8.count<=limit-bytes else{throw CocoaError(.fileWriteOutOfSpace)}
        bytes+=text.utf8.count;buffer+=text
        if buffer.utf8.count>=256*1024 {try Task.checkCancellation();try file.write(contentsOf:Data(buffer.utf8));buffer.removeAll(keepingCapacity:true)}
    }
    func finish()throws{try file.write(contentsOf:Data(buffer.utf8));buffer="";try file.close()}
}
