import Foundation
import Darwin
import SceneKit
import simd
import CoreGraphics

// Geometry-only subset derived from the pinned Snap3D native exporter.
// No Paint model, image texture stage, USDKit or private framework dependency.
enum ShapeAssetExporter {
    public static func writeGeometryUSDZ(
        vertices: [Float],
        faces: [UInt32],
        normals: [Float]? = nil,
        material: ShapeWholeMaterial? = nil,
        to url: URL,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) throws {
        try material?.validate()
        try writeCompliantGeometryUSDZ(
            vertices: vertices,
            faces: faces,
            normals: normals,
            material: material,
            to: url,
            isCancelled: isCancelled
        )
    }

    static func renameExclusive(_ source: URL, to destination: URL)
        throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw CocoaError(errno == EEXIST
                ? .fileWriteFileExists
                : .fileWriteUnknown)
        }
    }

    static func vertexNormals(
        vertices: [Float],
        faces: [UInt32],
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> [(Float, Float, Float)] {
        var values = [SIMD3<Float>](repeating: .zero, count: vertices.count / 3)
        func p(_ i: Int) -> SIMD3<Float> {
            SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
        }
        for i in stride(from: 0, to: faces.count, by: 3) {
            try checkCancellation(at: i, isCancelled: isCancelled)
            let a = Int(faces[i]), b = Int(faces[i+1]), c = Int(faces[i+2])
            guard a < values.count, b < values.count, c < values.count else { continue }
            let n = simd_cross(p(b) - p(a), p(c) - p(a))
            values[a] += n; values[b] += n; values[c] += n
        }
        return values.map {
            let length = simd_length($0)
            let n = length > 1e-8 ? $0 / length : SIMD3<Float>(0, 1, 0)
            return (n.x, n.y, n.z)
        }
    }

    static func checkCancellation(
        at index: Int = 0,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        if index.isMultiple(of: 4_096), isCancelled() {
            throw CancellationError()
        }
    }

    static func number(_ value: Float) -> String {
        // Locale-independent shortest round-trip text avoids per-coordinate
        // Foundation/ICU formatting and preserves every finite Float bit.
        // USD/OBJ accept decimal and scientific notation. Some values need
        // more digits than the previous seven-significant-digit formatting.
        value.isFinite ? String(value) : "0"
    }

    static func writeCompliantGeometryUSDZ(
        vertices: [Float],
        faces: [UInt32],
        normals: [Float]?,
        material: ShapeWholeMaterial?,
        to url: URL,
        isCancelled: @escaping () -> Bool
    ) throws {
        try validateGeometry(vertices: vertices, faces: faces)
        if let normals {
            guard normals.count == vertices.count, normals.allSatisfy(\.isFinite) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        guard url.isFileURL,
              url.pathExtension.lowercased() == "usdz" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let fileManager = FileManager.default
        let stagingRoot = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".worldcopy-compliant-geometry-usdz-"
                    + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let sourceURL = stagingRoot.appendingPathComponent("Model.usda")
        try writeGeometryUSDA(
            vertices: vertices,
            faces: faces,
            providedNormals: normals,
            material: material,
            to: sourceURL,
            isCancelled: isCancelled
        )
        let stagedURL = stagingRoot.appendingPathComponent("Model.usdz")
        try USDZArchiveWriter.write(
            entries: [USDZArchiveWriter.Entry(
                archivePath: "Model.usda",
                sourceURL: sourceURL
            )],
            to: stagedURL,
            isCancelled: isCancelled
        )
        try checkCancellation(isCancelled: isCancelled)
        try fileManager.removeItem(at: sourceURL)
        let reopened = try SCNScene(url: stagedURL, options: nil)
        var foundGeometry = false
        reopened.rootNode.enumerateHierarchy { node, stop in
            if node.geometry != nil {
                foundGeometry = true
                stop.pointee = true
            }
        }
        guard foundGeometry else { throw CocoaError(.fileReadCorruptFile) }
        try checkCancellation(isCancelled: isCancelled)
        try renameExclusive(stagedURL, to: url)
    }

    private static func validateGeometry(
        vertices: [Float],
        faces: [UInt32]
    ) throws {
        let vertexCount = vertices.count / 3
        guard vertices.count.isMultiple(of: 3),
              faces.count.isMultiple(of: 3),
              vertexCount >= 3,
              faces.count >= 3,
              vertices.allSatisfy(\.isFinite),
              faces.allSatisfy({ Int($0) < vertexCount }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private static func writeGeometryUSDA(
        vertices: [Float],
        faces: [UInt32],
        providedNormals: [Float]?,
        material: ShapeWholeMaterial?,
        to url: URL,
        isCancelled: @escaping () -> Bool
    ) throws {
        let computedNormals: [(Float, Float, Float)]? = providedNormals == nil
            ? try vertexNormals(vertices: vertices, faces: faces, isCancelled: isCancelled)
            : nil
        let sink = try USDATextSink(url: url)
        do {
            var header = """
                #usda 1.0
                (
                    defaultPrim = "Model"
                    metersPerUnit = 1
                    upAxis = "Y"
                )
                def Xform "Model"
                {
                    def Mesh "Geom"
                    {
                        uniform bool doubleSided = true
                        int[] faceVertexCounts = [
                """
            if material != nil {
                let old="    def Mesh \"Geom\"\n    {"
                guard let range=header.range(of:old) else {throw CocoaError(.fileWriteUnknown)}
                header.replaceSubrange(range,with:"    def Mesh \"Geom\" (\n        prepend apiSchemas = [\"MaterialBindingAPI\"]\n    )\n    {\n        rel material:binding = </Model/Looks/WholeMaterial>")
            }
            try sink.append(header)
            for index in 0 ..< faces.count / 3 {
                try checkCancellation(at: index, isCancelled: isCancelled)
                try sink.append(index == 0 ? "3" : ", 3")
            }
            try sink.append("]\n        int[] faceVertexIndices = [")
            for (index, value) in faces.enumerated() {
                try checkCancellation(at: index, isCancelled: isCancelled)
                try sink.append(index == 0 ? "\(value)" : ", \(value)")
            }
            try sink.append("]\n        normal3f[] normals = [")
            for index in 0..<(vertices.count / 3) {
                try checkCancellation(at: index, isCancelled: isCancelled)
                let value: (Float, Float, Float)
                if let providedNormals {
                    let base = index * 3
                    value = (providedNormals[base], providedNormals[base + 1], providedNormals[base + 2])
                } else {
                    value = computedNormals![index]
                }
                let item = "(\(number(value.0)), \(number(value.1)), "
                    + "\(number(value.2)))"
                try sink.append(index == 0 ? item : ", \(item)")
            }
            try sink.append(
                "] (\n            interpolation = \"vertex\"\n"
                    + "        )\n        point3f[] points = ["
            )
            for index in 0 ..< vertices.count / 3 {
                try checkCancellation(at: index, isCancelled: isCancelled)
                let base = index * 3
                let item = "(\(number(vertices[base])), "
                    + "\(number(vertices[base + 1])), "
                    + "\(number(vertices[base + 2])))"
                try sink.append(index == 0 ? item : ", \(item)")
            }
            try sink.append("]\n        uniform token subdivisionScheme = \"none\"\n    }\n")
            if let material {try sink.append(materialUSDA(material))}
            try sink.append("}\n")
            try sink.finish()
        } catch {
            sink.cancel()
            throw error
        }
    }

    private static func materialUSDA(_ material:ShapeWholeMaterial)throws->String {
        // Apple USD import exposes constant colors in linear Display P3. Encode
        // that declared standard space explicitly, converting from the API's
        // linear Rec.709 factors; this avoids relabeling Rec.709 numbers as P3.
        let components:[CGFloat]=[CGFloat(material.rgba[0]),CGFloat(material.rgba[1]),CGFloat(material.rgba[2]),1]
        guard let rec709=CGColorSpace(name:CGColorSpace.extendedLinearSRGB),
              let p3=CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3),
              let source=CGColor(colorSpace:rec709,components:components),
              let converted=source.converted(to:p3,intent:.relativeColorimetric,options:nil),
              let rgb=converted.components,rgb.count>=3 else {throw CocoaError(.fileWriteUnknown)}
        let c=[number(Float(rgb[0])),number(Float(rgb[1])),number(Float(rgb[2])),number(Float(material.rgba[3]))]
        let m=number(Float(material.metallic)),r=number(Float(material.roughness))
        return """
            def Scope "Looks"
            {
                def Material "WholeMaterial"
                {
                    token outputs:surface.connect = </Model/Looks/WholeMaterial/Surface.outputs:surface>
                    def Shader "Surface"
                    {
                        uniform token info:id = "UsdPreviewSurface"
                        color3f inputs:diffuseColor = (\(c[0]), \(c[1]), \(c[2])) (
                            colorSpace = "lin_p3d65_scene"
                        )
                        float inputs:opacity = \(c[3])
                        float inputs:metallic = \(m)
                        float inputs:roughness = \(r)
                        token outputs:surface
                    }
                }
            }

        """
    }


}

private final class USDATextSink {
    private let handle: FileHandle
    private var buffer = ""
    private var bufferedByteCount = 0
    private var isClosed = false
    private let flushThreshold = 256 * 1_024

    init(url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ text: String) throws {
        buffer.append(contentsOf: text)
        bufferedByteCount += text.utf8.count
        if bufferedByteCount >= flushThreshold { try flush() }
    }

    func finish() throws {
        try flush()
        try handle.close()
        isClosed = true
    }

    func cancel() {
        if !isClosed { try? handle.close() }
        isClosed = true
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
    }

    deinit {
        if !isClosed { try? handle.close() }
    }
}
