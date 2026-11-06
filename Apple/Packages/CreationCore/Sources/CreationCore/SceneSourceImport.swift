import Foundation

public enum SceneSourceFormat: String, Codable, Sendable {
    case rawJavaScript, codeFence, textThreeScript
}

public enum SceneSourceImportHint: Sendable {
    case automatic
    /// Explicit .js files bypass container detection. JavaScript strings may
    /// themselves contain HTML or Markdown; this layer is not a JS parser.
    case rawJavaScript
}

public struct SceneSourceProvenance: Codable, Sendable, Equatable {
    public let containers: [SceneSourceFormat]
    public let sourceUTF8Offset: Int
    public let sourceUTF8Length: Int
    public let codeFenceInfo: String?
}

/// Import formatting only. SHA identities, execution, compiler diagnostics and
/// model validity belong to the caller. originalData preserves even a UTF8 BOM.
public struct SceneSourceImportResult: Sendable, Equatable {
    public let originalData: Data
    public let original: String
    public let source: String
    public let format: SceneSourceFormat
    public let provenance: SceneSourceProvenance
}

public enum SceneSourceImportError: LocalizedError, Sendable, Equatable {
    case invalidUTF8, containsNUL, emptySource
    case rawInputTooLarge, sourceTooLarge
    case ambiguousSources(Int)
    case unterminatedCodeFence, malformedHTML
    case unsupportedHTMLScript

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "源文件必须是有效 UTF-8 文本。"
        case .containsNUL: "源文本不能包含 NUL 字符。"
        case .emptySource: "没有找到可导入的场景源码。"
        case .rawInputTooLarge: "导入原文不能超过 4 MiB。"
        case .sourceTooLarge: "实际场景源码不能超过 1 MiB。"
        case .ambiguousSources(let count): "发现 \(count) 段代码，请明确选择一段后再导入。"
        case .unterminatedCodeFence: "代码围栏没有完整结束，请重新复制完整代码。"
        case .malformedHTML: "HTML 场景容器不完整或格式不明确。"
        case .unsupportedHTMLScript: "HTML 仅接受一个内嵌的 script type=\"text/three\"，不会推定执行其他脚本。"
        }
    }
}

public enum SceneSourceImport {
    public static let maximumSourceBytes = 1_048_576
    public static let maximumRawBytes = 4_194_304

    public static func parse(_ text: String, hint: SceneSourceImportHint = .automatic) throws -> SceneSourceImportResult {
        try parse(Data(text.utf8), hint: hint)
    }

    public static func parse(_ data: Data, hint: SceneSourceImportHint = .automatic) throws -> SceneSourceImportResult {
        try Task.checkCancellation()
        guard data.count <= maximumRawBytes else { throw SceneSourceImportError.rawInputTooLarge }
        guard let original = String(data: data, encoding: .utf8) else { throw SceneSourceImportError.invalidUTF8 }
        guard !data.contains(0) else { throw SceneSourceImportError.containsNUL }
        let bytes = Array(data)
        var range = 0..<bytes.count
        var containers: [SceneSourceFormat] = []
        var fenceInfo: String?
        if case .automatic = hint {
            let first = contentStart(bytes, in: range)
            let htmlCandidate = first < range.upperBound && bytes[first] == 60
            if htmlCandidate, let htmlSource = try textThreeScript(in: bytes, range: first..<range.upperBound) {
                range = htmlSource
                containers.append(.textThreeScript)
            } else {
                let fences = try codeFences(in: bytes)
                guard fences.count <= 1 else { throw SceneSourceImportError.ambiguousSources(fences.count) }
                if let fence = fences.first {
                    range = fence.body; fenceInfo = fence.info; containers.append(.codeFence)
                    let inner = contentStart(bytes, in: range)
                    if inner < range.upperBound, bytes[inner] == 60 {
                        guard let htmlSource = try textThreeScript(in: bytes, range: inner..<range.upperBound) else {
                            throw SceneSourceImportError.unsupportedHTMLScript
                        }
                        range = htmlSource
                        containers.append(.textThreeScript)
                    }
                } else if htmlCandidate {
                    throw SceneSourceImportError.unsupportedHTMLScript
                }
            }
        }
        guard range.count <= maximumSourceBytes else { throw SceneSourceImportError.sourceTooLarge }
        let source = String(decoding: bytes[range], as: UTF8.self)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SceneSourceImportError.emptySource }
        try Task.checkCancellation()
        let format = containers.last ?? .rawJavaScript
        return .init(originalData: data, original: original, source: source, format: format,
            provenance: .init(containers: containers, sourceUTF8Offset: range.lowerBound,
                sourceUTF8Length: range.count, codeFenceInfo: fenceInfo))
    }

    private struct Fence { let body: Range<Int>; let info: String }
    private struct OpenFence { let marker: UInt8; let count: Int; let bodyStart: Int; let info: String }

    /// Common multiline Markdown fences, not JavaScript syntax validation.
    /// The body is an exact byte slice, including its original line endings.
    private static func codeFences(in bytes: [UInt8]) throws -> [Fence] {
        var index = 0, open: OpenFence?, result: [Fence] = []
        while index < bytes.count {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let start = index
            while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
            let end = index
            if index < bytes.count, bytes[index] == 13 { index += 1; if index < bytes.count, bytes[index] == 10 { index += 1 } }
            else if index < bytes.count { index += 1 }
            var cursor = start, spaces = 0
            if start == 0, end >= 3, Array(bytes[0..<3]) == [239,187,191] { cursor = 3 }
            while cursor < end, bytes[cursor] == 32, spaces < 4 { spaces += 1; cursor += 1 }
            guard spaces <= 3, cursor < end, bytes[cursor] == 96 || bytes[cursor] == 126 else { continue }
            let marker = bytes[cursor], runStart = cursor
            while cursor < end, bytes[cursor] == marker { cursor += 1 }
            let count = cursor - runStart
            guard count >= 3 else { continue }
            if let current = open {
                if marker == current.marker, count >= current.count,
                   bytes[cursor..<end].allSatisfy({ $0 == 32 || $0 == 9 }) {
                    result.append(.init(body: current.bodyStart..<start, info: current.info)); open = nil
                }
            } else {
                let infoBytes = bytes[cursor..<end]
                // Backticks inside an opening info string are not a Markdown
                // backtick fence; no attempt is made to repair it.
                if marker == 96, infoBytes.contains(96) { continue }
                let info = String(decoding: infoBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                open = .init(marker: marker, count: count, bodyStart: index, info: info)
            }
        }
        guard open == nil else { throw SceneSourceImportError.unterminatedCodeFence }
        return result
    }

    private static func contentStart(_ bytes: [UInt8], in range: Range<Int>) -> Int {
        var index = range.lowerBound
        if index + 3 <= range.upperBound, Array(bytes[index..<(index + 3)]) == [239,187,191] { index += 3 }
        while index < range.upperBound, whitespace(bytes[index]) { index += 1 }
        return index
    }

    private struct Tag {
        let name: String
        let closing: Bool
        let selfClosing: Bool
        let attributes: [String: String?]
        let end: Int
    }
    private struct Script { let body: Range<Int>; let allowed: Bool }

    /// HTML is never rendered. Only one explicit inline text/three raw-text
    /// element is extracted; classic/module/external scripts are never selected.
    private static func textThreeScript(in bytes: [UInt8], range: Range<Int>) throws -> Range<Int>? {
        var cursor = range.lowerBound, scripts: [Script] = []
        while cursor < range.upperBound {
            if cursor.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard bytes[cursor] == 60 else { cursor += 1; continue }
            if starts(bytes, at: cursor, literal: "<!--", end: range.upperBound) {
                guard let end = find(bytes, literal: "-->", from: cursor + 4, end: range.upperBound) else { throw SceneSourceImportError.malformedHTML }
                cursor = end + 3; continue
            }
            guard let tag = try readTag(bytes, start: cursor, end: range.upperBound) else { cursor += 1; continue }
            cursor = tag.end
            // These HTML raw-text/RCDATA elements can contain literal script
            // examples; their contents are not script elements to select.
            if !tag.closing, ["style","textarea","title","xmp","iframe","noembed","noframes"].contains(tag.name) {
                guard let close = try scriptClose(bytes, from: tag.end, end: range.upperBound, name: tag.name) else {
                    throw SceneSourceImportError.malformedHTML
                }
                cursor = close.end; continue
            }
            if tag.name == "plaintext", !tag.closing { break }
            guard tag.name == "script", !tag.closing else { continue }
            guard !tag.selfClosing, let close = try scriptClose(bytes, from: tag.end, end: range.upperBound) else { throw SceneSourceImportError.malformedHTML }
            let type = tag.attributes["type"] ?? nil
            let allowed = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/three"
                && tag.attributes["src"] == nil
            scripts.append(.init(body: tag.end..<close.start, allowed: allowed))
            cursor = close.end
        }
        guard scripts.count <= 1 else { throw SceneSourceImportError.ambiguousSources(scripts.count) }
        guard let script = scripts.first else { return nil }
        guard script.allowed else { throw SceneSourceImportError.unsupportedHTMLScript }
        return script.body
    }

    private static func scriptClose(_ bytes: [UInt8], from start: Int, end: Int, name: String = "script") throws -> (start: Int, end: Int)? {
        var index = start
        while index < end {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            if starts(bytes, at: index, literal: "</" + name, end: end, caseInsensitive: true) {
                let next = index + 2 + name.utf8.count
                if next < end, whitespace(bytes[next]) || bytes[next] == 62 {
                    guard let tag = try readTag(bytes, start: index, end: end), tag.closing, tag.name == name,
                          tag.attributes.isEmpty, !tag.selfClosing else { throw SceneSourceImportError.malformedHTML }
                    return (index, tag.end)
                }
            }
            index += 1
        }
        return nil
    }

    private static func readTag(_ bytes: [UInt8], start: Int, end: Int) throws -> Tag? {
        var index = start + 1
        guard index < end else { throw SceneSourceImportError.malformedHTML }
        if bytes[index] == 33 || bytes[index] == 63 {
            guard let finish = tagEnd(bytes, from: index, end: end) else { throw SceneSourceImportError.malformedHTML }
            return .init(name: "!", closing: false, selfClosing: false, attributes: [:], end: finish)
        }
        let closing = bytes[index] == 47
        if closing { index += 1 }
        let nameStart = index
        while index < end, nameByte(bytes[index]) { index += 1 }
        guard index > nameStart else { return nil }
        let name = asciiLower(bytes[nameStart..<index])
        var attributes: [String: String?] = [:], seen = Set<String>(), selfClosing = false
        while index < end {
            while index < end, whitespace(bytes[index]) { index += 1 }
            guard index < end else { throw SceneSourceImportError.malformedHTML }
            if bytes[index] == 62 { return .init(name: name, closing: closing, selfClosing: selfClosing, attributes: attributes, end: index + 1) }
            if bytes[index] == 47 {
                index += 1
                guard index < end, bytes[index] == 62 else { throw SceneSourceImportError.malformedHTML }
                selfClosing = true; continue
            }
            let attributeStart = index
            while index < end, !whitespace(bytes[index]), ![61,62,47,34,39,60].contains(bytes[index]) { index += 1 }
            guard index > attributeStart else { throw SceneSourceImportError.malformedHTML }
            let key = asciiLower(bytes[attributeStart..<index])
            guard seen.insert(key).inserted else { throw SceneSourceImportError.malformedHTML }
            while index < end, whitespace(bytes[index]) { index += 1 }
            var value: String?
            if index < end, bytes[index] == 61 {
                index += 1; while index < end, whitespace(bytes[index]) { index += 1 }
                guard index < end else { throw SceneSourceImportError.malformedHTML }
                if bytes[index] == 34 || bytes[index] == 39 {
                    let quote = bytes[index]; index += 1; let valueStart = index
                    while index < end, bytes[index] != quote { index += 1 }
                    guard index < end else { throw SceneSourceImportError.malformedHTML }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self); index += 1
                } else {
                    let valueStart = index
                    while index < end, !whitespace(bytes[index]), bytes[index] != 62 { index += 1 }
                    guard index > valueStart else { throw SceneSourceImportError.malformedHTML }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            // updateValue preserves the key even for a valueless attribute.
            attributes.updateValue(value, forKey: key)
        }
        throw SceneSourceImportError.malformedHTML
    }

    private static func tagEnd(_ bytes: [UInt8], from start: Int, end: Int) -> Int? {
        var quote: UInt8?, index = start
        while index < end {
            let byte = bytes[index]
            if let current = quote { if byte == current { quote = nil } }
            else if byte == 34 || byte == 39 { quote = byte }
            else if byte == 62 { return index + 1 }
            index += 1
        }
        return nil
    }
    private static func nameByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 58 || byte == 95
    }
    private static func whitespace(_ byte: UInt8) -> Bool { [9,10,12,13,32].contains(byte) }
    private static func asciiLower(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self) }
    private static func starts(_ bytes: [UInt8], at index: Int, literal: String, end: Int, caseInsensitive: Bool = false) -> Bool {
        let expected = Array(literal.utf8)
        guard index >= 0, expected.count <= end - index else { return false }
        for offset in expected.indices {
            let actual = bytes[index + offset]
            if (caseInsensitive && (65...90).contains(actual) ? actual + 32 : actual) != expected[offset] { return false }
        }
        return true
    }
    private static func find(_ bytes: [UInt8], literal: String, from start: Int, end: Int) -> Int? {
        var index = start
        while index < end { if starts(bytes, at: index, literal: literal, end: end) { return index }; index += 1 }
        return nil
    }
}
