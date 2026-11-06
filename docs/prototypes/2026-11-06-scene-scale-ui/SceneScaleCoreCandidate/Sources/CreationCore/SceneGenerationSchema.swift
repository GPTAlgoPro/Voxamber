import Foundation

/// The complete structural ScenePlan contract, generated without a script or resource.
///
/// ScenePlan/SceneSpec validation remains mandatory. JSON Schema cannot express
/// unique IDs, existing acyclic references, nondegenerate topology, attachment
/// bounds, the aggregate render budget, or whether a shape matches the request.
public enum SceneGenerationSchema {
    /// Returns deterministic Draft 2020-12 JSON Schema for new and edited scenes.
    /// Existing scenes are validated but do not restrict IDs, primitives or budgets.
    public static func jsonSchema(currentScene: SceneSpec? = nil) throws -> String {
        if let currentScene { _ = try SceneAttachmentResolver.resolve(currentScene) }

        let finiteLimit = Double(Float.greatestFiniteMagnitude)
        let finiteNumber = number(minimum: -finiteLimit, maximum: finiteLimit)
        let identifier: [String: Any] = ["type": "string", "pattern": "^[A-Za-z0-9_-]{1,32}$"]
        let definitions: [String: Any] = [
            "identifier": identifier,
            "color": ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"],
            // Bounds accept nominal SI decimals and Float snapshot precision.
            // They come from the same contract used by native/UI validation.
            "dimensions": object(properties: Dictionary(uniqueKeysWithValues:
                ["width", "height", "depth"].map {
                    ($0, number(minimum: SceneLimits.schemaMinimumDimension, maximum: Double(SceneLimits.maximumDimension)))
                }), required: ["width", "height", "depth"]),
            "origin": axes(minimum: Double(SceneLimits.positionRange.lowerBound), maximum: Double(SceneLimits.positionRange.upperBound)),
            "rotation": axes(minimum: Double(SceneLimits.rotationRange.lowerBound), maximum: Double(SceneLimits.rotationRange.upperBound)),
            "attachment": object(properties: [
                "parent": reference("identifier"),
                "face": ["type": "string", "enum": SceneNode.Attachment.allCases.map(\.rawValue)],
                "xOffset": number(minimum: Double(SceneLimits.offsetRange.lowerBound), maximum: Double(SceneLimits.offsetRange.upperBound), defaultValue: 0),
                "yOffset": number(minimum: Double(SceneLimits.offsetRange.lowerBound), maximum: Double(SceneLimits.offsetRange.upperBound), defaultValue: 0),
                "zOffset": number(minimum: Double(SceneLimits.offsetRange.lowerBound), maximum: Double(SceneLimits.offsetRange.upperBound), defaultValue: 0)
            ], required: ["parent", "face"]),
            "latheProfile": array(minimum: 2, maximum: SceneLimits.maximumProfilePoints,
                items: tuple([number(minimum: 0, maximum: finiteLimit), finiteNumber])),
            "extrusionProfile": array(minimum: 3, maximum: SceneLimits.maximumProfilePoints,
                items: tuple([finiteNumber, finiteNumber])),
            "meshVertices": array(minimum: 3, maximum: SceneLimits.maximumMeshVertices,
                items: tuple([finiteNumber, finiteNumber, finiteNumber])),
            "meshTriangles": array(minimum: 1, maximum: SceneLimits.maximumMeshTriangles,
                items: tuple(Array(repeating: ["type": "integer", "minimum": 0, "maximum": SceneLimits.maximumMeshVertices - 1], count: 3)))
        ]

        // Expand placement alternatives instead of `not`, `if`/`then` or
        // sibling `allOf` intersections, which native grammar adapters may ignore.
        // Disjoint complete objects also prevent origin+attach and foreign fields.
        let alternatives = SceneNode.Primitive.allCases.flatMap { primitive in
            Placement.allCases.map { placement in node(primitive: primitive, placement: placement) }
        }
        var schema = object(properties: [
            "name": [
                "type": "string", "minLength": 1,
                // Swift counts extended grapheme clusters; JSON Schema counts
                // Unicode code points. Do not reject a valid editable emoji or
                // combining-mark name with an incorrect maxLength: 40 bound.
                // The native response-byte gate bounds the whole JSON instead
                // of adding a huge per-string counter to the grammar.
                "description": "Native SceneSpec requires 1–40 extended grapheme clusters, a non-whitespace name, and no control characters."
            ],
            "nodes": array(minimum: 1, maximum: SceneSpec.maximumNodes,
                           items: ["oneOf": alternatives])
        ], required: ["name", "nodes"])
        schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        schema["$defs"] = definitions
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private enum Placement: CaseIterable { case groundedRoot, absoluteOrigin, attachment }

    private static func node(primitive: SceneNode.Primitive, placement: Placement) -> [String: Any] {
        var properties: [String: Any] = [
            "id": reference("identifier"),
            "primitive": ["type": "string", "const": primitive.rawValue],
            "dimensions": reference("dimensions"), "color": reference("color"),
            "rotation": reference("rotation"),
            "metallic": number(minimum: 0, maximum: 1, defaultValue: 0.1),
            "roughness": number(minimum: 0, maximum: 1, defaultValue: 0.45)
        ]
        var required = ["id", "primitive", "dimensions", "color"]
        switch primitive {
        case .lathe:
            properties["profile"] = reference("latheProfile"); required.append("profile")
        case .extrusion:
            properties["profile"] = reference("extrusionProfile"); required.append("profile")
        case .mesh:
            properties["vertices"] = reference("meshVertices")
            properties["triangles"] = reference("meshTriangles")
            required.append(contentsOf: ["vertices", "triangles"])
        default: break
        }
        switch placement {
        case .groundedRoot: break
        case .absoluteOrigin:
            properties["origin"] = reference("origin"); required.append("origin")
        case .attachment:
            properties["attach"] = reference("attachment"); required.append("attach")
        }
        return object(properties: properties, required: required)
    }

    private static func reference(_ name: String) -> [String: Any] { ["$ref": "#/$defs/" + name] }

    private static func number(minimum: Double, maximum: Double, defaultValue: Double? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "number", "minimum": minimum, "maximum": maximum]
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    private static func axes(minimum: Double, maximum: Double) -> [String: Any] {
        object(properties: Dictionary(uniqueKeysWithValues: ["x", "y", "z"].map {
            ($0, number(minimum: minimum, maximum: maximum))
        }), required: ["x", "y", "z"])
    }

    private static func object(properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func array(minimum: Int, maximum: Int, items: [String: Any]) -> [String: Any] {
        ["type": "array", "minItems": minimum, "maxItems": maximum, "items": items]
    }

    private static func tuple(_ items: [[String: Any]]) -> [String: Any] {
        ["type": "array", "prefixItems": items, "items": false,
         "minItems": items.count, "maxItems": items.count]
    }
}
