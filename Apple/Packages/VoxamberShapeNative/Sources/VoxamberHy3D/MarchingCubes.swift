import Foundation
import MLX
import simd

/// A triangle mesh in world space.
public struct Mesh {
    public var vertices: [SIMD3<Float>]
    public var faces: [(UInt32, UInt32, UInt32)]

    public init(
        vertices: [SIMD3<Float>],
        faces: [(UInt32, UInt32, UInt32)]
    ) {
        self.vertices = vertices
        self.faces = faces
    }

    /// Removes invalid, repeated-index, and numerically collapsed triangles
    /// before a generated surface crosses the GLB boundary. Sparse MoE can
    /// move an iso-surface exactly onto a grid corner; marching cubes may then
    /// emit two edge-degenerate faces even though the surrounding surface is
    /// healthy. Keeping those faces makes importers split a stray line
    /// primitive from the triangle mesh.
    func removingDegenerateFaces(
        squaredDoubleAreaEpsilon: Float = 1e-16
    ) -> Mesh {
        let validFaces = faces.filter { face in
            let a = Int(face.0)
            let b = Int(face.1)
            let c = Int(face.2)
            guard vertices.indices.contains(a),
                  vertices.indices.contains(b),
                  vertices.indices.contains(c),
                  a != b, b != c, a != c else { return false }
            let doubleArea = simd_cross(
                vertices[b] - vertices[a],
                vertices[c] - vertices[a]
            )
            return simd_length_squared(doubleArea)
                > squaredDoubleAreaEpsilon
        }
        guard !validFaces.isEmpty else {
            return Mesh(vertices: [], faces: [])
        }
        let used = Set(validFaces.flatMap { [$0.0, $0.1, $0.2] })
        var compactVertices = [SIMD3<Float>]()
        compactVertices.reserveCapacity(used.count)
        var remap = [UInt32: UInt32]()
        remap.reserveCapacity(used.count)
        for (index, vertex) in vertices.enumerated() {
            let oldIndex = UInt32(index)
            guard used.contains(oldIndex) else { continue }
            remap[oldIndex] = UInt32(compactVertices.count)
            compactVertices.append(vertex)
        }
        let compactFaces: [(UInt32, UInt32, UInt32)] = validFaces.compactMap {
            face -> (UInt32, UInt32, UInt32)? in
            guard let a = remap[face.0],
                  let b = remap[face.1],
                  let c = remap[face.2] else { return nil }
            return (a, b, c)
        }
        return Mesh(vertices: compactVertices, faces: compactFaces)
    }
}

/// Marching cubes over an (n,n,n) SDF grid using lewiner-derived tables (MCTables, generated from
/// skimage). Vertices interpolated at `level`, deduped by grid edge => watertight, smooth surface
/// matching the Python reference. Pure Swift (the table is a baked constant; no runtime Python).
public enum MarchingCubes {
    private static func corner(_ c: Int) -> (Int, Int, Int) { (c & 1, (c >> 1) & 1, (c >> 2) & 1) }

    public static func extract(grid: MLXArray, level: Float = 0.0,
                               bboxMin: Float = -1.01, bboxMax: Float = 1.01) -> Mesh {
        try! extract(
            grid: grid,
            level: level,
            bboxMin: bboxMin,
            bboxMax: bboxMax,
            isCancelled: { false }
        )
    }

    public static func extract(
        grid: MLXArray,
        level: Float = 0.0,
        bboxMin: Float = -1.01,
        bboxMax: Float = 1.01,
        isCancelled: () -> Bool
    ) throws -> Mesh {
        try checkCancellation(isCancelled)
        let n = grid.dim(0)
        let g = grid.asType(.float32).asArray(Float.self)
        try checkCancellation(isCancelled)
        return try extract(
            values: g,
            dimension: n,
            level: level,
            bboxMin: bboxMin,
            bboxMax: bboxMax,
            isCancelled: isCancelled
        )
    }

    static func extract(
        values g: [Float],
        dimension n: Int,
        level: Float = 0.0,
        bboxMin: Float = -1.01,
        bboxMax: Float = 1.01,
        isCancelled: () -> Bool
    ) throws -> Mesh {
        try checkCancellation(isCancelled)
        guard n >= 2, g.count == n * n * n else {
            return Mesh(vertices: [], faces: [])
        }
        @inline(__always) func idx(_ i: Int, _ j: Int, _ k: Int) -> Int { (i * n + j) * n + k }
        @inline(__always) func val(_ i: Int, _ j: Int, _ k: Int) -> Float { g[idx(i, j, k)] }
        let edgeCorners = MCTables.edgeCorners
        let triTable = MCTables.triTable

        var verts: [SIMD3<Float>] = []
        var faces: [(UInt32, UInt32, UInt32)] = []
        var edgeCache: [Int64: UInt32] = [:]
        let nnn = Int64(n * n * n)

        func edgeVertex(_ ai: (Int, Int, Int), _ bi: (Int, Int, Int), _ fa: Float, _ fb: Float) -> UInt32 {
            let ga = Int64(idx(ai.0, ai.1, ai.2)), gb = Int64(idx(bi.0, bi.1, bi.2))
            let key = ga < gb ? ga * nnn + gb : gb * nnn + ga
            if let v = edgeCache[key] { return v }
            let t = (level - fa) / (fb - fa)
            let p = SIMD3<Float>(Float(ai.0) + t * Float(bi.0 - ai.0),
                                 Float(ai.1) + t * Float(bi.1 - ai.1),
                                 Float(ai.2) + t * Float(bi.2 - ai.2))
            let v = UInt32(verts.count); verts.append(p); edgeCache[key] = v
            return v
        }

        var cc = [(Int, Int, Int)](repeating: (0, 0, 0), count: 8)
        var cv = [Float](repeating: 0, count: 8)
        for i in 0 ..< (n - 1) {
            try checkCancellation(isCancelled)
            for j in 0 ..< (n - 1) {
                for k in 0 ..< (n - 1) {
                    var config = 0
                    var hasNaN = false
                    for c in 0 ..< 8 {
                        let (dx, dy, dz) = corner(c)
                        cc[c] = (i + dx, j + dy, k + dz)
                        let v = val(i + dx, j + dy, k + dz); cv[c] = v
                        if v.isNaN { hasNaN = true }
                        if v < level { config |= 1 << c }
                    }
                    if hasNaN { continue }   // octree band edge: NaN edges don't cross the iso-level
                    let tris = triTable[config]
                    if tris.isEmpty { continue }
                    var m = 0
                    while m < tris.count {
                        var tri = [UInt32](repeating: 0, count: 3)
                        for t in 0 ..< 3 {
                            let (a, b) = edgeCorners[tris[m + t]]
                            tri[t] = edgeVertex(cc[a], cc[b], cv[a], cv[b])
                        }
                        faces.append((tri[0], tri[1], tri[2]))
                        m += 3
                    }
                }
            }
        }
        let s = (bboxMax - bboxMin) / Float(n - 1)
        var world = [SIMD3<Float>]()
        world.reserveCapacity(verts.count)
        for (index, vertex) in verts.enumerated() {
            if index.isMultiple(of: 4_096) {
                try checkCancellation(isCancelled)
            }
            world.append(SIMD3<Float>(
                vertex.x * s + bboxMin,
                vertex.y * s + bboxMin,
                vertex.z * s + bboxMin
            ))
        }
        return Mesh(vertices: world, faces: faces)
    }

    private static func checkCancellation(
        _ isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
    }
}
