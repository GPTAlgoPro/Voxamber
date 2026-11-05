import Foundation

/// Validate the actual Float DTO consumed by Metal/exporters, not only its
/// higher-precision local mesh or nonzero overall bounds. Never repair vertices.
enum WorldMeshValidation {
    static func validate(positions: [Float], normals: [Float], indices: [UInt32]) throws {
        guard !positions.isEmpty, positions.count % 3 == 0,
              normals.count == positions.count,
              !indices.isEmpty, indices.count % 3 == 0,
              positions.allSatisfy(\.isFinite), normals.allSatisfy(\.isFinite),
              indices.allSatisfy({ Int($0) < positions.count / 3 }) else {
            throw CreationError.invalidParameter("世界坐标网格含无效的顶点、法线或三角面索引。")
        }
        for start in stride(from: 0, to: normals.count, by: 3) {
            let x=Double(normals[start]), y=Double(normals[start+1]), z=Double(normals[start+2])
            let squared=x*x+y*y+z*z
            guard squared.isFinite, abs(squared-1) < 0.001 else {
                throw CreationError.invalidParameter("世界坐标网格法线无效。")
            }
        }
        func point(_ index: UInt32) -> SIMD3<Double> {
            let start=Int(index)*3
            return .init(Double(positions[start]),Double(positions[start+1]),Double(positions[start+2]))
        }
        for start in stride(from: 0, to: indices.count, by: 3) {
            if start % 96 == 0 { try Task.checkCancellation() }
            let a=point(indices[start]), b=point(indices[start+1]), c=point(indices[start+2])
            let u=b-a, v=c-a
            let cross=SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
            let areaSquared=cross.x*cross.x+cross.y*cross.y+cross.z*cross.z
            guard areaSquared.isFinite, areaSquared > 0 else {
                throw CreationError.invalidParameter("当前位置与尺寸超出 Float 世界坐标网格精度，三角面已塌缩。请增大细节尺寸或将物体移近原点。")
            }
        }
    }
}
