import Foundation

/// Draft three-phase creation contract. This is not visual-quality acceptance.
/// Existing ScenePlan and editable SceneSpec formats remain unchanged.
public enum SceneAssemblyProtocol {
    public static func outlineRequest(_ request: String) throws -> SceneCreationCall {
        try AssemblyContract.request(request)
        let common: [String:Any] = [
            "id": identifier,
            "primitive": ["type":"string", "enum":SceneNode.Primitive.allCases.map(\.rawValue)],
            "purpose": ["type":"string", "minLength":1, "maxLength":120]
        ]
        let root = object(common, required: ["id","primitive","purpose"])
        var child = common
        child["parent"] = identifier
        child["face"] = ["type":"string", "enum":SceneNode.Attachment.allCases.map(\.rawValue)]
        let schema = object([
            "name":["type":"string", "minLength":1],
            "parts":["type":"array", "minItems":1, "maxItems":SceneSpec.maximumNodes,
                     "items":["oneOf":[root,object(child, required:["id","primitive","purpose","parent","face"])]]]
        ], required:["name","parts"])
        return SceneCreationCall(systemPrompt: outlineSystem, userPrompt: request,
                                 jsonSchema: try AssemblyContract.text(schema), maxTokens: 3072)
    }

    public static func placementRequest(_ request: String, outline: SceneAssemblyOutline) throws -> SceneCreationCall {
        try AssemblyContract.request(request)
        try outline.validate()
        let children = outline.parts.filter { $0.parent != nil }
        let rows = children.map { ["id":$0.id, "face":$0.face!.rawValue, "purpose":$0.purpose] }
        let entries = children.map { part in
            var fields: [String:Any] = ["id":["type":"string", "const":part.id],
                "anchor":["type":"string", "enum":SceneFaceAnchor.allowed(for:part.face!).map(\.rawValue)]]
            for key in AssemblyContract.deltaKeys(for:part.face!) {
                fields[key] = ["type":"number", "minimum":-3, "maximum":3]
            }
            return object(fields, required:["id","anchor"])
        }
        let schema = object(["anchors": exactArray(entries)], required:["anchors"])
        // The tested semantic phase consumes only model-authored rows. The
        // original request is validated here but is not an extra semantic hint.
        return SceneCreationCall(systemPrompt: placementSystem,
            userPrompt: try AssemblyContract.text(["rows":rows]),
            jsonSchema: try AssemblyContract.text(schema), maxTokens: 3072)
    }

    public static func geometryRequest(_ request: String, outline: SceneAssemblyOutline,
                                       placement: SceneAssemblyPlacement) throws -> SceneCreationCall {
        try AssemblyContract.request(request)
        try placement.validate(outline: outline)
        let outlineText = try AssemblyContract.encoded(outline)
        let placementText = try AssemblyContract.encoded(placement)
        var user = try ScenePrompt.userRequest(request, currentSpec:nil) +
            "\n\n上一阶段模型给出的实际装配提纲如下：\n" + outlineText +
            "\n现在严格依照这些部件的顺序、id、primitive以及parent/face补全完整ScenePlan；purpose用于确定尺寸、相对方位与偏移，不写入最终JSON。不要增删部件或改变连接图。" +
            "\n\n以下是模型在独立语义步骤中实际选择的锚点计划（原样，已经固定）：\n" + placementText +
            "\n本次只补全几何尺寸、材质与其他原合同字段；必须遵守这份固定placement计划，不增删部件，不改变id、primitive、parent、face或anchor。"
        if outline.parts.filter({ $0.parent == nil }).count > 1 {
            user += "\n本场景有多个独立根。每个根必须明确填写origin绝对中心，由你决定布局，不得全部依赖省略origin的默认位置。"
        }
        return SceneCreationCall(systemPrompt: ScenePrompt.system + spatialAppend, userPrompt: user,
            jsonSchema: try geometrySchema(outline: outline, placement: placement), maxTokens: 3072)
    }

    public static func decodeGeometryResponse(_ text: String, outline: SceneAssemblyOutline,
                                              placement: SceneAssemblyPlacement) throws -> SceneSpec {
        try placement.validate(outline: outline)
        var plan = try StrictJSONObject.decode(text, maximumBytes: SceneSpec.maximumResponseBytes)
        guard Set(plan.keys) == ["name","nodes"], plan["name"] as? String == outline.name,
              var nodes = plan["nodes"] as? [[String:Any]], nodes.count == outline.parts.count else {
            throw AssemblyContract.invalid("几何响应改变了模型提纲的名称或部件数量。")
        }
        let anchors = Dictionary(uniqueKeysWithValues: placement.anchors.map { ($0.id,$0) })
        let multipleRoots = outline.parts.filter { $0.parent == nil }.count > 1
        for (node, part) in zip(nodes, outline.parts) {
            guard node["id"] as? String == part.id, node["primitive"] as? String == part.primitive.rawValue else {
                throw AssemblyContract.invalid("几何响应改变了模型提纲的标识、顺序或形状类型。")
            }
            if let parent = part.parent, let face = part.face, let selection = anchors[part.id] {
                let expected = Set(["parent","face","anchor"]).union(selection.providedDeltas.keys)
                guard node["origin"] == nil, let attach = node["attach"] as? [String:Any],
                      Set(attach.keys) == expected,
                      attach["parent"] as? String == parent, attach["face"] as? String == face.rawValue,
                      attach["anchor"] as? String == selection.anchor.rawValue else {
                    throw AssemblyContract.invalid("几何响应改变了模型选择的连接或锚点。")
                }
                for (key, value) in selection.providedDeltas {
                    guard let raw = attach[key], try AssemblyContract.float(raw) == value else {
                        throw AssemblyContract.invalid("几何响应改变了模型选择的锚点残差。")
                    }
                }
            } else {
                guard node["attach"] == nil, !multipleRoots || node["origin"] is [String:Any] else {
                    throw AssemblyContract.invalid("根部件连接无效，或多根场景缺少明确 origin。")
                }
            }
        }

        // Extents do not depend on translation. Measure each real transformed
        // primitive independently at origin, so a temporary center layout cannot
        // prematurely fail the final scene's +/-3m position validation.
        var bounds: [String:GeometryBounds] = [:]
        for (node, part) in zip(nodes, outline.parts) {
            try Task.checkCancellation()
            var measure = node
            measure.removeValue(forKey:"attach")
            measure["origin"] = ["x":0,"y":0,"z":0]
            let single = try ScenePlan.decodeModelResponse(AssemblyContract.text(["name":outline.name,"nodes":[measure]]))
            bounds[part.id] = try SceneGenerator.bounds(for:single.nodes[0])
        }
        for (index, part) in outline.parts.enumerated() {
            guard let parentID = part.parent, let face = part.face, let selection = anchors[part.id],
                  let parent = bounds[parentID], let child = bounds[part.id] else { continue }
            try Task.checkCancellation()
            let offset = try AssemblyAnchorKernel.offsets(parent:parent, child:child, face:face,
                anchor:selection.anchor, deltas:selection.deltaVector)
            nodes[index]["attach"] = ["parent":parentID,"face":face.rawValue,
                "xOffset":offset[0],"yOffset":offset[1],"zOffset":offset[2]]
        }
        plan["nodes"] = nodes
        // Only declared anchors were translated. Keep every generated geometry,
        // material, rotation and root origin for unchanged native validation.
        return try ScenePlan.decodeModelResponse(AssemblyContract.text(plan))
    }

    private static func geometrySchema(outline: SceneAssemblyOutline,
                                       placement: SceneAssemblyPlacement) throws -> String {
        var schema = try StrictJSONObject.decode(SceneGenerationSchema.jsonSchema(), maximumBytes:SceneSpec.maximumResponseBytes)
        guard var properties = schema["properties"] as? [String:Any],
              let nodeArray = properties["nodes"] as? [String:Any],
              let item = nodeArray["items"] as? [String:Any],
              let alternatives = item["oneOf"] as? [[String:Any]], alternatives.count == 24 else {
            throw AssemblyContract.invalid("完整几何合同布局不符合预期。")
        }
        let selections = Dictionary(uniqueKeysWithValues: placement.anchors.map { ($0.id,$0) })
        let multipleRoots = outline.parts.filter { $0.parent == nil }.count > 1
        let prefix: [[String:Any]] = try outline.parts.map { part in
            let candidates = alternatives.filter { value in
                guard let fields = value["properties"] as? [String:Any],
                      (fields["primitive"] as? [String:Any])?["const"] as? String == part.primitive.rawValue else { return false }
                if part.parent != nil { return fields["attach"] != nil }
                return fields["attach"] == nil && (!multipleRoots || fields["origin"] != nil)
            }
            guard candidates.count == (part.parent == nil && !multipleRoots ? 2 : 1) else {
                throw AssemblyContract.invalid("装配几何的放置合同不符合预期。")
            }
            let constrained: [[String:Any]] = try candidates.map { original in
                var node = original
                guard var fields = node["properties"] as? [String:Any] else { throw AssemblyContract.invalid("部件字段合同无效。") }
                fields["id"] = ["type":"string", "const":part.id]
                fields["primitive"] = ["type":"string", "const":part.primitive.rawValue]
                if let parent = part.parent, let face = part.face, let selection = selections[part.id] {
                    var attachFields: [String:Any] = [
                        "parent":["type":"string", "const":parent],
                        "face":["type":"string", "const":face.rawValue],
                        "anchor":["type":"string", "const":selection.anchor.rawValue]
                    ]
                    for (key, value) in selection.providedDeltas {
                        attachFields[key] = ["type":"number", "const":value]
                    }
                    fields["attach"] = object(attachFields,
                        required:["parent","face","anchor"] + selection.providedDeltas.keys.sorted())
                }
                node["properties"] = fields
                return node
            }
            return constrained.count == 1 ? constrained[0] : ["oneOf":constrained]
        }
        var name = properties["name"] as? [String:Any] ?? [:]
        name["const"] = outline.name
        properties["name"] = name
        properties["nodes"] = exactArray(prefix)
        schema["properties"] = properties
        return try AssemblyContract.text(schema)
    }

    private static var identifier: [String:Any] { ["type":"string", "pattern":"^[A-Za-z0-9_-]{1,32}$"] }
    private static func object(_ fields: [String:Any], required: [String]) -> [String:Any] {
        ["type":"object", "properties":fields, "required":required, "additionalProperties":false]
    }
    private static func exactArray(_ entries: [[String:Any]]) -> [String:Any] {
        var array: [String:Any] = ["type":"array", "items":false, "minItems":entries.count, "maxItems":entries.count]
        if !entries.isEmpty { array["prefixItems"] = entries }
        return array
    }

    private static let outlineSystem = """
    你是通用三维造型的装配规划器。只输出一个符合格式的JSON装配提纲，不输出尺寸、坐标、颜色或解释。
    name是作品名称，parts是作品必需且彼此可区分的实体部件。每个部件只写id、primitive、purpose；连接部件再写parent、face。primitive可用box、sphere、cylinder、cone、torus、mesh、lathe、extrusion。purpose简短说明该实体作用与相对方位。
    主体根部件可优先放第一项，不写parent和face；多个独立物体允许多个根，不强制单根。需要连接的部件连接实际承载它的部件。并列的部件共享同一实际支撑，不要为了书写顺序把它们逐个串接。只规划构成物体所需的实体，避免重复拆分。
    原生几何都是闭合实体，不需要另外添加封口、盖面、边角或连接占位部件。不要增加展示平台。部件最多32个；由题材需要决定数量，不必填满。仅输出JSON。
    """

    private static let placementSystem = """
    Classify semantic placement anchors only. For each input row choose the anchor matching its stated purpose on the given face. If the purpose states no tangential direction, choose center. Directions are world directions; a back face does not mirror left and right.
    Exact allowed anchor labels:
    top/bottom faces: center,left,right,front,back,frontLeft,frontRight,backLeft,backRight.
    front/back faces: center,left,right,top,bottom,topLeft,topRight,bottomLeft,bottomRight.
    left/right faces: center,front,back,top,bottom,frontTop,frontBottom,backTop,backBottom.
    inside face: center.
    Return only this JSON format: {"anchors":[{"id":"same input id","anchor":"one allowed label"}]}. Include each input id exactly once, keep input order, and include no extra keys or explanations.
    Optional xOffset/yOffset/zOffset are residual displacements in meters relative to the selected anchor, not absolute centers. Include them only when the stated purpose needs placement beyond the label. top/bottom may use xOffset,zOffset; front/back may use xOffset,yOffset; left/right may use yOffset,zOffset; inside may use all three. Omit unused fields. Every supplied displacement must be finite and between -3 and 3. Never supply the face-normal offset.
    """

    private static let spatialAppend = """

    本次采用离散贴面锚点加可选残差协议。attach必须包含parent、face、anchor，并只能添加前一步模型已明确选择的xOffset/yOffset/zOffset。未声明的残差不得新增，已声明的数值不得改变；残差是相对anchor的米数，不是绝对中心。anchor与残差均已由前一步模型根据用途选择。
    所有方向沿世界坐标：left=-X，right=+X，front=+Z，back=-Z，top=+Y，bottom=-Y；不随父部件旋转，也不因back面而镜像左右。
    face为top或bottom时，anchor可选center,left,right,front,back,frontLeft,frontRight,backLeft,backRight。
    face为front或back时，anchor可选center,left,right,top,bottom,topLeft,topRight,bottomLeft,bottomRight。
    face为left或right时，anchor可选center,front,back,top,bottom,frontTop,frontBottom,backTop,backBottom。inside目前只允许center。
    原生实现先按实际旋转后几何外包框贴面，再按anchor在贴面切向对齐边界。每个切向轴的偏移为anchor方向符号乘max(0,(父外包框跨度-子外包框跨度)/2)，再加该轴已声明残差。top/bottom只用X/Z残差，front/back只用X/Y残差，left/right只用Y/Z残差，inside允许XYZ残差。法向贴合和整体落地沿用原生规则。
    """
}

enum AssemblyAnchorKernel {
    static func offsets(parent: GeometryBounds, child: GeometryBounds,
                        face: SceneNode.Attachment, anchor: SceneFaceAnchor,
                        deltas: [Double] = [0,0,0]) throws -> [Double] {
        let signs = try anchor.signs(on:face)
        let parentExtent = (0..<3).map { parent.maximum[$0] - parent.minimum[$0] }
        let childExtent = (0..<3).map { child.maximum[$0] - child.minimum[$0] }
        guard (parentExtent + childExtent).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw AssemblyContract.invalid("锚点外包框跨度无效。")
        }
        guard deltas.count == 3, deltas.allSatisfy({ $0.isFinite && abs($0) <= 3 }) else {
            throw AssemblyContract.invalid("锚点残差须为三个 ±3 米内有限数。")
        }
        let keys = ["xOffset","yOffset","zOffset"]
        let allowed = AssemblyContract.deltaKeys(for:face)
        guard (0..<3).allSatisfy({ allowed.contains(keys[$0]) || deltas[$0] == 0 }) else {
            throw AssemblyContract.invalid("锚点残差不得包含法向位移。")
        }
        let result = (0..<3).map { signs[$0] * max(0,(parentExtent[$0] - childExtent[$0]) / 2) + deltas[$0] }
        guard result.allSatisfy({ $0.isFinite && abs($0) <= 3 }) else {
            throw AssemblyContract.invalid("锚点与残差组合超过原生连接偏移范围。")
        }
        return result
    }
}
