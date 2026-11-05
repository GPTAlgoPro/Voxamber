import Foundation

public enum SceneCreationPhase: String, Codable, CaseIterable, Sendable {
    case outline, placement, geometry
}

public struct SceneCreationCall: Sendable, Equatable {
    public let systemPrompt: String
    public let userPrompt: String
    public let jsonSchema: String
    public let maxTokens: Int

    public init(systemPrompt: String, userPrompt: String, jsonSchema: String, maxTokens: Int) {
        self.systemPrompt = systemPrompt; self.userPrompt = userPrompt
        self.jsonSchema = jsonSchema; self.maxTokens = maxTokens
    }
}

/// Directions always refer to world axes, including when a parent is rotated.
public enum SceneFaceAnchor: String, Codable, CaseIterable, Sendable {
    case center, left, right, front, back, top, bottom
    case frontLeft, frontRight, backLeft, backRight
    case topLeft, topRight, bottomLeft, bottomRight
    case frontTop, frontBottom, backTop, backBottom

    public static func allowed(for face: SceneNode.Attachment) -> [Self] {
        switch face {
        case .top, .bottom: [.center,.left,.right,.front,.back,.frontLeft,.frontRight,.backLeft,.backRight]
        case .front, .back: [.center,.left,.right,.top,.bottom,.topLeft,.topRight,.bottomLeft,.bottomRight]
        case .left, .right: [.center,.front,.back,.top,.bottom,.frontTop,.frontBottom,.backTop,.backBottom]
        case .inside: [.center]
        }
    }

    public func isAllowed(on face: SceneNode.Attachment) -> Bool { Self.allowed(for: face).contains(self) }

    func signs(on face: SceneNode.Attachment) throws -> [Double] {
        guard isAllowed(on: face) else { throw AssemblyContract.invalid("锚点不适用于声明的连接面。") }
        switch face {
        case .top, .bottom:
            switch self {
            case .left: return [-1,0,0]
            case .right: return [1,0,0]
            case .front: return [0,0,1]
            case .back: return [0,0,-1]
            case .frontLeft: return [-1,0,1]
            case .frontRight: return [1,0,1]
            case .backLeft: return [-1,0,-1]
            case .backRight: return [1,0,-1]
            default: return [0,0,0]
            }
        case .front, .back:
            switch self {
            case .left: return [-1,0,0]
            case .right: return [1,0,0]
            case .top: return [0,1,0]
            case .bottom: return [0,-1,0]
            case .topLeft: return [-1,1,0]
            case .topRight: return [1,1,0]
            case .bottomLeft: return [-1,-1,0]
            case .bottomRight: return [1,-1,0]
            default: return [0,0,0]
            }
        case .left, .right:
            switch self {
            case .front: return [0,0,1]
            case .back: return [0,0,-1]
            case .top: return [0,1,0]
            case .bottom: return [0,-1,0]
            case .frontTop: return [0,1,1]
            case .frontBottom: return [0,-1,1]
            case .backTop: return [0,1,-1]
            case .backBottom: return [0,-1,-1]
            default: return [0,0,0]
            }
        case .inside: return [0,0,0]
        }
    }
}

public struct SceneAssemblyOutline: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable {
        public let id: String
        public let primitive: SceneNode.Primitive
        public let purpose: String
        public let parent: String?
        public let face: SceneNode.Attachment?

        public init(id: String, primitive: SceneNode.Primitive, purpose: String,
                    parent: String? = nil, face: SceneNode.Attachment? = nil) {
            self.id = id; self.primitive = primitive; self.purpose = purpose
            self.parent = parent; self.face = face
        }
    }

    public let name: String
    public let parts: [Part]

    public init(name: String, parts: [Part]) throws {
        self.name = name; self.parts = parts
        try validate()
    }

    public static func decodeModelResponse(_ text: String) throws -> Self {
        let object = try StrictJSONObject.decode(text, maximumBytes: SceneSpec.maximumResponseBytes)
        guard Set(object.keys) == ["name","parts"], let rows = object["parts"] as? [[String:Any]] else {
            throw AssemblyContract.invalid("装配提纲只能包含 name 和 parts。")
        }
        for row in rows {
            let keys = Set(row.keys)
            guard keys.isSuperset(of: ["id","primitive","purpose"]),
                  keys.isSubset(of: ["id","primitive","purpose","parent","face"]),
                  row["parent"] == nil || row["parent"] is String,
                  row["face"] == nil || row["face"] is String else {
                throw AssemblyContract.invalid("装配部件含未知字段或无效连接类型。")
            }
        }
        do {
            let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
            try value.validate()
            return value
        } catch let error as CreationError { throw error }
        catch { throw AssemblyContract.invalid("装配提纲的字段类型不符合合同。") }
    }

    public func validate() throws {
        try AssemblyContract.name(name)
        guard (1...SceneSpec.maximumNodes).contains(parts.count) else {
            throw AssemblyContract.invalid("装配提纲须包含 1–32 个部件。")
        }
        var byID: [String:Part] = [:]
        for part in parts {
            guard AssemblyContract.identifier(part.id), byID[part.id] == nil,
                  !part.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  part.purpose.count <= 120,
                  (part.parent == nil) == (part.face == nil) else {
                throw AssemblyContract.invalid("装配部件标识、用途或连接字段无效。")
            }
            byID[part.id] = part
        }
        for part in parts {
            var seen: Set<String> = [part.id]
            var parent = part.parent
            while let id = parent {
                try Task.checkCancellation()
                guard let ancestor = byID[id], seen.insert(id).inserted else {
                    throw AssemblyContract.invalid("装配提纲引用不存在的部件或包含循环。")
                }
                parent = ancestor.parent
            }
        }
        // A forest is valid. Roots need not occupy a special array position.
    }
}

public struct SceneAssemblyPlacement: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let anchor: SceneFaceAnchor
        /// Optional residual displacement in meters relative to the anchor.
        /// Absence is distinct from an explicitly model-selected zero.
        public let xOffset: Float?
        public let yOffset: Float?
        public let zOffset: Float?
        public init(id: String, anchor: SceneFaceAnchor,
                    xOffset: Float? = nil, yOffset: Float? = nil, zOffset: Float? = nil) {
            self.id = id; self.anchor = anchor
            self.xOffset = xOffset; self.yOffset = yOffset; self.zOffset = zOffset
        }
        var providedDeltas: [String:Float] {
            var result: [String:Float] = [:]
            if let xOffset { result["xOffset"] = xOffset }
            if let yOffset { result["yOffset"] = yOffset }
            if let zOffset { result["zOffset"] = zOffset }
            return result
        }
        var deltaVector: [Double] { [Double(xOffset ?? 0),Double(yOffset ?? 0),Double(zOffset ?? 0)] }
    }
    public let anchors: [Entry]

    public init(anchors: [Entry], outline: SceneAssemblyOutline) throws {
        self.anchors = anchors
        try validate(outline: outline)
    }

    public static func decodeModelResponse(_ text: String, outline: SceneAssemblyOutline) throws -> Self {
        try outline.validate()
        let object = try StrictJSONObject.decode(text, maximumBytes: SceneSpec.maximumResponseBytes)
        guard Set(object.keys) == ["anchors"], let rows = object["anchors"] as? [[String:Any]],
              rows.allSatisfy({ row in
                  Set(row.keys).isSuperset(of:["id","anchor"]) &&
                  Set(row.keys).isSubset(of:["id","anchor","xOffset","yOffset","zOffset"]) &&
                  !row.values.contains(where: { $0 is NSNull })
              }) else {
            throw AssemblyContract.invalid("锚点计划含未知字段或 null 占位。")
        }
        do {
            let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
            try value.validate(outline: outline)
            return value
        } catch let error as CreationError { throw error }
        catch { throw AssemblyContract.invalid("锚点计划的类型或标签无效。") }
    }

    public func validate(outline: SceneAssemblyOutline) throws {
        try outline.validate()
        let children = outline.parts.filter { $0.parent != nil }
        guard anchors.count == children.count else { throw AssemblyContract.invalid("锚点计划部件数量不符。") }
        for (entry, part) in zip(anchors, children) {
            guard entry.id == part.id, let face = part.face, entry.anchor.isAllowed(on: face) else {
                throw AssemblyContract.invalid("锚点计划改变部件顺序、标识或连接面含义。")
            }
            let deltas = entry.providedDeltas
            guard Set(deltas.keys).isSubset(of: AssemblyContract.deltaKeys(for:face)),
                  deltas.values.allSatisfy({ $0.isFinite && abs($0) <= 3 }) else {
                throw AssemblyContract.invalid("锚点残差只能使用当前连接面的切向轴，数值须为 ±3 米内有限数。")
            }
        }
    }
}

enum AssemblyContract {
    static func invalid(_ text: String) -> CreationError { .invalidModelResponse(text) }
    static func name(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 40,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid("作品名称须为 1–40 个字符，不能包含控制字符。")
        }
    }
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func request(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 2_000 else {
            throw invalid("创作描述须为 1–2000 个字符。")
        }
    }
    static func text(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func deltaKeys(for face: SceneNode.Attachment) -> Set<String> {
        switch face {
        case .top, .bottom: ["xOffset","zOffset"]
        case .front, .back: ["xOffset","yOffset"]
        case .left, .right: ["yOffset","zOffset"]
        case .inside: ["xOffset","yOffset","zOffset"]
        }
    }
    static func float(_ value: Any) throws -> Float {
        do {
            let data = try JSONSerialization.data(withJSONObject:value, options:.fragmentsAllowed)
            let result = try JSONDecoder().decode(Float.self, from:data)
            guard result.isFinite else { throw invalid("数值须为有限 Float。") }
            return result
        } catch let error as CreationError { throw error }
        catch { throw invalid("残差的数值类型无效。") }
    }
}
