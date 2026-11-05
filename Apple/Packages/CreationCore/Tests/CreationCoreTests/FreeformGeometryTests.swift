import Foundation
import Testing
@testable import CreationCore

private typealias FV = SIMD3<Double>
private func fp(_ data: [Float], _ index: UInt32) -> FV {
    let i=Int(index)*3
    return .init(Double(data[i]),Double(data[i+1]),Double(data[i+2]))
}
private func fcross(_ a: FV,_ b: FV)->FV { .init(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) }
private func fdot(_ a: FV,_ b: FV)->Double { a.x*b.x+a.y*b.y+a.z*b.z }
private func native(_ node: SceneNode)throws->GeneratedMesh {
    try #require(SceneGenerator.generate(for:.init(name:"任意题材自由造型",nodes:[node])).first)
}
private func signedVolume(_ mesh:GeneratedMesh)->Double {
    stride(from:0,to:mesh.indices.count,by:3).reduce(0){total,i in
        total+fdot(fp(mesh.positions,mesh.indices[i]),fcross(fp(mesh.positions,mesh.indices[i+1]),fp(mesh.positions,mesh.indices[i+2])))/6
    }
}
private func assertNormalsAndFaces(_ mesh:GeneratedMesh) {
    #expect(mesh.positions.allSatisfy{$0.isFinite})
    #expect(mesh.normals.allSatisfy{$0.isFinite})
    for i in stride(from:0,to:mesh.indices.count,by:3) {
        let a=mesh.indices[i],b=mesh.indices[i+1],c=mesh.indices[i+2]
        let face=fcross(fp(mesh.positions,b)-fp(mesh.positions,a),fp(mesh.positions,c)-fp(mesh.positions,a))
        #expect(fdot(face,face)>0)
        for vertex in [a,b,c] {
            let n=fp(mesh.normals,vertex)
            #expect(abs(fdot(n,n)-1)<1e-6)
            #expect(fdot(face,n)>0)
        }
    }
}
/// Weld coincident position triples before auditing closed-surface edge incidence.
private func assertClosed(_ mesh:GeneratedMesh) {
    var ids:[[Float]:Int]=[:], remap:[Int]=[]
    for i in stride(from:0,to:mesh.positions.count,by:3) {
        let p=Array(mesh.positions[i..<(i+3)])
        let id=ids[p] ?? ids.count
        ids[p]=id;remap.append(id)
    }
    var edges:[String:Int]=[:]
    for i in stride(from:0,to:mesh.indices.count,by:3) {
        let face=(0..<3).map{remap[Int(mesh.indices[i+$0])]}
        for j in 0..<3 {
            let a=face[j],b=face[(j+1)%3]
            let key="\(min(a,b))_\(max(a,b))"
            edges[key,default:0]+=1
        }
    }
    #expect(!edges.isEmpty)
    #expect(edges.values.allSatisfy{$0==2})
}

@Test func customMeshPreservesItsActualTopologyAndUsesRequestedTransform() throws {
    var node=SceneNode.defaultNode(primitive:.mesh,id:"free_tetra",position:[0.3,0.9,-0.1])
    node.size=[1.2,1.6,2]
    let mesh=try native(node)
    #expect(mesh.indices.count/3==4)
    let bounds=try SceneGenerator.bounds(for:node)
    #expect(abs(bounds.width-1.2)<1e-6)
    #expect(abs(bounds.height-1.6)<1e-6)
    #expect(abs(bounds.depth-2)<1e-6)
    #expect(abs(signedVolume(mesh)-(1.2*1.6*2/6))<1e-6)
    assertNormalsAndFaces(mesh)
    assertClosed(mesh)
    // A non-template planar wing is also legal; zero local thickness remains finite.
    let wing=SceneNode(id:"wing",primitive:.mesh,position:[0,0.7,0],size:[1,1,0.2],
        vertices:[[0,0,0],[1,0.2,0],[0.4,0.5,0],[1,0.8,0],[0,1,0]],triangles:[[0,1,2],[0,2,4],[2,3,4]])
    let surface=try native(wing)
    #expect(surface.indices.count==9)
    #expect(stride(from:2,to:surface.positions.count,by:3).allSatisfy{surface.positions[$0]==0})
    assertNormalsAndFaces(surface)
}

@Test func meshRejectsInvalidIndicesDegenerateFacesAndBudgets() throws {
    let good=SceneNode.defaultNode(primitive:.mesh,id:"mesh")
    var index=good;index.triangles=[[0,1,99]]
    #expect(throws:CreationError.self){try index.validate()}
    var duplicate=good;duplicate.triangles=[[0,0,1]]
    #expect(throws:CreationError.self){try duplicate.validate()}
    var collinear=good;collinear.vertices=[[0,0,0],[1,1,1],[2,2,2]];collinear.triangles=[[0,1,2]]
    #expect(throws:CreationError.self){try collinear.validate()}
    var nonfinite=good;nonfinite.vertices?[0][0] = .nan
    #expect(throws:CreationError.self){try nonfinite.validate()}
    var large=good;large.vertices=Array(repeating:[0,0,0],count:1_025)
    #expect(throws:CreationError.self){try large.validate()}
    var tooMany=good;tooMany.triangles=Array(repeating:[0,1,2],count:2_049)
    #expect(throws:CreationError.self){try tooMany.validate()}
    let dense=(0..<4).map { i->SceneNode in
        var value=good;value.id="dense_\(i)";value.triangles=Array(repeating:[0,1,2],count:2_048)
        return value
    }
    do { _=try SceneGenerator.generate(for:.init(name:"budget",nodes:dense));Issue.record("Global geometry budget was bypassed") }
    catch CreationError.budgetExceeded {}
}

@Test func latheCapsAndCylinderProfileHaveCorrectSizeVolumeAndOutwardNormals() throws {
    let node=SceneNode(id:"turned",primitive:.lathe,position:[0,0.7,0],size:[1,1.4,1],
        profile:[[0,-1],[0.5,-1],[0.5,1],[0,1]])
    let mesh=try native(node)
    let expected=32.0/2*0.25*sin(2*Double.pi/32)*1.4
    #expect(abs(signedVolume(mesh)-expected)<1e-6)
    #expect(mesh.indices.count/3==128)
    assertNormalsAndFaces(mesh)
    assertClosed(mesh)
    for i in stride(from:0,to:mesh.positions.count,by:3) {
        let p=fp(mesh.positions,UInt32(i/3)),n=fp(mesh.normals,UInt32(i/3))
        if abs(n.y)<0.5 { #expect(p.x*n.x+p.z*n.z>0) }
        if p.y<0.000001 && abs(n.y)>0.9 { #expect(n.y<0) }
        if p.y>1.399999 && abs(n.y)>0.9 { #expect(n.y>0) }
    }
}

@Test func latheCreatesGenuinelyHollowBowlInsteadOfClosingItsMouth() throws {
    let node=SceneNode(id:"hollow_bowl",primitive:.lathe,position:[0,0.5,0],size:[1,1,1],
        profile:[[0,-0.5],[0.5,-0.5],[0.5,0.5],[0.4,0.5],[0.4,-0.4],[0,-0.4]])
    let mesh=try native(node)
    let expected=32.0/2*sin(2*Double.pi/32)*(0.25-0.16*0.9)
    #expect(abs(signedVolume(mesh)-expected)<1e-6)
    assertNormalsAndFaces(mesh)
    assertClosed(mesh)
    var innerWall=false
    for i in stride(from:0,to:mesh.positions.count,by:3) {
        let p=fp(mesh.positions,UInt32(i/3)),n=fp(mesh.normals,UInt32(i/3))
        if abs(n.y)<0.1 && p.x*n.x+p.z*n.z < -0.3 { innerWall=true }
    }
    #expect(innerWall)
    for i in stride(from:0,to:mesh.indices.count,by:3) {
        let a=fp(mesh.positions,mesh.indices[i]),b=fp(mesh.positions,mesh.indices[i+1]),c=fp(mesh.positions,mesh.indices[i+2])
        if abs(a.y-1)<1e-6 && abs(b.y-1)<1e-6 && abs(c.y-1)<1e-6 {
            let center=(a+b+c)/3
            #expect(center.x*center.x+center.z*center.z>0.35*0.35)
        }
    }
}

@Test func closedLatheRequiresAnAreaAndProducesARealToroidalSurface() throws {
    let degenerate=SceneNode(id:"flat_loop",primitive:.lathe,position:[0,0,0],size:[1,1,1],
        profile:[[0.3,0],[0.5,0],[0.3,0]])
    #expect(throws:CreationError.self){try degenerate.validate()}
    let controls:[[Float]]=(0...16).map { i in
        let angle=2*Double.pi*Double(i)/16
        return [Float(0.35+0.15*cos(angle)),Float(0.15*sin(angle))]
    }
    var exactClosed=controls
    exactClosed[exactClosed.count-1]=exactClosed[0]
    let toroidal=SceneNode(id:"free_ring",primitive:.lathe,position:[0,0,0],size:[1,0.3,1],profile:exactClosed)
    let mesh=try native(toroidal)
    assertNormalsAndFaces(mesh)
    assertClosed(mesh)
    #expect(signedVolume(mesh)>0)
    for i in stride(from:0,to:mesh.positions.count,by:3) {
        let p=fp(mesh.positions,UInt32(i/3))
        #expect(p.x*p.x+p.z*p.z>0.19*0.19)
    }
}

@Test func concaveExtrusionIsClosedAndDoesNotFillTheConcaveCutout() throws {
    let profile:[[Float]]=[[0,0],[2,0],[2,1],[1,1],[1,2],[0,2]]
    for ordered in [profile,Array(profile.reversed())] {
        let node=SceneNode(id:"concave",primitive:.extrusion,position:[0,0,0],size:[2,2,0.4],profile:ordered)
        let mesh=try native(node)
        #expect(mesh.indices.count/3==20)
        #expect(abs(signedVolume(mesh)-1.2)<1e-6)
        assertNormalsAndFaces(mesh)
        assertClosed(mesh)
        for i in stride(from:0,to:mesh.indices.count,by:3) {
            let a=fp(mesh.positions,mesh.indices[i]),b=fp(mesh.positions,mesh.indices[i+1]),c=fp(mesh.positions,mesh.indices[i+2])
            if abs(a.z-b.z)<1e-6 && abs(a.z-c.z)<1e-6 {
                let center=(a+b+c)/3
                #expect(!(center.x>0.000001 && center.y>0.000001))
            }
        }
    }
}

@Test func extrusionRejectsSelfIntersectionsAndNonfiniteOrCollinearProfiles() {
    for profile:[[Float]] in [ [[0,0],[1,1],[0,1],[1,0]], [[0,0],[1,0],[2,0]], [[0,0],[1,0],[1,Float.infinity]], [[0,0],[1,0],[1,0],[0,1]] ] {
        let node=SceneNode(id:"bad",primitive:.extrusion,position:[0,0,0],size:[1,1,1],profile:profile)
        #expect(throws:CreationError.self){try node.validate()}
    }
}

@Test func freeformJSONAllowsOnlyTheFieldsAppropriateToItsPrimitive() throws {
    for primitive in [SceneNode.Primitive.mesh,.lathe,.extrusion] {
        let scene=SceneSpec(name:"自由数据",nodes:[.defaultNode(primitive:primitive,id:"part")])
        let encoded=try JSONEncoder().encode(scene)
        #expect(try SceneSpec.decodeModelResponse(String(decoding:encoded,as:UTF8.self))==scene)
    }
    var box=SceneNode.defaultNode(primitive:.box,id:"box");box.profile=[[0,0],[1,1]]
    #expect(throws:CreationError.self){try box.validate()}
    var mesh=SceneNode.defaultNode(primitive:.mesh,id:"mesh");mesh.profile=[[0,0],[1,1]]
    #expect(throws:CreationError.self){try mesh.validate()}
    var lathe=SceneNode.defaultNode(primitive:.lathe,id:"lathe");lathe.triangles=[[0,1,2]]
    #expect(throws:CreationError.self){try lathe.validate()}
    var object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(SceneSpec.chair)) as? [String:Any])
    var nodes=try #require(object["nodes"] as? [[String:Any]])
    nodes[0]["profile"]=NSNull();object["nodes"]=nodes
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(String(decoding:JSONSerialization.data(withJSONObject:object),as:UTF8.self))}
}

@Test func freeformGenerationHonorsCancellationBeforePublishingGeometry() async {
    let task=Task {
        withUnsafeCurrentTask{$0?.cancel()}
        return try SceneGenerator.generate(for:.init(name:"cancel",nodes:[.defaultNode(primitive:.lathe,id:"vase")]))
    }
    do { _=try await task.value;Issue.record("Cancelled freeform generation completed") }
    catch is CancellationError {}
    catch { Issue.record("Unexpected cancellation error: \(error)") }
}
