import Foundation
import Testing
import simd
@testable import ReferenceColorProjection

@Suite struct FaceTextureSelectionTests {
    private var raster:ReferenceRaster {
        .init(width:64,height:64,rgba:[UInt8](repeating:255,count:64*64*4))
    }
    private var triangle:[SIMD3<Double>] {[SIMD3(10,10,2),SIMD3(50,10,2),SIMD3(30,50,2)]}

    @Test func opaqueUnoccludedFaceUsesImageMaterial() throws {
        let result=try FaceTextureSelector.select(screen:triangle,indices:[0,1,2],reference:raster)
        #expect(result.imageFaces==[0] && result.neutralFaces.isEmpty)
    }
    @Test func nearbyHiddenFaceStaysNeutral() throws {
        let points=triangle+triangle.map{SIMD3($0.x,$0.y,$0.z+0.002)}
        let result=try FaceTextureSelector.select(screen:points,indices:[0,1,2,3,4,5],reference:raster)
        #expect(result.imageFaces==[0] && result.neutralFaces==[1])
        #expect(result.occluded==1)
    }
    @Test func smallBlockerInsideTheFaceRejectsItEvenThoughAllCornersAreVisible() throws {
        let points=triangle+[SIMD3(26.0,24,1.9),SIMD3(34.0,24,1.9),SIMD3(30.0,32,1.9)]
        let result=try FaceTextureSelector.select(screen:points,indices:[0,1,2,3,4,5],reference:raster)
        #expect(result.neutralFaces==[0] && result.imageFaces==[1])
    }
    @Test func alphaHoleInsideFaceRejectsItEvenWhenAllCornersAreOpaque() throws {
        var pixels=raster.rgba
        pixels[((64-28-1)*64+30)*4+3]=0
        let result=try FaceTextureSelector.select(screen:triangle,indices:[0,1,2],reference:.init(width:64,height:64,rgba:pixels))
        #expect(result.imageFaces.isEmpty && result.neutralFaces==[0] && result.maskRejected==1)
    }
    @Test func bilinearFootprintIncludesPixelsBeyondTheTriangleCorners() throws {
        var pixels=raster.rgba
        pixels[((64-10-1)*64+9)*4+3]=0
        let result=try FaceTextureSelector.select(screen:triangle,indices:[0,1,2],reference:.init(width:64,height:64,rgba:pixels))
        #expect(result.neutralFaces==[0])
    }
    @Test func coplanarNeighborSharingAnEdgeDoesNotHideTheFace() throws {
        let points=[SIMD3(10.0,10,2),SIMD3(50.0,10,2),SIMD3(50.0,50,2),SIMD3(10.0,50,2)]
        let result=try FaceTextureSelector.select(screen:points,indices:[0,1,2,0,2,3],reference:raster)
        #expect(result.imageFaces==[0,1] && result.neutralFaces.isEmpty)
    }
    @Test func invalidCoordinatesAndTopologyAreRejected() throws {
        #expect(throws:ProjectionError.self) {try FaceTextureSelector.select(screen:[SIMD3(.infinity,1,2)],indices:[0,0,0],reference:raster)}
        #expect(throws:ProjectionError.self) {try FaceTextureSelector.select(screen:triangle,indices:[0,1,3],reference:raster)}
    }
    @Test func cancelledCallerNeverReceivesASelectedScene() async throws {
        let raster=raster,points=triangle
        let operation=Task {
            while !Task.isCancelled {await Task.yield()}
            return try FaceTextureSelector.select(screen:points,indices:[0,1,2],reference:raster)
        }
        operation.cancel()
        do {_=try await operation.value;Issue.record("Cancelled selector returned a value")}
        catch is CancellationError {}
    }
}
