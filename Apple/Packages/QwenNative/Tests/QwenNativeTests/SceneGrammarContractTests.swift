import Foundation
import CreationCore
import MLXGuidedGeneration
import XCTest
@testable import QwenNative

/// The product's full contract is tested through the actual native compiler and
/// matcher, without model weights or generated output. CreationCore is test-only.
final class SceneGrammarContractTests: XCTestCase {
    func testFullSchemaCompilesAndAcceptsCanonicalSnapshotsAndFreeGeometryLimits() throws {
        let allShapes = SceneSpec(name: "all_shapes", nodes: SceneNode.Primitive.allCases.map {
            SceneNode.defaultNode(primitive: $0, id: $0.rawValue)
        })
        let maximumNodes = SceneSpec(name: "all_parts", nodes: (0..<32).map {
            SceneNode.defaultNode(primitive: .box, id: "part_\($0)")
        })
        var tiny = SceneNode.defaultNode(primitive: .box, id: "tiny")
        tiny.size = [0.02,0.02,2.5]
        tiny.position = [-3,3,0]
        tiny.rotation = [-360,360,0]
        tiny.metallic = 0; tiny.roughness = 1
        let floatBoundary = SceneSpec(name: String(repeating: "a\u{0301}", count: 40), nodes: [tiny])
        var mesh = SceneNode.defaultNode(primitive: .mesh, id: "surface")
        mesh.vertices = [[0,0,0],[2,0,0],[0,2,1]] + (3..<1_024).map { [Float($0),0,0] }
        mesh.triangles = Array(repeating: [0,1,2], count: 2_048)
        var lathe = SceneNode.defaultNode(primitive: .lathe, id: "vessel")
        lathe.profile = (0..<64).map { [Float($0 % 2 + 3), Float($0) - 31] }
        var extrusion = SceneNode.defaultNode(primitive: .extrusion, id: "outline")
        extrusion.profile = (0..<64).map { index in
            let angle = Double(index) * 2 * .pi / 64
            return [Float(4 * cos(angle)), Float(4 * sin(angle))]
        }
        let free = SceneSpec(name: "free_geometry", nodes: [mesh, lathe, extrusion])
        // Canonical storage JSON stays untouched. Explicitly reorder fixture JSON
        // to the compiler's required-first key order, and compare decoded values.
        // Child-before-parent refers to node array order, which stays unrestricted.
        let reverseAttachment = ##"{"name":"attachment","nodes":[{"attach":{"face":"top","parent":"root","xOffset":0.1},"color":"#123ABC","dimensions":{"depth":0.2,"height":0.2,"width":0.2},"id":"child","primitive":"sphere"},{"color":"#ffffff","dimensions":{"depth":0.4,"height":0.4,"width":0.4},"id":"root","primitive":"box"}]}"##
        let scientific = ##"{"name":"scientific","nodes":[{"id":"shape","primitive":"lathe","dimensions":{"width":2e-1,"height":3e-1,"depth":4e-1},"color":"#ABCDEF","profile":[[0,0],[5e-1,1e-1],[0,1]]}]}"##
        let scenes = [allShapes, maximumNodes, floatBoundary, free]
        let originals = try scenes.map { try ScenePlan.snapshot($0) } + [reverseAttachment, scientific]
        // Keep the final hand-written fixture's scientific notation verbatim.
        let snapshots = try originals.dropLast().map(fixtureRequiredFirstPlan) + [scientific]
        let vocab = ["<eos>"] + Set(snapshots.flatMap { $0.unicodeScalars.map(String.init) }).sorted()
        let ids = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($0.element, Int32($0.offset)) })
        let tokenizer = try GrammarTokenizer(vocab: vocab, vocabType: .raw, eosTokenId: 0)
        let schema = try SceneGenerationSchema.jsonSchema(currentScene: free)
        let began = ContinuousClock.now
        let template = try NativeGrammarTemplate(tokenizer: tokenizer, schema: schema)
        XCTAssertTrue(template.metadata.floatBoundsRequireNativeValidation)
        XCTAssertNotEqual(template.metadata.originalSchemaSHA256, template.metadata.compiledSchemaSHA256)
        XCTAssertLessThan(began.duration(to: .now), .seconds(30), "Native schema compilation must stay bounded")
        for (fixture, text) in snapshots.enumerated() {
            let matcher = try template.freshConstraint()
            for (offset, scalar) in text.unicodeScalars.enumerated() {
                do { _ = try matcher.commitToken(ids[String(scalar)]!) }
                catch {
                    // These are fixed synthetic fixtures, never user responses.
                    XCTFail("Native matcher rejected fixture=\(fixture) scalarOffset=\(offset) suffix=\(String(String.UnicodeScalarView(text.unicodeScalars.prefix(offset + 1))).suffix(100))")
                    return
                }
            }
            XCTAssertTrue(try matcher.commitToken(0).isTerminated)
            do {
                XCTAssertEqual(try ScenePlan.decodeModelResponse(text),
                               try ScenePlan.decodeModelResponse(originals[fixture]))
            }
            catch { XCTFail("Native decode rejected synthetic fixture=\(fixture): \(error)"); return }
        }
    }

    func testSyntaxCountsAndIntegerBoundsStayConstrainedWhileCoreChecksFloatBounds() throws {
        func encode(_ nodes: [[String: Any]]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["name": "synthetic", "nodes": nodes],
                                                  options: [.sortedKeys])
            return try fixtureRequiredFirstPlan(String(decoding: data, as: UTF8.self))
        }
        let box: [String: Any] = ["id": "box", "primitive": "box", "color": "#AAAAAA",
            "dimensions": ["width": 0.2, "height": 0.3, "depth": 0.4]]
        var negativeRadius = box
        negativeRadius["primitive"] = "lathe"
        negativeRadius["profile"] = [[-0.1,0],[0.4,1]]
        var tall = box; tall["dimensions"] = ["width": 0.2, "height": 4.5, "depth": 0.4]
        var foreign = box; foreign["script"] = "forbidden"
        var mesh = box; mesh["primitive"] = "mesh"
        mesh["vertices"] = [[0,0,0],[1,0,0],[0,1,0]]
        mesh["triangles"] = [[-1,1,2]]
        let extraParts = (0..<33).map { index in
            var value = box; value["id"] = "part_\(index)"; return value
        }
        let valid = try encode([box])
        let deferred = try [encode([negativeRadius]), encode([tall])]
        let rejected = try [encode([foreign]), encode([mesh]), encode(extraParts)] +
            [valid.replacingOccurrences(of: "\"color\":\"#AAAAAA\"", with: "\"color\":\"#AAAAAA\"\"")]
        let texts = [valid] + deferred + rejected
        let vocab = ["<eos>"] + Set(texts.flatMap { $0.unicodeScalars.map(String.init) }).sorted()
        let ids = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($0.element, Int32($0.offset)) })
        let tokenizer = try GrammarTokenizer(vocab: vocab, vocabType: .raw, eosTokenId: 0)
        let template = try NativeGrammarTemplate(tokenizer: tokenizer, schema: SceneGenerationSchema.jsonSchema())
        func accepts(_ text: String) throws -> Bool {
            let matcher = try template.freshConstraint()
            do {
                for scalar in text.unicodeScalars { _ = try matcher.commitToken(ids[String(scalar)]!) }
                return try matcher.commitToken(0).isTerminated
            } catch { return false }
        }
        XCTAssertTrue(try accepts(valid))
        for text in deferred {
            XCTAssertTrue(try accepts(text), "Float syntax stays expressible")
            XCTAssertThrowsError(try ScenePlan.decodeModelResponse(text), "Native bounds must still reject")
        }
        for text in rejected { XCTAssertFalse(try accepts(text)) }
    }

    func testNativeGrammarAcceptsIDPrimitiveAndWidthHeightDepthFirstButRejectsOtherOrders() throws {
        let ordered = ##"{"name":"order_probe","nodes":[{"id":"part","primitive":"box","dimensions":{"width":0.2,"height":0.3,"depth":0.4},"color":"#AAAAAA"}]}"##
        let reversedDimensions = ordered.replacingOccurrences(
            of: #""width":0.2,"height":0.3,"depth":0.4"#,
            with: #""depth":0.4,"height":0.3,"width":0.2"#)
        let canonical = try ScenePlan.snapshot(ScenePlan.decodeModelResponse(ordered))
        let texts = [ordered, reversedDimensions, canonical]
        let vocab = ["<eos>"] + Set(texts.flatMap { $0.unicodeScalars.map(String.init) }).sorted()
        let ids = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($0.element, Int32($0.offset)) })
        let tokenizer = try GrammarTokenizer(vocab: vocab, vocabType: .raw, eosTokenId: 0)
        let template = try NativeGrammarTemplate(tokenizer: tokenizer, schema: SceneGenerationSchema.jsonSchema())
        func accepts(_ text: String) throws -> Bool {
            let matcher = try template.freshConstraint()
            do {
                for scalar in text.unicodeScalars { _ = try matcher.commitToken(ids[String(scalar)]!) }
                return try matcher.commitToken(0).isTerminated
            } catch { return false }
        }
        XCTAssertTrue(try accepts(ordered))
        XCTAssertFalse(try accepts(reversedDimensions))
        XCTAssertFalse(try accepts(canonical), "Arbitrary JSON key ordering is not supported")
        XCTAssertEqual(try ScenePlan.decodeModelResponse(ordered), try ScenePlan.decodeModelResponse(canonical))
        XCTAssertEqual(try ScenePlan.decodeModelResponse(fixtureRequiredFirstPlan(canonical)),
                       try ScenePlan.decodeModelResponse(fixtureRequiredFirstPlan(ordered)))
    }
}

/// Test fixture conversion only. Stored ScenePlan snapshots are never modified by
/// production code. Match the full schema's required[] order and prove native
/// decoded values equal the untouched original snapshots in the tests above.
private func fixtureRequiredFirstPlan(_ text: String) throws -> String {
    enum Position { case root, nodes, node, dimensions, axes, attachment, literal }
    func literal(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
    }
    func render(_ value: Any, at position: Position) throws -> String {
        if position == .literal { return try literal(value) }
        if let nodes = value as? [Any], position == .nodes {
            return try "[" + nodes.map { try render($0, at: .node) }.joined(separator: ",") + "]"
        }
        guard let object = value as? [String: Any] else { return try literal(value) }
        var required: [String]
        switch position {
        case .root: required = ["name", "nodes"]
        case .node:
            switch object["primitive"] as? String {
            case "mesh": required = ["id", "primitive", "dimensions", "color", "vertices", "triangles"]
            case "lathe", "extrusion": required = ["id", "primitive", "dimensions", "color", "profile"]
            default: required = ["id", "primitive", "dimensions", "color"]
            }
            // Placement alternatives make their selected origin/attach field
            // required too, after the primitive's required geometry fields.
            if object["origin"] != nil { required.append("origin") }
            if object["attach"] != nil { required.append("attach") }
        case .dimensions: required = ["width", "height", "depth"]
        case .axes: required = ["x", "y", "z"]
        case .attachment: required = ["parent", "face"]
        case .nodes, .literal: required = []
        }
        let keys = required.filter { object[$0] != nil } + object.keys.filter { !required.contains($0) }.sorted()
        let pairs = try keys.map { key -> String in
            let childPosition: Position
            switch (position, key) {
            case (.root, "nodes"): childPosition = .nodes
            case (.node, "dimensions"): childPosition = .dimensions
            case (.node, "origin"), (.node, "rotation"): childPosition = .axes
            case (.node, "attach"): childPosition = .attachment
            default: childPosition = .literal
            }
            return try literal(key) + ":" + render(object[key]!, at: childPosition)
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }
    return try render(JSONSerialization.jsonObject(with: Data(text.utf8)), at: .root)
}
