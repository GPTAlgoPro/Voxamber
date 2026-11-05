import Foundation

/// Data-only freeform geometry. Profiles and topology never contain executable code.
/// Custom triangle meshes are flat shaded so hard creases and opposing surfaces keep
/// correct face normals even when their source vertices are shared.
enum FreeformGeometry {
    private typealias V = SIMD3<Double>
    private typealias P = SIMD2<Double>
    private struct Surface { var points: [V]; var faces: [SIMD3<Int>] }
    private static let epsilon = 1e-12
    private static let latheSegments = 32

    static func validate(_ node: SceneNode) throws {
        guard node.path == nil else { throw invalid("当前形状不接受路径字段。") }
        switch node.primitive {
        case .mesh:
            guard node.profile == nil else { throw invalid("自由网格不接受轮廓字段。") }
            let surface = try mesh(node)
            _ = try canonical(surface)
        case .lathe:
            guard node.vertices == nil, node.triangles == nil else { throw invalid("旋转体只接受轮廓控制点。") }
            _ = try latheProfile(node)
        case .extrusion:
            guard node.vertices == nil, node.triangles == nil else { throw invalid("挤出体只接受二维轮廓。") }
            _ = try polygon(node)
        default:
            guard node.profile == nil, node.vertices == nil, node.triangles == nil else {
                throw invalid("基础形状不接受轮廓或自定义网格字段。")
            }
        }
    }

    static func generate(_ node: SceneNode) throws -> PrimitiveMesh {
        let source: Surface
        switch node.primitive {
        case .mesh: source = try mesh(node)
        case .lathe: source = try lathe(node)
        case .extrusion: source = try extrusion(node)
        default: throw invalid("该形状不是自由几何。")
        }
        let surface = try canonical(source)
        var output = PrimitiveMesh()
        for (index, face) in surface.faces.enumerated() {
            if index % 32 == 0 { try Task.checkCancellation() }
            let a = surface.points[face.x], b = surface.points[face.y], c = surface.points[face.z]
            let rawNormal = cross(b - a, c - a)
            let normal = rawNormal / sqrt(lengthSquared(rawNormal))
            let base = UInt32(output.positions.count)
            output.positions.append(contentsOf: [a, b, c])
            output.normals.append(contentsOf: [normal, normal, normal])
            output.indices.append(contentsOf: [base, base + 1, base + 2])
        }
        return output
    }

    static func validateRendered(positions: [Float], indices: [UInt32]) throws {
        for offset in stride(from: 0, to: indices.count, by: 3) {
            if offset % 96 == 0 { try Task.checkCancellation() }
            func point(_ index: UInt32) -> V {
                let i = Int(index) * 3
                return .init(Double(positions[i]), Double(positions[i + 1]), Double(positions[i + 2]))
            }
            let a = point(indices[offset]), b = point(indices[offset + 1]), c = point(indices[offset + 2])
            let area = lengthSquared(cross(b - a, c - a))
            guard area.isFinite, area > 0 else { throw invalid("变换后的网格面退化，请增大细节尺寸。") }
        }
    }

    private static func mesh(_ node: SceneNode) throws -> Surface {
        guard let vertices = node.vertices, let triangles = node.triangles,
              (3...1_024).contains(vertices.count), (1...2_048).contains(triangles.count),
              vertices.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              triangles.allSatisfy({ $0.count == 3 && $0.allSatisfy({ Int($0) < vertices.count }) }) else {
            throw invalid("自由网格须为 3–1024 个有限三维顶点和 1–2048 个有效索引三角面。")
        }
        return Surface(points: vertices.map { .init(Double($0[0]), Double($0[1]), Double($0[2])) },
                       faces: triangles.map { .init(Int($0[0]), Int($0[1]), Int($0[2])) })
    }

    /// Normalize the actual referenced geometry, not unused vertices, to a centered
    /// unit bounding box. Zero-thickness axes remain planar instead of becoming NaN.
    private static func canonical(_ source: Surface) throws -> Surface {
        try Task.checkCancellation()
        guard !source.faces.isEmpty else { throw invalid("没有可生成的曲面。") }
        let used = Set(source.faces.flatMap { [$0.x, $0.y, $0.z] })
        var minimum = V(repeating: .infinity), maximum = V(repeating: -.infinity)
        for index in used {
            let point = source.points[index]
            for axis in 0..<3 {
                minimum[axis] = min(minimum[axis], point[axis])
                maximum[axis] = max(maximum[axis], point[axis])
            }
        }
        let span = maximum - minimum
        guard span.x.isFinite, span.y.isFinite, span.z.isFinite,
              max(span.x, span.y, span.z) > 0 else { throw invalid("网格外包尺寸无效。") }
        let normalized = source.points.map { point -> V in
            var result = V.zero
            for axis in 0..<3 where span[axis] > 0 {
                result[axis] = (point[axis] - minimum[axis]) / span[axis] - 0.5
            }
            return result
        }
        for (index, face) in source.faces.enumerated() {
            if index % 32 == 0 { try Task.checkCancellation() }
            let a = normalized[face.x], b = normalized[face.y], c = normalized[face.z]
            let area = lengthSquared(cross(b - a, c - a))
            guard area.isFinite, area > 1e-24 else { throw invalid("自由网格含重复索引、共线顶点或退化三角面。") }
        }
        return Surface(points: normalized, faces: source.faces)
    }

    private static func latheProfile(_ node: SceneNode) throws -> (points: [P], closed: Bool) {
        guard let raw = node.profile, (2...64).contains(raw.count),
              raw.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) && $0[0] >= 0 }),
              raw.contains(where: { $0[0] > 0 }) else {
            throw invalid("旋转体需要 2–64 个 [半径,高度] 有限控制点，半径不能为负。")
        }
        var points = raw.map { P(Double($0[0]), Double($0[1])) }
        let closed = points.count > 2 && points.first == points.last
        if closed { points.removeLast() }
        guard points.count >= 2 else { throw invalid("旋转轮廓不能全部重合。") }
        for i in 1..<points.count where points[i] == points[i - 1] {
            throw invalid("相邻旋转轮廓点不能重合。")
        }
        var area: Double = 0
        if closed {
            area = signedArea(points)
            guard points.count >= 3, area.isFinite, area != 0 else {
                throw invalid("封闭旋转轮廓必须包含有面积的经线。")
            }
        } else {
            let withAxis = [P(0, points[0].y)] + points + [P(0, points[points.count - 1].y)]
            area = signedArea(withAxis)
        }
        if area < 0 { points.reverse() }
        return (points, closed)
    }

    private static func lathe(_ node: SceneNode) throws -> Surface {
        let profile = try latheProfile(node)
        var points: [V] = [], rings: [[Int]] = [], faces: [SIMD3<Int>] = []
        for control in profile.points {
            try Task.checkCancellation()
            if control.x == 0 {
                rings.append([points.count]); points.append(.init(0, control.y, 0))
            } else {
                var ring: [Int] = []
                for segment in 0..<latheSegments {
                    let angle = 2 * Double.pi * Double(segment) / Double(latheSegments)
                    ring.append(points.count)
                    points.append(.init(control.x * cos(angle), control.y, control.x * sin(angle)))
                }
                rings.append(ring)
            }
        }
        let links = profile.closed ? rings.count : rings.count - 1
        for i in 0..<links {
            try Task.checkCancellation()
            let a = rings[i], b = rings[(i + 1) % rings.count]
            if a.count == 1 && b.count == 1 { continue }
            for j in 0..<latheSegments {
                let next = (j + 1) % latheSegments
                if a.count == 1 {
                    faces.append(.init(a[0], b[j], b[next]))
                } else if b.count == 1 {
                    faces.append(.init(a[j], b[0], a[next]))
                } else {
                    faces.append(.init(a[j], b[j], b[next]))
                    faces.append(.init(a[j], b[next], a[next]))
                }
            }
        }
        return Surface(points: points, faces: faces)
    }

    private static func polygon(_ node: SceneNode) throws -> [P] {
        guard let raw = node.profile, (3...64).contains(raw.count),
              raw.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
            throw invalid("挤出体需要 3–64 个有限二维轮廓点。")
        }
        var points = raw.map { P(Double($0[0]), Double($0[1])) }
        if points.first == points.last { points.removeLast() }
        guard points.count >= 3 else { throw invalid("挤出轮廓至少需要三个不同点。") }
        let low = P(points.map(\.x).min()!, points.map(\.y).min()!)
        let high = P(points.map(\.x).max()!, points.map(\.y).max()!)
        let span = high - low
        guard span.x > 0, span.y > 0 else { throw invalid("挤出轮廓不能共线。") }
        points = points.map { ($0 - low) / span - P(repeating: 0.5) }
        for i in points.indices {
            guard squared(points[i] - points[(i + 1) % points.count]) > 1e-24 else {
                throw invalid("挤出轮廓的相邻点不能重合。")
            }
        }
        // Remove harmless points on a straight edge, preserving its exact outline.
        var changed = true
        while changed && points.count > 3 {
            changed = false
            for i in points.indices {
                let previous = points[(i + points.count - 1) % points.count]
                let next = points[(i + 1) % points.count]
                if abs(turn(previous, points[i], next)) <= epsilon {
                    let a = points[i] - previous, b = points[i] - next
                    guard a.x * b.x + a.y * b.y <= epsilon else {
                        throw invalid("挤出轮廓不能折返重叠。")
                    }
                    points.remove(at: i); changed = true; break
                }
            }
        }
        for i in points.indices {
            try Task.checkCancellation()
            for j in points.indices where j > i {
                if j == (i + 1) % points.count || i == (j + 1) % points.count { continue }
                if intersects(points[i], points[(i + 1) % points.count], points[j], points[(j + 1) % points.count]) {
                    throw invalid("挤出轮廓不能自交或自接触。")
                }
            }
        }
        let area = signedArea(points)
        guard abs(area) > epsilon else { throw invalid("挤出轮廓面积必须大于零。") }
        if area < 0 { points.reverse() }
        return points
    }

    private static func extrusion(_ node: SceneNode) throws -> Surface {
        let profile = try polygon(node)
        let cap = try triangulate(profile)
        let count = profile.count
        let points = profile.map { V($0.x, $0.y, -0.5) } + profile.map { V($0.x, $0.y, 0.5) }
        var faces: [SIMD3<Int>] = []
        for face in cap {
            faces.append(.init(face.x, face.z, face.y))
            faces.append(.init(face.x + count, face.y + count, face.z + count))
        }
        for i in profile.indices {
            let j = (i + 1) % count
            faces.append(.init(i, j, j + count))
            faces.append(.init(i, j + count, i + count))
        }
        return Surface(points: points, faces: faces)
    }

    private static func triangulate(_ points: [P]) throws -> [SIMD3<Int>] {
        var remaining = Array(points.indices), faces: [SIMD3<Int>] = []
        while remaining.count > 3 {
            try Task.checkCancellation()
            var clipped = false
            for i in remaining.indices {
                let a = remaining[(i + remaining.count - 1) % remaining.count]
                let b = remaining[i], c = remaining[(i + 1) % remaining.count]
                guard turn(points[a], points[b], points[c]) > epsilon else { continue }
                let occupied = remaining.contains { index in
                    guard index != a && index != b && index != c else { return false }
                    let p = points[index]
                    return turn(points[a], points[b], p) >= -epsilon &&
                        turn(points[b], points[c], p) >= -epsilon &&
                        turn(points[c], points[a], p) >= -epsilon
                }
                if !occupied {
                    faces.append(.init(a, b, c)); remaining.remove(at: i); clipped = true; break
                }
            }
            guard clipped else { throw invalid("挤出轮廓无法可靠三角剖分，请调整过近或共线的点。") }
        }
        guard turn(points[remaining[0]], points[remaining[1]], points[remaining[2]]) > epsilon else {
            throw invalid("挤出轮廓留下退化三角面。")
        }
        faces.append(.init(remaining[0], remaining[1], remaining[2]))
        return faces
    }

    private static func signedArea(_ points: [P]) -> Double {
        points.indices.reduce(0) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        } * 0.5
    }

    private static func turn(_ a: P, _ b: P, _ c: P) -> Double {
        let p = b - a, q = c - a
        return p.x * q.y - p.y * q.x
    }

    private static func intersects(_ a: P, _ b: P, _ c: P, _ d: P) -> Bool {
        let abC = turn(a, b, c), abD = turn(a, b, d), cdA = turn(c, d, a), cdB = turn(c, d, b)
        if ((abC > epsilon && abD < -epsilon) || (abC < -epsilon && abD > epsilon)) &&
            ((cdA > epsilon && cdB < -epsilon) || (cdA < -epsilon && cdB > epsilon)) { return true }
        func onSegment(_ p: P, _ q: P, _ v: P, _ area: Double) -> Bool {
            abs(area) <= epsilon && v.x >= min(p.x, q.x) - epsilon && v.x <= max(p.x, q.x) + epsilon &&
                v.y >= min(p.y, q.y) - epsilon && v.y <= max(p.y, q.y) + epsilon
        }
        return onSegment(a, b, c, abC) || onSegment(a, b, d, abD) || onSegment(c, d, a, cdA) || onSegment(c, d, b, cdB)
    }

    private static func squared(_ v: P) -> Double { v.x * v.x + v.y * v.y }
    private static func lengthSquared(_ v: V) -> Double { v.x * v.x + v.y * v.y + v.z * v.z }
    private static func cross(_ a: V, _ b: V) -> V {
        .init(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    private static func invalid(_ message: String) -> CreationError { .invalidParameter(message) }
}
