import Foundation

public struct SceneNode: Codable, Sendable, Equatable {
    public enum Primitive: String, Codable, CaseIterable, Sendable {
        case box, sphere, cylinder, cone, torus, mesh, lathe, extrusion
    }
    public enum Attachment: String, Codable, CaseIterable, Sendable {
        case top, bottom, front, back, left, right, inside
    }
    public var id: String
    public var primitive: Primitive
    /// Center in meters, XYZ; Y is up.
    public var position: [Float]
    /// Positive width, height and depth in meters, before rotation.
    public var size: [Float]
    /// Euler angles in degrees, applied X then Y then Z.
    public var rotation: [Float]
    /// sRGB hexadecimal material color.
    public var color: String
    public var metallic: Float
    public var roughness: Float
    public var profile: [[Float]]?
    public var path: [[Float]]?
    public var vertices: [[Float]]?
    public var triangles: [[UInt32]]?
    public var parentID: String?
    public var attachment: Attachment?
    public var offset: [Float]?

    public init(id: String, primitive: Primitive, position: [Float], size: [Float],
                rotation: [Float] = [0,0,0], color: String = "#46CBB8",
                metallic: Float = 0.1, roughness: Float = 0.45,
                profile: [[Float]]? = nil, path: [[Float]]? = nil,
                vertices: [[Float]]? = nil, triangles: [[UInt32]]? = nil,
                parentID: String? = nil, attachment: Attachment? = nil, offset: [Float]? = nil) {
        self.id=id; self.primitive=primitive; self.position=position; self.size=size
        self.rotation=rotation; self.color=color; self.metallic=metallic; self.roughness=roughness
        self.profile=profile; self.path=path; self.vertices=vertices; self.triangles=triangles
        self.parentID=parentID; self.attachment=attachment; self.offset=offset
    }

    public static func defaultNode(primitive: Primitive, id: String,
                                   position: [Float] = [0,0.25,0]) -> Self {
        var node=Self(id:id,primitive:primitive,position:position,size:[0.5,0.5,0.5])
        switch primitive {
        case .mesh:
            node.vertices=[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0,-0.5,0.5],[0,0.5,0]]
            node.triangles=[[0,1,2],[0,3,1],[1,3,2],[2,3,0]]
        case .lathe:
            node.profile=[[0,-0.5],[0.32,-0.5],[0.5,-0.2],[0.42,0.12],[0.2,0.3],[0.23,0.5],[0,0.5]]
        case .extrusion:
            node.profile=[[-0.5,-0.5],[0.5,-0.5],[0.5,-0.15],[-0.1,-0.15],[-0.1,0.5],[-0.5,0.5]]
        default: break
        }
        return node
    }

    public func validate() throws {
        guard !id.isEmpty,id.utf8.count<=32,id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45 || $0==95
        }) else { throw CreationError.invalidParameter("部件标识须为 1–32 位英文字母、数字、下划线或连字符。") }
        guard position.count==3,size.count==3,rotation.count==3 else {
            throw CreationError.invalidParameter("位置、尺寸和旋转各须包含三个数值。")
        }
        guard (position+size+rotation+[metallic,roughness]).allSatisfy(\.isFinite) else {
            throw CreationError.invalidParameter("场景参数必须为有限数值。")
        }
        guard position.allSatisfy({abs($0)<=3}),size.allSatisfy({(0.02...2.5).contains($0)}),
              rotation.allSatisfy({(-360...360).contains($0)}) else {
            throw CreationError.invalidParameter("部件中心须在 ±3 米内，尺寸须为 0.02–2.5 米，旋转须为 ±360 度内。")
        }
        guard (0...1).contains(metallic),(0...1).contains(roughness) else {
            throw CreationError.invalidParameter("金属度和粗糙度须在 0–1 之间。")
        }
        guard color.utf8.count==7,color.first=="#",color.dropFirst().utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw CreationError.invalidParameter("材质颜色须为 #RRGGBB 格式。") }
        if let parentID {
            guard parentID != id, !parentID.isEmpty, parentID.utf8.count<=32,
                  parentID.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45 || $0==95}),
                  attachment != nil else {
                throw CreationError.invalidParameter("连接关系需要有效的父部件标识与连接面。")
            }
        } else if attachment != nil || offset?.contains(where:{$0 != 0}) == true {
            throw CreationError.invalidParameter("连接面或偏移需要父部件标识。")
        }
        if let offset {
            guard offset.count==3,offset.allSatisfy({$0.isFinite && abs($0)<=3}) else {
                throw CreationError.invalidParameter("连接偏移须为 ±3 米内的三个有限数值。")
            }
        }
        try FreeformGeometry.validate(self)
    }

    static let requiredKeys: Set<String> = ["id","primitive","position","size","rotation","color","metallic","roughness"]
    static func permittedKeys(for primitive: Primitive)->Set<String> {
        var keys=requiredKeys.union(["parentID","attachment","offset"])
        switch primitive {
        case .mesh: keys.formUnion(["vertices","triangles"])
        case .lathe,.extrusion: keys.insert("profile")
        default: break
        }
        return keys
    }
}

public struct SceneSpec: Codable, Sendable, Equatable {
    public var name: String
    public var nodes: [SceneNode]
    public init(name: String, nodes: [SceneNode]) { self.name=name; self.nodes=nodes }
    public static let maximumNodes=32
    public static let maximumResponseBytes=262_144

    public func validate() throws {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=40,
              !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else {
            throw CreationError.invalidParameter("作品名称须为 1–40 个字符，不能包含控制字符。")
        }
        guard (1...Self.maximumNodes).contains(nodes.count) else {
            throw CreationError.budgetExceeded("每件作品须包含 1–32 个部件。")
        }
        guard Set(nodes.map(\.id)).count==nodes.count else {
            throw CreationError.invalidParameter("场景内的部件标识不能重复。")
        }
        for node in nodes { try node.validate() }
    }

    public static func decodeModelResponse(_ response: String) throws -> Self {
        guard response.utf8.count<=maximumResponseBytes else {
            throw CreationError.invalidModelResponse("场景参数响应过长。")
        }
        var text=response.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("```json\n"),text.hasSuffix("```") {
            text=String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in:.whitespacesAndNewlines)
        } else if text.hasPrefix("```\n"),text.hasSuffix("```") {
            text=String(text.dropFirst(4).dropLast(3)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let object=try StrictJSONObject.decode(text,maximumBytes:maximumResponseBytes)
        if let nodes=object["nodes"] as? [[String:Any]],nodes.contains(where:{$0["dimensions"] != nil}) {
            return try ScenePlan.decodeObject(object,text:text)
        }
        guard Set(object.keys)==["name","nodes"],let nodes=object["nodes"] as? [[String:Any]],
              nodes.allSatisfy({ node in
                  guard let raw=node["primitive"] as? String,let primitive=SceneNode.Primitive(rawValue:raw) else{return false}
                  let keys=Set(node.keys)
                  return keys.isSuperset(of:SceneNode.requiredKeys) && keys.isSubset(of:SceneNode.permittedKeys(for:primitive))
              }) else {
            throw CreationError.invalidModelResponse("模型须返回完整的场景 JSON，且只能包含规定的场景和部件字段。")
        }
        do {
            let result=try JSONDecoder().decode(Self.self,from:Data(text.utf8))
            try result.validate()
            return try SceneAttachmentResolver.resolve(result)
        } catch let error as CreationError { throw error }
        catch { throw CreationError.invalidModelResponse("场景参数类型、部件形状或枚举值不符合要求。") }
    }

    public static let chair=SceneSpec(name:"青玉扶手椅",nodes:[
        .init(id:"seat",primitive:.box,position:[0,0.46,0],size:[0.55,0.09,0.52],color:"#29A99A",roughness:0.35),
        .init(id:"back",primitive:.box,position:[0,0.76,-0.22],size:[0.53,0.56,0.08],rotation:[-6,0,0],color:"#34C3B0",roughness:0.35),
        .init(id:"leg_fl",primitive:.cylinder,position:[-0.21,0.22,0.20],size:[0.045,0.44,0.045],color:"#40374D",metallic:0.65),
        .init(id:"leg_fr",primitive:.cylinder,position:[0.21,0.22,0.20],size:[0.045,0.44,0.045],color:"#40374D",metallic:0.65),
        .init(id:"leg_bl",primitive:.cylinder,position:[-0.21,0.22,-0.20],size:[0.045,0.44,0.045],color:"#40374D",metallic:0.65),
        .init(id:"leg_br",primitive:.cylinder,position:[0.21,0.22,-0.20],size:[0.045,0.44,0.045],color:"#40374D",metallic:0.65),
        .init(id:"arm_l",primitive:.box,position:[-0.26,0.66,0],size:[0.055,0.055,0.48],color:"#D7B975",metallic:0.65),
        .init(id:"arm_r",primitive:.box,position:[0.26,0.66,0],size:[0.055,0.055,0.48],color:"#D7B975",metallic:0.65)
    ])

    public static let robot=SceneSpec(name:"星际小机器人",nodes:[
        .init(id:"torso",primitive:.box,position:[0,0.62,0],size:[0.38,0.42,0.23],color:"#6E64CE",metallic:0.55),
        .init(id:"head",primitive:.sphere,position:[0,0.99,0],size:[0.40,0.32,0.28],color:"#DDE2F3",metallic:0.5,roughness:0.25),
        .init(id:"eye_l",primitive:.sphere,position:[-0.08,1.02,0.132],size:[0.065,0.065,0.035],color:"#24D8DA",roughness:0.2),
        .init(id:"eye_r",primitive:.sphere,position:[0.08,1.02,0.132],size:[0.065,0.065,0.035],color:"#24D8DA",roughness:0.2),
        .init(id:"arm_l",primitive:.cylinder,position:[-0.24,0.62,0],size:[0.09,0.36,0.09],rotation:[0,0,-12],color:"#DDE2F3",metallic:0.55),
        .init(id:"arm_r",primitive:.cylinder,position:[0.24,0.62,0],size:[0.09,0.36,0.09],rotation:[0,0,12],color:"#DDE2F3",metallic:0.55),
        .init(id:"leg_l",primitive:.cylinder,position:[-0.10,0.23,0],size:[0.10,0.35,0.10],color:"#DDE2F3",metallic:0.55),
        .init(id:"leg_r",primitive:.cylinder,position:[0.10,0.23,0],size:[0.10,0.35,0.10],color:"#DDE2F3",metallic:0.55),
        .init(id:"foot_l",primitive:.box,position:[-0.10,0.045,0.035],size:[0.15,0.09,0.23],color:"#5D52B4",metallic:0.55),
        .init(id:"foot_r",primitive:.box,position:[0.10,0.045,0.035],size:[0.15,0.09,0.23],color:"#5D52B4",metallic:0.55),
        .init(id:"antenna",primitive:.cylinder,position:[0,1.20,0],size:[0.025,0.13,0.025],color:"#D7B975",metallic:0.65),
        .init(id:"antenna_tip",primitive:.sphere,position:[0,1.28,0],size:[0.065,0.065,0.065],color:"#24D8DA",roughness:0.2)
    ])

    public static let lamp=SceneSpec(name:"环光工作灯",nodes:[
        .init(id:"base",primitive:.cylinder,position:[0,0.04,0],size:[0.36,0.08,0.36],color:"#303749",metallic:0.65,roughness:0.3),
        .init(id:"stem",primitive:.cylinder,position:[0,0.35,0],size:[0.045,0.56,0.045],color:"#D6C899",metallic:0.8,roughness:0.25),
        .init(id:"joint",primitive:.sphere,position:[0,0.64,0],size:[0.10,0.10,0.10],color:"#A0A8BE",metallic:0.8),
        .init(id:"arm",primitive:.cylinder,position:[0.13,0.78,0],size:[0.04,0.36,0.04],rotation:[0,0,-43],color:"#D6C899",metallic:0.8,roughness:0.25),
        .init(id:"shade",primitive:.cone,position:[0.26,0.91,0],size:[0.34,0.24,0.34],color:"#6651A7",metallic:0.35,roughness:0.3),
        .init(id:"rim",primitive:.torus,position:[0.26,0.795,0],size:[0.35,0.028,0.35],color:"#E8D39B",metallic:0.8,roughness:0.25),
        .init(id:"bulb",primitive:.sphere,position:[0.26,0.81,0],size:[0.13,0.10,0.13],color:"#FFF1CC",roughness:0.2)
    ])
    public static let presets:[SceneSpec]=[.chair,.robot,.lamp]
}

public enum ScenePrompt {
    public static let system="""
    你是离线通用3D艺术造型设计师。根据用户任意题材的描述，规划可辨认的物体轮廓、部件、比例与材质。只返回完整JSON，不解释、不输出Markdown、脚本、网址或思考过程。
    输出规划格式：场景{name,nodes}，name为1到40字，nodes为1到32部件，优先少而准确。不存在物体类别白名单，不要把所有题材都做成方块。
    每部件只必需四字段：id,primitive,dimensions,color。id为不同的短英文名称。dimensions必须是命名对象{width:宽X,height:高Y,depth:深Z}，三个正数各0.02到2.5米。绝不能用数组代替dimensions。
    Y向上，Z正向是物体正面。cylinder/cone/lathe的天然长轴沿Y；竖直细杆height应远大于width/depth，不要把杆长写到depth。水平板height薄、width/depth大；竖板height大、depth薄。需要横杆或斜杆时仍用沿Y的长形状再加rotation。
    primitive可选box,sphere,cylinder,cone,torus,lathe,extrusion,mesh。color为#RRGGBB。可选metallic和roughness为0到1，默认0.1和0.45；可选rotation为命名对象{x,y,z}，单位角度、XYZ依次旋转，每项-360到360，默认0。
    优先用连接关系attach，不要算绝对浮点中心。选一个主体根部件不写attach/origin；其他部件可加attach:{parent:父部件id,face:贴面方向,xOffset:横偏移,yOffset:竖偏移,zOffset:前后偏移}。偏移可省略，单位米，各-3到3。parent必须存在，不得自指或循环。
    face可选top,bottom,front,back,left,right,inside。原生引擎按实际旋转几何外包框贴合并统一落地。top/bottom沿Y且只使用xOffset/zOffset；front/back沿Z且只使用xOffset/yOffset；left/right沿X且只使用yOffset/zOffset。法向offset不会让部件离开贴面。
    成对部件必须明确分离：左右两眼都front连接同一头部，分别xOffset=-0.08和+0.08，不能都是0。左右机翼分别left/right连接机身。多条腿都bottom连接承托件，以正负xOffset/zOffset分开。不要把多个parts重叠同一位置。
    通用示例：竖直支杆dimensions={width:0.04,height:0.6,depth:0.04}、attach.face=top；竖立薄板dimensions={width:0.5,height:0.4,depth:0.04}，top连接下方结构并向后偏移；左右球形装饰dimensions相同，但front贴面xOffset分别为负和正。这些是空间语义示例，不限制创作题材。
    有圆滑旋转轮廓用lathe，额外profile:[[半径,高度],...]，2到64点、半径非负、按轮廓有序，绕Y旋转，回到内壁可形成真实空心碗杯瓶。按轮廓需要4到12点即可，末端半径0可封口。
    不规则板、翼、尾鳍、标志轮廓用extrusion，额外profile:[[x,y],...]，3到64个有序不自交点，允许凹轮廓，沿Z挤出；dimensions.depth为厚度。水平翼面可rotation.x=90。不要以矩形代替用户明确要求的弯曲或分叉轮廓。
    特殊自由表面用mesh，额外vertices:[[x,y,z],...]及triangles:[[整数索引,整数索引,整数索引],...]，索引从0，外侧看逆时针，不能退化；最多1024顶点/2048面，优先8到32顶点。自由几何会居中归一化再应用dimensions与rotation。
    基础5种形状不得含profile/vertices/triangles；lathe/extrusion只加profile；mesh只加vertices/triangles。不要写null占位，不要加入未规定字段，禁止重复JSON键、NaN和无效引用。
    修改现有作品时，当前作品已经使用相同的命名规划格式。保留未要求改变的部件、id、dimensions、origin和rotation。origin是绝对中心米，origin与attach二选一，不能同时指定。仅改颜色时原样保留每部件origin，不加attach、不清零位姿。新增连接件才用attach。
    单件物体应具有清楚轮廓和空间连接，不要无关大平台。复杂题材做低复杂度艺术造型，优先保证比例和结构。最终只返回完整规划JSON。
    """

    public static func userRequest(_ request:String,currentSpec:SceneSpec?=nil)throws->String {
        guard !request.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,request.count<=2_000 else {
            throw CreationError.invalidParameter("创作描述须为 1–2000 个字符。")
        }
        if let currentSpec {
            try currentSpec.validate()
            return "当前作品参数：\n\(try ScenePlan.snapshot(currentSpec))\n用户修改要求：\n\(request)"
        }
        return "请根据题材需要用适当数量的几何部件或自由曲面创作：\n\(request)"
    }
}
