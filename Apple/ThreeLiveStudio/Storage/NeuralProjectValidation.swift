import Foundation
import CryptoKit
import CoreFoundation
import ImageIO
import Darwin
import zlib

enum ProjectFileIO {
    // Legacy pretty-printed free-geometry metadata can exceed 1 MiB.
    static let metadataLimit: Int64 = 16 * 1_048_576

    static func safePath(_ url: URL) throws {
        guard url.isFileURL else { throw ProjectStorageError.unsafePath }
        var item = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            item.append(path: component)
            let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                // Canonical OS aliases, unlike links under a project/operation.
                // Foundation deliberately normalizes these two back to /var
                // and /tmp even after resolvingSymlinksInPath(). Inspect the
                // real link target, rather than trusting that normalization.
                let aliases: [String: Set<String>] = ["/var": ["private/var", "/private/var"],
                    "/tmp": ["private/tmp", "/private/tmp"]]
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                guard aliases[item.path]?.contains(target) == true else {
                    throw ProjectStorageError.unsafePath
                }
            }
        }
    }

    static func openRead(_ url: URL, limit: Int64) throws -> (FileHandle, Int64) {
        try safePath(url)
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw ProjectStorageError.missingArtifact }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= limit else {
            Darwin.close(fd); throw ProjectStorageError.sizeLimit
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), info.st_size)
    }

    static func readSmall(_ url: URL, limit: Int64 = metadataLimit) throws -> Data {
        let (file, size) = try openRead(url, limit: limit); defer { try? file.close() }
        return try readExactly(file, count: Int(size))
    }

    static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
        guard count >= 0 else { throw ProjectStorageError.invalidArtifact }
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            try Task.checkCancellation()
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else {
                throw ProjectStorageError.invalidArtifact
            }
            data.append(part)
        }
        return data
    }

    /// Streams each file; a destination is exclusively created, never overwritten.
    static func fingerprint(_ source: URL, limit: Int64, copyingTo destination: URL? = nil,
                            permit: PublicationPermit? = nil) throws -> (bytes: Int64, sha256: String) {
        let (input, size) = try openRead(source, limit: limit); defer { try? input.close() }
        var output: FileHandle?
        if let destination {
            try safePath(destination)
            let fd = destination.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard fd >= 0 else { throw ProjectStorageError.unsafePath }
            output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var hasher = SHA256(), read: Int64 = 0
        while true {
            try Task.checkCancellation(); try permit?.check()
            let part = try autoreleasepool { try input.read(upToCount: 1_048_576) ?? Data() }
            if part.isEmpty { break }
            read += Int64(part.count)
            guard read <= size, read <= limit else { throw ProjectStorageError.invalidArtifact }
            hasher.update(data: part); try output?.write(contentsOf: part)
        }
        guard read == size else { throw ProjectStorageError.invalidArtifact }
        try permit?.check()
        return (read, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// File/geometry integrity, not proof of neural origin or visual quality. The
/// actual SDK receipt and model provenance are independently retained in V2.
enum NeuralProjectValidator {
    static func inspect(_ input: NeuralPublicationInput, permit: PublicationPermit? = nil) throws -> NeuralProjectDescriptor {
        try permit?.check()
        let sameBase = input.files.glb.standardizedFileURL == input.files.baseMesh.standardizedFileURL
        var mappings: [(NeuralArtifactRole, URL, String, String, Int, Int64)] = [
            (.glb, input.files.glb, "model.glb", "org.khronos.gltf.binary", 2, NeuralArtifactLimits.maximumGLBBytes),
            (.usdz, input.files.usdz, "model.usdz", "com.pixar.universal-scene-description-mobile", 1, NeuralArtifactLimits.maximumUSDZBytes),
            (.baseMesh, input.files.baseMesh, sameBase ? "model.glb" : "base.glb", "org.khronos.gltf.binary", 2, NeuralArtifactLimits.maximumGLBBytes),
            (.sourcePNG, input.files.sourcePNG, "source.png", "public.png", 1, NeuralArtifactLimits.maximumPNGBytes)
        ]
        if let reference = input.files.referencePNG {
            mappings.append((.referencePNG, reference, "reference.png", "public.png", 1, NeuralArtifactLimits.maximumPNGBytes))
        }
        var references: [ArtifactReference] = []
        for (role, source, path, format, version, limit) in mappings {
            let value = try ProjectFileIO.fingerprint(source, limit: limit, permit: permit)
            references.append(.init(role: role, relativePath: path, byteCount: value.bytes,
                sha256: value.sha256, formatID: format, formatVersion: version))
        }
        try input.editRecord?.validate(parentRevision: input.provenance.parentRevision)
        let descriptor = NeuralProjectDescriptor(geometryLayoutVersion: 1, artifacts: references,
            statistics: input.statistics, baseStatistics: input.baseStatistics, provenance: input.provenance,
            generationEvidence: input.generationEvidence, geometryContract: NeuralArtifactLimits.sourceContract,
            editRecipe: input.editRecord?.recipe, editEvidence: input.editRecord?.evidence)
        try descriptor.validate(requireEditRecord: true)
        try compare(try inspectGLB(input.files.glb), input.statistics)
        try compare(try inspectGLB(input.files.baseMesh, baseGeometry: true), input.baseStatistics)
        try validateUSDZ(input.files.usdz); try validatePNG(input.files.sourcePNG)
        if let reference = input.files.referencePNG { try validatePNG(reference, prepared: false) }
        return descriptor
    }

    static func validateFiles(in directory: URL, descriptor: NeuralProjectDescriptor,
                              permit: PublicationPermit? = nil) throws {
        try descriptor.validate()
        for item in descriptor.artifacts {
            try permit?.check()
            let value = try ProjectFileIO.fingerprint(directory.appending(path: item.relativePath),
                limit: limit(item.role), permit: permit)
            guard value.bytes == item.byteCount, value.sha256 == item.sha256 else { throw ProjectStorageError.invalidArtifact }
        }
        try compare(try inspectGLB(directory.appending(path: descriptor.artifact(.glb)!.relativePath)), descriptor.statistics)
        try compare(try inspectGLB(directory.appending(path: descriptor.artifact(.baseMesh)!.relativePath), baseGeometry: true), descriptor.baseStatistics)
        try validateUSDZ(directory.appending(path: descriptor.artifact(.usdz)!.relativePath))
        try validatePNG(directory.appending(path: descriptor.artifact(.sourcePNG)!.relativePath))
        if let reference = descriptor.artifact(.referencePNG) { try validatePNG(directory.appending(path: reference.relativePath), prepared: false) }
        try permit?.check()
    }

    static func limit(_ role: NeuralArtifactRole) -> Int64 {
        switch role {
        case .glb, .baseMesh: NeuralArtifactLimits.maximumGLBBytes
        case .usdz: NeuralArtifactLimits.maximumUSDZBytes
        case .sourcePNG, .referencePNG: NeuralArtifactLimits.maximumPNGBytes
        }
    }

    private static func compare(_ a: NeuralMeshStatistics, _ b: NeuralMeshStatistics) throws {
        try b.validate()
        guard a.vertexCount == b.vertexCount, a.triangleCount == b.triangleCount, a.meshCount == b.meshCount,
              zip(a.boundsMinimum, b.boundsMinimum).allSatisfy({ abs(Double($0) - Double($1)) <= 1e-6 * max(1, abs(Double($0))) }),
              zip(a.boundsMaximum, b.boundsMaximum).allSatisfy({ abs(Double($0) - Double($1)) <= 1e-6 * max(1, abs(Double($0))) }) else {
            throw ProjectStorageError.invalidArtifact
        }
    }

    private static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int(number.stringValue), result >= 0 else { throw ProjectStorageError.invalidArtifact }
        return result
    }

    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw ProjectStorageError.invalidArtifact }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else { throw ProjectStorageError.invalidArtifact }
        return data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    /// Base remains the restorable layout1 POSITION/UInt32-index archive.
    /// Render layout2 can add a real NORMAL accessor and uniform PBR material.
    /// Neither path trusts accessor counts without reading the actual buffers.
    static func inspectGLB(_ url: URL, baseGeometry: Bool = false) throws -> NeuralMeshStatistics {
        let (file, bytes) = try ProjectFileIO.openRead(url, limit: NeuralArtifactLimits.maximumGLBBytes)
        defer { try? file.close() }
        let header = try ProjectFileIO.readExactly(file, count: 20)
        guard try u32(header, 0) == 0x46546c67, try u32(header, 4) == 2,
              try Int64(u32(header, 8)) == bytes, try u32(header, 16) == 0x4e4f534a else { throw ProjectStorageError.invalidArtifact }
        let jsonBytes = Int(try u32(header, 12))
        guard jsonBytes > 0, jsonBytes <= 4_194_304, jsonBytes % 4 == 0,
              Int64(jsonBytes) + 28 < bytes,
              let object = try JSONSerialization.jsonObject(with: ProjectFileIO.readExactly(file, count: jsonBytes)) as? [String: Any],
              let asset = object["asset"] as? [String: Any], asset["version"] as? String == "2.0",
              let buffers = object["buffers"] as? [[String: Any]], buffers.count == 1, buffers[0]["uri"] == nil,
              let views = object["bufferViews"] as? [[String: Any]], (2...3).contains(views.count),
              let accessors = object["accessors"] as? [[String: Any]], accessors.count == views.count,
              let meshes = object["meshes"] as? [[String: Any]], meshes.count == 1,
              let primitives = meshes[0]["primitives"] as? [[String: Any]], primitives.count == 1,
              let attributes = primitives[0]["attributes"] as? [String: Any],
              let nodes = object["nodes"] as? [[String: Any]], nodes.count == 1,
              let scenes = object["scenes"] as? [[String: Any]], scenes.count == 1,
              let sceneNodes = scenes[0]["nodes"] as? [Any], sceneNodes.count == 1,
              nodes[0]["matrix"] == nil, nodes[0]["translation"] == nil, nodes[0]["rotation"] == nil, nodes[0]["scale"] == nil,
              nodes[0]["children"] == nil else { throw ProjectStorageError.invalidArtifact }
        let hasNormals = attributes["NORMAL"] != nil
        guard Set(attributes.keys) == (hasNormals ? ["POSITION", "NORMAL"] : ["POSITION"]),
              views.count == (hasNormals ? 3 : 2), !baseGeometry || !hasNormals else {
            throw ProjectStorageError.invalidArtifact
        }
        let indexAccessor = try integer(primitives[0]["indices"]), positionAccessor = try integer(attributes["POSITION"])
        let normalAccessor = try attributes["NORMAL"].map { try integer($0) }
        let usedAccessors = [indexAccessor, positionAccessor] + (normalAccessor.map { [$0] } ?? [])
        guard usedAccessors.allSatisfy({ $0 < accessors.count }), Set(usedAccessors).count == accessors.count,
              !baseGeometry || (indexAccessor == 0 && positionAccessor == 1) else { throw ProjectStorageError.invalidArtifact }
        try validateMaterials(object, primitive: primitives[0])
        guard try integer(object["scene"]) == 0, try integer(sceneNodes[0]) == 0,
              try integer(nodes[0]["mesh"]) == 0,
              try (primitives[0]["mode"] == nil || integer(primitives[0]["mode"]) == 4) else { throw ProjectStorageError.invalidArtifact }
        let binaryHeader = try ProjectFileIO.readExactly(file, count: 8)
        let binaryBytes = Int(try u32(binaryHeader, 0)), binaryStart = 28 + jsonBytes
        guard try u32(binaryHeader, 4) == 0x004e4942, Int64(binaryStart + binaryBytes) == bytes,
              try integer(buffers[0]["byteLength"]) == binaryBytes else { throw ProjectStorageError.invalidArtifact }
        func location(_ index: Int, component: Int, type: String, width: Int) throws -> (Int, Int) {
            let a = accessors[index], viewIndex = try integer(a["bufferView"])
            guard viewIndex < views.count, try integer(a["componentType"]) == component,
                  a["type"] as? String == type, a["sparse"] == nil else { throw ProjectStorageError.invalidArtifact }
            let v = views[viewIndex], count = try integer(a["count"])
            let offset = try integer(v["byteOffset"] ?? 0), local = try integer(a["byteOffset"] ?? 0)
            let length = try integer(v["byteLength"])
            guard try integer(v["buffer"]) == 0, v["byteStride"] == nil,
                  count <= NeuralArtifactLimits.maximumIndices, offset <= binaryBytes, local <= length,
                  offset % 4 == 0, local % 4 == 0,
                  length <= binaryBytes - offset, count <= (length - local) / width else { throw ProjectStorageError.invalidArtifact }
            return (binaryStart + offset + local, count)
        }
        let (indexOffset, count) = try location(indexAccessor, component: 5125, type: "SCALAR", width: 4)
        let (positionOffset, vertices) = try location(positionAccessor, component: 5126, type: "VEC3", width: 12)
        guard vertices >= 3, vertices <= NeuralArtifactLimits.maximumVertices,
              count >= 3, count % 3 == 0, count <= NeuralArtifactLimits.maximumIndices else { throw ProjectStorageError.sizeLimit }
        try file.seek(toOffset: UInt64(positionOffset))
        var positions: [SIMD3<Float>] = []; positions.reserveCapacity(vertices)
        var lower = [Float](repeating: .infinity, count: 3), upper = [Float](repeating: -.infinity, count: 3)
        while positions.count < vertices {
            try Task.checkCancellation()
            let amount = min(16_384, vertices - positions.count), data = try ProjectFileIO.readExactly(file, count: amount * 12)
            for i in 0..<amount {
                let values = try (0..<3).map { Float(bitPattern: try u32(data, i * 12 + $0 * 4)) }
                guard values.allSatisfy(\.isFinite) else { throw ProjectStorageError.invalidArtifact }
                for axis in 0..<3 { lower[axis] = min(lower[axis], values[axis]); upper[axis] = max(upper[axis], values[axis]) }
                positions.append(.init(values[0], values[1], values[2]))
            }
        }
        if let normalAccessor {
            let (normalOffset, normalCount) = try location(normalAccessor, component: 5126, type: "VEC3", width: 12)
            guard normalCount == vertices else { throw ProjectStorageError.invalidArtifact }
            try file.seek(toOffset: UInt64(normalOffset)); var remaining = normalCount * 3
            while remaining > 0 {
                try Task.checkCancellation()
                let amount = min(49_152, remaining), data = try ProjectFileIO.readExactly(file, count: amount * 4)
                for i in 0..<amount {
                    guard try Float(bitPattern: u32(data, i * 4)).isFinite else { throw ProjectStorageError.invalidArtifact }
                }
                remaining -= amount
            }
        }
        try file.seek(toOffset: UInt64(indexOffset)); var read = 0
        while read < count {
            try Task.checkCancellation()
            let amount = min(65_536 * 3, count - read), data = try ProjectFileIO.readExactly(file, count: amount * 4)
            for i in stride(from: 0, to: amount, by: 3) {
                let a = Int(try u32(data, i * 4)), b = Int(try u32(data, (i + 1) * 4)), c = Int(try u32(data, (i + 2) * 4))
                guard a < vertices, b < vertices, c < vertices else { throw ProjectStorageError.invalidArtifact }
                let p = positions[a], q = positions[b], r = positions[c]
                let x = SIMD3<Double>(Double(q.x) - Double(p.x), Double(q.y) - Double(p.y), Double(q.z) - Double(p.z))
                let y = SIMD3<Double>(Double(r.x) - Double(p.x), Double(r.y) - Double(p.y), Double(r.z) - Double(p.z))
                let cross = SIMD3<Double>(x.y * y.z - x.z * y.y, x.z * y.x - x.x * y.z, x.x * y.y - x.y * y.x)
                let area = cross.x * cross.x + cross.y * cross.y + cross.z * cross.z
                guard area.isFinite, area > 0 else { throw ProjectStorageError.invalidArtifact }
            }
            read += amount
        }
        let result = NeuralMeshStatistics(vertexCount: vertices, triangleCount: count / 3, meshCount: 1,
            boundsMinimum: lower, boundsMaximum: upper)
        try result.validate(); return result
    }

    private static func validateMaterials(_ object: [String: Any], primitive: [String: Any]) throws {
        // Layout2 exports uniform materials; it does not silently accept external
        // texture files/URLs or pretend that the shape model generated textures.
        for key in ["images", "textures"] {
            if let value = object[key] {
                guard let array = value as? [Any], array.isEmpty else { throw ProjectStorageError.invalidArtifact }
            }
        }
        var materials: [[String: Any]] = []
        if let value = object["materials"] {
            guard let array = value as? [[String: Any]] else { throw ProjectStorageError.invalidArtifact }
            materials = array
        }
        if let value = primitive["material"] {
            guard try integer(value) < materials.count else { throw ProjectStorageError.invalidArtifact }
        }
        func factor(_ value: Any) throws {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, (0...1).contains(n.doubleValue) else { throw ProjectStorageError.invalidArtifact }
        }
        func vector(_ value: Any, count: Int) throws {
            guard let values = value as? [Any], values.count == count else { throw ProjectStorageError.invalidArtifact }
            for value in values { try factor(value) }
        }
        for material in materials {
            if let value = material["pbrMetallicRoughness"] {
                guard let pbr = value as? [String: Any], pbr["baseColorTexture"] == nil,
                      pbr["metallicRoughnessTexture"] == nil else { throw ProjectStorageError.invalidArtifact }
                if let color = pbr["baseColorFactor"] { try vector(color, count: 4) }
                for key in ["metallicFactor", "roughnessFactor"] { if let value = pbr[key] { try factor(value) } }
            }
            guard material["normalTexture"] == nil, material["occlusionTexture"] == nil,
                  material["emissiveTexture"] == nil else { throw ProjectStorageError.invalidArtifact }
            if let emission = material["emissiveFactor"] { try vector(emission, count: 3) }
            if let alpha = material["alphaCutoff"] { try factor(alpha) }
            if let mode = material["alphaMode"] as? String {
                guard ["OPAQUE", "MASK", "BLEND"].contains(mode) else { throw ProjectStorageError.invalidArtifact }
            } else if material["alphaMode"] != nil { throw ProjectStorageError.invalidArtifact }
        }
    }

    private static func validatePNG(_ url: URL, prepared: Bool = true) throws {
        let data = try ProjectFileIO.readSmall(url, limit: NeuralArtifactLimits.maximumPNGBytes)
        guard data.starts(with: [137,80,78,71,13,10,26,10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4_096, height <= 4_096,
              (!prepared || (width == 512 && height == 512)),
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
            throw ProjectStorageError.invalidArtifact
        }
    }

    /// Full stored ZIP directory/CRC and aligned USDA payload validation. The
    /// SDK evidence separately records that Apple's USD importer opened it.
    private static func validateUSDZ(_ url: URL) throws {
        let (file, size) = try ProjectFileIO.openRead(url, limit: NeuralArtifactLimits.maximumUSDZBytes); defer { try? file.close() }
        guard size >= 22 else { throw ProjectStorageError.invalidArtifact }
        try file.seek(toOffset: UInt64(size - 22)); let end = try ProjectFileIO.readExactly(file, count: 22)
        guard try u32(end, 0) == 0x06054b50, try u16(end, 4) == 0, try u16(end, 6) == 0,
              try u16(end, 8) == 1, try u16(end, 10) == 1, try u16(end, 20) == 0 else { throw ProjectStorageError.invalidArtifact }
        let centralSize = Int(try u32(end, 12)), centralOffset = Int(try u32(end, 16))
        guard centralOffset > 0, centralSize >= 46, Int64(centralOffset + centralSize) == size - 22 else { throw ProjectStorageError.invalidArtifact }
        try file.seek(toOffset: UInt64(centralOffset)); let central = try ProjectFileIO.readExactly(file, count: centralSize)
        guard try u32(central, 0) == 0x02014b50, try u16(central, 8) == 0, try u16(central, 10) == 0,
              try u32(central, 20) == u32(central, 24), try u32(central, 42) == 0 else { throw ProjectStorageError.invalidArtifact }
        let nameLength = Int(try u16(central, 28)), extraLength = Int(try u16(central, 30)), commentLength = Int(try u16(central, 32))
        guard 46 + nameLength + extraLength + commentLength == central.count, nameLength > 0,
              let name = String(data: central.subdata(in: 46..<(46 + nameLength)), encoding: .utf8),
              !name.contains("/"), !name.contains("\\"), !name.contains(".."), name.hasSuffix(".usda") else { throw ProjectStorageError.unsafePath }
        try file.seek(toOffset: 0); let local = try ProjectFileIO.readExactly(file, count: 30)
        let localName = Int(try u16(local, 26)), localExtra = Int(try u16(local, 28)), payload = 30 + localName + localExtra
        let length = Int(try u32(local, 22)), crc = try u32(local, 14)
        guard try u32(local, 0) == 0x04034b50, try u16(local, 6) == 0, try u16(local, 8) == 0,
              try u32(local, 18) == u32(local, 22), try u32(local, 22) == u32(central, 24),
              try crc == u32(central, 16), localName == nameLength, payload % 64 == 0,
              payload + length == centralOffset else { throw ProjectStorageError.invalidArtifact }
        let localPath = try ProjectFileIO.readExactly(file, count: localName)
        guard localPath == Data(name.utf8) else { throw ProjectStorageError.invalidArtifact }
        try file.seek(toOffset: UInt64(payload)); var remaining = length, checksum: uLong = 0
        var first = true
        while remaining > 0 {
            let data = try ProjectFileIO.readExactly(file, count: min(1_048_576, remaining))
            if first { guard data.starts(with: Data("#usda 1.0".utf8)) else { throw ProjectStorageError.invalidArtifact }; first = false }
            checksum = data.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
            remaining -= data.count
        }
        guard !first, UInt32(checksum) == crc else { throw ProjectStorageError.invalidArtifact }
    }
}
