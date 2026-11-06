import XCTest
@testable import VoxamberCreationNative

final class CreationImageReceiptTests: XCTestCase {
    func testKleinPreservesHighSeedBitsAndReportsAllComponents() throws {
        let seed = UInt64.max - 42
        let value = CreationImageBackend.klein4B.receipt(requestedSeed: seed)
        XCTAssertEqual(value.seed, seed)
        XCTAssertEqual(value.width, 512); XCTAssertEqual(value.height, 512)
        XCTAssertEqual(value.steps, 4); XCTAssertEqual(value.guidance, 1)
        XCTAssertEqual(Set(value.componentRevisions.keys), ["transformer", "textEncoder", "smallVAE"])
        XCTAssertEqual(value.parameters["transformerVariant"], "klein4B_4bit")
        XCTAssertEqual(try JSONDecoder().decode(CreationImageStageReceipt.self, from: JSONEncoder().encode(value)), value)
    }

    func testSDXLRetainsItsActualUInt32SeedAndFixedConfiguration() throws {
        let requested: UInt64 = 0x12345678abcdef01
        let value = CreationImageBackend.sdxl.receipt(requestedSeed: requested)
        XCTAssertEqual(value.seed, 0xabcdef01)
        XCTAssertEqual(value.width, 768); XCTAssertEqual(value.steps, 20); XCTAssertEqual(value.guidance, 7.5)
        XCTAssertEqual(value.parameters["tokenizerPolicy"], "openai-clip-3bee281-native-v1")
    }

    func testConfigurationIdentityExcludesSeedAndDistinguishesBackends() throws {
        let a = CreationImageBackend.klein4B.receipt(requestedSeed: 1)
        let b = CreationImageBackend.klein4B.receipt(requestedSeed: UInt64.max)
        let c = CreationImageBackend.sdxl.receipt(requestedSeed: 1)
        XCTAssertEqual(try a.configurationSHA256, try b.configurationSHA256)
        XCTAssertNotEqual(try a.configurationSHA256, try c.configurationSHA256)
        XCTAssertEqual(try a.configurationSHA256.count, 64)
    }

    func testExistingResourceInitializerKeepsOriginalBackend() {
        let folder = URL(fileURLWithPath: "/tmp/receipt-test")
        let old = CreationResources(intentModelDirectory: folder, imageModelDirectory: folder, shapeModelFile: folder)
        XCTAssertEqual(old.imageBackend, .sdxl)
    }
}
