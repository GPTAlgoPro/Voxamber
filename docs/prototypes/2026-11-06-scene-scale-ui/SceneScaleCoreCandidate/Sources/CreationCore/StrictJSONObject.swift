import Foundation

/// Foundation's JSON decoders silently collapse duplicate keys. Check keys before decoding models.
public enum StrictJSONObject {
    public static func decode(_ text: String, maximumBytes: Int = 65_536) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CreationError.invalidModelResponse("模型须返回一个完整、有效的 JSON 对象。")
        }
        var scanner = KeyScanner(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count else {
            throw CreationError.invalidModelResponse("模型 JSON 对象后含有额外内容。")
        }
        return object
    }
}

private struct KeyScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func whitespace() {
        while index < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw invalid("模型 JSON 嵌套层级过深。") }
        whitespace()
        guard index < bytes.count else { throw invalid() }
        switch bytes[index] {
        case 123: try object(depth: depth)
        case 91:
            index += 1; whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth + 1); whitespace()
                if consume(93) { return }
                guard consume(44) else { throw invalid() }
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![UInt8(44), 93, 125, 32, 9, 10, 13].contains(bytes[index]) { index += 1 }
            guard index > start else { throw invalid() }
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1; whitespace()
        if consume(125) { return }
        var keys: Set<String> = []
        while true {
            whitespace()
            let key = try string()
            guard keys.insert(key).inserted else { throw invalid("模型 JSON 含有重复字段。") }
            whitespace()
            guard consume(58) else { throw invalid() }
            try value(depth: depth + 1); whitespace()
            if consume(125) { return }
            guard consume(44) else { throw invalid() }
        }
    }

    private mutating func string() throws -> String {
        let start = index
        guard consume(34) else { throw invalid() }
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 {
                index += 1
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                    throw invalid()
                }
                return value
            }
            index += 1
        }
        throw invalid()
    }

    private mutating func consume(_ value: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == value else { return false }
        index += 1
        return true
    }

    private func invalid(_ message: String = "模型 JSON 格式无效。") -> CreationError {
        .invalidModelResponse(message)
    }
}
