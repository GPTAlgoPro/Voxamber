import Foundation

public struct GeometryBounds: Codable, Sendable, Equatable {
    public var minimum: [Double]
    public var maximum: [Double]
    public var width: Double { maximum[0] - minimum[0] }
    public var height: Double { maximum[1] - minimum[1] }
    public var depth: Double { maximum[2] - minimum[2] }
}

public struct GeometryStatistics: Codable, Sendable, Equatable {
    public let meshes: Int
    public let vertices: Int
    public let triangles: Int
    public let bufferBytes: Int
    public let columns: Int
    public let roofCount: Int
    public let tileRibs: Int
    public let bounds: GeometryBounds
}

public struct GeneratedBuilding: Sendable, Equatable {
    public let meshes: [GeneratedMesh]
    public let statistics: GeometryStatistics
}

public struct GeneratedMesh: Sendable, Equatable {
    public let name: String
    public let positions: [Float]
    public let normals: [Float]
    public let indices: [UInt32]
    /// Linear RGB components in the range 0...1.
    public let color: [Float]
    public let metallic: Float
    public let roughness: Float

    public init(name: String, positions: [Float], normals: [Float], indices: [UInt32],
                color: [Float], metallic: Float, roughness: Float) {
        self.name=name; self.positions=positions; self.normals=normals; self.indices=indices
        self.color=color; self.metallic=metallic; self.roughness=roughness
    }
}

public enum BuildingGenerator {
    public static let version = "1.0.0"
    public static let maximumBufferBytes = 4_194_304
    public static let maximumVertices = 90_000
    public static let maximumIndices = 270_000

    public static func generate(for spec: BuildingSpec) throws -> GeneratedBuilding {
        try spec.validate()
        try Task.checkCancellation()
        var builder = ArchitectureBuilder(spec: spec)
        try builder.build()
        return try builder.emit()
    }
}

private struct V3: Hashable {
    var x: Double; var y: Double; var z: Double
    static func +(a: Self, b: Self) -> Self { .init(x: a.x+b.x, y: a.y+b.y, z: a.z+b.z) }
    static func -(a: Self, b: Self) -> Self { .init(x: a.x-b.x, y: a.y-b.y, z: a.z-b.z) }
    static func *(a: Self, b: Double) -> Self { .init(x: a.x*b, y: a.y*b, z: a.z*b) }
    func dot(_ b: Self) -> Double { x*b.x + y*b.y + z*b.z }
    func cross(_ b: Self) -> Self { .init(x: y*b.z-z*b.y, y: z*b.x-x*b.z, z: x*b.y-y*b.x) }
    var lengthSquared: Double { dot(self) }
    var unit: Self { lengthSquared > 1e-24 ? self * (1 / sqrt(lengthSquared)) : .init(x: 0, y: 1, z: 0) }
    var values: [Double] { [x,y,z] }
    var quantized: Self { .init(x: (x*100_000).rounded()/100_000, y: (y*100_000).rounded()/100_000, z: (z*100_000).rounded()/100_000) }
}

private struct VertexKey: Hashable { let position: V3; let normal: V3 }
private struct TriangleKey: Hashable { let a: Int; let b: Int; let c: Int }
private struct MeshBucket {
    var positions: [V3] = []
    var normals: [V3] = []
    var indices: [Int] = []
    var lookup: [VertexKey: Int] = [:]
    var triangleLookup: Set<TriangleKey> = []

    mutating func vertex(_ position: V3, normal: V3) -> Int {
        let key = VertexKey(position: position.quantized, normal: normal.quantized)
        if let existing = lookup[key] { return existing }
        let result = positions.count
        lookup[key] = result; positions.append(key.position); normals.append(key.normal)
        return result
    }

    mutating func triangle(_ a: Int, _ b: Int, _ c: Int) {
        guard a != b, b != c, a != c else { return }
        let face = (positions[b]-positions[a]).cross(positions[c]-positions[a])
        guard face.lengthSquared > 1e-20 else { return }
        let sorted = [a,b,c].sorted()
        guard triangleLookup.insert(.init(a: sorted[0], b: sorted[1], c: sorted[2])).inserted else { return }
        if face.dot(normals[a]+normals[b]+normals[c]) < 0 { indices.append(contentsOf: [a,c,b]) }
        else { indices.append(contentsOf: [a,b,c]) }
    }

    mutating func quad(_ a: V3, _ b: V3, _ c: V3, _ d: V3, upward: Bool = false) {
        var normal = (b-a).cross(c-a)
        if normal.lengthSquared < 1e-20 { normal = (c-a).cross(d-a) }
        if upward && normal.y < 0 { normal = normal * -1 }
        normal = normal.unit
        let ids = [a,b,c,d].map { vertex($0, normal: normal) }
        triangle(ids[0],ids[1],ids[2]); triangle(ids[0],ids[2],ids[3])
    }

    mutating func box(center p: V3, width: Double, height: Double, depth: Double) {
        let x0=p.x-width/2, x1=p.x+width/2, y0=p.y-height/2, y1=p.y+height/2, z0=p.z-depth/2, z1=p.z+depth/2
        quad(.init(x:x0,y:y0,z:z1),.init(x:x1,y:y0,z:z1),.init(x:x1,y:y1,z:z1),.init(x:x0,y:y1,z:z1))
        quad(.init(x:x1,y:y0,z:z0),.init(x:x0,y:y0,z:z0),.init(x:x0,y:y1,z:z0),.init(x:x1,y:y1,z:z0))
        quad(.init(x:x1,y:y0,z:z1),.init(x:x1,y:y0,z:z0),.init(x:x1,y:y1,z:z0),.init(x:x1,y:y1,z:z1))
        quad(.init(x:x0,y:y0,z:z0),.init(x:x0,y:y0,z:z1),.init(x:x0,y:y1,z:z1),.init(x:x0,y:y1,z:z0))
        quad(.init(x:x0,y:y1,z:z1),.init(x:x1,y:y1,z:z1),.init(x:x1,y:y1,z:z0),.init(x:x0,y:y1,z:z0))
        quad(.init(x:x0,y:y0,z:z0),.init(x:x1,y:y0,z:z0),.init(x:x1,y:y0,z:z1),.init(x:x0,y:y0,z:z1))
    }

    mutating func tube(_ points: [V3], radius: Double, sides: Int = 5, caps: Bool = false) {
        guard points.count >= 2, radius > 0 else { return }
        var rings: [[Int]] = []
        for j in points.indices {
            let tangent = (points[min(j+1,points.count-1)]-points[max(0,j-1)]).unit
            let u = tangent.cross(abs(tangent.z)<0.85 ? .init(x:0,y:0,z:1) : .init(x:0,y:1,z:0)).unit
            let v = tangent.cross(u).unit
            var ring: [Int] = []
            for k in 0..<sides {
                let angle = 2 * Double.pi * Double(k) / Double(sides)
                let normal = u*cos(angle)+v*sin(angle)
                ring.append(vertex(points[j]+normal*radius,normal:normal))
            }
            rings.append(ring)
        }
        for j in 0..<(rings.count-1) {
            for k in 0..<sides {
                let next=(k+1)%sides, a=rings[j], b=rings[j+1]
                triangle(a[k],b[next],b[k]); triangle(a[k],a[next],b[next])
            }
        }
        if caps {
            for endpoint in [0,points.count-1] {
                let normal = (points.last!-points.first!).unit * (endpoint==0 ? -1 : 1)
                let center = vertex(points[endpoint],normal:normal)
                let ids = rings[endpoint].map { vertex(positions[$0],normal:normal) }
                for k in 0..<sides { triangle(center,ids[k],ids[(k+1)%sides]) }
            }
        }
    }

    mutating func cylinder(_ p: V3, radius: Double, height: Double, sides: Int = 8) {
        tube([p + .init(x:0,y:-height/2,z:0),p + .init(x:0,y:height/2,z:0)],radius:radius,sides:sides,caps:true)
    }
}

private enum Material: Int, CaseIterable {
    case stone, marble, wood, column, trim, jade, lapis, roof, tile, gold, lantern
    var name: String { ["stone","marble","wood","columns","joinery","brackets_jade","brackets_lapis","curved_roof","tile_ribs","ridge_gold","lanterns"][rawValue] }
    func color(_ spec: BuildingSpec) -> String {
        switch self {
        case .stone: "#8f928b"
        case .marble: "#e3d9bf"
        case .wood: "#39251e"
        case .column: spec.columnColor == .vermilion ? "#aa3526" : spec.columnColor == .walnut ? "#65412b" : "#e8ddc5"
        case .trim: "#bf6840"
        case .jade: "#238273"
        case .lapis: "#264d64"
        case .roof: spec.roofColor == .gold ? "#b67d24" : spec.roofColor == .jade ? "#2d8175" : "#52616a"
        case .tile: spec.roofColor == .gold ? "#dda945" : spec.roofColor == .jade ? "#5aa593" : "#81939a"
        case .gold: "#ddba68"
        case .lantern: "#d35b31"
        }
    }
}

private struct ArchitectureBuilder {
    let spec: BuildingSpec
    var buckets = Material.allCases.map { _ in MeshBucket() }
    var columnCount = 0
    var roofCount = 0
    var tileRibCount = 0

    mutating func box(_ mat: Material, _ x: Double, _ y: Double, _ z: Double, _ w: Double, _ h: Double, _ d: Double) {
        buckets[mat.rawValue].box(center:.init(x:x,y:y,z:z),width:w,height:h,depth:d)
    }
    mutating func cylinder(_ mat: Material, _ x: Double, _ y: Double, _ z: Double, _ r: Double, _ h: Double, sides: Int = 8) {
        buckets[mat.rawValue].cylinder(.init(x:x,y:y,z:z),radius:r,height:h,sides:sides)
    }
    mutating func tube(_ mat: Material, _ points: [V3], _ radius: Double, sides: Int = 5) {
        buckets[mat.rawValue].tube(points,radius:radius,sides:sides)
    }

    mutating func build() throws {
        let w=spec.width, d=spec.depth, h=spec.height
        let unit=min(w,d), base=h*0.1
        box(.stone,0,base*0.13,0,w,base*0.26,d)
        for step in 0..<3 {
            let t=Double(step)
            box(step == 0 ? .stone : .marble,0,base*(0.30+t*0.24),0,w*(0.94-t*0.04),base*0.24,d*(0.92-t*0.04))
        }
        for step in 0..<7 {
            let top=base*(1-Double(step)/8)
            box(.marble,0,top/2,d*(0.30+Double(step)*0.022),w*0.22,top,d*0.025)
        }
        let floorHeight=(h-base)/Double(spec.floors)
        for level in 0..<spec.floors {
            try Task.checkCancellation()
            let shrink=pow(spec.kind == .tower ? 0.82 : 0.94, Double(level))
            let hw=w*0.37*shrink, hd=d*0.32*shrink
            let bottom=base+Double(level)*floorHeight, body=floorHeight*0.49
            box(.wood,0,bottom+floorHeight*0.015,0,hw*2.08,floorHeight*0.03,hd*2.13)
            let count=spec.kind == .palace ? 7 : spec.kind == .tower ? 5 : 3
            var positions: [(Double,Double)] = []
            for z in [-hd,hd] {
                for i in 0..<count { positions.append((-hw+2*hw*Double(i)/Double(count-1),z)) }
            }
            for x in [-hw,hw] { positions.append((x,0)) }
            for (x,z) in positions {
                columnCount += 1
                cylinder(.stone,x,bottom+body*0.045,z,unit*0.012*shrink,body*0.09)
                cylinder(.column,x,bottom+body*0.52,z,unit*0.009*shrink,body*0.9,sides:spec.detail == .fine ? 10 : 8)
                cylinder(.gold,x,bottom+body*0.10,z,unit*0.0098*shrink,body*0.018)
                cylinder(.gold,x,bottom+body*0.94,z,unit*0.0098*shrink,body*0.022)
                for bracket in 0..<2 {
                    let y=bottom+body*(1.01+Double(bracket)*0.045), size=unit*shrink*(0.032+Double(bracket)*0.013)
                    box(.jade,x,y,z,size,body*0.035,unit*0.017*shrink)
                    box(.lapis,x,y+body*0.018,z,unit*0.017*shrink,body*0.03,size)
                }
            }
            for z in [-hd,hd] {
                box(.column,0,bottom+body*0.96,z,hw*2.04,body*0.055,unit*0.02*shrink)
                box(.jade,0,bottom+body*1.105,z,hw*2.13,body*0.045,unit*0.025*shrink)
                box(.gold,0,bottom+body*1.15,z,hw*2.15,body*0.018,unit*0.026*shrink)
            }
            for x in [-hw,hw] {
                box(.column,x,bottom+body*0.96,0,unit*0.02*shrink,body*0.055,hd*2.04)
                box(.jade,x,bottom+body*1.105,0,unit*0.025*shrink,body*0.045,hd*2.13)
            }
            if spec.kind != .pavilion { lattice(hw:hw*0.87,hd:hd*0.75,bottom:bottom,body:body,count:count) }
            if spec.kind == .pavilion || level > 0 { railing(hw:hw,hd:hd,bottom:bottom,body:body,unit:unit*shrink) }
            for i in 0..<spec.roofTiers {
                try Task.checkCancellation()
                let tier=Double(i), tiers=Double(spec.roofTiers), tierShrink=pow(0.83,tier)
                let roofSpan=floorHeight*0.39/tiers
                let top=bottom+floorHeight*0.60+roofSpan*(tier+0.72)
                let roofW=w*0.44*shrink*tierShrink, roofD=d*0.41*shrink*tierShrink
                roof(hw:roofW,hd:roofD,ridge:roofW*(spec.kind == .pavilion ? 0.05 : 0.38),
                     top:top,drop:roofSpan*0.66,lift:min(spec.eaveLift,roofSpan*0.28),unit:min(unit*shrink,roofSpan*4))
                if i > 0 {
                    box(.wood,0,top-roofSpan*0.75,0,roofW*1.33,roofSpan*0.75,roofD*1.1)
                    for x in [-roofW*0.50,0,roofW*0.50] {
                        box(.column,x,top-roofSpan*0.75,roofD*0.56,unit*0.011,roofSpan*0.76,unit*0.014)
                    }
                }
            }
            // Paired hanging lanterns retain an open front and distinguish the veranda.
            for x in [-hw*0.67,hw*0.67] {
                let y=bottom+body*0.76, z=hd*0.92, radius=unit*0.016*shrink
                tube(.wood,[.init(x:x,y:bottom+body*0.96,z:z),.init(x:x,y:y+radius*1.5,z:z)],unit*0.0015)
                cylinder(.lantern,x,y,z,radius,radius*2.1)
                cylinder(.gold,x,y+radius*1.1,z,radius*0.9,radius*0.15)
                cylinder(.gold,x,y-radius*1.1,z,radius*0.9,radius*0.15)
            }
        }
        // The central finial defines the requested total height exactly.
        let finialBottom=h-floorHeight*0.052
        cylinder(.gold,0,(h+finialBottom)/2,0,unit*0.009,h-finialBottom,sides:8)
    }

    mutating func lattice(hw: Double, hd: Double, bottom: Double, body: Double, count: Int) {
        for sign in [-1.0,1.0] {
            let z=sign*hd
            box(.wood,0,bottom+body*0.49,z,hw*2,body*0.94,hd*0.022)
            for panel in 0..<(count-1) {
                let span=2*hw/Double(count-1), x = -hw+span*(Double(panel)+0.5)
                box(.column,x,bottom+body*0.24,z+sign*hd*0.02,span*0.90,body*0.35,hd*0.024)
                let divisions=spec.detail == .fine ? 4 : 3
                for j in 0...divisions {
                    box(.gold,x+span*(-0.43+0.86*Double(j)/Double(divisions)),bottom+body*0.66,z+sign*hd*0.04,
                        span*0.014,body*0.48,hd*0.022)
                }
                for row in 0..<4 {
                    box(.gold,x,bottom+body*(0.43+Double(row)*0.16),z+sign*hd*0.04,span*0.89,body*0.014,hd*0.023)
                }
            }
        }
        for x in [-hw,hw] { box(.wood,x,bottom+body*0.49,0,hw*0.022,body*0.94,hd*2) }
    }

    mutating func railing(hw: Double, hd: Double, bottom: Double, body: Double, unit: Double) {
        let y=bottom+body*0.24
        for x in [-hw,hw] {
            tube(.marble,[.init(x:x,y:y,z:-hd),.init(x:x,y:y,z:hd)],unit*0.004,sides:4)
            for j in 0...4 { box(.marble,x,bottom+body*0.15,-hd+2*hd*Double(j)/4,unit*0.008,body*0.30,unit*0.008) }
        }
        tube(.marble,[.init(x:-hw,y:y,z:-hd),.init(x:hw,y:y,z:-hd)],unit*0.004,sides:4)
    }

    mutating func roof(hw: Double, hd: Double, ridge: Double, top: Double, drop: Double, lift: Double, unit: Double) {
        roofCount += 1
        func point(_ face: Int, _ u: Double, _ v: Double, _ extra: Double = 0) -> V3 {
            let y=top-drop*pow(v,0.72)+lift*pow(v,6)*(1+0.65*pow(abs(u),4))+extra
            if face<2 { return .init(x:u*(ridge+(hw-ridge)*v),y:y,z:(face==0 ? -1 : 1)*hd*v) }
            return .init(x:(face==2 ? -1 : 1)*(ridge+(hw-ridge)*v),y:y,z:u*hd*v)
        }
        for face in 0..<4 {
            let nu=face<2 ? 10 : 5, nv=5
            for j in 0..<nv {
                for i in 0..<nu {
                    let u0 = -1+2*Double(i)/Double(nu), u1 = -1+2*Double(i+1)/Double(nu)
                    let v0=Double(j)/Double(nv), v1=Double(j+1)/Double(nv)
                    buckets[Material.roof.rawValue].quad(point(face,u0,v0),point(face,u1,v0),point(face,u1,v1),point(face,u0,v1),upward:true)
                }
            }
            let ribs=face<2 ? (spec.detail == .fine ? 24 : 16) : (spec.detail == .fine ? 12 : 8)
            for i in 0...ribs {
                let u = -1+2*Double(i)/Double(ribs)
                tube(.tile,(0...5).map { point(face,u,0.018+0.982*Double($0)/5,unit*0.0015) },unit*0.0022,sides:3)
                tileRibCount += 1
            }
            for v in [0.3,0.53,0.74,0.91] {
                tube(.roof,(0...6).map { point(face,-1+Double($0)/3,v,unit*0.0008) },unit*0.001,sides:3)
            }
            tube(.gold,(0...10).map { point(face,-1+Double($0)/5,1,unit*0.0015) },unit*0.0045,sides:5)
            tube(.wood,(0...10).map { point(face,-1+Double($0)/5,1,-unit*0.005) },unit*0.004,sides:4)
            if face<2 {
                for u in [-1.0,1.0] {
                    tube(.gold,(0...6).map { point(face,u,Double($0)/6,unit*0.0035) },unit*0.005,sides:5)
                    for v in [0.77,0.94] {
                        let p=point(face,u,v,unit*0.007)
                        cylinder(.gold,p.x,p.y+unit*0.004,p.z,unit*0.005,unit*0.012,sides:6)
                        tube(.gold,[p+V3(x:0,y:unit*0.007,z:0),p+V3(x:-u*unit*0.004,y:unit*0.018,z:0)],unit*0.003,sides:4)
                    }
                }
            }
        }
        tube(.gold,[.init(x:-ridge-unit*0.004,y:top+unit*0.005,z:0),.init(x:0,y:top+unit*0.008,z:0),.init(x:ridge+unit*0.004,y:top+unit*0.005,z:0)],unit*0.006,sides:6)
    }

    func emit() throws -> GeneratedBuilding {
        let vertexCount=buckets.reduce(0) { $0+$1.positions.count }, indexCount=buckets.reduce(0) { $0+$1.indices.count }
        guard vertexCount <= BuildingGenerator.maximumVertices, indexCount <= BuildingGenerator.maximumIndices else {
            throw CreationError.budgetExceeded("建筑几何超出手机预算，请减少楼层或屋檐。")
        }
        var meshes: [GeneratedMesh] = []
        let bufferBytes = vertexCount*6*MemoryLayout<Float>.stride+indexCount*MemoryLayout<UInt32>.stride
        guard bufferBytes <= BuildingGenerator.maximumBufferBytes else {
            throw CreationError.budgetExceeded("建筑细节超出手机内存预算，请选择标准细节或减少楼层。")
        }
        var minimum=V3(x:.infinity,y:.infinity,z:.infinity), maximum=V3(x:-.infinity,y:-.infinity,z:-.infinity)
        for material in Material.allCases {
            try Task.checkCancellation()
            let b=buckets[material.rawValue]
            guard !b.positions.isEmpty else { continue }
            for p in b.positions {
                minimum = .init(x:min(minimum.x,p.x),y:min(minimum.y,p.y),z:min(minimum.z,p.z))
                maximum = .init(x:max(maximum.x,p.x),y:max(maximum.y,p.y),z:max(maximum.z,p.z))
            }
            let colorHex=material.color(spec).dropFirst()
            let colorValue=UInt32(colorHex,radix:16)!
            let color: [Float] = [16,8,0].map { shift in
                let srgb=Float((colorValue >> shift)&255)/255
                return srgb <= 0.04045 ? srgb/12.92 : pow((srgb+0.055)/1.055,2.4)
            }
            meshes.append(.init(name:material.name,
                positions:b.positions.flatMap(\.values).map(Float.init),
                normals:b.normals.flatMap(\.values).map(Float.init),
                indices:b.indices.map(UInt32.init),color:color,
                metallic:material == .gold ? 0.4 : 0.05,
                roughness:material == .gold || material == .roof || material == .tile ? 0.4 : 0.7))
        }
        let stats=GeometryStatistics(meshes:meshes.count,vertices:vertexCount,triangles:indexCount/3,bufferBytes:bufferBytes,
            columns:columnCount,roofCount:roofCount,tileRibs:tileRibCount,bounds:.init(minimum:minimum.values,maximum:maximum.values))
        return .init(meshes:meshes,statistics:stats)
    }
}
