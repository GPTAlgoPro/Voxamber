import Foundation
import Testing
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SceneKit
import CoreImage
@testable import ReferenceColorProjection

@Test func frontVisibleVerticesReceiveImageAndOccludedBackStaysNeutral() throws {
    let positions:[Float]=[-0.5,-0.5,0.5,0.5,-0.5,0.5,0.5,0.5,0.5,-0.5,0.5,0.5,
                           -0.5,-0.5,-0.5,0.5,-0.5,-0.5,0.5,0.5,-0.5,-0.5,0.5,-0.5]
    let indices:[UInt32]=[0,1,2,0,2,3,4,6,5,4,7,6]
    let pixels:[UInt8]=(0..<(32*32)).flatMap { _ -> [UInt8] in [0,0,255,255] }
    let projected=try SingleViewProjector.project(positions:positions,indices:indices,
        reference:.init(width:32,height:32,rgba:pixels))
    #expect(projected.coloredVertices==4)
    #expect(projected.colors.prefix(4).allSatisfy{$0==SIMD4(0,0,1,1)})
    #expect(projected.colors.suffix(4).allSatisfy{$0==SingleViewProjector.neutral})
}

@Test func closeOccludedLayerDoesNotReceiveTheFrontReferenceColor() throws {
    let positions:[Float]=[-0.5,-0.5,0.001,0.5,-0.5,0.001,0.5,0.5,0.001,-0.5,0.5,0.001,
                           -0.5,-0.5,-0.001,0.5,-0.5,-0.001,0.5,0.5,-0.001,-0.5,0.5,-0.001]
    let indices:[UInt32]=[0,1,2,0,2,3,4,6,5,4,7,6]
    let pixels:[UInt8]=(0..<(32*32)).flatMap { _ -> [UInt8] in [0,0,255,255] }
    let projected=try SingleViewProjector.project(positions:positions,indices:indices,
        reference:.init(width:32,height:32,rgba:pixels))
    #expect(projected.coloredVertices==4)
    #expect(projected.colors.suffix(4).allSatisfy{$0==SingleViewProjector.neutral})
}

@Test func premultipliedSRGBIsUnpremultipliedThenConvertedToLinear() throws {
    let pixels:[UInt8]=(0..<4).flatMap { _ -> [UInt8] in [102,51,0,204] }
    let color=try #require(ReferenceRaster(width:2,height:2,rgba:pixels).linearColor(x:1,y:1))
    #expect(abs(Double(color.x)-0.21404114048223255)<1e-6)
    #expect(abs(Double(color.y)-0.05087608817155679)<1e-6)
    #expect(color.w==1)
}

@Test func nativePNGDecodeKeepsTopRowsAndBottomLeftSamplingDistinct() throws {
    // A provider-backed CGImage stores the first two rows red and the last
    // two blue. This catches a vertical flip introduced by CI bitmap reading.
    let rgba: [UInt8] = (0..<16).flatMap { index -> [UInt8] in
        index < 8 ? [255,0,0,255] : [0,0,255,255]
    }
    let provider=try #require(CGDataProvider(data:Data(rgba) as CFData))
    let colorSpace=try #require(CGColorSpace(name:CGColorSpace.sRGB))
    let image=try #require(CGImage(width:4,height:4,bitsPerComponent:8,bitsPerPixel:32,
        bytesPerRow:16,space:colorSpace,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let encoded=NSMutableData()
    let destination=try #require(CGImageDestinationCreateWithData(encoded,UTType.png.identifier as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil)
    #expect(CGImageDestinationFinalize(destination))
    let decoded=try ReferenceRaster(png:encoded as Data)
    #expect(decoded.rgba[0]==255 && decoded.rgba[2]==0)
    let top=try #require(decoded.linearColor(x:1,y:3))
    let bottom=try #require(decoded.linearColor(x:1,y:1))
    #expect(top.x==1 && top.z==0)
    #expect(bottom.x==0 && bottom.z==1)
}

@Test func nativePNGDecodePreservesAsymmetricAlphaBoundsAndLeftRightColors() throws {
    var rgba=[UInt8](repeating:0,count:8*8*4)
    for row in 1...3 {
        for x in 1...4 {
            let offset=(row*8+x)*4
            rgba[offset]=x<=2 ? 255 : 0
            rgba[offset+2]=x<=2 ? 0 : 255
            rgba[offset+3]=255
        }
    }
    let provider=try #require(CGDataProvider(data:Data(rgba) as CFData))
    let colorSpace=try #require(CGColorSpace(name:CGColorSpace.sRGB))
    let image=try #require(CGImage(width:8,height:8,bitsPerComponent:8,bitsPerPixel:32,
        bytesPerRow:32,space:colorSpace,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let encoded=NSMutableData()
    let destination=try #require(CGImageDestinationCreateWithData(encoded,UTType.png.identifier as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil)
    #expect(CGImageDestinationFinalize(destination))
    let decoded=try ReferenceRaster(png:encoded as Data)
    #expect(decoded.foregroundBounds==CGRect(x:1,y:4,width:4,height:3))
    let left=try #require(decoded.linearColor(x:2,y:5.5))
    let right=try #require(decoded.linearColor(x:4,y:5.5))
    #expect(left.x==1 && left.z==0)
    #expect(right.x==0 && right.z==1)
    #expect(decoded.linearColor(x:2,y:2)==nil)
}

@Test func addingCOLOR0KeepsOriginalGeometryBufferBitsAndIndexOrder() throws {
    let input=try tinyGLB(),mesh=try GLBMesh(data:input)
    let colors=[SIMD4<Float>(1,0,0,1),SIMD4<Float>(0,1,0,1),SIMD4<Float>(0,0,1,1)]
    let output=try GLBMesh(data:mesh.exporting(colors:colors))
    #expect(output.positionBytes==mesh.positionBytes)
    #expect(output.indexBytes==mesh.indexBytes)
    #expect(output.positions==mesh.positions && output.indices==mesh.indices)
    #expect(try output.colors()==colors)
}

@Test func nativeLinearP3BasisConversionPreservesWhiteAndFiniteChannels() throws {
    let converter=try LinearP3Converter(),white=converter.convert(SIMD4(1,1,1,1))
    #expect(abs(white.x-1)<0.001 && abs(white.y-1)<0.001 && abs(white.z-1)<0.001)
    let blue=converter.convert(SIMD4(0,0,1,1))
    #expect((0..<3).allSatisfy{blue[$0].isFinite})
    #expect(blue.z>0.8 && blue.z<1)
}

@Test @MainActor func realVertexColorUSDZRoundTripsThroughTheNativeImporter() throws {
    let mesh=try GLBMesh(data:tinyGLB())
    let colors=[SIMD4<Float>(1,0,0,1),SIMD4<Float>(0,1,0,1),SIMD4<Float>(0,0,1,1)]
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("reference-color-roundtrip-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer {try? FileManager.default.removeItem(at:directory)}
    let path=directory.appendingPathComponent("test.usdz")
    let p3=try VertexColorUSDZ.export(mesh:mesh,colors:colors,to:path)
    let (scene,readback)=try NativeReadback.validate(url:path,original:mesh,p3Colors:p3)
    #expect(readback["nativeVertexColorReadbackPassed"] as? Bool==true)
    let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=42
    camera.position=SCNVector3(0.5,0.5,2.1);camera.look(at:SCNVector3(0.5,0.5,0))
    scene.rootNode.addChildNode(camera)
    let light=SCNNode();light.light=SCNLight();light.light!.type = .ambient;light.light!.intensity=1000
    scene.rootNode.addChildNode(light)
    let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
    let rendered=renderer.snapshot(atTime:0,with:CGSize(width:160,height:160),antialiasingMode:.none)
    let cg=try #require(rendered.cgImage(forProposedRect:nil,context:nil,hints:nil))
    var bytes=[UInt8](repeating:0,count:160*160*4)
    CIContext(options:[.useSoftwareRenderer:true]).render(CIImage(cgImage:cg),toBitmap:&bytes,rowBytes:160*4,
        bounds:CGRect(x:0,y:0,width:160,height:160),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
    let coloredPixels=stride(from:0,to:bytes.count,by:4).filter { offset in
        let rgb=bytes[offset..<(offset+3)]
        return Int(rgb.max()!)-Int(rgb.min()!)>25
    }.count
    #expect(coloredPixels>500,"A true native vertex-color asset must render chromatic pixels, not just retain a hidden attribute")
    if let path=ProcessInfo.processInfo.environment["VOX_COLOR_SMOKE_OUTPUT"] {
        let output=URL(fileURLWithPath:path,isDirectory:true)
        guard !FileManager.default.fileExists(atPath:output.path) else {throw CocoaError(.fileWriteFileExists)}
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:directory.appendingPathComponent("Model.usda"),to:output.appendingPathComponent("synthetic-primary-triangle.usda"))
        try FileManager.default.copyItem(at:directory.appendingPathComponent("test.usdz"),to:output.appendingPathComponent("synthetic-primary-triangle.usdz"))
        let encoded=NSMutableData()
        let writer=try #require(CGImageDestinationCreateWithData(encoded,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(writer,cg,nil);#expect(CGImageDestinationFinalize(writer))
        try (encoded as Data).write(to:output.appendingPathComponent("native-triangle.png"),options:.withoutOverwriting)
        let evidence:[String:Any]=["syntheticDiagnosticOnly":true,"NNCalls":0,"chromaticPixels":coloredPixels,
            "nativeUSDZReadback":readback,"USDZSHA256":fileSHA(try Data(contentsOf:directory.appendingPathComponent("test.usdz")))]
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("native-triangle-result.json"),options:.withoutOverwriting)
    }
}

private func tinyGLB() throws -> Data {
    var binary=Data()
    for value:Float in [0,0,0,1,0,0,0,1,0] {binary.appendLE(value.bitPattern)}
    for value:UInt32 in [0,1,2] {binary.appendLE(value)}
    let object:[String:Any]=["asset":["version":"2.0"],"buffers":[["byteLength":binary.count]],
      "bufferViews":[["buffer":0,"byteOffset":0,"byteLength":36],["buffer":0,"byteOffset":36,"byteLength":12]],
      "accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3"],["bufferView":1,"componentType":5125,"count":3,"type":"SCALAR"]],
      "meshes":[["primitives":[["attributes":["POSITION":0],"indices":1,"mode":4]]]],"nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0]
    var json=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);while !json.count.isMultiple(of:4){json.append(32)}
    var result=Data();result.appendLE(UInt32(0x46546c67));result.appendLE(UInt32(2));result.appendLE(UInt32(28+json.count+binary.count))
    result.appendLE(UInt32(json.count));result.appendLE(UInt32(0x4e4f534a));result.append(json)
    result.appendLE(UInt32(binary.count));result.appendLE(UInt32(0x004e4942));result.append(binary)
    return result
}
