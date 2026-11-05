import Foundation
import simd

/// Minimal binary glTF (.glb) writer + reader: one mesh with POSITION + indices.
public enum GLB {
    public enum GLBError: Error { case malformed }

    /// Read back a `.glb` written by `write` (POSITION accessor 1, indices accessor 0).
    /// Throws `GLBError.malformed` rather than trapping on a truncated/unexpected file.
    public static func read(_ url: URL) throws -> Mesh {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    /// Voxamber adaptation: restore the same native geometry layout without
    /// materializing a second temporary file. No model or Metal work is needed.
    public static func read(data: Data) throws -> Mesh {
        guard data.count >= 12 else { throw GLBError.malformed }
        func u32(_ off: Int) throws -> UInt32 {
            guard off >= 0, off <= data.count - 4 else {
                throw GLBError.malformed
            }
            return data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(
                    fromByteOffset: off,
                    as: UInt32.self
                ))
            }
        }
        guard data.count <= Int(UInt32.max),
              try u32(0) == 0x4654_6C67,
              try u32(4) == 2,
              try u32(8) == UInt32(data.count) else {
            throw GLBError.malformed
        }
        var off = 12, jsonData = Data(), bin = Data()        // skip 12-byte header
        var sawJSON = false, sawBinary = false
        while off + 8 <= data.count {
            let len = Int(try u32(off)); let type = try u32(off + 4); off += 8
            let end = off.addingReportingOverflow(len)
            guard !end.overflow, end.partialValue <= data.count else {
                throw GLBError.malformed
            }
            let chunk = data.subdata(in: off ..< end.partialValue)
            off = end.partialValue
            if type == 0x4E4F_534A {                         // "JSON"
                guard !sawJSON, !sawBinary else { throw GLBError.malformed }
                sawJSON = true
                jsonData = chunk
            } else if type == 0x004E_4942 {                  // "BIN\0"
                guard sawJSON, !sawBinary else { throw GLBError.malformed }
                sawBinary = true
                bin = chunk
            } else {
                throw GLBError.malformed
            }
        }
        guard off == data.count, sawJSON, sawBinary,
              !jsonData.isEmpty, !bin.isEmpty,
              let json = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              let asset = json["asset"] as? [String: Any],
              asset["version"] as? String == "2.0",
              let buffers = json["buffers"] as? [[String: Any]],
              buffers.count == 1,
              buffers[0]["byteLength"] as? Int == bin.count,
              let accessors = json["accessors"] as? [[String: Any]],
              accessors.count == 2,
              let views = json["bufferViews"] as? [[String: Any]],
              views.count == 2,
              let meshes = json["meshes"] as? [[String: Any]],
              meshes.count == 1,
              let primitives = meshes[0]["primitives"] as? [[String: Any]],
              primitives.count == 1,
              primitives[0]["indices"] as? Int == 0,
              let attributes = primitives[0]["attributes"] as? [String: Any],
              attributes["POSITION"] as? Int == 1
        else { throw GLBError.malformed }
        func loc(
            _ a: [String: Any],
            componentType: Int,
            type: String,
            elementBytes: Int
        ) -> (off: Int, count: Int)? {
            guard let bv = a["bufferView"] as? Int,
                  bv >= 0, bv < views.count,
                  (views[bv]["buffer"] as? Int) == 0,
                  views[bv]["byteStride"] == nil,
                  a["componentType"] as? Int == componentType,
                  a["type"] as? String == type,
                  a["sparse"] == nil,
                  let count = a["count"] as? Int, count >= 0,
                  let viewLength = views[bv]["byteLength"] as? Int,
                  viewLength >= 0 else { return nil }
            let viewOffset = (views[bv]["byteOffset"] as? Int) ?? 0
            let accessorOffset = (a["byteOffset"] as? Int) ?? 0
            guard viewOffset >= 0, accessorOffset >= 0 else { return nil }
            let start = viewOffset.addingReportingOverflow(accessorOffset)
            let byteCount = count.multipliedReportingOverflow(by: elementBytes)
            let end = start.partialValue.addingReportingOverflow(
                byteCount.partialValue
            )
            guard !start.overflow, !byteCount.overflow, !end.overflow,
                  accessorOffset <= viewLength,
                  byteCount.partialValue <= viewLength - accessorOffset,
                  end.partialValue <= bin.count else { return nil }
            return (start.partialValue, count)
        }
        guard let (iOff, iCount) = loc(
            accessors[0],
            componentType: 5125,
            type: "SCALAR",
            elementBytes: 4
        ), let (pOff, pCount) = loc(
            accessors[1],
            componentType: 5126,
            type: "VEC3",
            elementBytes: 12
        ), iCount >= 3, pCount >= 3,
           iCount.isMultiple(of: 3) else { throw GLBError.malformed }
        let idx: [UInt32] = bin.subdata(in: iOff ..< iOff + iCount * 4)
            .withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let pos: [Float] = bin.subdata(in: pOff ..< pOff + pCount * 12)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard idx.count == iCount, pos.count == pCount * 3,
              pos.allSatisfy(\.isFinite),
              idx.allSatisfy({ Int($0) < pCount }) else {
            throw GLBError.malformed
        }
        var verts = [SIMD3<Float>](); verts.reserveCapacity(pCount)
        for i in 0 ..< pCount { verts.append(SIMD3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])) }
        var faces = [(UInt32, UInt32, UInt32)](); faces.reserveCapacity(iCount / 3)
        for i in stride(from: 0, to: iCount, by: 3) { faces.append((idx[i], idx[i + 1], idx[i + 2])) }
        return Mesh(vertices: verts, faces: faces)
    }

    /// Optional render normals/material do not change the default source-geometry layout.
    public struct Material {
        public let rgba:[Float]
        public let metallic:Float
        public let roughness:Float
        public init(rgba:[Float],metallic:Float,roughness:Float){self.rgba=rgba;self.metallic=metallic;self.roughness=roughness}
    }
    public static func write(_ mesh:Mesh,to url:URL,normals:[Float]?=nil,material:Material?=nil,
                             isCancelled:()->Bool={false})throws {
        func check()throws{if isCancelled(){throw CancellationError()}}
        try check()
        guard !mesh.vertices.isEmpty,!mesh.faces.isEmpty,
              mesh.vertices.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),
              mesh.faces.allSatisfy({Int($0.0)<mesh.vertices.count && Int($0.1)<mesh.vertices.count && Int($0.2)<mesh.vertices.count}) else {throw GLBError.malformed}
        if let normals {guard normals.count==mesh.vertices.count*3,normals.allSatisfy(\.isFinite) else {throw GLBError.malformed}}
        if let material {guard material.rgba.count==4,material.rgba.allSatisfy({$0.isFinite && (0...1).contains($0)}),
            material.metallic.isFinite,(0...1).contains(material.metallic),material.roughness.isFinite,(0...1).contains(material.roughness) else {throw GLBError.malformed}}
        var indices=[UInt32]();indices.reserveCapacity(mesh.faces.count*3)
        for (i,f) in mesh.faces.enumerated(){if i.isMultiple(of:4096){try check()};indices += [f.0,f.1,f.2]}
        var positions=[Float]();positions.reserveCapacity(mesh.vertices.count*3)
        var mn=SIMD3<Float>(repeating:.greatestFiniteMagnitude),mx=SIMD3<Float>(repeating:-.greatestFiniteMagnitude)
        for (i,v) in mesh.vertices.enumerated(){if i.isMultiple(of:4096){try check()};positions += [v.x,v.y,v.z];mn=simd_min(mn,v);mx=simd_max(mx,v)}
        let idxData=indices.withUnsafeBytes{Data($0)},posData=positions.withUnsafeBytes{Data($0)}
        let normalData=normals.map{$0.withUnsafeBytes{Data($0)}}
        var bin=Data();bin.append(idxData);bin.append(posData);if let normalData{bin.append(normalData)}
        while bin.count%4 != 0 {bin.append(0)}
        let normalView=normalData.map{",{\"buffer\":0,\"byteOffset\":\(idxData.count+posData.count),\"byteLength\":\($0.count),\"target\":34962}"} ?? ""
        let normalAccessor=normalData == nil ? "" : ",{\"bufferView\":2,\"componentType\":5126,\"count\":\(mesh.vertices.count),\"type\":\"VEC3\"}"
        let normalAttribute=normalData == nil ? "" : ",\"NORMAL\":2"
        let materialAttribute=material == nil ? "" : ",\"material\":0"
        let materialRoot:String
        if let material {
            let value:[String:Any]=["pbrMetallicRoughness":["baseColorFactor":material.rgba,"metallicFactor":material.metallic,"roughnessFactor":material.roughness],
                "alphaMode":material.rgba[3]<1 ? "BLEND":"OPAQUE","doubleSided":true]
            materialRoot=",\"materials\":["+String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self)+"]"
        }else{materialRoot=""}
        let json="""
        {"asset":{"version":"2.0"},"buffers":[{"byteLength":\(bin.count)}],\
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":\(idxData.count),"target":34963},\
        {"buffer":0,"byteOffset":\(idxData.count),"byteLength":\(posData.count),"target":34962}\(normalView)],\
        "accessors":[{"bufferView":0,"componentType":5125,"count":\(indices.count),"type":"SCALAR"},\
        {"bufferView":1,"componentType":5126,"count":\(mesh.vertices.count),"type":"VEC3",\
        "min":[\(mn.x),\(mn.y),\(mn.z)],"max":[\(mx.x),\(mx.y),\(mx.z)]}\(normalAccessor)],\
        "meshes":[{"primitives":[{"attributes":{"POSITION":1\(normalAttribute)},"indices":0\(materialAttribute)}]}],\
        "nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}],"scene":0\(materialRoot)}
        """
        var jsonData=Data(json.utf8);while jsonData.count%4 != 0 {jsonData.append(0x20)}
        func u32(_ v:UInt32)->Data{var x=v.littleEndian;return Data(bytes:&x,count:4)}
        var glb=Data();glb.append(Data("glTF".utf8));glb.append(u32(2));glb.append(u32(UInt32(12+8+jsonData.count+8+bin.count)))
        glb.append(u32(UInt32(jsonData.count)));glb.append(Data("JSON".utf8));glb.append(jsonData)
        glb.append(u32(UInt32(bin.count)));glb.append(Data([0x42,0x49,0x4e,0]));glb.append(bin)
        try check();try glb.write(to:url)
    }
}
