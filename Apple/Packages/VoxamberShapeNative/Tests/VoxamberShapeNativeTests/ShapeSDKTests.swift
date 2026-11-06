import Foundation
import XCTest
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VoxamberShapeNative

final class ShapeSDKTests:XCTestCase {
    func testBundledTrainedConfigurationMatchesPinnedHashAndRejectsAlteration() throws {
        let yaml=try HunyuanShape21Configuration.bundledYAML
        XCTAssertEqual(HunyuanShape21Configuration.digest(Data(yaml.utf8)),HunyuanShape21Configuration.configurationSHA256)
        XCTAssertTrue(yaml.contains("input_size: &num_latents 4096"))
        XCTAssertThrowsError(try HunyuanShape21Configuration.validate(yaml+"\n"))
    }
    func testPreparedInputRequiresActualDecoded512PNG() throws {
        XCTAssertEqual(try PreparedShapeInput.decode(png(size:512)).width,512)
        XCTAssertThrowsError(try PreparedShapeInput.decode(png(size:768)))
        XCTAssertThrowsError(try PreparedShapeInput.decode(Data("notPNG".utf8)))
        XCTAssertThrowsError(try PreparedShapeInput.decode(Data(png(size:512).prefix(33))))
    }
    func testPreparedRGBAForegroundAlphaIsPreservedBeforeNativePreprocessing() throws {
        let image=try PreparedShapeInput.decode(png(size:512,transparent:true))
        var bytes=[UInt8](repeating:0,count:512*512*4)
        let context=try XCTUnwrap(CGContext(data:&bytes,width:512,height:512,bitsPerComponent:8,bytesPerRow:512*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:512,height:512))
        XCTAssertEqual(bytes[3],0,"Transparent border must not be flattened to opaque white")
        XCTAssertEqual(bytes[(256*512+256)*4+3],255)
    }
    func testStreamingIntegrityRejectsMutationSymlinkAndCancellation() throws {
        let root=temporary();try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appending(path:"weights.dat"),bytes=Data(repeating:37,count:2_097_169)
        try bytes.write(to:file);let hash=HunyuanShape21Configuration.digest(bytes)
        try ShapePackVerifier.verifyFile(file,bytes:Int64(bytes.count),expectedSHA256:hash,cancellation:.init())
        var changed=bytes;changed[changed.count-1]^=1;try changed.write(to:file)
        XCTAssertThrowsError(try ShapePackVerifier.verifyFile(file,bytes:Int64(bytes.count),expectedSHA256:hash,cancellation:.init()))
        let link=root.appending(path:"link.dat");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try ShapePackVerifier.verifyFile(link,bytes:Int64(bytes.count),expectedSHA256:hash,cancellation:.init()))
        let token=ShapeCancellationToken();token.cancel()
        XCTAssertThrowsError(try ShapePackVerifier.verifyFile(file,bytes:Int64(bytes.count),expectedSHA256:hash,cancellation:token)) {XCTAssertTrue($0 is CancellationError)}
    }
    func testBuffersValidateRealIndexAndFiniteDataWithLargeExplicitCaps() throws {
        XCTAssertEqual(ShapeArtifactLimits.maximumVertices,2_000_000)
        XCTAssertEqual(ShapeArtifactLimits.maximumTriangles,4_000_000)
        XCTAssertEqual(ShapeArtifactLimits.maximumIndices,12_000_000)
        XCTAssertEqual(ShapeArtifactLimits.maximumGLBBytes,256*1024*1024)
        let valid=try triangle();XCTAssertEqual(valid.vertexCount,3)
        XCTAssertThrowsError(try ShapeMeshBuffers(positions:valid.positions,normals:valid.normals,indices:[0,1,3]))
        var bad=valid.positions;bad[0]=Float.nan
        XCTAssertThrowsError(try ShapeMeshBuffers(positions:bad,normals:valid.normals,indices:valid.indices))
    }
    func testGlobalShapeLeaseHasOneOwnerAndSafeRelease() throws {
        let lease=ShapeRuntimeLease(),first=try XCTUnwrap(lease.acquire())
        XCTAssertNil(lease.acquire());lease.release(UUID());XCTAssertNil(lease.acquire())
        lease.release(first);let second=try XCTUnwrap(lease.acquire());XCTAssertNotEqual(first,second);lease.release(second)
    }
    func testColdIdleCancellationAndUnloadRequireNoModelOrGPUWork() async throws {
        let engine=ShapeEngine();await engine.cancel();await engine.unload()
        let state=await engine.status;XCTAssertEqual(state,.idle)
        let task=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await engine.generate(pngData:Data(),shapePackURL:URL(fileURLWithPath:"/missing"),configurationYAML:"",seed:0)
        }
        do {_ = try await task.value;XCTFail("Pre-cancelled request must stop before model work")}
        catch {XCTAssertTrue(error is CancellationError)}
        let after=await engine.status;XCTAssertEqual(after,.idle)
    }
    func testBaseGLBRestoresGeometryAndDoesNotOverwriteExistingDestination() throws {
        let mesh=try triangle(),data=try ShapeMeshArchive.encode(mesh),restored=try ShapeMeshArchive.read(data:data)
        XCTAssertEqual(restored.positions,mesh.positions);XCTAssertEqual(restored.indices,mesh.indices)
        XCTAssertEqual(restored.normals,mesh.normals)
        let folder=temporary();try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appending(path:"base.glb");try ShapeMeshArchive.write(mesh,to:file)
        let before=try Data(contentsOf:file);XCTAssertThrowsError(try ShapeMeshArchive.write(mesh,to:file))
        XCTAssertEqual(try Data(contentsOf:file),before)
        XCTAssertThrowsError(try ShapeMeshArchive.read(data:Data("badGLB".utf8)))
    }
    func testSyntheticLargeNeuralSizedGeometryExportsAndRestoresBeyondOldCaps() throws {
        // CPU-only known grid, never represented as a neural/model inference pass.
        let side=393;var positions:[Float]=[];positions.reserveCapacity(side*side*3)
        for y in 0..<side {for x in 0..<side {positions += [Float(x)/Float(side-1),Float(y)/Float(side-1),0]}}
        var indices:[UInt32]=[];indices.reserveCapacity((side-1)*(side-1)*6)
        for y in 0..<(side-1) {for x in 0..<(side-1) {
            let a=UInt32(y*side+x),b=a+1,c=a+UInt32(side),d=c+1
            indices += [a,b,d,a,d,c]
        }}
        let tuples=try ShapeAssetExporter.vertexNormals(vertices:positions,faces:indices)
        let normals=tuples.flatMap{[$0.0,$0.1,$0.2]}
        let mesh=try ShapeMeshBuffers(positions:positions,normals:normals,indices:indices)
        XCTAssertEqual(mesh.vertexCount,154_449);XCTAssertEqual(mesh.triangleCount,307_328)
        let data=try ShapeMeshArchive.encode(mesh),restored=try ShapeMeshArchive.read(data:data)
        XCTAssertEqual(HunyuanShape21Configuration.digest(data),"58c3c024b419d15a60183a70a43d9a1004c31aca4442d4540e186ed792102d7b",
                       "Optional edit export must not change default generation/base GLB bytes")
        XCTAssertEqual(restored.positions,positions);XCTAssertEqual(restored.indices,indices);XCTAssertEqual(restored.normals,normals)
        let folder=temporary();try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let usdz=folder.appending(path:"large.usdz")
        try ShapeAssetExporter.writeGeometryUSDZ(vertices:positions,faces:indices,normals:normals,to:usdz)
        let bytes=try Data(contentsOf:usdz);XCTAssertTrue(bytes.starts(with:[0x50,0x4b]))
        XCTAssertEqual(HunyuanShape21Configuration.digest(bytes),"a7d17bb3d563ecfcfd9eeea879c6ee52eb9c6a228452a6bd7c6c3858987db376",
                       "Nil edit material must retain the default generation USDZ bytes")
        if let destination=ProcessInfo.processInfo.environment["VOXAMBER_SHAPE_TEST_OUTPUT"] {
            let output=URL(fileURLWithPath:destination);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try data.write(to:output.appending(path:"synthetic-large.glb"),options:.atomic)
            try bytes.write(to:output.appending(path:"synthetic-large.usdz"),options:.atomic)
            try JSONSerialization.data(withJSONObject:["syntheticCPUFixture":true,"neuralInferencePerformed":false,
                "vertices":mesh.vertexCount,"triangles":mesh.triangleCount,"GLBbytes":data.count,"USDZbytes":bytes.count],options:.prettyPrinted)
                .write(to:output.appending(path:"fixture.json"),options:.atomic)
        }
    }
    private func triangle()throws->ShapeMeshBuffers {
        try .init(positions:[0,0,0,1,0,0,0,1,0],normals:[0,0,1,0,0,1,0,0,1],indices:[0,1,2])
    }
    private func temporary()->URL {FileManager.default.temporaryDirectory.appending(path:"VoxamberShapeSDKTests-"+UUID().uuidString)}
    private func png(size:Int,transparent:Bool=false)throws->Data {
        let context=try XCTUnwrap(CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:(transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1))
        context.fill(transparent ? CGRect(x:size/4,y:size/4,width:size/2,height:size/2) : CGRect(x:0,y:0,width:size,height:size))
        let image=try XCTUnwrap(context.makeImage()),data=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination));return data as Data
    }
}
