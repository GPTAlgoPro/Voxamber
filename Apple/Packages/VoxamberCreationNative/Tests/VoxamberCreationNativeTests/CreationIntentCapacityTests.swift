import XCTest
import Foundation
@testable import VoxamberCreationNative

final class CreationIntentCapacityTests: XCTestCase {
    func testBeyondFormerBoundaryAndExact512KeepEveryDecodedCharacter() throws {
        for length in [180, 181, 511, 512] {
            let positive = String(repeating: "a", count: length)
            let intent = try CreationIntentDecoder.decode(json(positive), sourcePrompt: "  原始  描述\n后续内容")
            XCTAssertEqual(intent.positivePrompt, positive)
            XCTAssertEqual(intent.positivePrompt.utf8.count, length)
            XCTAssertEqual(intent.title, "原始 描述")
            XCTAssertEqual(intent.negativePrompt, "")
        }
        XCTAssertThrowsError(try CreationIntentDecoder.decode(json(String(repeating: "a", count: 513)), sourcePrompt: "原描述"))
    }

    func testCapacityCountsDecodedASCIIInsteadOfJSONEscapeBytes() throws {
        let positive = String(repeating: "\\\"", count: 256)
        XCTAssertEqual(positive.count, 512)
        let raw = try json(positive)
        XCTAssertGreaterThan(raw.utf8.count, 512)
        let intent = try CreationIntentDecoder.decode(raw, sourcePrompt: "原描述")
        XCTAssertEqual(intent.positivePrompt, positive)
        XCTAssertThrowsError(try CreationIntentDecoder.decode(json(positive + "x"), sourcePrompt: "原描述"))
    }

    func testRegexCapacityAndIndependentDecoderGuardsPreserveWireContract() throws {
        let data = try XCTUnwrap(CreationIntentDecoder.schema.data(using: .utf8))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let pattern = try XCTUnwrap(properties["positivePrompt"]?["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        for (positive, expected) in [(String(repeating: "x", count: 512), true),
                                     (String(repeating: "x", count: 513), false),
                                     (String(repeating: "x", count: 511) + "é", false)] {
            let acceptedByRegex = regex.firstMatch(in: positive, range: NSRange(positive.startIndex..., in: positive)) != nil
            XCTAssertEqual(acceptedByRegex, expected)
            if expected { XCTAssertNoThrow(try CreationIntentDecoder.decode(json(positive), sourcePrompt: "原描述")) }
            else { XCTAssertThrowsError(try CreationIntentDecoder.decode(json(positive), sourcePrompt: "原描述")) }
        }
        // Foundation permits `$` before a final newline. Do not mistake a
        // regex-engine convention for relaxed decoder scalar/control guards.
        // This condition deliberately preserves the existing schema anchors.
        XCTAssertThrowsError(try CreationIntentDecoder.decode(
            json(String(repeating: "x", count: 511) + "\n"), sourcePrompt: "原描述"))
        XCTAssertEqual(schema["required"] as? [String], ["positivePrompt"])
        XCTAssertEqual(Set(properties.keys), ["positivePrompt"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    private func json(_ positive: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["positivePrompt": positive], options: [.sortedKeys]), as: UTF8.self)
    }
}
