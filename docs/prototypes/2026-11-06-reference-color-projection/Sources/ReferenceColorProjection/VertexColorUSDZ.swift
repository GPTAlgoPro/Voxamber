import Foundation
import CoreGraphics
import simd

struct LinearP3Converter {
    let columns: [SIMD3<Double>]
    init() throws {
        guard let source = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let target = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { throw ProjectionError.nativeReadbackFailed }
        columns = try (0..<3).map { axis in
            var value = [CGFloat](repeating: 0, count: 4); value[axis] = 1; value[3] = 1
            guard let color = CGColor(colorSpace: source, components: value),
                  let converted = color.converted(to: target, intent: .relativeColorimetric, options: nil),
                  let c = converted.components, c.count >= 3 else { throw ProjectionError.nativeReadbackFailed }
            return SIMD3(Double(c[0]),Double(c[1]),Double(c[2]))
        }
    }
    func convert(_ color: SIMD4<Float>) -> SIMD3<Float> {
        let value = columns[0]*Double(color.x)+columns[1]*Double(color.y)+columns[2]*Double(color.z)
        return SIMD3(Float(value.x),Float(value.y),Float(value.z))
    }
}

enum VertexColorUSDZ {
    static func normals(_ mesh: GLBMesh) -> [SIMD3<Float>] {
        var sums = [SIMD3<Double>](repeating: .zero, count: mesh.vertexCount)
        func p(_ index: Int) -> SIMD3<Double> {
            SIMD3(Double(mesh.positions[index*3]),Double(mesh.positions[index*3+1]),Double(mesh.positions[index*3+2]))
        }
        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a=Int(mesh.indices[offset]),b=Int(mesh.indices[offset+1]),c=Int(mesh.indices[offset+2])
            let n=simd_cross(p(b)-p(a),p(c)-p(a));sums[a]+=n;sums[b]+=n;sums[c]+=n
        }
        return sums.map { n in
            let length=simd_length(n)
            return length > 0 ? SIMD3(Float(n.x/length),Float(n.y/length),Float(n.z/length)) : SIMD3(0,1,0)
        }
    }

    static func export(mesh: GLBMesh, colors: [SIMD4<Float>], to url: URL) throws -> [SIMD3<Float>] {
        guard colors.count == mesh.vertexCount else { throw ProjectionError.invalidGeometry }
        let converter=try LinearP3Converter(),p3=colors.map(converter.convert)
        let stage=url.deletingLastPathComponent().appendingPathComponent("Model.usda")
        guard !FileManager.default.fileExists(atPath: stage.path), !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        let sink=try TextSink(stage)
        let normals=normals(mesh)
        try sink.append("""
        #usda 1.0
        (defaultPrim = "Model"
         metersPerUnit = 1
         upAxis = "Y")
        def Xform "Model" {
          def Mesh "Geom" (prepend apiSchemas = ["MaterialBindingAPI"]) {
            rel material:binding = </Model/Looks/Projected>
            uniform bool doubleSided = true
            uniform token subdivisionScheme = "none"
            int[] faceVertexCounts = [
        """)
        for f in 0..<mesh.triangleCount { try sink.append(f == 0 ? "3" : ",3") }
        try sink.append("]\nint[] faceVertexIndices = [")
        for (i,value) in mesh.indices.enumerated() { try sink.append(i == 0 ? String(value) : ",\(value)") }
        try sink.append("]\npoint3f[] points = [")
        for i in 0..<mesh.vertexCount {
            let value="(\(mesh.positions[i*3]),\(mesh.positions[i*3+1]),\(mesh.positions[i*3+2]))"
            try sink.append(i == 0 ? value : ","+value)
        }
        try sink.append("]\nnormal3f[] normals = [")
        for (i,n) in normals.enumerated() { let value="(\(n.x),\(n.y),\(n.z))";try sink.append(i == 0 ? value : ","+value) }
        try sink.append("] (interpolation = \"vertex\")\ncolor3f[] primvars:displayColor = [")
        for (i,c) in p3.enumerated() { let value="(\(c.x),\(c.y),\(c.z))";try sink.append(i == 0 ? value : ","+value) }
        try sink.append("""
        ] (interpolation = "vertex"
           colorSpace = "lin_p3d65_scene")
        float[] primvars:displayOpacity = [1] (interpolation = "constant")
          }
          def Scope "Looks" {
            def Material "Projected" {
              token outputs:surface.connect = </Model/Looks/Projected/Surface.outputs:surface>
              def Shader "Surface" {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (1,1,1) (colorSpace = "lin_p3d65_scene")
                float inputs:metallic = 0
                float inputs:roughness = 0.7
                token outputs:surface
              }
            }
          }
        }
        """)
        try sink.finish()
        try USDZArchiveWriter.write(entries: [.init(archivePath: "Model.usda", sourceURL: stage)], to: url)
        return p3
    }
}

private final class TextSink {
    let file: FileHandle
    var buffer=""
    init(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        file=try FileHandle(forWritingTo: url)
    }
    func append(_ text: String) throws {
        buffer+=text
        if buffer.utf8.count>=256*1024 { try flush() }
    }
    func flush() throws { if !buffer.isEmpty { try file.write(contentsOf: Data(buffer.utf8));buffer.removeAll(keepingCapacity:true) } }
    func finish() throws { try flush();try file.close() }
}
