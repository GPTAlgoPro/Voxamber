import Foundation
import simd

enum ProjectionError: Error { case invalidGLB, invalidImage, invalidGeometry, nativeReadbackFailed, nativeReadbackDetails(String) }

struct GLBMesh {
    var document: [String: Any]
    var binary: Data
    let positions: [Float]
    let indices: [UInt32]
    let positionBytes: Data
    let indexBytes: Data
    var vertexCount: Int { positions.count / 3 }
    var triangleCount: Int { indices.count / 3 }

    init(data: Data) throws {
        guard data.count >= 28, data.u32(0) == 0x46546c67, data.u32(4) == 2,
              Int(data.u32(8)) == data.count, data.u32(16) == 0x4e4f534a else { throw ProjectionError.invalidGLB }
        let jsonLength = Int(data.u32(12)), binHeader = 20 + jsonLength
        guard jsonLength > 0, binHeader + 8 <= data.count,
              data.u32(binHeader + 4) == 0x004e4942,
              binHeader + 8 + Int(data.u32(binHeader)) == data.count,
              let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<binHeader)) as? [String: Any],
              let meshes = json["meshes"] as? [[String: Any]], meshes.count == 1,
              let primitives = meshes[0]["primitives"] as? [[String: Any]], primitives.count == 1,
              (primitives[0]["mode"] as? Int ?? 4) == 4,
              let attributes = primitives[0]["attributes"] as? [String: Int],
              let positionID = attributes["POSITION"], let indexID = primitives[0]["indices"] as? Int else {
            throw ProjectionError.invalidGLB
        }
        document = json; binary = data.subdata(in: (binHeader + 8)..<data.count)
        if let nodes = json["nodes"] as? [[String: Any]], nodes.contains(where: {
            $0["matrix"] != nil || $0["translation"] != nil || $0["rotation"] != nil || $0["scale"] != nil
        }) { throw ProjectionError.invalidGLB }
        let p = try Self.accessor(positionID, json: json, binary: binary, components: 3, componentType: 5126)
        let i = try Self.accessor(indexID, json: json, binary: binary, components: 1, componentType: 5125)
        guard p.count <= 2_000_000, i.count.isMultiple(of: 3), i.count <= 12_000_000 else { throw ProjectionError.invalidGeometry }
        positionBytes = p.bytes; indexBytes = i.bytes
        positions = stride(from: 0, to: p.bytes.count, by: 4).map { Float(bitPattern: p.bytes.u32($0)) }
        indices = stride(from: 0, to: i.bytes.count, by: 4).map { i.bytes.u32($0) }
        guard positions.count >= 9, positions.allSatisfy(\.isFinite),
              indices.count >= 3, indices.allSatisfy({ Int($0) < p.count }) else { throw ProjectionError.invalidGeometry }
    }

    func exporting(colors: [SIMD4<Float>]) throws -> Data {
        guard colors.count == vertexCount, colors.allSatisfy({ c in (0..<4).allSatisfy { c[$0].isFinite && (0...1).contains(c[$0]) } }) else { throw ProjectionError.invalidGeometry }
        var json = document, bytes = binary
        while !bytes.count.isMultiple(of: 4) { bytes.append(0) }
        let offset = bytes.count
        for color in colors { for axis in 0..<4 { bytes.appendLE(color[axis].bitPattern) } }
        var views = json["bufferViews"] as! [[String: Any]], accessors = json["accessors"] as! [[String: Any]]
        let viewID = views.count, colorID = accessors.count
        views.append(["buffer":0,"byteOffset":offset,"byteLength":colors.count * 16,"target":34962])
        accessors.append(["bufferView":viewID,"byteOffset":0,"componentType":5126,"count":vertexCount,"type":"VEC4"])
        var meshes = json["meshes"] as! [[String: Any]], primitives = meshes[0]["primitives"] as! [[String: Any]]
        var attributes = primitives[0]["attributes"] as! [String: Int]
        attributes["COLOR_0"] = colorID; primitives[0]["attributes"] = attributes
        var materials = json["materials"] as? [[String: Any]] ?? []
        primitives[0]["material"] = materials.count
        materials.append(["name":"SingleViewColorProjection","doubleSided":true,"alphaMode":"OPAQUE",
                          "pbrMetallicRoughness":["baseColorFactor":[1,1,1,1],"metallicFactor":0,"roughnessFactor":0.7]])
        meshes[0]["primitives"] = primitives; json["meshes"] = meshes
        json["materials"] = materials; json["accessors"] = accessors; json["bufferViews"] = views
        json["buffers"] = [["byteLength":bytes.count]]
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while !jsonData.count.isMultiple(of: 4) { jsonData.append(32) }
        var result = Data(); result.appendLE(UInt32(0x46546c67)); result.appendLE(UInt32(2))
        result.appendLE(UInt32(12 + 8 + jsonData.count + 8 + bytes.count))
        result.appendLE(UInt32(jsonData.count)); result.appendLE(UInt32(0x4e4f534a)); result.append(jsonData)
        result.appendLE(UInt32(bytes.count)); result.appendLE(UInt32(0x004e4942)); result.append(bytes)
        return result
    }

    func colors() throws -> [SIMD4<Float>] {
        guard let meshes = document["meshes"] as? [[String: Any]],
              let primitives = meshes[0]["primitives"] as? [[String: Any]],
              let attributes = primitives[0]["attributes"] as? [String: Int], let id = attributes["COLOR_0"] else { throw ProjectionError.invalidGLB }
        let color = try Self.accessor(id, json: document, binary: binary, components: 4, componentType: 5126)
        guard color.count == vertexCount else { throw ProjectionError.invalidGLB }
        return stride(from: 0, to: color.bytes.count, by: 16).map { offset in
            SIMD4((0..<4).map { Float(bitPattern: color.bytes.u32(offset + $0 * 4)) })
        }
    }

    private static func accessor(_ id: Int, json: [String: Any], binary: Data,
                                 components: Int, componentType: Int) throws -> (count: Int, bytes: Data) {
        guard let accessors = json["accessors"] as? [[String: Any]], accessors.indices.contains(id),
              let views = json["bufferViews"] as? [[String: Any]] else { throw ProjectionError.invalidGLB }
        let accessor = accessors[id]
        guard accessor["componentType"] as? Int == componentType, accessor["sparse"] == nil,
              accessor["type"] as? String == (components == 1 ? "SCALAR" : "VEC\(components)"),
              let count = accessor["count"] as? Int, count > 0,
              let viewID = accessor["bufferView"] as? Int, views.indices.contains(viewID) else { throw ProjectionError.invalidGLB }
        let view = views[viewID], length = components * 4
        guard view["buffer"] as? Int == 0, (view["byteStride"] as? Int ?? length) == length else { throw ProjectionError.invalidGLB }
        let offset = (view["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let size = count.multipliedReportingOverflow(by: length)
        guard !size.overflow, offset >= 0, offset <= binary.count, size.partialValue <= binary.count - offset else { throw ProjectionError.invalidGLB }
        return (count, binary.subdata(in: offset..<(offset + size.partialValue)))
    }
}

extension Data {
    func u32(_ offset: Int) -> UInt32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian } }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
