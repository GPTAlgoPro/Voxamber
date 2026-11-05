import Foundation
import XCTest
import CreationCore
@testable import ThreeLiveNative

final class ThreeLiveNativeTests: XCTestCase {
    func testAllActualPresetsExportValidDeterministicContainers() throws {
        for spec in BuildingSpec.presets {
            let building = try BuildingGenerator.generate(for: spec)
            let glb = try ThreeLiveNative.exportGLB(building.meshes)
            XCTAssertEqual(glb, try ThreeLiveNative.exportGLB(building.meshes))
            XCTAssertEqual(read(glb, 0, 4), 0x46546c67)
            XCTAssertEqual(read(glb, 4, 4), 2)
            XCTAssertEqual(read(glb, 8, 4), glb.count)
            let jsonLength = read(glb, 12, 4)
            XCTAssertEqual(jsonLength % 4, 0)
            XCTAssertEqual(read(glb, 16, 4), 0x4e4f534a)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: glb[20..<(20 + jsonLength)]) as? [String: Any])
            let primitives = try XCTUnwrap(json["meshes"] as? [[String: Any]])
            XCTAssertEqual(primitives.count, building.meshes.count)
            let binOffset = 20 + jsonLength
            XCTAssertEqual(read(glb, binOffset + 4, 4), 0x004e4942)
            XCTAssertEqual(binOffset + 8 + read(glb, binOffset, 4), glb.count)
            let usdz = try ThreeLiveNative.exportUSDZ(building.meshes)
            XCTAssertEqual(usdz, try ThreeLiveNative.exportUSDZ(building.meshes))
            let usda = try inspectUSDZ(usdz)
            XCTAssertEqual(usda.components(separatedBy: "MaterialBindingAPI").count - 1, building.meshes.count)
            XCTAssertEqual(usda.components(separatedBy: "subdivisionScheme = \"none\"").count - 1, building.meshes.count)
            XCTAssertTrue(usda.contains("metersPerUnit = 1.0"))
            XCTAssertTrue(usda.contains("upAxis = \"Y\""))
            if let directory = ProcessInfo.processInfo.environment["THREELIVE_NATIVE_EVIDENCE_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let stem = spec.kind.rawValue
                try glb.write(to: url.appendingPathComponent(stem + ".glb"), options: .atomic)
                try usdz.write(to: url.appendingPathComponent(stem + ".usdz"), options: .atomic)
            }
        }
    }

    func testBinaryPositionAndIndexDataMatchesSourceExactly() throws {
        let mesh = triangle()
        let data = try ThreeLiveNative.exportGLB([mesh])
        let jsonLength = read(data, 12, 4)
        let binStart = 20 + jsonLength + 8
        for (i, value) in mesh.positions.enumerated() {
            XCTAssertEqual(UInt32(read(data, binStart + i * 4, 4)), value.bitPattern)
        }
        let indexStart = binStart + (mesh.positions.count + mesh.normals.count) * 4
        for (i, value) in mesh.indices.enumerated() {
            XCTAssertEqual(UInt32(read(data, indexStart + i * 4, 4)), value)
        }
    }

    func testMalformedGeometryCannotBeExported() {
        let good = triangle()
        let invalid = [
            GeneratedMesh(name: "bad-index", positions: good.positions, normals: good.normals,
                          indices: [0, 1, 30], color: good.color, metallic: 0, roughness: 0.5),
            GeneratedMesh(name: "non-finite", positions: [0, .nan, 0], normals: [0, 1, 0],
                          indices: [0, 0, 0], color: good.color, metallic: 0, roughness: 0.5),
            GeneratedMesh(name: "bad-normal-count", positions: good.positions, normals: [0, 1, 0],
                          indices: good.indices, color: good.color, metallic: 0, roughness: 0.5),
            GeneratedMesh(name: "bad-normal-length", positions: good.positions, normals: Array(repeating: 0, count: 9),
                          indices: good.indices, color: good.color, metallic: 0, roughness: 0.5),
            GeneratedMesh(name: "bad-material", positions: good.positions, normals: good.normals,
                          indices: good.indices, color: [1, -1, 0], metallic: 0, roughness: 0.5)
        ]
        XCTAssertThrowsError(try ThreeLiveNative.exportGLB([]))
        XCTAssertThrowsError(try ThreeLiveNative.exportUSDZ([]))
        for mesh in invalid {
            XCTAssertThrowsError(try ThreeLiveNative.exportGLB([mesh]))
            XCTAssertThrowsError(try ThreeLiveNative.exportUSDZ([mesh]))
        }
    }

    func testOversizedGeometryIsRejectedBeforeSerialization() {
        let positions = Array(repeating: Float(0), count: 100_001 * 3)
        let mesh = GeneratedMesh(name: "too-large", positions: positions, normals: positions,
                                 indices: [0, 1, 2], color: [1, 0, 0], metallic: 0, roughness: 1)
        XCTAssertThrowsError(try ThreeLiveNative.exportGLB([mesh])) { error in
            XCTAssertEqual(error as? NativeExportError, .budgetExceeded)
        }
    }

    private func triangle() -> GeneratedMesh {
        .init(name: "Triangle", positions: [0, 0, 0, 0, 0, 1, 1, 0, 0],
              normals: [0, 1, 0, 0, 1, 0, 0, 1, 0], indices: [0, 1, 2],
              color: [0.4, 0.7, 0.8], metallic: 0.2, roughness: 0.6)
    }

    private func read(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }

    private func inspectUSDZ(_ archive: Data) throws -> String {
        XCTAssertGreaterThan(archive.count, 30)
        XCTAssertEqual(read(archive, 0, 4), 0x04034b50)
        XCTAssertEqual(read(archive, 8, 2), 0)
        let payloadStart = 30 + read(archive, 26, 2) + read(archive, 28, 2)
        let payloadEnd = payloadStart + read(archive, 18, 4)
        XCTAssertEqual(payloadStart % 64, 0)
        XCTAssertLessThanOrEqual(payloadEnd, archive.count)
        let centralStart = payloadEnd
        XCTAssertEqual(read(archive, centralStart, 4), 0x02014b50)
        let eocd = archive.count - 22
        XCTAssertEqual(read(archive, eocd, 4), 0x06054b50)
        XCTAssertEqual(read(archive, eocd + 16, 4), centralStart)
        let text = try XCTUnwrap(String(data: archive[payloadStart..<payloadEnd], encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("#usda 1.0"))
        return text
    }
}
