import Foundation

public enum OfficialUSDZCompatibilityError: Error, Equatable, Sendable {
    case invalidArchive, unsupportedArchive, unsupportedUSDA, budgetExceeded
}

/// Metadata repair for the pinned Google Three-Live v1.2.3 single-model.usda
/// stored-ZIP emitter, not a compiler or a general USD parser/validator.
/// Existing geometry, shader values and material relationships are never edited.
public enum OfficialUSDZCompatibility {
    public static let maximumArchiveBytes = 64 * 1_024 * 1_024

    public static func repair(_ archive: Data) throws -> Data {
        try Task.checkCancellation()
        let payload = try readSingleUSDA(archive)
        let repaired = try repairEmitterText(payload)
        guard repaired != payload else { return archive }
        guard repaired.count <= maximumArchiveBytes - 256 else { throw OfficialUSDZCompatibilityError.budgetExceeded }
        let output = ThreeLiveNative.storedUSDZ(name: "model.usda", payload: repaired)
        try Task.checkCancellation()
        return output
    }

    private static func readSingleUSDA(_ data: Data) throws -> Data {
        guard data.count <= maximumArchiveBytes else { throw OfficialUSDZCompatibilityError.budgetExceeded }
        guard data.count >= 22 else { throw OfficialUSDZCompatibilityError.invalidArchive }
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= data.count - 2 else { throw OfficialUSDZCompatibilityError.invalidArchive }
            return data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw OfficialUSDZCompatibilityError.invalidArchive }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        func bytes(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
                throw OfficialUSDZCompatibilityError.invalidArchive
            }
            return data.withUnsafeBytes { Data($0[offset..<(offset + count)]) }
        }
        let footer = data.count - 22
        guard try u32(footer) == 0x06054b50, try u16(footer + 4) == 0, try u16(footer + 6) == 0,
              try u16(footer + 8) == 1, try u16(footer + 10) == 1, try u16(footer + 20) == 0 else {
            throw OfficialUSDZCompatibilityError.unsupportedArchive
        }
        let directorySize = Int(try u32(footer + 12)), directory = Int(try u32(footer + 16))
        guard directory >= 30, directory <= footer, directorySize >= 46, directorySize == footer - directory,
              try u32(directory) == 0x02014b50 else { throw OfficialUSDZCompatibilityError.invalidArchive }
        let flags = try u16(directory + 8), method = try u16(directory + 10)
        guard flags == 0 || flags == 0x0800, method == 0,
              try u16(directory + 6) <= 20, try u16(directory + 34) == 0, try u32(directory + 42) == 0 else {
            throw OfficialUSDZCompatibilityError.unsupportedArchive
        }
        let compressed = Int(try u32(directory + 20)), size = Int(try u32(directory + 24))
        let nameLength = Int(try u16(directory + 28)), extraLength = Int(try u16(directory + 30))
        let commentLength = Int(try u16(directory + 32))
        guard compressed == size, size > 0, nameLength == 10, commentLength == 0,
              46 + nameLength + extraLength + commentLength == directorySize,
              try bytes(directory + 46, nameLength) == Data("model.usda".utf8) else {
            throw OfficialUSDZCompatibilityError.unsupportedArchive
        }
        guard try u32(0) == 0x04034b50, try u16(4) == u16(directory + 6), try u16(6) == flags, try u16(8) == method,
              try u32(14) == u32(directory + 16), try u32(18) == UInt32(size), try u32(22) == UInt32(size),
              try u16(26) == UInt16(nameLength) else { throw OfficialUSDZCompatibilityError.invalidArchive }
        let payloadStart = 30 + nameLength + Int(try u16(28))
        guard payloadStart % 64 == 0, payloadStart <= directory, size == directory - payloadStart,
              try bytes(30, nameLength) == Data("model.usda".utf8) else { throw OfficialUSDZCompatibilityError.invalidArchive }
        let payload = try bytes(payloadStart, size)
        try Task.checkCancellation()
        guard ThreeLiveNative.crc32(payload) == (try u32(14)) else { throw OfficialUSDZCompatibilityError.invalidArchive }
        return payload
    }

    private static func repairEmitterText(_ payload: Data) throws -> Data {
        guard let text = String(data: payload, encoding: .utf8), text.hasPrefix("#usda 1.0\n"),
              !text.contains("\0"), !text.contains("\r"), !text.contains("\"\"\"") else {
            throw OfficialUSDZCompatibilityError.unsupportedUSDA
        }
        // This emitter puts each prim declaration, brace and property on its
        // own line. Keeping that narrow layout avoids guessing at arbitrary USD.
        var lines = text.components(separatedBy: "\n")
        let header = try NSRegularExpression(pattern: #"^([ \t]*)def Mesh "(?:[^"\\]|\\.)+"[ \t]*(\()?[ \t]*$"#)
        let binding = try NSRegularExpression(pattern: #"^rel material:binding\s*=\s*</[^<>\r\n]+>\s*$"#)
        let subdivision = try NSRegularExpression(pattern: #"^(?:uniform\s+)?token subdivisionScheme\s*=\s*"none"\s*$"#)
        func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
            pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        func trimmed(_ index: Int) -> String { lines[index].trimmingCharacters(in: .whitespaces) }
        func nextContent(after index: Int) throws -> Int {
            var next = index + 1
            while next < lines.count, trimmed(next).isEmpty || trimmed(next).hasPrefix("#") { next += 1 }
            guard next < lines.count else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
            return next
        }
        var depth = 0, meshes = 0, index = 0
        while index < lines.count {
            try Task.checkCancellation()
            let line = trimmed(index)
            guard line.hasPrefix("def Mesh") else {
                depth += try braceDelta(lines[index])
                guard depth >= 0, depth <= 64 else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
                index += 1; continue
            }
            let ns = NSRange(lines[index].startIndex..., in: lines[index])
            guard let match = header.firstMatch(in: lines[index], range: ns), depth > 0 else {
                throw OfficialUSDZCompatibilityError.unsupportedUSDA
            }
            meshes += 1
            guard meshes <= 1_000 else { throw OfficialUSDZCompatibilityError.budgetExceeded }
            let hasAPI = match.range(at: 2).location != NSNotFound
            var opening = try nextContent(after: index)
            if hasAPI {
                guard trimmed(opening) == #"prepend apiSchemas = ["MaterialBindingAPI"]"# else {
                    throw OfficialUSDZCompatibilityError.unsupportedUSDA
                }
                opening = try nextContent(after: opening)
                guard trimmed(opening) == ")" else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
                opening = try nextContent(after: opening)
            }
            guard trimmed(opening) == "{" else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
            var cursor = opening + 1, bodyDepth = depth + 1, bindingCount = 0, subdivisionCount = 0
            while cursor < lines.count, bodyDepth > depth {
                let bodyLine = trimmed(cursor)
                if bodyDepth == depth + 1 {
                    if bodyLine.hasPrefix("rel material:binding") {
                        guard matches(binding, bodyLine) else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
                        bindingCount += 1
                    }
                    if bodyLine.hasPrefix("uniform token subdivisionScheme") || bodyLine.hasPrefix("token subdivisionScheme") {
                        guard matches(subdivision, bodyLine) else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
                        subdivisionCount += 1
                    }
                    guard !bodyLine.hasPrefix("def ") else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
                }
                bodyDepth += try braceDelta(lines[cursor])
                guard bodyDepth >= depth, bodyDepth <= 64 else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
                cursor += 1
            }
            guard bodyDepth == depth, bindingCount == 1, subdivisionCount <= 1 else {
                throw OfficialUSDZCompatibilityError.unsupportedUSDA
            }
            // The inserted strings alone contain the new metadata. Every
            // original line, including all arrays and shader values, survives.
            if !hasAPI { lines[index] += " (\n    prepend apiSchemas = [\"MaterialBindingAPI\"]\n)" }
            if subdivisionCount == 0 { lines[opening] += "\n    uniform token subdivisionScheme = \"none\"" }
            index = cursor
        }
        guard depth == 0, meshes > 0 else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Braces inside a quoted string or line comment do not delimit a prim.
    /// Multiline/triple-quoted strings are outside the pinned emitter contract.
    private static func braceDelta(_ line: String) throws -> Int {
        var quoted = false, escaped = false, delta = 0
        for byte in line.utf8 {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                if byte == 35 { break }
                if byte == 34 { quoted = true }
                else if byte == 123 { delta += 1 }
                else if byte == 125 { delta -= 1 }
            }
        }
        guard !quoted else { throw OfficialUSDZCompatibilityError.unsupportedUSDA }
        return delta
    }
}
