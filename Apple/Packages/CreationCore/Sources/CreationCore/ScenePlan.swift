import Foundation

/// Named planning fields keep the language model's dimensions and attachment intent
/// separate from the canonical, editable SceneSpec coordinates used by the renderer.
public enum ScenePlan {
    /// Edits receive the same named fields as generation, without asking the model to reinterpret axes.
    public static func snapshot(_ scene: SceneSpec) throws -> String {
        let canonical = try SceneAttachmentResolver.resolve(scene)
        let nodes: [[String: Any]] = canonical.nodes.map { node in
            var value: [String: Any] = [
                "id": node.id, "primitive": node.primitive.rawValue, "color": node.color,
                "dimensions": ["width": node.size[0], "height": node.size[1], "depth": node.size[2]],
                "origin": ["x": node.position[0], "y": node.position[1], "z": node.position[2]],
                "rotation": ["x": node.rotation[0], "y": node.rotation[1], "z": node.rotation[2]],
                "metallic": node.metallic, "roughness": node.roughness
            ]
            if let profile = node.profile { value["profile"] = profile }
            if let vertices = node.vertices { value["vertices"] = vertices }
            if let triangles = node.triangles { value["triangles"] = triangles }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: ["name": canonical.name, "nodes": nodes], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeModelResponse(_ response: String) throws -> SceneSpec {
        guard response.utf8.count <= SceneSpec.maximumResponseBytes else {
            throw invalid("场景计划响应过长。")
        }
        var text=response.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("```json\n"),text.hasSuffix("```") {
            text=String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in:.whitespacesAndNewlines)
        } else if text.hasPrefix("```\n"),text.hasSuffix("```") {
            text=String(text.dropFirst(4).dropLast(3)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let object=try StrictJSONObject.decode(text,maximumBytes:SceneSpec.maximumResponseBytes)
        return try decodeObject(object,text:text)
    }

    static func decodeObject(_ object:[String:Any],text:String)throws->SceneSpec {
        guard Set(object.keys)==["name","nodes"],let nodes=object["nodes"] as? [[String:Any]] else {
            throw invalid("场景计划只能包含 name 和 nodes。")
        }
        let required:Set<String>=["id","primitive","dimensions","color"]
        let standard=required.union(["rotation","origin","attach","metallic","roughness"])
        for node in nodes {
            guard let raw=node["primitive"] as? String,let primitive=SceneNode.Primitive(rawValue:raw) else {
                throw invalid("场景计划中的形状类型无效。")
            }
            var allowed=standard
            switch primitive {
            case .mesh: allowed.formUnion(["vertices","triangles"])
            case .lathe,.extrusion: allowed.insert("profile")
            default: break
            }
            let keys=Set(node.keys)
            guard keys.isSuperset(of:required),keys.isSubset(of:allowed),
                  let dimensions=node["dimensions"] as? [String:Any],
                  Set(dimensions.keys)==["width","height","depth"] else {
                throw invalid("计划必须使用命名宽高深，不得混用渲染坐标或未知字段。")
            }
            for key in ["rotation","origin"] {
                if let value=node[key],!(value is NSNull) {
                    guard let axes=value as? [String:Any],Set(axes.keys)==["x","y","z"] else {
                        throw invalid("\(key) 必须为包含 x、y、z 的命名坐标。")
                    }
                }
            }
            if let value=node["attach"],!(value is NSNull) {
                guard let attach=value as? [String:Any],
                      Set(attach.keys).isSuperset(of:["parent","face"]),
                      Set(attach.keys).isSubset(of:["parent","face","xOffset","yOffset","zOffset"]) else {
                    throw invalid("连接计划必须指明父部件与连接面，只能添加命名偏移。")
                }
            }
        }
        do {
            let plan=try JSONDecoder().decode(Plan.self,from:Data(text.utf8))
            let canonical=try plan.nodes.map { node->SceneNode in
                guard node.origin == nil || node.attach == nil else {
                    throw invalid("同一个部件不能同时指定绝对中心与连接关系。")
                }
                let offset:[Float]?
                if let attach=node.attach {
                    offset=[attach.xOffset ?? 0,attach.yOffset ?? 0,attach.zOffset ?? 0]
                } else {
                    // A new graph root is explicitly grounded; an edited absolute origin is preserved.
                    offset=node.origin == nil ? [0,0,0] : nil
                }
                return SceneNode(id:node.id,primitive:node.primitive,
                    position:node.origin?.values ?? [0,0,0],
                    size:[node.dimensions.width,node.dimensions.height,node.dimensions.depth],
                    rotation:node.rotation?.values ?? [0,0,0],color:node.color,
                    metallic:node.metallic ?? 0.1,roughness:node.roughness ?? 0.45,
                    profile:node.profile,vertices:node.vertices,triangles:node.triangles,
                    parentID:node.attach?.parent,attachment:node.attach?.face,offset:offset)
            }
            let scene=SceneSpec(name:plan.name,nodes:canonical)
            try scene.validate()
            return try SceneAttachmentResolver.resolve(scene)
        } catch let error as CreationError { throw error }
        catch { throw invalid("场景计划的数值、类型或连接面不符合要求。") }
    }

    private struct Plan:Decodable { let name:String;let nodes:[Node] }
    private struct Node:Decodable {
        let id:String;let primitive:SceneNode.Primitive;let dimensions:Dimensions;let color:String
        let rotation:Axes?;let origin:Axes?;let attach:AttachmentPlan?
        let metallic:Float?;let roughness:Float?
        let profile:[[Float]]?;let vertices:[[Float]]?;let triangles:[[UInt32]]?
    }
    private struct Dimensions:Decodable { let width:Float;let height:Float;let depth:Float }
    private struct Axes:Decodable {
        let x:Float;let y:Float;let z:Float
        var values:[Float]{[x,y,z]}
    }
    private struct AttachmentPlan:Decodable {
        let parent:String;let face:SceneNode.Attachment
        let xOffset:Float?;let yOffset:Float?;let zOffset:Float?
    }
    private static func invalid(_ message:String)->CreationError { .invalidModelResponse(message) }
}
