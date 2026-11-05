import Foundation
import Testing
@testable import CreationCore

private func planNode(_ id:String,_ primitive:String="box",width:Float=0.3,height:Float=0.4,depth:Float=0.5)->[String:Any] {
    ["id":id,"primitive":primitive,"dimensions":["width":width,"height":height,"depth":depth],"color":"#3ABDA7"]
}
private func planText(_ nodes:[[String:Any]],name:String="任意题材造型")throws->String {
    String(decoding:try JSONSerialization.data(withJSONObject:["name":name,"nodes":nodes],options:.sortedKeys),as:UTF8.self)
}

@Test func editSnapshotPreservesNamedDimensionsPoseAndFreeformTopology() throws {
    var mesh = SceneNode.defaultNode(primitive: .mesh, id: "free_surface")
    mesh.position = [0.41, 0.78, -0.22]
    mesh.rotation = [17, -28, 39]
    mesh.size = [0.34, 0.56, 0.78]
    let source = SceneSpec(name: "自由曲面作品", nodes: [mesh])
    let text = try ScenePlan.snapshot(source)
    let object = try StrictJSONObject.decode(text, maximumBytes: SceneSpec.maximumResponseBytes)
    let first = try #require((object["nodes"] as? [[String: Any]])?.first)
    #expect(first["dimensions"] != nil && first["origin"] != nil)
    #expect(first["size"] == nil && first["position"] == nil)
    let restored = try SceneSpec.decodeModelResponse(text)
    #expect(restored == source)
    let before = try SceneGenerator.generate(for: source)
    let after = try SceneGenerator.generate(for: restored)
    #expect(before == after)
}

@Test func namedDimensionsMapToCanonicalAxesAndGroundNewRoots() throws {
    let text=try planText([planNode("vertical_rod","cylinder",width:0.02,height:0.8,depth:0.02)])
    let scene=try SceneSpec.decodeModelResponse(text)
    let node=try #require(scene.nodes.first)
    #expect(node.size == [0.02,0.8,0.02])
    #expect(node.rotation == [0,0,0])
    #expect(node.metallic == 0.1)
    #expect(node.roughness == 0.45)
    #expect(node.parentID == nil && node.attachment == nil && node.offset == nil)
    let bounds=try SceneGenerator.bounds(for:node)
    #expect(abs(bounds.height-0.8)<1e-6)
    #expect(abs(bounds.width-0.02)<1e-6)
    #expect(abs(bounds.minimum[1])<1e-6)
    #expect(try ScenePlan.decodeModelResponse(text) == scene)
}

@Test func namedAttachmentPlansResolveChildBeforeParentWithoutModelArithmetic() throws {
    var base=planNode("foundation","cylinder",width:0.4,height:0.06,depth:0.4)
    base["metallic"]=0.8
    var stem=planNode("stem","cylinder",width:0.04,height:0.8,depth:0.04)
    stem["attach"]=["parent":"foundation","face":"top","yOffset":2]
    var top=planNode("top","cone",width:0.35,height:0.3,depth:0.35)
    top["attach"]=["parent":"stem","face":"top"]
    let scene=try SceneSpec.decodeModelResponse(planText([top,stem,base]))
    let root=try #require(scene.nodes.first{$0.id=="foundation"})
    let rod=try #require(scene.nodes.first{$0.id=="stem"})
    let head=try #require(scene.nodes.first{$0.id=="top"})
    let b=try SceneGenerator.bounds(for:root),s=try SceneGenerator.bounds(for:rod),t=try SceneGenerator.bounds(for:head)
    #expect(abs(b.minimum[1])<1e-6)
    #expect(abs(s.minimum[1]-b.maximum[1])<0.004)
    #expect(abs(t.minimum[1]-s.maximum[1])<0.004)
    #expect(root.metallic==0.8)
    #expect(scene.nodes.allSatisfy{$0.parentID==nil && $0.attachment==nil && $0.offset==nil})
}

@Test func namedAbsoluteOriginPreservesExistingEditablePose() throws {
    var node=planNode("existing")
    node["origin"]=["x":-1.0,"y":2.0,"z":1.5]
    node["rotation"]=["x":10.0,"y":20.0,"z":30.0]
    let scene=try SceneSpec.decodeModelResponse(planText([node]))
    #expect(scene.nodes[0].position==[-1,2,1.5])
    #expect(scene.nodes[0].rotation==[10,20,30])
}

@Test func freeformPlansCarryActualProfilesAndArbitraryTriangleTopology() throws {
    for primitive in [SceneNode.Primitive.mesh,.lathe,.extrusion] {
        let example=SceneNode.defaultNode(primitive:primitive,id:"free")
        var node=planNode("free",primitive.rawValue)
        if let profile=example.profile {node["profile"]=profile}
        if let vertices=example.vertices {node["vertices"]=vertices}
        if let triangles=example.triangles {node["triangles"]=triangles}
        let scene=try SceneSpec.decodeModelResponse(planText([node],name:"自由曲面与未预设题材"))
        #expect(scene.name=="自由曲面与未预设题材")
        #expect(scene.nodes[0].profile==example.profile)
        #expect(scene.nodes[0].vertices==example.vertices)
        #expect(scene.nodes[0].triangles==example.triangles)
        let meshes=try SceneGenerator.generate(for:scene)
        #expect(!meshes.isEmpty)
        #expect(meshes[0].indices.count>0)
    }
}

@Test func plansRejectUnknownFieldsMixedCoordinateContractsAndInvalidGraphReferences() throws {
    let good=planNode("valid")
    var wrongDimension=good
    wrongDimension["dimensions"]=["width":0.4,"height":0.5,"depth":0.6,"x":0]
    var mixed=good;mixed["size"]=[0.4,0.5,0.6]
    var wrongRotation=good;wrongRotation["rotation"]=["x":0,"y":0,"z":0,"pitch":20]
    var wrongAttach=good;wrongAttach["attach"]=["parent":"other","face":"top","offset":[0,0,0]]
    var missingParent=good;missingParent["attach"]=["parent":"unknown","face":"top"]
    var both=good;both["origin"]=["x":0,"y":0,"z":0];both["attach"]=["parent":"other","face":"top"]
    var wrongPrimitiveField=good;wrongPrimitiveField["vertices"]=[[0,0,0]]
    var executable=good;executable["script"]="arbitraryCode()"
    var booleanDimension=good;booleanDimension["dimensions"]=["width":true,"height":0.5,"depth":0.6]
    for value in [wrongDimension,mixed,wrongRotation,wrongAttach,missingParent,both,wrongPrimitiveField,executable,booleanDimension] {
        #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(planText([value]))}
    }
    // Mixing canonical and planning nodes in one response must not silently reinterpret either.
    let canonical=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(SceneSpec.chair)) as? [String:Any])
    let old=try #require((canonical["nodes"] as? [[String:Any]])?.first)
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(planText([good,old]))}
}

@Test func planningContractKeepsDuplicateKeyAndComplexityGuards() throws {
    let duplicate=##"{"name":"x","nodes":[{"id":"part","primitive":"box","dimensions":{"width":0.2,"width":0.3,"height":0.4,"depth":0.5},"color":"#FFFFFF"}]}"##
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(duplicate)}
    let excessive=(0...SceneSpec.maximumNodes).map{planNode("part_\($0)")}
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(planText(excessive))}
    var invalidSize=planNode("part");invalidSize["dimensions"]=["width":0.0,"height":0.4,"depth":0.5]
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(planText([invalidSize]))}
}
