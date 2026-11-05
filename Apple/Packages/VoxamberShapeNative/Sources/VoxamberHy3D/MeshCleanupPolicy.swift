import Foundation
import simd

/// Explicit geometry postprocess identity, separate from model/YAML identity.
/// Existing low-level callers retain the legacy default.
public enum MeshCleanupPolicy: String, Codable, Sendable {
    case legacyThreshold = "legacy-eps1e-16-v1"
    case finitePositiveAreaFloat64 = "finite-positive-f64-v1"
}

extension Mesh {
    func removingDegenerateFaces(policy: MeshCleanupPolicy) -> Mesh {
        switch policy {
        case .legacyThreshold:
            return removingDegenerateFaces()
        case .finitePositiveAreaFloat64:
            break
        }
        let valid = faces.filter { face in
            let a = Int(face.0), b = Int(face.1), c = Int(face.2)
            guard vertices.indices.contains(a), vertices.indices.contains(b), vertices.indices.contains(c),
                  a != b, b != c, a != c else { return false }
            let p = vertices[a], q = vertices[b], r = vertices[c]
            guard [p,q,r].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return false }
            func double(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x),Double(v.y),Double(v.z)) }
            let area = simd_cross(double(q)-double(p), double(r)-double(p))
            // Avoid Float32 squared-area underflow and any arbitrary epsilon.
            // This is a Double numerical predicate, not an adaptive exact-real
            // predicate for arbitrary extreme coordinate dynamic ranges.
            return area.x.isFinite && area.y.isFinite && area.z.isFinite
                && (area.x != 0 || area.y != 0 || area.z != 0)
        }
        guard !valid.isEmpty else { return Mesh(vertices: [], faces: []) }
        let used = Set(valid.flatMap { [$0.0,$0.1,$0.2] })
        var compact = [SIMD3<Float>](), remap = [UInt32:UInt32]()
        compact.reserveCapacity(used.count); remap.reserveCapacity(used.count)
        for (index, vertex) in vertices.enumerated() where used.contains(UInt32(index)) {
            remap[UInt32(index)] = UInt32(compact.count); compact.append(vertex)
        }
        // Original order/winding and coordinates are preserved. No welding,
        // hole filling, smoothing, decimation or replacement geometry occurs.
        return Mesh(vertices: compact, faces: valid.map { (remap[$0.0]!,remap[$0.1]!,remap[$0.2]!) })
    }
}

/// Shared by both generateGLB paths. A nil sink performs no diagnostic I/O.
/// The snapshot is a value: mutations of a caller's copy cannot edit generated.
enum ShapeMeshFinalizer {
    static func cleaned(_ generated: Mesh, policy: MeshCleanupPolicy = .legacyThreshold,
                        onRawMesh: ((Mesh) throws -> Void)?) throws -> Mesh {
        try onRawMesh?(generated)
        return generated.removingDegenerateFaces(policy: policy)
    }
    static func legacyCleaned(_ generated: Mesh, onRawMesh: ((Mesh) throws -> Void)?) throws -> Mesh {
        try onRawMesh?(generated)
        return generated.removingDegenerateFaces()
    }
}
