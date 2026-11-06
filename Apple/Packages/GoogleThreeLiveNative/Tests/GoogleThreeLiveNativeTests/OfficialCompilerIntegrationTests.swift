import Foundation
import XCTest
import CryptoKit
@testable import GoogleThreeLiveNative

final class OfficialCompilerIntegrationTests: XCTestCase {
    func testRealOfficialCompilerGeneratesNamedRobotFromCodexAuthoredSource() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../").standardizedFileURL
        let file = repo.appending(path: "Apple/SceneStudio/Resources/RobotScene.js")
        let sourceData = try Data(contentsOf: file)
        let source = try XCTUnwrap(String(data: sourceData, encoding: .utf8))
        let engine = GoogleThreeLiveEngine()
        let result = try await engine.compile(source: source)
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.sourceSHA256, SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined())
        let running = await engine.isRunning
        XCTAssertFalse(running)
        let glb = result.glb
        func u32(_ offset: Int) -> Int {
            glb.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        }
        XCTAssertGreaterThan(glb.count, 28)
        XCTAssertEqual(u32(0), 0x46546c67)
        XCTAssertEqual(u32(4), 2)
        XCTAssertEqual(u32(8), glb.count)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + u32(12)))) as? [String: Any])
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let names = Set(nodes.compactMap { $0["name"] as? String })
        XCTAssertEqual(meshes.count, 19)
        XCTAssertTrue(names.isSuperset(of: ["torso", "head", "left_eye", "right_eye", "left_foot", "right_foot"]))
        XCTAssertTrue(result.usdz.starts(with: [0x50, 0x4b]))
        XCTAssertTrue(result.metadataRepairApplied)
        if let folder = ProcessInfo.processInfo.environment["VOXAMBER_OFFICIAL_INTEGRATION_OUTPUT"] {
            let output = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try sourceData.write(to: output.appending(path: "source.js"), options: .withoutOverwriting)
            try glb.write(to: output.appending(path: "model.glb"), options: .withoutOverwriting)
            try result.usdz.write(to: output.appending(path: "model.usdz"), options: .withoutOverwriting)
        }
    }
}
