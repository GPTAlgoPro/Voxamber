import Foundation
import CoreFoundation
import Testing
@testable import CreationCore

@Test func generationSchemaKeepsFullNodeBudgetAndAllPlacementOrders() throws {
    let schema = try SchemaContract(try SceneGenerationSchema.jsonSchema())
    let full = SceneSpec(name: "完整编辑范围", nodes: (0..<SceneSpec.maximumNodes).map {
        SceneNode.defaultNode(primitive: .box, id: "part_\($0)")
    })
    try schema.accept(try ScenePlan.snapshot(full))
    #expect(try ScenePlan.decodeModelResponse(ScenePlan.snapshot(full)) == full)

    var child = schemaNode("child")
    child["attach"] = ["parent": "root", "face": "top", "xOffset": 0.1]
    // An attached first node and an unattached later root are both valid.
    let reverseOrder = try schemaPlan([child, schemaNode("root")])
    try schema.accept(reverseOrder)
    #expect(try ScenePlan.decodeModelResponse(reverseOrder).nodes.count == 2)
    #expect(throws: SchemaContract.Failure.self) {
        try schema.accept(schemaPlan((0...SceneSpec.maximumNodes).map { schemaNode("part_\($0)") }))
    }
}

@Test func generationSchemaAcceptsEditableFreeGeometryAtItsActualLimits() throws {
    var mesh = SceneNode.defaultNode(primitive: .mesh, id: "surface")
    mesh.vertices = [[0,0,0],[2,0,0],[0,2,1]] + (3..<1_024).map { [Float($0),0,0] }
    mesh.triangles = Array(repeating: [0,1,2], count: 2_048)
    mesh.position = [-0.3,0.7,0.6]
    mesh.rotation = [17,-28,39]
    var lathe = SceneNode.defaultNode(primitive: .lathe, id: "vessel")
    lathe.profile = (0..<64).map { [Float($0 % 2 + 3), Float($0) - 31] }
    var extrusion = SceneNode.defaultNode(primitive: .extrusion, id: "outline")
    extrusion.profile = (0..<64).map { index in
        let angle = Double(index) * 2 * .pi / 64
        return [Float(4 * cos(angle)), Float(4 * sin(angle))]
    }
    let source = SceneSpec(name: "完整自由几何", nodes: [mesh, lathe, extrusion])
    try source.validate()
    let text = try ScenePlan.snapshot(source)
    let schema = try SchemaContract(try SceneGenerationSchema.jsonSchema(currentScene: source))
    try schema.accept(text)
    let decoded = try ScenePlan.decodeModelResponse(text)
    #expect(decoded == source)
    #expect(decoded.nodes[0].vertices?.count == 1_024)
    #expect(decoded.nodes[0].triangles?.count == 2_048)
    #expect(decoded.nodes[1].profile?.count == 64)
    #expect(decoded.nodes[2].profile?.count == 64)
    #expect(try SceneGenerator.generate(for: decoded).count == 3)
}

@Test func generationSchemaPreservesSnapshotFloatBoundaryAndGraphemeNames() throws {
    var tiny = SceneNode.defaultNode(primitive: .box, id: "tiny")
    tiny.size = [0.02,0.02,2.5]
    tiny.position = [-3,3,0]
    tiny.rotation = [-360,360,0]
    tiny.metallic = 0; tiny.roughness = 1
    let name = String(repeating: "a\u{0301}", count: 40)
    #expect(name.count == 40 && name.unicodeScalars.count > 40)
    let source = SceneSpec(name: name, nodes: [tiny])
    try source.validate()
    let schema = try SchemaContract(try SceneGenerationSchema.jsonSchema(currentScene: source))
    let snapshot = try ScenePlan.snapshot(source)
    try schema.accept(snapshot)
    #expect(try ScenePlan.decodeModelResponse(snapshot) == source)
}

@Test func generationSchemaLeavesMaterialsRotationAndPlacementOptional() throws {
    let schema = try SchemaContract(try SceneGenerationSchema.jsonSchema())
    for primitive in SceneNode.Primitive.allCases {
        var node = schemaNode("free", primitive)
        let example = SceneNode.defaultNode(primitive: primitive, id: "free")
        if let profile = example.profile { node["profile"] = profile }
        if let vertices = example.vertices { node["vertices"] = vertices }
        if let triangles = example.triangles { node["triangles"] = triangles }
        let text = try schemaPlan([node])
        try schema.accept(text)
        let result = try ScenePlan.decodeModelResponse(text)
        #expect(result.nodes[0].rotation == [0,0,0])
        #expect(result.nodes[0].metallic == 0.1 && result.nodes[0].roughness == 0.45)
    }
    // A zero-radius endpoint is a supported pole, not a negative radius.
    var lathe = schemaNode("pole", .lathe)
    lathe["profile"] = [[0,0],[4,10]]
    try schema.accept(schemaPlan([lathe]))
    #expect(try ScenePlan.decodeModelResponse(schemaPlan([lathe])).nodes.count == 1)
}

@Test func generationSchemaRejectsMalformedFieldsRangesAndPrimitiveGeometry() throws {
    let schema = try SchemaContract(try SceneGenerationSchema.jsonSchema())
    let base = schemaNode("part")
    var cases: [[String:Any]] = []
    var unknown = base; unknown["script"] = "execute()"; cases.append(unknown)
    var both = base
    both["origin"] = ["x":0,"y":0,"z":0]
    both["attach"] = ["parent":"parent","face":"top"]; cases.append(both)
    var axes = base; axes["origin"] = ["x":0,"y":0]; cases.append(axes)
    var rotation = base; rotation["rotation"] = ["x":361,"y":0,"z":0]; cases.append(rotation)
    var size = base; size["dimensions"] = ["width":0.01,"height":0.3,"depth":0.4]; cases.append(size)
    var large = base; large["dimensions"] = ["width":2.6,"height":0.3,"depth":0.4]; cases.append(large)
    var boolean = base; boolean["dimensions"] = ["width":true,"height":0.3,"depth":0.4]; cases.append(boolean)
    var color = base; color["color"] = "jade"; cases.append(color)
    var material = base; material["roughness"] = 1.1; cases.append(material)
    var foreign = base; foreign["profile"] = [[0,0],[1,1]]; cases.append(foreign)
    var lathe = schemaNode("part", .lathe)
    lathe["profile"] = [[-0.1,0],[0.4,1]]; cases.append(lathe)
    lathe["profile"] = Array(repeating: [0.4,1], count: 65); cases.append(lathe)
    var extrusion = schemaNode("part", .extrusion)
    extrusion["profile"] = [[0,0],[1,1]]; cases.append(extrusion)
    var mesh = schemaNode("part", .mesh)
    mesh["vertices"] = [[0,0,0],[1,0,0],[0,1,0]]; cases.append(mesh)
    mesh["triangles"] = [[0,1,2,0]]; cases.append(mesh)
    mesh["triangles"] = [[-1,1,2]]; cases.append(mesh)
    mesh["triangles"] = [[0,1,2]]
    mesh["vertices"] = Array(repeating: [0,0,0], count: 1_025); cases.append(mesh)
    mesh["vertices"] = [[0,0,0],[1,0,0],[0,1,0]]
    mesh["triangles"] = Array(repeating: [0,1,2], count: 2_049); cases.append(mesh)
    for node in cases {
        let text = try schemaPlan([node])
        #expect(throws: SchemaContract.Failure.self) { try schema.accept(text) }
        #expect(throws: CreationError.self) { try ScenePlan.decodeModelResponse(text) }
    }
    #expect(throws: SchemaContract.Failure.self) {
        try schema.accept(##"{"name":"x","nodes":[],"unexpected":0}"##)
    }
}

@Test func generationSchemaDoesNotReplaceNativeGraphAndTopologyValidation() throws {
    let schema = try SchemaContract(try SceneGenerationSchema.jsonSchema())
    var missing = schemaNode("child"); missing["attach"] = ["parent":"unknown","face":"top"]
    var cycleA = schemaNode("a"); cycleA["attach"] = ["parent":"b","face":"top"]
    var cycleB = schemaNode("b"); cycleB["attach"] = ["parent":"a","face":"top"]
    var mesh = schemaNode("surface", .mesh)
    mesh["vertices"] = [[0,0,0],[1,0,0],[0,1,0]]
    mesh["triangles"] = [[0,1,99]]
    var degenerate = mesh; degenerate["triangles"] = [[0,0,1]]
    for nodes in [[missing],[cycleA,cycleB],[schemaNode("same"),schemaNode("same")],[mesh],[degenerate]] {
        let text = try schemaPlan(nodes)
        try schema.accept(text)
        #expect(throws: CreationError.self) { try ScenePlan.decodeModelResponse(text) }
    }
    let duplicates = ##"{"name":"x","nodes":[{"id":"a","primitive":"box","dimensions":{"width":0.2,"width":0.3,"height":0.4,"depth":0.5},"color":"#FFFFFF"}]}"##
    #expect(throws: CreationError.self) { try ScenePlan.decodeModelResponse(duplicates) }
}

@Test func generationSchemaIsDeterministicAndRejectsInvalidEditInput() throws {
    let first = try SceneGenerationSchema.jsonSchema()
    let repeated = try SceneGenerationSchema.jsonSchema()
    let editing = try SceneGenerationSchema.jsonSchema(currentScene: .robot)
    #expect(first == repeated)
    #expect(first == editing)
    let object = try StrictJSONObject.decode(first, maximumBytes: SceneSpec.maximumResponseBytes)
    func inspect(_ value: Any) {
        if let dictionary = value as? [String:Any] {
            if dictionary["type"] as? String == "object" {
                #expect(dictionary["additionalProperties"] as? Bool == false)
            }
            #expect(dictionary["not"] == nil && dictionary["allOf"] == nil && dictionary["if"] == nil)
            for child in dictionary.values { inspect(child) }
        } else if let array = value as? [Any] { for child in array { inspect(child) } }
    }
    inspect(object)
    #expect(throws: CreationError.self) {
        try SceneGenerationSchema.jsonSchema(currentScene: SceneSpec(name: "", nodes: []))
    }
}

private func schemaNode(_ id: String, _ primitive: SceneNode.Primitive = .box) -> [String:Any] {
    ["id":id,"primitive":primitive.rawValue,"dimensions":["width":0.3,"height":0.4,"depth":0.5],"color":"#3ABDA7"]
}

private func schemaPlan(_ nodes: [[String:Any]]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["name":"自由题材","nodes":nodes],
        options: .sortedKeys), as: UTF8.self)
}

/// A small independent evaluator of the standard keywords this contract emits.
/// It validates actual plans/snapshots, not the builder's private helpers. Grammar
/// engine compilation/acceptance is tested separately by the native MLX adapter.
private struct SchemaContract {
    enum Failure: Error { case invalidSchema, mismatch }
    let root: [String:Any]
    init(_ text: String) throws { root = try StrictJSONObject.decode(text, maximumBytes: SceneSpec.maximumResponseBytes) }

    func accept(_ text: String) throws {
        try check(StrictJSONObject.decode(text, maximumBytes: SceneSpec.maximumResponseBytes), root)
    }

    private func check(_ value: Any, _ rawSchema: Any) throws {
        if let allowed = rawSchema as? Bool { if !allowed { throw Failure.mismatch }; return }
        guard let schema = rawSchema as? [String:Any] else { throw Failure.invalidSchema }
        if let ref = schema["$ref"] as? String {
            guard ref.hasPrefix("#/$defs/"), let defs = root["$defs"] as? [String:Any],
                  let target = defs[String(ref.dropFirst(8))] else { throw Failure.invalidSchema }
            try check(value, target); return
        }
        if let alternatives = schema["oneOf"] as? [[String:Any]] {
            let count = alternatives.filter { (try? check(value, $0)) != nil }.count
            guard count == 1 else { throw Failure.mismatch }; return
        }
        if let constant = schema["const"] as? String, value as? String != constant { throw Failure.mismatch }
        if let choices = schema["enum"] as? [String], !choices.contains(value as? String ?? "") { throw Failure.mismatch }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String:Any], let properties = schema["properties"] as? [String:Any],
                  let required = schema["required"] as? [String], required.allSatisfy({ object[$0] != nil }) else { throw Failure.mismatch }
            if schema["additionalProperties"] as? Bool == false,
               !Set(object.keys).isSubset(of: Set(properties.keys)) { throw Failure.mismatch }
            for (key, child) in object { if let property = properties[key] { try check(child, property) } }
        case "array":
            guard let array = value as? [Any] else { throw Failure.mismatch }
            if let min = schema["minItems"] as? Int, array.count < min { throw Failure.mismatch }
            if let max = schema["maxItems"] as? Int, array.count > max { throw Failure.mismatch }
            let prefix = schema["prefixItems"] as? [Any] ?? []
            for index in array.indices {
                if index < prefix.count { try check(array[index], prefix[index]) }
                else if let item = schema["items"] { try check(array[index], item) }
            }
        case "number", "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { throw Failure.mismatch }
            let numberValue = number.doubleValue
            if schema["type"] as? String == "integer", numberValue.rounded() != numberValue { throw Failure.mismatch }
            if let min = schema["minimum"] as? Double, numberValue < min { throw Failure.mismatch }
            if let max = schema["maximum"] as? Double, numberValue > max { throw Failure.mismatch }
        case "string":
            guard let string = value as? String else { throw Failure.mismatch }
            if let min = schema["minLength"] as? Int, string.unicodeScalars.count < min { throw Failure.mismatch }
            if let max = schema["maxLength"] as? Int, string.unicodeScalars.count > max { throw Failure.mismatch }
            if let pattern = schema["pattern"] as? String {
                let regex = try NSRegularExpression(pattern: pattern)
                guard regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else { throw Failure.mismatch }
            }
        default: throw Failure.invalidSchema
        }
    }
}
