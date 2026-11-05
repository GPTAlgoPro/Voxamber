import Foundation
import CreationCore

public enum NativeExportError: Error, LocalizedError, Equatable {
    case invalidMesh(String)
    case budgetExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidMesh(let detail): return "模型数据无效：\(detail)"
        case .budgetExceeded: return "模型超过本机导出的安全预算。"
        }
    }
}

/// Pure Swift serialization of already-generated geometry. No code interpreter is used.
public enum ThreeLiveNative {
    public static let version = "1.0.0"
    private static let maximumVertices = 100_000
    private static let maximumIndices = 300_000
    private static let maximumMeshes = 1_000

    public static func exportGLB(_ meshes: [GeneratedMesh]) throws -> Data {
        let bounds = try validate(meshes)
        var binary = Data()
        var views: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var objects: [[String: Any]] = []
        var materials: [[String: Any]] = []
        var nodes: [[String: Any]] = []

        func appendAccessor(_ bytes: Data, component: Int, count: Int, type: String,
                            target: Int, bounds: Bounds? = nil) -> Int {
            binary.pad(to: 4, byte: 0)
            let view = views.count
            views.append(["buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count, "target": target])
            binary.append(bytes)
            var accessor: [String: Any] = ["bufferView": view, "byteOffset": 0,
                                         "componentType": component, "count": count, "type": type]
            if let bounds {
                accessor["min"] = bounds.minimum
                accessor["max"] = bounds.maximum
            }
            accessors.append(accessor)
            return accessors.count - 1
        }

        for (index, mesh) in meshes.enumerated() {
            try Task.checkCancellation()
            let position = appendAccessor(floatBytes(mesh.positions), component: 5126,
                                          count: mesh.positions.count / 3, type: "VEC3", target: 34962,
                                          bounds: bounds[index])
            let normal = appendAccessor(floatBytes(mesh.normals), component: 5126,
                                        count: mesh.normals.count / 3, type: "VEC3", target: 34962)
            let indices = appendAccessor(indexBytes(mesh.indices), component: 5125,
                                         count: mesh.indices.count, type: "SCALAR", target: 34963)
            materials.append([
                "name": "Material_\(index)", "doubleSided": false,
                "pbrMetallicRoughness": ["baseColorFactor": Array(mesh.color.prefix(3)) + [Float(1)],
                                         "metallicFactor": mesh.metallic, "roughnessFactor": mesh.roughness]
            ])
            objects.append(["name": mesh.name,
                            "primitives": [["attributes": ["POSITION": position, "NORMAL": normal],
                                            "indices": indices, "material": index, "mode": 4]]])
            nodes.append(["name": mesh.name, "mesh": index])
        }
        let document: [String: Any] = [
            "asset": ["version": "2.0", "generator": "ThreeLiveStudio Native Swift \(version)"],
            "scene": 0, "scenes": [["nodes": Array(meshes.indices)]],
            "nodes": nodes, "meshes": objects, "materials": materials,
            "accessors": accessors, "bufferViews": views, "buffers": [["byteLength": binary.count]]
        ]
        var json = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        json.pad(to: 4, byte: 0x20)
        binary.pad(to: 4, byte: 0)
        var result = Data()
        result.appendLE(UInt32(0x46546c67))
        result.appendLE(UInt32(2))
        result.appendLE(UInt32(12 + 8 + json.count + 8 + binary.count))
        result.appendLE(UInt32(json.count))
        result.appendLE(UInt32(0x4e4f534a))
        result.append(json)
        result.appendLE(UInt32(binary.count))
        result.appendLE(UInt32(0x004e4942))
        result.append(binary)
        return result
    }

    public static func exportUSDZ(_ meshes: [GeneratedMesh]) throws -> Data {
        let bounds = try validate(meshes)
        var text = """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1.0
            upAxis = "Y"
        )
        def Xform "Root" (
            kind = "component"
        ) {
            def Scope "Materials" {

        """
        for (index, mesh) in meshes.enumerated() {
            text += """
                def Material "Mat\(index)" {
                    token outputs:surface.connect = </Root/Materials/Mat\(index)/PBR.outputs:surface>
                    def Shader "PBR" {
                        uniform token info:id = "UsdPreviewSurface"
                        color3f inputs:diffuseColor = \(triple(mesh.color, 0))
                        float inputs:metallic = \(number(mesh.metallic))
                        float inputs:roughness = \(number(mesh.roughness))
                        token outputs:surface
                    }
                }

            """
        }
        text += "    }\n"
        for (index, mesh) in meshes.enumerated() {
            try Task.checkCancellation()
            text += """
                def Mesh "Mesh\(index)" (
                    prepend apiSchemas = ["MaterialBindingAPI"]
                ) {
                    uniform token subdivisionScheme = "none"
                    uniform token orientation = "rightHanded"
                    float3[] extent = [\(triple(bounds[index].minimum, 0)), \(triple(bounds[index].maximum, 0))]
                    int[] faceVertexCounts = [
            """
            text += Array(repeating: "3", count: mesh.indices.count / 3).joined(separator: ",")
            text += "]\n        int[] faceVertexIndices = ["
            text += mesh.indices.map(String.init).joined(separator: ",")
            text += "]\n        point3f[] points = ["
            text += triplets(mesh.positions)
            text += "]\n        normal3f[] normals = ["
            text += triplets(mesh.normals)
            text += "] ( interpolation = \"vertex\" )\n"
            text += "        rel material:binding = </Root/Materials/Mat\(index)>\n    }\n"
        }
        text += "}\n"
        return storedUSDZ(name: "scene.usda", payload: Data(text.utf8))
    }

    private struct Bounds {
        var minimum: [Float]
        var maximum: [Float]
    }

    private static func validate(_ meshes: [GeneratedMesh]) throws -> [Bounds] {
        guard !meshes.isEmpty else { throw NativeExportError.invalidMesh("没有可导出的网格") }
        guard meshes.count <= maximumMeshes else { throw NativeExportError.budgetExceeded }
        var vertices = 0
        var indices = 0
        var results: [Bounds] = []
        for mesh in meshes {
            try Task.checkCancellation()
            let count = mesh.positions.count / 3
            vertices += count
            indices += mesh.indices.count
            guard vertices <= maximumVertices, indices <= maximumIndices else {
                throw NativeExportError.budgetExceeded
            }
            guard count > 0, mesh.positions.count % 3 == 0,
                  mesh.normals.count == mesh.positions.count,
                  !mesh.indices.isEmpty, mesh.indices.count % 3 == 0,
                  mesh.color.count == 3,
                  mesh.positions.allSatisfy(\.isFinite), mesh.normals.allSatisfy(\.isFinite),
                  mesh.indices.allSatisfy({ $0 < count }),
                  mesh.color.prefix(3).allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  mesh.metallic.isFinite, (0...1).contains(mesh.metallic),
                  mesh.roughness.isFinite, (0...1).contains(mesh.roughness) else {
                throw NativeExportError.invalidMesh(mesh.name)
            }
            for start in stride(from: 0, to: mesh.normals.count, by: 3) {
                let x = mesh.normals[start], y = mesh.normals[start + 1], z = mesh.normals[start + 2]
                let lengthSquared = x * x + y * y + z * z
                guard (0.998...1.002).contains(lengthSquared) else {
                    throw NativeExportError.invalidMesh(mesh.name + "：法线必须归一化")
                }
            }
            var minimum = Array(mesh.positions.prefix(3))
            var maximum = minimum
            for vertex in 0..<count {
                for axis in 0..<3 {
                    let value = mesh.positions[vertex * 3 + axis]
                    minimum[axis] = min(minimum[axis], value)
                    maximum[axis] = max(maximum[axis], value)
                }
            }
            results.append(Bounds(minimum: minimum, maximum: maximum))
        }
        return results
    }

    private static func floatBytes(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values { data.appendLE(value.bitPattern) }
        return data
    }

    private static func indexBytes(_ values: [UInt32]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values { data.appendLE(value) }
        return data
    }

    private static func number(_ value: Float) -> String {
        value == 0 ? "0" : String(value)
    }

    private static func triple(_ values: [Float], _ start: Int) -> String {
        "(\(number(values[start])),\(number(values[start + 1])),\(number(values[start + 2])))"
    }

    private static func triplets(_ values: [Float]) -> String {
        stride(from: 0, to: values.count, by: 3).map { triple(values, $0) }.joined(separator: ",")
    }

    /// USDZ is a stored ZIP whose file payloads begin at a multiple of 64 bytes.
    private static func storedUSDZ(name: String, payload: Data) -> Data {
        let filename = Data(name.utf8)
        var extraLength = (64 - ((30 + filename.count) % 64)) % 64
        if extraLength > 0 && extraLength < 4 { extraLength += 64 }
        var extra = Data()
        if extraLength > 0 {
            extra.appendLE(UInt16(0x1986))
            extra.appendLE(UInt16(extraLength - 4))
            extra.append(Data(repeating: 0, count: extraLength - 4))
        }
        let checksum = crc32(payload)
        let size = UInt32(payload.count)
        var archive = Data(capacity: payload.count + 256)
        archive.appendLE(UInt32(0x04034b50))
        archive.appendLE(UInt16(20))
        archive.appendLE(UInt16(0x0800))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(33))
        archive.appendLE(checksum)
        archive.appendLE(size)
        archive.appendLE(size)
        archive.appendLE(UInt16(filename.count))
        archive.appendLE(UInt16(extra.count))
        archive.append(filename)
        archive.append(extra)
        archive.append(payload)
        let directoryOffset = UInt32(archive.count)
        archive.appendLE(UInt32(0x02014b50))
        archive.appendLE(UInt16(20))
        archive.appendLE(UInt16(20))
        archive.appendLE(UInt16(0x0800))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(33))
        archive.appendLE(checksum)
        archive.appendLE(size)
        archive.appendLE(size)
        archive.appendLE(UInt16(filename.count))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt32(0))
        archive.appendLE(UInt32(0))
        archive.append(filename)
        let directorySize = UInt32(archive.count) - directoryOffset
        archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(1))
        archive.appendLE(UInt16(1))
        archive.appendLE(directorySize)
        archive.appendLE(directoryOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func pad(to alignment: Int, byte: UInt8) {
        let padding = (alignment - count % alignment) % alignment
        append(Data(repeating: byte, count: padding))
    }
}
