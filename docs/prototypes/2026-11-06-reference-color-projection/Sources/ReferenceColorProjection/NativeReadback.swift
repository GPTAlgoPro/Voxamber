import Foundation
import SceneKit
import SceneKit.ModelIO
import ModelIO
import AppKit
import ImageIO
import UniformTypeIdentifiers
import simd

enum NativeReadback {
    static func validate(url: URL, original: GLBMesh, p3Colors: [SIMD3<Float>]) throws -> (SCNScene, [String: Any]) {
        let directScene=try SCNScene(url:url,options:nil)
        let directGeometry=try geometry(in:directScene)
        try validateGeometry(directGeometry,original:original)
        var report:[String:Any]=["nativeTriangles":original.triangleCount,
            "nativeVertices":original.vertexCount,"positionsExactlySame":true,
            "indicesAndWindingExactlySame":true,
            "directSCNURLColorSourcePresent":directGeometry.sources(for:.color).first != nil]
        if let source=directGeometry.sources(for:.color).first {
            let error=try validateColors(try floats(source,expectedComponents:source.componentsPerVector),
                components:source.componentsPerVector,count:source.vectorCount,expected:p3Colors)
            report["nativeColorReadbackImporter"]="SCNScene(url: USDZ)"
            report["nativeColorMaxAbsoluteP3Error"]=error
            report["nativeVertexColorReadbackPassed"]=true
            report["renderSceneImporter"]="SCNScene(url: USDZ)"
            return (directScene,report)
        }

        // The direct USDZ SceneKit importer currently omits displayColor. The
        // native ModelIO importer reads it from the serialized asset; its
        // standard SceneKit bridge preserves the attribute without recoloring
        // geometry or changing materials in the renderer.
        let asset=MDLAsset(url:url)
        let meshes=asset.childObjects(of:MDLMesh.self) as? [MDLMesh] ?? []
        guard meshes.count==1,let mesh=meshes.first,mesh.vertexCount==original.vertexCount,
              let attribute=mesh.vertexAttributeData(forAttributeNamed:MDLVertexAttributeColor,as:.float4) else {
            throw ProjectionError.nativeReadbackDetails("Native ModelIO did not expose one vertex-colored mesh")
        }
        let mdlColors=(0..<mesh.vertexCount).flatMap { index in
            (0..<4).map { axis in attribute.dataStart.loadUnaligned(fromByteOffset:index*attribute.stride+axis*4,as:Float.self) }
        }
        let mdlError=try validateColors(mdlColors,components:4,count:mesh.vertexCount,expected:p3Colors)
        let scene=SCNScene(mdlAsset:asset)
        let bridgedGeometry=try geometry(in:scene)
        try validateGeometry(bridgedGeometry,original:original)
        guard let source=bridgedGeometry.sources(for:.color).first else {
            throw ProjectionError.nativeReadbackDetails("Native SceneKit.ModelIO bridge omitted serialized vertex colors")
        }
        let bridgedError=try validateColors(try floats(source,expectedComponents:source.componentsPerVector),
            components:source.componentsPerVector,count:source.vectorCount,expected:p3Colors)
        report["nativeColorReadbackImporter"]="MDLAsset(url: USDZ), MDLVertexAttributeColor float4"
        report["nativeColorMaxAbsoluteP3Error"]=mdlError
        report["SCNViaMDLColorMaxAbsoluteP3Error"]=bridgedError
        report["nativeVertexColorReadbackPassed"]=true
        report["renderSceneImporter"]="SCNScene(mdlAsset: MDLAsset(url: USDZ)); standard native bridge"
        return (scene,report)
    }

    private static func geometry(in scene: SCNScene) throws -> SCNGeometry {
        var values:[SCNGeometry]=[]
        scene.rootNode.enumerateHierarchy { node,_ in if let geometry=node.geometry { values.append(geometry) } }
        guard values.count==1,let geometry=values.first else {
            throw ProjectionError.nativeReadbackDetails("Native geometry count \(values.count)")
        }
        return geometry
    }

    private static func validateGeometry(_ geometry: SCNGeometry,original: GLBMesh) throws {
        guard let source=geometry.sources(for:.vertex).first else {throw ProjectionError.nativeReadbackFailed}
        let positions=try floats(source,expectedComponents:3)
        let indices=try geometry.elements.flatMap { element -> [UInt32] in
            guard element.primitiveType == .triangles else { throw ProjectionError.nativeReadbackFailed }
            return try (0..<(element.primitiveCount*3)).map { index in
                let offset=index*element.bytesPerIndex
                guard offset+element.bytesPerIndex<=element.data.count else { throw ProjectionError.nativeReadbackFailed }
                if element.bytesPerIndex==4 { return element.data.u32(offset) }
                if element.bytesPerIndex==2 { return element.data.withUnsafeBytes { UInt32($0.loadUnaligned(fromByteOffset:offset,as:UInt16.self).littleEndian) } }
                throw ProjectionError.nativeReadbackFailed
            }
        }
        guard positions==original.positions,indices==original.indices else {
            throw ProjectionError.nativeReadbackDetails("Native imported positions/index order differ from input")
        }
    }

    private static func validateColors(_ colors: [Float],components: Int,count: Int,expected: [SIMD3<Float>]) throws -> Float {
        guard count==expected.count,components>=3,colors.count==count*components,
              colors.allSatisfy(\.isFinite),expected.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}) else {
            throw ProjectionError.nativeReadbackDetails("Native vertex color count/format/nonfinite mismatch")
        }
        var error:Float=0
        for index in expected.indices {
            for axis in 0..<3 {error=max(error,abs(colors[index*components+axis]-expected[index][axis]))}
        }
        guard error<=0.001 else {throw ProjectionError.nativeReadbackDetails("Native vertex color P3 error \(error)")}
        return error
    }

    static func floats(_ source: SCNGeometrySource, expectedComponents: Int) throws -> [Float] {
        guard source.componentsPerVector==expectedComponents else { throw ProjectionError.nativeReadbackFailed }
        return try (0..<source.vectorCount).flatMap { index in
            try (0..<source.componentsPerVector).map { component in
                let offset=source.dataOffset+index*source.dataStride+component*source.bytesPerComponent
                guard offset+source.bytesPerComponent<=source.data.count else { throw ProjectionError.nativeReadbackFailed }
                if source.usesFloatComponents && source.bytesPerComponent==4 { return Float(bitPattern:source.data.u32(offset)) }
                if !source.usesFloatComponents && source.bytesPerComponent==1 { return Float(source.data[offset])/255 }
                throw ProjectionError.nativeReadbackFailed
            }
        }
    }

    @MainActor static func views(scene: SCNScene, mesh: GLBMesh, output: URL) throws -> [String] {
        var low=SIMD3<Float>(repeating:.infinity),high=SIMD3<Float>(repeating:-.infinity)
        for i in stride(from:0,to:mesh.positions.count,by:3) {
            let p=SIMD3(mesh.positions[i],mesh.positions[i+1],mesh.positions[i+2]);low=simd_min(low,p);high=simd_max(high,p)
        }
        let center=(low+high)/2,size=high-low,distance=max(size.x,max(size.y,size.z))*2.1
        scene.background.contents=NSColor(calibratedWhite:0.09,alpha:1)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=450;scene.rootNode.addChildNode(ambient)
        let light=SCNNode();light.light=SCNLight();light.light!.type = .omni;light.light!.intensity=850
        light.simdPosition=center+SIMD3(-distance,distance,distance);scene.rootNode.addChildNode(light)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=42
        camera.camera!.projectionDirection = .vertical;camera.camera!.zNear=0.01;camera.camera!.zFar=Double(max(100,distance*10))
        scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        var files:[String]=[]
        for (name,direction) in [("front",SIMD3<Float>(0,0,1)),("threequarter",simd_normalize(SIMD3<Float>(1,0.35,1)))] {
            camera.simdPosition=center+direction*distance
            camera.look(at:SCNVector3(center))
            let image=renderer.snapshot(atTime:0,with:CGSize(width:900,height:900),antialiasingMode:.multisampling4X)
            guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw ProjectionError.nativeReadbackFailed }
            let path=output.appendingPathComponent("projected-\(name).png")
            let sink=NSMutableData()
            guard let destination=CGImageDestinationCreateWithData(sink,UTType.png.identifier as CFString,1,nil) else { throw ProjectionError.nativeReadbackFailed }
            CGImageDestinationAddImage(destination,cg,nil)
            guard CGImageDestinationFinalize(destination) else { throw ProjectionError.nativeReadbackFailed }
            try (sink as Data).write(to:path,options:.withoutOverwriting);files.append(path.lastPathComponent)
        }
        return files
    }
}
