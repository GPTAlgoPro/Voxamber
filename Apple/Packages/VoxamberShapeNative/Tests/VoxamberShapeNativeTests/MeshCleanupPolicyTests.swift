import Foundation
import simd
import XCTest
@testable import VoxamberHy3D

/// CPU-only predicates and immutable snapshot controls; no model or GPU work.
final class MeshCleanupPolicyTests: XCTestCase {
    func testActual509BoundarySpanningTrianglesArePositiveAndKeepWinding() throws {
        struct Fixture: Decodable {
            struct Triangle: Decodable { let positions: [[Float]] }
            let sourceGLBSHA256: String
            let triangles: [Triangle]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "CandidateBoundaryTriangles", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.sourceGLBSHA256,"8153667ca874a56aac9a2eef95fb28f470d5a9b68166fb7bcf35a728db9c18e4")
        XCTAssertEqual(fixture.triangles.count,509)
        for triangle in fixture.triangles {
            let p = triangle.positions.map { SIMD3<Float>($0[0],$0[1],$0[2]) }
            let original = Mesh(vertices:p,faces:[(0,1,2)])
            let cross32 = simd_cross(p[1]-p[0],p[2]-p[0])
            let d = p.map { SIMD3<Double>(Double($0.x),Double($0.y),Double($0.z)) }
            let cross64 = simd_cross(d[1]-d[0],d[2]-d[0])
            XCTAssertGreaterThan(simd_length_squared(cross32),0)
            XCTAssertLessThanOrEqual(simd_length_squared(cross32),1e-16)
            XCTAssertGreaterThan(simd_dot(SIMD3(Double(cross32.x),Double(cross32.y),Double(cross32.z)),cross64),0)
            XCTAssertEqual(original.removingDegenerateFaces(policy:.legacyThreshold).faces.count,0)
            let kept = original.removingDegenerateFaces(policy:.finitePositiveAreaFloat64)
            XCTAssertEqual(kept.vertices,p); XCTAssertEqual(kept.faces.count,1)
            XCTAssertEqual(kept.faces[0].0,0);XCTAssertEqual(kept.faces[0].1,1);XCTAssertEqual(kept.faces[0].2,2)
        }
    }

    func testSmallPositiveAreaSurvivesFloat32SquaredUnderflow() {
        let mesh=Mesh(vertices:[.zero,SIMD3(1e-13,0,0),SIMD3(0,1e-13,0)],faces:[(0,1,2)])
        let cross=simd_cross(mesh.vertices[1],mesh.vertices[2])
        XCTAssertNotEqual(cross.z,0);XCTAssertEqual(simd_length_squared(cross),0)
        XCTAssertEqual(mesh.removingDegenerateFaces(policy:.legacyThreshold).faces.count,0)
        let strict=mesh.removingDegenerateFaces(policy:.finitePositiveAreaFloat64)
        XCTAssertEqual(strict.vertices,mesh.vertices);XCTAssertEqual(strict.faces.count,1)
    }

    func testTrueDegeneracyInvalidIndicesAndNonfiniteCoordinatesStillReject() {
        let vertices:[SIMD3<Float>]=[.zero,SIMD3(1,0,0),SIMD3(2,0,0),SIMD3(.nan,1,0),SIMD3(1,.infinity,0)]
        let mesh=Mesh(vertices:vertices,faces:[(0,1,2),(0,0,1),(0,1,99),(0,1,3),(0,1,4)])
        XCTAssertTrue(mesh.removingDegenerateFaces(policy:.finitePositiveAreaFloat64).faces.isEmpty)
    }

    func testSurvivingFaceOrderAndWindingRemainStable() {
        let vertices:[SIMD3<Float>]=[.zero,SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)]
        let mesh=Mesh(vertices:vertices,faces:[(0,1,2),(0,0,1),(0,3,1)])
        let kept=mesh.removingDegenerateFaces(policy:.finitePositiveAreaFloat64)
        XCTAssertEqual(kept.vertices,vertices);XCTAssertEqual(kept.faces.count,2)
        XCTAssertEqual([kept.faces[0].0,kept.faces[0].1,kept.faces[0].2],[0,1,2])
        XCTAssertEqual([kept.faces[1].0,kept.faces[1].1,kept.faces[1].2],[0,3,1])
    }

    func testRawSinkSeesUncleanedValueAndCannotModifyDefaultResult() throws {
        let raw=Mesh(vertices:[.zero,SIMD3(1e-5,0,0),SIMD3(0,1e-5,0),SIMD3(0,1,0)],faces:[(0,1,2),(0,1,3)])
        var calls=0
        let cleaned=try ShapeMeshFinalizer.legacyCleaned(raw) { captured in
            calls+=1;XCTAssertEqual(captured.faces.count,2);XCTAssertEqual(captured.vertices,raw.vertices)
            var copy=captured;copy.vertices[0]=SIMD3(99,99,99);copy.faces.removeAll()
        }
        XCTAssertEqual(calls,1);XCTAssertEqual(raw.faces.count,2);XCTAssertEqual(raw.vertices[0],.zero)
        XCTAssertEqual(cleaned.faces.count,1);XCTAssertEqual(cleaned.vertices,raw.removingDegenerateFaces().vertices)
        let withoutSink=try ShapeMeshFinalizer.legacyCleaned(raw,onRawMesh:nil)
        XCTAssertEqual(withoutSink.vertices,cleaned.vertices);XCTAssertEqual(withoutSink.faces.count,cleaned.faces.count)
        let defaultPolicy=try ShapeMeshFinalizer.cleaned(raw,onRawMesh:nil)
        XCTAssertEqual(defaultPolicy.vertices,cleaned.vertices);XCTAssertEqual(defaultPolicy.faces.count,cleaned.faces.count)
        let explicitStrict=try ShapeMeshFinalizer.cleaned(raw,policy:.finitePositiveAreaFloat64,onRawMesh:nil)
        XCTAssertEqual(explicitStrict.vertices,raw.vertices);XCTAssertEqual(explicitStrict.faces.count,raw.faces.count)
        XCTAssertThrowsError(try ShapeMeshFinalizer.legacyCleaned(raw) { _ in throw CocoaError(.fileWriteUnknown) })
    }
}
