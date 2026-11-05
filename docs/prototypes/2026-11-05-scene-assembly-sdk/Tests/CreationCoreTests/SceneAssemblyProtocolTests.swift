import Foundation
import Testing
@testable import CreationCore

@Test func assemblyOutlineAllowsForestsAndChildBeforeParentButRejectsInvalidGraphs() throws {
    let forest = try SceneAssemblyOutline.decodeModelResponse(assemblyJSON([
        "name":"forest", "parts":[
            ["id":"child","primitive":"sphere","purpose":"decoration","parent":"a","face":"top"],
            ["id":"b","primitive":"box","purpose":"independent object"],
            ["id":"a","primitive":"box","purpose":"main object"]
        ]
    ]))
    #expect(forest.parts.filter { $0.parent == nil }.count == 2)
    let bad: [[[String:Any]]] = [
        [["id":"same","primitive":"box","purpose":"x"],["id":"same","primitive":"box","purpose":"y"]],
        [["id":"a","primitive":"box","purpose":"x","parent":"missing","face":"top"]],
        [["id":"a","primitive":"box","purpose":"x","parent":"b","face":"top"],
         ["id":"b","primitive":"box","purpose":"y","parent":"a","face":"bottom"]],
        [["id":"a","primitive":"box","purpose":"x","parent":"a","face":"top"]],
        [["id":"a","primitive":"box","purpose":"x","face":"top"]],
        [["id":"a","primitive":"box","purpose":"x","script":"execute()"]]
    ]
    for parts in bad {
        #expect(throws:CreationError.self) {
            try SceneAssemblyOutline.decodeModelResponse(assemblyJSON(["name":"bad","parts":parts]))
        }
    }
    let duplicate = #"{"name":"x","parts":[{"id":"a","id":"b","primitive":"box","purpose":"x"}]}"#
    #expect(throws:CreationError.self) { try SceneAssemblyOutline.decodeModelResponse(duplicate) }
    let full = try SceneAssemblyOutline(name:"all", parts:(0..<32).map {
        .init(id:"part_\($0)",primitive:.box,purpose:"independent object")
    })
    #expect(full.parts.count == 32)
}

@Test func assemblyRequestsKeepFullDefinitionsAndHandleZeroChildrenWithoutInvalidEmptyUnions() throws {
    let outline = try SceneAssemblyOutline(name:"single", parts:[.init(id:"one",primitive:.mesh,purpose:"surface")])
    let placement = try SceneAssemblyPlacement.decodeModelResponse(#"{"anchors":[]}"#, outline:outline)
    let call = try SceneAssemblyProtocol.placementRequest("任意曲面", outline:outline)
    let schema = try StrictJSONObject.decode(call.jsonSchema)
    let array = try #require((schema["properties"] as? [String:Any])?["anchors"] as? [String:Any])
    #expect(array["minItems"] as? Int == 0 && array["maxItems"] as? Int == 0)
    #expect(array["items"] as? Bool == false)
    #expect(array["oneOf"] == nil && array["prefixItems"] == nil)
    let geometry = try SceneAssemblyProtocol.geometryRequest("任意曲面", outline:outline, placement:placement)
    let full = try StrictJSONObject.decode(SceneGenerationSchema.jsonSchema())
    let narrowed = try StrictJSONObject.decode(geometry.jsonSchema)
    #expect((full["$defs"] as? NSDictionary) == (narrowed["$defs"] as? NSDictionary))
    let nodes = try #require((narrowed["properties"] as? [String:Any])?["nodes"] as? [String:Any])
    let first = try #require((nodes["prefixItems"] as? [[String:Any]])?.first)
    #expect((first["oneOf"] as? [[String:Any]])?.count == 2)
    #expect(geometry.maxTokens == 3072 && call.maxTokens == 3072)
    let firstCall = try SceneAssemblyProtocol.outlineRequest("任意曲面")
    let firstSchema = try StrictJSONObject.decode(firstCall.jsonSchema)
    let parts = try #require((firstSchema["properties"] as? [String:Any])?["parts"] as? [String:Any])
    #expect(parts["maxItems"] as? Int == 32)
    #expect(parts["prefixItems"] == nil)
}

@Test func assemblyPlacementRetainsLegacyDeltasAndRejectsNormalAxesEvenWhenZero() throws {
    for face in SceneNode.Attachment.allCases {
        let outline = try assemblyOutline(face:face)
        let keys = AssemblyContract.deltaKeys(for:face)
        var row: [String:Any] = ["id":"child","anchor":"center"]
        for (axis,value) in [("xOffset",Float(-0.13)),("yOffset",Float(0.15)),("zOffset",Float(0.17))] where keys.contains(axis) {
            row[axis] = value
        }
        let placement = try SceneAssemblyPlacement.decodeModelResponse(assemblyJSON(["anchors":[row]]), outline:outline)
        var nodes = assemblyNodes()
        var attach = row; attach.removeValue(forKey:"id")
        attach["parent"] = "parent"; attach["face"] = face.rawValue
        nodes[1]["attach"] = attach
        let actual = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),
            outline:outline, placement:placement)
        attach.removeValue(forKey:"anchor")
        nodes[1]["attach"] = attach
        let old = try ScenePlan.decodeModelResponse(assemblyJSON(["name":outline.name,"nodes":nodes]))
        #expect(actual == old, "center plus explicit deltas preserves the legacy placement")
        let call = try SceneAssemblyProtocol.geometryRequest("abstract fixture", outline:outline, placement:placement)
        let schema = try StrictJSONObject.decode(call.jsonSchema)
        let rows = try #require(((schema["properties"] as? [String:Any])?["nodes"] as? [String:Any])?["prefixItems"] as? [[String:Any]])
        let fields = try #require(rows[1]["properties"] as? [String:Any])
        let selected = try #require((fields["attach"] as? [String:Any])?["properties"] as? [String:Any])
        #expect(Set(selected.keys) == Set(["parent","face","anchor"]).union(keys))
        if face != .inside {
            let forbidden = Set(["xOffset","yOffset","zOffset"]).subtracting(keys).first!
            var invalid = row; invalid[forbidden] = 0
            #expect(throws:CreationError.self) {
                try SceneAssemblyPlacement.decodeModelResponse(assemblyJSON(["anchors":[invalid]]), outline:outline)
            }
        }
    }
    let outline = try assemblyOutline(face:.inside)
    for row in [["id":"child","anchor":"front"], ["id":"child","anchor":"center","extra":"x"]] {
        #expect(throws:CreationError.self) {
            try SceneAssemblyPlacement.decodeModelResponse(assemblyJSON(["anchors":[row]]), outline:outline)
        }
    }
    #expect(throws:CreationError.self) {
        try SceneAssemblyPlacement.decodeModelResponse(#"{"anchors":[{"id":"child","anchor":"center","xOffset":null}]}"#, outline:outline)
    }
}

@Test func assemblyAnchorAllFacesAlignActualBoundsWithoutDoubleCenterOrNormal() throws {
    let cases: [(SceneNode.Attachment,SceneFaceAnchor,[(Int,Bool)])] = [
        (.top,.frontLeft,[(0,false),(2,true)]),(.bottom,.backRight,[(0,true),(2,false)]),
        (.front,.topRight,[(0,true),(1,true)]),(.back,.bottomLeft,[(0,false),(1,false)]),
        (.left,.frontBottom,[(2,true),(1,false)]),(.right,.backTop,[(2,false),(1,true)]),
        (.inside,.center,[])
    ]
    for (face,anchor,edges) in cases {
        let outline = try assemblyOutline(face:face)
        let placement = try SceneAssemblyPlacement(anchors:[.init(id:"child",anchor:anchor)],outline:outline)
        var nodes = assemblyNodes()
        nodes[0]["origin"] = ["x":0.7,"y":0.6,"z":-0.4]
        nodes[0]["rotation"] = ["x":15,"y":20,"z":-11]
        nodes[1]["rotation"] = ["x":-8,"y":17,"z":13]
        nodes[1]["attach"] = ["parent":"parent","face":face.rawValue,"anchor":anchor.rawValue]
        let scene = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),
            outline:outline, placement:placement)
        let parent = try SceneGenerator.bounds(for:scene.nodes[0]), child = try SceneGenerator.bounds(for:scene.nodes[1])
        for (axis,high) in edges {
            #expect(abs((high ? parent.maximum[axis] : parent.minimum[axis]) -
                        (high ? child.maximum[axis] : child.minimum[axis])) < 5e-6)
        }
        let normal: (Int,Bool)? = switch face {
        case .top: (1,true); case .bottom: (1,false)
        case .front: (2,true); case .back: (2,false)
        case .left: (0,false); case .right: (0,true); case .inside: nil
        }
        if let (axis,positive) = normal {
            let overlap = positive ? parent.maximum[axis]-child.minimum[axis] : child.maximum[axis]-parent.minimum[axis]
            #expect(abs(overlap-0.003) < 5e-6)
        } else {
            for axis in 0..<3 {
                #expect(abs((parent.minimum[axis]+parent.maximum[axis]) - (child.minimum[axis]+child.maximum[axis])) < 5e-6)
            }
        }
    }
}

@Test func assemblyRotatedFreeformUsesActualExtentsAndExplicitResiduals() throws {
    let outline = try SceneAssemblyOutline(name:"free", parts:[
        .init(id:"parent",primitive:.mesh,purpose:"main shape"),
        .init(id:"child",primitive:.extrusion,purpose:"detail",parent:"parent",face:.top)
    ])
    let placement = try SceneAssemblyPlacement(anchors:[.init(id:"child",anchor:.frontLeft,xOffset:0.07,zOffset:-0.03)],outline:outline)
    var nodes = assemblyNodes()
    nodes[0]["primitive"] = "mesh"
    nodes[0]["vertices"] = [[0,0,0],[4,0,0],[0,2,0],[0,0,1]]
    nodes[0]["triangles"] = [[0,2,1],[0,1,3],[1,2,3],[2,0,3]]
    nodes[0]["rotation"] = ["x":17,"y":31,"z":-12]
    nodes[0]["origin"] = ["x":0.7,"y":0.6,"z":-0.4]
    nodes[1]["primitive"] = "extrusion"
    nodes[1]["profile"] = [[0,0],[1,0],[1,0.4],[0.4,0.4],[0.4,1],[0,1]]
    nodes[1]["rotation"] = ["x":-11,"y":23,"z":7]
    nodes[1]["attach"] = ["parent":"parent","face":"top","anchor":"frontLeft","xOffset":Float(0.07),"zOffset":Float(-0.03)]
    let first = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),outline:outline,placement:placement)
    let pa = try SceneGenerator.bounds(for:first.nodes[0]), cb = try SceneGenerator.bounds(for:first.nodes[1])
    #expect(abs(cb.minimum[0]-pa.minimum[0]-0.07)<5e-6)
    #expect(abs(cb.maximum[2]-pa.maximum[2]+0.03)<5e-6)
    nodes[0]["origin"] = ["x":-0.5,"y":0.2,"z":0.7]
    let moved = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),outline:outline,placement:placement)
    for axis in [0,2] {
        #expect(abs((Double(first.nodes[1].position[axis])-Double(first.nodes[0].position[axis])) -
                    (Double(moved.nodes[1].position[axis])-Double(moved.nodes[0].position[axis])))<5e-6)
    }
    #expect(try ScenePlan.decodeModelResponse(ScenePlan.snapshot(first)) == first)
}

@Test func assemblyMultipleRootsRequireModelOriginsAndLegacyEditsRemainExact() throws {
    let outline = try SceneAssemblyOutline(name:"forest",parts:[
        .init(id:"left",primitive:.box,purpose:"independent shape"),
        .init(id:"right",primitive:.sphere,purpose:"independent shape")
    ])
    let placement = try SceneAssemblyPlacement(anchors:[],outline:outline)
    var nodes = assemblyNodes()
    nodes[0]["id"] = "left"; nodes[1]["id"] = "right"; nodes[1]["primitive"] = "sphere"
    #expect(throws:CreationError.self) {
        try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),outline:outline,placement:placement)
    }
    nodes[0]["origin"] = ["x":-0.8,"y":0.4,"z":0]
    nodes[1]["origin"] = ["x":0.8,"y":0.4,"z":0]
    let scene = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),outline:outline,placement:placement)
    #expect(scene.nodes[0].position == [-0.8,0.4,0])
    #expect(scene.nodes[1].position == [0.8,0.4,0])
    #expect(try ScenePlan.decodeModelResponse(ScenePlan.snapshot(scene)) == scene)
    for original in SceneSpec.presets {
        #expect(try ScenePlan.decodeModelResponse(ScenePlan.snapshot(original)) == original)
    }
}

@Test func assemblyGeometryCannotChangeModelGraphAnchorOrDeltaPresence() throws {
    let outline = try assemblyOutline(face:.top)
    let placement = try SceneAssemblyPlacement(anchors:[.init(id:"child",anchor:.left,xOffset:0.1)],outline:outline)
    var nodes = assemblyNodes()
    let attach: [String:Any] = ["parent":"parent","face":"top","anchor":"left","xOffset":Float(0.1)]
    nodes[1]["attach"] = attach
    _ = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),outline:outline,placement:placement)
    var changedRows: [[String:Any]] = []
    var value = nodes[1]; value["id"] = "other"; changedRows.append(value)
    value = nodes[1]; value["primitive"] = "sphere"; changedRows.append(value)
    value = nodes[1]; value["profile"] = [[0,0],[1,1]]; changedRows.append(value)
    value = nodes[1]; value["origin"] = ["x":0,"y":0,"z":0]; changedRows.append(value)
    for key in ["parent","face","anchor","xOffset"] {
        var changed = attach
        switch key {
        case "parent": changed[key] = "child"
        case "face": changed[key] = "bottom"
        case "anchor": changed[key] = "right"
        default: changed[key] = 0.2
        }
        value = nodes[1]; value["attach"] = changed; changedRows.append(value)
    }
    var added = attach; added["zOffset"] = 0
    value = nodes[1]; value["attach"] = added; changedRows.append(value)
    var removed = attach; removed.removeValue(forKey:"xOffset")
    value = nodes[1]; value["attach"] = removed; changedRows.append(value)
    for row in changedRows {
        #expect(throws:CreationError.self) {
            try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":[nodes[0],row]]),outline:outline,placement:placement)
        }
    }
}

@Test func assemblyIndependentBoundsAvoidAFalseTemporaryCenterLayoutRejection() throws {
    let parts: [SceneAssemblyOutline.Part] = [
        .init(id:"r",primitive:.box,purpose:"body"),
        .init(id:"s",primitive:.box,purpose:"detail",parent:"r",face:.right),
        .init(id:"t",primitive:.box,purpose:"body",parent:"s",face:.top),
        .init(id:"u",primitive:.box,purpose:"detail",parent:"t",face:.right),
        .init(id:"v",primitive:.box,purpose:"body",parent:"u",face:.top)
    ]
    let outline = try SceneAssemblyOutline(name:"nested",parts:parts)
    let placement = try SceneAssemblyPlacement(anchors:[
        .init(id:"s",anchor:.bottom),.init(id:"t",anchor:.center),
        .init(id:"u",anchor:.center),.init(id:"v",anchor:.center)
    ],outline:outline)
    var nodes: [[String:Any]] = []
    for (index,part) in parts.enumerated() {
        var node: [String:Any] = ["id":part.id,"primitive":"box","color":"#7799AA",
            "dimensions":["width":0.1,"height":[0,2,4].contains(index) ? 2.5 : 0.1,"depth":0.1]]
        if let parent = part.parent, let face = part.face {
            node["attach"] = ["parent":parent,"face":face.rawValue,
                "anchor":placement.anchors.first { $0.id == part.id }!.anchor.rawValue]
        }
        nodes.append(node)
    }
    let scene = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),outline:outline,placement:placement)
    #expect(abs(Double(scene.nodes[4].position[1])-2.644)<1e-5)
    var neutral = nodes
    for index in 1..<neutral.count {
        var attach = neutral[index]["attach"] as! [String:Any]; attach.removeValue(forKey:"anchor")
        neutral[index]["attach"] = attach
    }
    #expect(throws:CreationError.self) { try ScenePlan.decodeModelResponse(assemblyJSON(["name":outline.name,"nodes":neutral])) }
}

@Test func assemblyFreeformDefinitionsAndAllEightShapesSurviveTypedEvaluation() throws {
    let parts = SceneNode.Primitive.allCases.enumerated().map { index,primitive in
        SceneAssemblyOutline.Part(id:"p\(index)",primitive:primitive,purpose:"synthetic geometry contract",
            parent:index == 0 ? nil : "p0",face:index == 0 ? nil : .inside)
    }
    let outline = try SceneAssemblyOutline(name:"geometry",parts:parts)
    let placement = try SceneAssemblyPlacement(anchors:parts.dropFirst().map { .init(id:$0.id,anchor:.center) },outline:outline)
    let defaults = parts.map { SceneNode.defaultNode(primitive:$0.primitive,id:$0.id) }
    let snapshot = try StrictJSONObject.decode(ScenePlan.snapshot(SceneSpec(name:outline.name,nodes:defaults)))
    var nodes = snapshot["nodes"] as! [[String:Any]]
    for index in 1..<nodes.count {
        nodes[index].removeValue(forKey:"origin")
        nodes[index]["attach"] = ["parent":"p0","face":"inside","anchor":"center"]
    }
    let scene = try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),outline:outline,placement:placement)
    for (node,original) in zip(scene.nodes,defaults) {
        #expect(node.primitive == original.primitive)
        #expect(node.profile == original.profile && node.vertices == original.vertices && node.triangles == original.triangles)
        #expect(node.rotation == original.rotation && node.metallic == original.metallic && node.roughness == original.roughness)
    }
    #expect(try SceneGenerator.generate(for:scene).count == 8)
    let call = try SceneAssemblyProtocol.geometryRequest("abstract scene",outline:outline,placement:placement)
    let raw = try StrictJSONObject.decode(call.jsonSchema)
    let authority = try StrictJSONObject.decode(SceneGenerationSchema.jsonSchema())
    #expect((raw["$defs"] as? NSDictionary) == (authority["$defs"] as? NSDictionary))
}

@Test func assemblyZeroSpreadDoesNotResizeAndOutOfRangeCombinationsAreRejected() throws {
    let outline = try assemblyOutline(face:.top)
    var nodes = assemblyNodes()
    nodes[1]["dimensions"] = ["width":1.2,"height":0.2,"depth":0.2]
    var results: [SceneSpec] = []
    for anchor in [SceneFaceAnchor.left,.right] {
        let placement = try SceneAssemblyPlacement(anchors:[.init(id:"child",anchor:anchor)],outline:outline)
        nodes[1]["attach"] = ["parent":"parent","face":"top","anchor":anchor.rawValue]
        results.append(try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),
            outline:outline,placement:placement))
    }
    #expect(results[0].nodes[1].position == results[1].nodes[1].position,
            "Zero tangent spread legitimately collapses labels; do not invent separation")
    #expect(results[0].nodes[1].size[0] == 1.2)
    nodes[1]["dimensions"] = ["width":0.2,"height":0.2,"depth":0.2]
    nodes[1]["attach"] = ["parent":"parent","face":"top","anchor":"right","xOffset":3]
    let tooFar = try SceneAssemblyPlacement(anchors:[.init(id:"child",anchor:.right,xOffset:3)],outline:outline)
    #expect(throws:CreationError.self) {
        try SceneAssemblyProtocol.decodeGeometryResponse(assemblyJSON(["name":outline.name,"nodes":nodes]),
            outline:outline,placement:tooFar)
    }
}

private func assemblyOutline(face: SceneNode.Attachment) throws -> SceneAssemblyOutline {
    try SceneAssemblyOutline(name:"fixture",parts:[
        .init(id:"parent",primitive:.box,purpose:"main shape"),
        .init(id:"child",primitive:.box,purpose:"detail",parent:"parent",face:face)
    ])
}
private func assemblyNodes() -> [[String:Any]] {
    [["id":"parent","primitive":"box","dimensions":["width":1,"height":0.8,"depth":0.6],"color":"#667788"],
     ["id":"child","primitive":"box","dimensions":["width":0.2,"height":0.2,"depth":0.2],"color":"#88AACC"]]
}
private func assemblyJSON(_ value: Any) throws -> String {
    String(decoding:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self)
}
