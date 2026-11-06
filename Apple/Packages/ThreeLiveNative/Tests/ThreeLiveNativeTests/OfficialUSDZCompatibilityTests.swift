import Foundation
import XCTest
@testable import ThreeLiveNative

final class OfficialUSDZCompatibilityTests: XCTestCase {
    // Actual output of retained verified Google v1.2.3 CLI (not a synthetic ZIP):
    // tools/three-live-cli convert scenes/smoke.js -o smoke-official-raw.usdz
    // CLI SHA256 70dbe721a1fc00f6c169b16d2ef4fd8a16d765ff0aaab1f6c9165241e00eac6c
    // Actual archive SHA256 834a8e98ec2af76688be848a1c4575d0efcfa05636481e345c9570f0f5c9dd55,2089bytes.
    private var actualRaw: Data { Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters)! }

    func testActualOfficialOutputRepairsOnlyMetadataAndPreservesEveryPropertyLiteral() throws {
        let raw = actualRaw, original = try payload(raw)
        let repaired = try OfficialUSDZCompatibility.repair(raw), text = try payload(repaired)
        XCTAssertEqual(raw.count, 2089)
        XCTAssertNotEqual(repaired, raw)
        XCTAssertEqual(text.components(separatedBy: "MaterialBindingAPI").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "subdivisionScheme = \"none\"").count - 1, 1)
        XCTAssertEqual(authoredProperties(text), authoredProperties(original))
        XCTAssertEqual(materialSection(text), materialSection(original))
        XCTAssertTrue(text.contains("rel material:binding = </Root/Materials/Material_0>"))
        XCTAssertEqual(try OfficialUSDZCompatibility.repair(repaired), repaired)
    }

    func testRetainedActualPalaceAllSeventeenMeshesPreserveGeometryAndMaterials() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../").standardizedFileURL
        let path = repo.appendingPathComponent("artifacts/palace-raw.usdz")
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("Repository-only retained palace integration asset is not present.") }
        let raw = try Data(contentsOf: path), before = try payload(raw)
        XCTAssertEqual(raw.count, 1_650_759)
        let fixed = try OfficialUSDZCompatibility.repair(raw), after = try payload(fixed)
        XCTAssertEqual(after.components(separatedBy: "MaterialBindingAPI").count - 1, 17)
        XCTAssertEqual(after.components(separatedBy: "subdivisionScheme = \"none\"").count - 1, 17)
        XCTAssertEqual(authoredProperties(after), authoredProperties(before))
        XCTAssertEqual(materialSection(after), materialSection(before))
        XCTAssertEqual(try OfficialUSDZCompatibility.repair(fixed), fixed)
    }

    func testExistingNoneIsNotDuplicatedAndExistingAPIIsNotDuplicated() throws {
        let original = try payload(actualRaw)
        let withNone = original.replacingOccurrences(of: "def Mesh \"native_compiler_smoke\"\n{", with: "def Mesh \"native_compiler_smoke\"\n{\nuniform token subdivisionScheme = \"none\"")
        XCTAssertNotEqual(withNone, original)
        let a = try payload(OfficialUSDZCompatibility.repair(pack(withNone)))
        XCTAssertEqual(a.components(separatedBy: "subdivisionScheme = \"none\"").count - 1, 1)
        let withAPI = original.replacingOccurrences(of: "def Mesh \"native_compiler_smoke\"\n{", with: "def Mesh \"native_compiler_smoke\" (\n    prepend apiSchemas = [\"MaterialBindingAPI\"]\n)\n{")
        XCTAssertNotEqual(withAPI, original)
        let b = try payload(OfficialUSDZCompatibility.repair(pack(withAPI)))
        XCTAssertEqual(b.components(separatedBy: "MaterialBindingAPI").count - 1, 1)
    }

    func testUnknownMetadataExplicitSubdivisionAndMissingMaterialAreRejected() throws {
        let original = try payload(actualRaw)
        let candidates = [
            original.replacingOccurrences(of: "def Mesh \"native_compiler_smoke\"\n{", with: "def Mesh \"native_compiler_smoke\" (\nprepend apiSchemas = [\"PhysicsCollisionAPI\"]\n)\n{"),
            original.replacingOccurrences(of: "def Mesh \"native_compiler_smoke\"\n{", with: "def Mesh \"native_compiler_smoke\"\n{\nuniform token subdivisionScheme = \"catmullClark\""),
            original.replacingOccurrences(of: "rel material:binding = </Root/Materials/Material_0>", with: ""),
            original.replacingOccurrences(of: "def Mesh \"native_compiler_smoke\"\n{", with: "def Mesh \"native_compiler_smoke\" {")
        ]
        for candidate in candidates {
            XCTAssertNotEqual(candidate, original, "The malformed fixture must actually differ from the real compiler output")
            XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(pack(candidate)))
        }
    }

    func testStringsAndCommentsCannotInventMeshDeclarationsOrChangeBraceDepth() throws {
        let original = try payload(actualRaw)
        let candidate = original.replacingOccurrences(of: "def Shader \"PBRShader\"\n{", with: "def Shader \"PBRShader\"\n{\nstring inputs:note = \"brace } and def Mesh in a string\"\n# def Mesh \"fake\" {")
        XCTAssertNotEqual(candidate, original)
        let fixed = try payload(OfficialUSDZCompatibility.repair(pack(candidate)))
        XCTAssertEqual(fixed.components(separatedBy: "MaterialBindingAPI").count - 1, 1)
        XCTAssertEqual(authoredProperties(fixed), authoredProperties(candidate))
    }

    func testCRCAndLocalCentralDisagreementAreRejected() {
        let start = 30 + read(actualRaw, 26, 2) + read(actualRaw, 28, 2)
        var badCRC = actualRaw; badCRC[start + 2] ^= 1
        XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(badCRC))
        var badLocalCRC = actualRaw; badLocalCRC[14] ^= 1
        XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(badLocalCRC))
        var badName = actualRaw; badName[30] ^= 1
        XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(badName))
    }

    func testZIPBoundaryAlignmentOverflowAndTrailingDataAreRejected() {
        let raw = actualRaw, footer = raw.count - 22, directory = read(raw, footer + 16, 4)
        var offset = raw; write(0xffff_ffff, into: &offset, at: footer + 16, count: 4)
        var overlap = raw; write(directory - 1, into: &overlap, at: footer + 16, count: 4)
        var alignment = raw; write(read(raw, 28, 2) + 1, into: &alignment, at: 28, count: 2)
        var size = raw; write(0xffff_ffff, into: &size, at: directory + 24, count: 4)
        var localOffset = raw; write(4, into: &localOffset, at: directory + 42, count: 4)
        for bad in [offset, overlap, alignment, size, localOffset, raw + Data([0]), Data(raw.prefix(21))] {
            XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(bad))
        }
    }

    func testUnsupportedZIPModesAndPathsAreRejected() throws {
        let raw = actualRaw, footer = raw.count - 22, directory = read(raw, footer + 16, 4)
        for (local, central, value) in [(6, directory + 8, 1), (6, directory + 8, 8), (8, directory + 10, 8), (4, directory + 6, 45)] {
            var bad = raw; write(value, into: &bad, at: local, count: 2); write(value, into: &bad, at: central, count: 2)
            XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(bad))
        }
        var multiple = raw; write(2, into: &multiple, at: footer + 8, count: 2); write(2, into: &multiple, at: footer + 10, count: 2)
        XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(multiple))
        XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(ThreeLiveNative.storedUSDZ(name: "../xx.usda", payload: Data(try payload(raw).utf8))))
    }

    func testUnsupportedUSDAIsRejectedAndSlicedDataIsSupported() throws {
        for text in ["#usda 1.0\n", "#usda 1.0\r\n", "#usda 1.0\n\"\"\"", String((try payload(actualRaw)).dropLast(3))] {
            XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(pack(text)))
        }
        XCTAssertThrowsError(try OfficialUSDZCompatibility.repair(ThreeLiveNative.storedUSDZ(name: "model.usda", payload: Data([255, 254]))))
        let padded = Data([1, 2, 3]) + actualRaw
        XCTAssertEqual(try OfficialUSDZCompatibility.repair(padded.dropFirst(3)), try OfficialUSDZCompatibility.repair(actualRaw))
    }

    func testPreCancelledCallerCannotReturnRepairedData() async {
        let raw = actualRaw
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try OfficialUSDZCompatibility.repair(raw)
        }
        switch await task.result {
        case .success: XCTFail("A cancelled caller returned a repaired artifact")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    private func pack(_ text: String) -> Data { ThreeLiveNative.storedUSDZ(name: "model.usda", payload: Data(text.utf8)) }
    private func payload(_ archive: Data) throws -> String {
        let start = 30 + read(archive, 26, 2) + read(archive, 28, 2), count = read(archive, 22, 4)
        XCTAssertEqual(start % 64, 0)
        return try XCTUnwrap(String(data: archive.subdata(in: start..<(start + count)), encoding: .utf8))
    }
    private func read(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
    private func write(_ value: Int, into data: inout Data, at offset: Int, count: Int) {
        for i in 0..<count { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private func authoredProperties(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            $0.contains(" = ") && !$0.contains("subdivisionScheme") && !$0.contains("apiSchemas")
        }
    }
    private func materialSection(_ text: String) -> String { text.components(separatedBy: "def Mesh").first! }
    private static let fixture = """
UEsDBBQAAAAAAAAAAAAghRImmwcAAJsHAAAKABgAbW9kZWwudXNkYYYZFAAAAAAAAAAAAAAAAAAAAAAAAAAAACN1c2RhIDEuMAoo
CmRlZmF1bHRQcmltID0gIlJvb3QiCm1ldGVyc1BlclVuaXQgPSAxLjAKdXBBeGlzID0gIlkiCikKCmRlZiBYZm9ybSAiUm9vdCIg
KApraW5kID0gImNvbXBvbmVudCIKKQp7CmRlZiBTY29wZSAiTWF0ZXJpYWxzIgp7CmRlZiBNYXRlcmlhbCAiTWF0ZXJpYWxfMCIK
ewpkZWYgU2hhZGVyICJQQlJTaGFkZXIiCnsKdW5pZm9ybSB0b2tlbiBpbmZvOmlkID0gIlVzZFByZXZpZXdTdXJmYWNlIgpjb2xv
cjNmIGlucHV0czpkaWZmdXNlQ29sb3IgPSAoMC42NjY2NywgMC4xMzMzMywgMC4xMzMzMykKZmxvYXQgaW5wdXRzOm1ldGFsbGlj
ID0gMC4xCmZsb2F0IGlucHV0czpyb3VnaG5lc3MgPSAwLjcKdG9rZW4gb3V0cHV0czpzdXJmYWNlCn0KdG9rZW4gb3V0cHV0czpz
dXJmYWNlLmNvbm5lY3QgPSA8L1Jvb3QvTWF0ZXJpYWxzL01hdGVyaWFsXzAvUEJSU2hhZGVyLm91dHB1dHM6c3VyZmFjZT4KfQp9
CmRlZiBTY29wZSAiTWVzaGVzIgp7CmRlZiBNZXNoICJuYXRpdmVfY29tcGlsZXJfc21va2UiCnsKZmxvYXQzW10gZXh0ZW50ID0g
WygtMC4xLCAwLCAtMC4xKSwgKDAuMSwgMC4yLCAwLjEpXQppbnRbXSBmYWNlVmVydGV4Q291bnRzID0gWzMsIDMsIDMsIDMsIDMs
IDMsIDMsIDMsIDMsIDMsIDMsIDNdCmludFtdIGZhY2VWZXJ0ZXhJbmRpY2VzID0gWzAsIDEsIDIsIDAsIDIsIDMsIDQsIDUsIDYs
IDQsIDYsIDcsIDgsIDksIDEwLCA4LCAxMCwgMTEsIDEyLCAxMywgMTQsIDEyLCAxNCwgMTUsIDE2LCAxNywgMTgsIDE2LCAxOCwg
MTksIDIwLCAyMSwgMjIsIDIwLCAyMiwgMjNdCnBvaW50M2ZbXSBwb2ludHMgPSBbKC0wLjEsIDAsIDAuMSksICgwLjEsIDAsIDAu
MSksICgwLjEsIDAuMiwgMC4xKSwgKC0wLjEsIDAuMiwgMC4xKSwgKDAuMSwgMCwgLTAuMSksICgtMC4xLCAwLCAtMC4xKSwgKC0w
LjEsIDAuMiwgLTAuMSksICgwLjEsIDAuMiwgLTAuMSksICgtMC4xLCAwLjIsIDAuMSksICgwLjEsIDAuMiwgMC4xKSwgKDAuMSwg
MC4yLCAtMC4xKSwgKC0wLjEsIDAuMiwgLTAuMSksICgtMC4xLCAwLCAtMC4xKSwgKDAuMSwgMCwgLTAuMSksICgwLjEsIDAsIDAu
MSksICgtMC4xLCAwLCAwLjEpLCAoMC4xLCAwLCAwLjEpLCAoMC4xLCAwLCAtMC4xKSwgKDAuMSwgMC4yLCAtMC4xKSwgKDAuMSwg
MC4yLCAwLjEpLCAoLTAuMSwgMCwgLTAuMSksICgtMC4xLCAwLCAwLjEpLCAoLTAuMSwgMC4yLCAwLjEpLCAoLTAuMSwgMC4yLCAt
MC4xKV0Kbm9ybWFsM2ZbXSBub3JtYWxzID0gWygwLCAwLCAxLjApLCAoMCwgMCwgMS4wKSwgKDAsIDAsIDEuMCksICgwLCAwLCAx
LjApLCAoMCwgMCwgLTEuMCksICgwLCAwLCAtMS4wKSwgKDAsIDAsIC0xLjApLCAoMCwgMCwgLTEuMCksICgwLCAxLjAsIDApLCAo
MCwgMS4wLCAwKSwgKDAsIDEuMCwgMCksICgwLCAxLjAsIDApLCAoMCwgLTEuMCwgMCksICgwLCAtMS4wLCAwKSwgKDAsIC0xLjAs
IDApLCAoMCwgLTEuMCwgMCksICgxLjAsIDAsIDApLCAoMS4wLCAwLCAwKSwgKDEuMCwgMCwgMCksICgxLjAsIDAsIDApLCAoLTEu
MCwgMCwgMCksICgtMS4wLCAwLCAwKSwgKC0xLjAsIDAsIDApLCAoLTEuMCwgMCwgMCldICgKaW50ZXJwb2xhdGlvbiA9ICJ2ZXJ0
ZXgiCikKdGV4Q29vcmQyZltdIHByaW12YXJzOnN0ID0gWygwLCAxLjApLCAoMS4wLCAxLjApLCAoMS4wLCAwKSwgKDAsIDApLCAo
MCwgMS4wKSwgKDEuMCwgMS4wKSwgKDEuMCwgMCksICgwLCAwKSwgKDAsIDEuMCksICgxLjAsIDEuMCksICgxLjAsIDApLCAoMCwg
MCksICgwLCAxLjApLCAoMS4wLCAxLjApLCAoMS4wLCAwKSwgKDAsIDApLCAoMCwgMS4wKSwgKDEuMCwgMS4wKSwgKDEuMCwgMCks
ICgwLCAwKSwgKDAsIDEuMCksICgxLjAsIDEuMCksICgxLjAsIDApLCAoMCwgMCldICgKaW50ZXJwb2xhdGlvbiA9ICJ2ZXJ0ZXgi
CikKcmVsIG1hdGVyaWFsOmJpbmRpbmcgPSA8L1Jvb3QvTWF0ZXJpYWxzL01hdGVyaWFsXzA+Cn0KfQp9ClBLAQIUABQAAAAAAAAA
AAAghRImmwcAAJsHAAAKAAAAAAAAAAAAAAAAAAAAAABtb2RlbC51c2RhUEsFBgAAAAABAAEAOAAAANsHAAAAAA==
"""
}
