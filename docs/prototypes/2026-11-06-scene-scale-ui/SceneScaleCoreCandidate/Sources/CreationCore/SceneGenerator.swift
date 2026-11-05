import Foundation

/// Deterministic native parametric modeling. Geometry contains no runtime scripts or downloaded assets.
public enum SceneGenerator {
    public static let version="1.1.0"
    public static let maximumVertices=SceneLimits.maximumRenderedVertices
    public static let maximumIndices=SceneLimits.maximumRenderedIndices

    public static func generate(for input:SceneSpec)throws->[GeneratedMesh] {
        let spec=try SceneAttachmentResolver.resolve(input)
        try spec.validate()
        try Task.checkCancellation()
        var result:[GeneratedMesh]=[]
        var vertices=0,indices=0
        for node in spec.nodes {
            try Task.checkCancellation()
            let mesh=try mesh(for:node)
            vertices += mesh.positions.count/3
            indices += mesh.indices.count
            guard vertices<=maximumVertices,indices<=maximumIndices else {
                throw CreationError.budgetExceeded("造型超过手机几何预算，请减少部件数量。")
            }
            result.append(mesh)
        }
        return result
    }

    /// Actual rotated vertices determine attachment bounds, including asymmetric freeform shapes.
    /// This deliberately bypasses scene attachment resolution to avoid recursion in the solver.
    public static func bounds(for node:SceneNode)throws->GeometryBounds {
        try node.validate()
        let value=try mesh(for:node)
        var minimum=[Double.infinity,Double.infinity,Double.infinity]
        var maximum=[-Double.infinity,-Double.infinity,-Double.infinity]
        for (index,value) in value.positions.enumerated() {
            let axis=index%3
            minimum[axis]=min(minimum[axis],Double(value))
            maximum[axis]=max(maximum[axis],Double(value))
        }
        return .init(minimum:minimum,maximum:maximum)
    }

    private static func mesh(for node:SceneNode)throws->GeneratedMesh {
        let local:PrimitiveMesh
        switch node.primitive {
        case .box: local=PrimitiveMesh.box()
        case .sphere: local=PrimitiveMesh.sphere()
        case .cylinder: local=PrimitiveMesh.cylinder(cone:false)
        case .cone: local=PrimitiveMesh.cylinder(cone:true)
        case .torus: local=PrimitiveMesh.torus()
        case .mesh,.lathe,.extrusion: local=try FreeformGeometry.generate(node)
        }
        let transform=NodeTransform(node)
        let positions=local.positions.flatMap { p->[Float] in
            let v=transform.position(p)
            return [Float(v.x),Float(v.y),Float(v.z)]
        }
        let normals=local.normals.flatMap { n->[Float] in
            let v=transform.normal(n)
            return [Float(v.x),Float(v.y),Float(v.z)]
        }
        try WorldMeshValidation.validate(positions:positions,normals:normals,indices:local.indices)
        return .init(name:node.id,positions:positions,normals:normals,indices:local.indices,
                     color:linearColor(node.color),metallic:node.metallic,roughness:node.roughness)
    }

    private static func linearColor(_ hex:String)->[Float] {
        let value=UInt32(hex.dropFirst(),radix:16)!
        return [16,8,0].map { shift in
            let component=Float((value >> shift)&255)/255
            return component<=0.04045 ? component/12.92 : pow((component+0.055)/1.055,2.4)
        }
    }
}

typealias Vector=SIMD3<Double>
private func vectorLengthSquared(_ v:Vector)->Double { v.x*v.x+v.y*v.y+v.z*v.z }
private func normalized(_ v:Vector)->Vector { v/sqrt(vectorLengthSquared(v)) }
private func cross(_ a:Vector,_ b:Vector)->Vector {
    .init(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
}
private func dot(_ a:Vector,_ b:Vector)->Double { a.x*b.x+a.y*b.y+a.z*b.z }

private struct NodeTransform {
    let scale:Vector
    let translation:Vector
    let angles:Vector
    init(_ node:SceneNode) {
        scale = .init(Double(node.size[0]),Double(node.size[1]),Double(node.size[2]))
        translation = .init(Double(node.position[0]),Double(node.position[1]),Double(node.position[2]))
        angles = .init(Double(node.rotation[0]),Double(node.rotation[1]),Double(node.rotation[2])) * (.pi/180)
    }
    func rotate(_ v:Vector)->Vector {
        let sx=sin(angles.x),cx=cos(angles.x),sy=sin(angles.y),cy=cos(angles.y),sz=sin(angles.z),cz=cos(angles.z)
        let xrot=Vector(v.x,v.y*cx-v.z*sx,v.y*sx+v.z*cx)
        let yrot=Vector(xrot.x*cy+xrot.z*sy,xrot.y,-xrot.x*sy+xrot.z*cy)
        return .init(yrot.x*cz-yrot.y*sz,yrot.x*sz+yrot.y*cz,yrot.z)
    }
    func position(_ v:Vector)->Vector { rotate(v*scale)+translation }
    // inverse-transpose of R*S is R*inverse(S); normalizing handles nonuniform positive scale.
    func normal(_ n:Vector)->Vector { normalized(rotate(n/scale)) }
}

struct PrimitiveMesh {
    var positions:[Vector]=[]
    var normals:[Vector]=[]
    var indices:[UInt32]=[]

    @discardableResult mutating func vertex(_ p:Vector,_ n:Vector)->UInt32 {
        let index=UInt32(positions.count)
        positions.append(p);normals.append(normalized(n))
        return index
    }
    mutating func triangle(_ a:UInt32,_ b:UInt32,_ c:UInt32) {
        let face=cross(positions[Int(b)]-positions[Int(a)],positions[Int(c)]-positions[Int(a)])
        precondition(vectorLengthSquared(face)>1e-24,"Primitive generation produced a degenerate triangle")
        let mean=normals[Int(a)]+normals[Int(b)]+normals[Int(c)]
        indices.append(contentsOf:dot(face,mean)<0 ? [a,c,b] : [a,b,c])
    }
    mutating func quad(_ a:Vector,_ b:Vector,_ c:Vector,_ d:Vector) {
        let normal=cross(b-a,c-a)
        let ids=[a,b,c,d].map { vertex($0,normal) }
        triangle(ids[0],ids[1],ids[2]);triangle(ids[0],ids[2],ids[3])
    }

    static func box()->Self {
        var mesh=Self()
        mesh.quad(.init(-0.5,-0.5,0.5),.init(0.5,-0.5,0.5),.init(0.5,0.5,0.5),.init(-0.5,0.5,0.5))
        mesh.quad(.init(0.5,-0.5,-0.5),.init(-0.5,-0.5,-0.5),.init(-0.5,0.5,-0.5),.init(0.5,0.5,-0.5))
        mesh.quad(.init(0.5,-0.5,0.5),.init(0.5,-0.5,-0.5),.init(0.5,0.5,-0.5),.init(0.5,0.5,0.5))
        mesh.quad(.init(-0.5,-0.5,-0.5),.init(-0.5,-0.5,0.5),.init(-0.5,0.5,0.5),.init(-0.5,0.5,-0.5))
        mesh.quad(.init(-0.5,0.5,0.5),.init(0.5,0.5,0.5),.init(0.5,0.5,-0.5),.init(-0.5,0.5,-0.5))
        mesh.quad(.init(-0.5,-0.5,-0.5),.init(0.5,-0.5,-0.5),.init(0.5,-0.5,0.5),.init(-0.5,-0.5,0.5))
        return mesh
    }

    static func sphere()->Self {
        let segments=24,latitudes=16
        var mesh=Self()
        let north=mesh.vertex(.init(0,0.5,0),.init(0,1,0))
        for latitude in 1..<latitudes {
            let phi=Double.pi*Double(latitude)/Double(latitudes)
            for longitude in 0..<segments {
                let theta=2*Double.pi*Double(longitude)/Double(segments)
                let p=Vector(sin(phi)*cos(theta),cos(phi),sin(phi)*sin(theta))
                mesh.vertex(p*0.5,p)
            }
        }
        let south=mesh.vertex(.init(0,-0.5,0),.init(0,-1,0))
        for longitude in 0..<segments {
            let next=(longitude+1)%segments
            mesh.triangle(north,UInt32(1+longitude),UInt32(1+next))
            mesh.triangle(south,UInt32(1+(latitudes-2)*segments+next),UInt32(1+(latitudes-2)*segments+longitude))
        }
        for latitude in 0..<(latitudes-2) {
            for longitude in 0..<segments {
                let next=(longitude+1)%segments
                let a=UInt32(1+latitude*segments+longitude),b=UInt32(1+latitude*segments+next)
                let c=UInt32(1+(latitude+1)*segments+next),d=UInt32(1+(latitude+1)*segments+longitude)
                mesh.triangle(a,b,c);mesh.triangle(a,c,d)
            }
        }
        return mesh
    }

    static func cylinder(cone:Bool)->Self {
        let segments=32
        var mesh=Self()
        for i in 0..<segments {
            let angle=Double(i)*2*Double.pi/Double(segments),x=cos(angle),z=sin(angle)
            let normal=Vector(x,cone ? 0.5 : 0,z)
            mesh.vertex(.init(x*0.5,-0.5,z*0.5),normal)
            if !cone { mesh.vertex(.init(x*0.5,0.5,z*0.5),normal) }
        }
        for i in 0..<segments {
            let next=(i+1)%segments
            if cone {
                let angle=(Double(i)+0.5)*2*Double.pi/Double(segments)
                let tip=mesh.vertex(.init(0,0.5,0),.init(cos(angle),0.5,sin(angle)))
                mesh.triangle(UInt32(i),UInt32(next),tip)
            } else {
                let a=UInt32(2*i),b=UInt32(2*next)
                mesh.triangle(a,b,b+1);mesh.triangle(a,b+1,a+1)
            }
        }
        for y in cone ? [-0.5] : [-0.5,0.5] {
            let normal=Vector(0,y<0 ? -1 : 1,0)
            let center=mesh.vertex(.init(0,y,0),normal)
            var ring:[UInt32]=[]
            for i in 0..<segments {
                let angle=Double(i)*2*Double.pi/Double(segments)
                ring.append(mesh.vertex(.init(cos(angle)*0.5,y,sin(angle)*0.5),normal))
            }
            for i in 0..<segments { mesh.triangle(center,ring[i],ring[(i+1)%segments]) }
        }
        return mesh
    }

    static func torus()->Self {
        let majorSegments=32,minorSegments=12,majorRadius=0.36,minorRadius=0.14
        var mesh=Self()
        for i in 0..<majorSegments {
            let theta=2*Double.pi*Double(i)/Double(majorSegments)
            for j in 0..<minorSegments {
                let phi=2*Double.pi*Double(j)/Double(minorSegments)
                let radius=majorRadius+minorRadius*cos(phi)
                let p=Vector(radius*cos(theta),0.5*sin(phi),radius*sin(theta))
                let normal=Vector(cos(theta)*cos(phi)/minorRadius,sin(phi)/0.5,sin(theta)*cos(phi)/minorRadius)
                mesh.vertex(p,normal)
            }
        }
        for i in 0..<majorSegments {
            for j in 0..<minorSegments {
                let nextI=(i+1)%majorSegments,nextJ=(j+1)%minorSegments
                let a=UInt32(i*minorSegments+j),b=UInt32(nextI*minorSegments+j)
                let c=UInt32(nextI*minorSegments+nextJ),d=UInt32(i*minorSegments+nextJ)
                mesh.triangle(a,b,c);mesh.triangle(a,c,d)
            }
        }
        return mesh
    }
}
