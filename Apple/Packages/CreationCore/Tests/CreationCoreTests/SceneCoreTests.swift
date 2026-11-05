import Foundation
import Testing
@testable import CreationCore

private func point(_ values:[Float],_ index:UInt32)->SIMD3<Double> {
    let i=Int(index)*3
    return .init(Double(values[i]),Double(values[i+1]),Double(values[i+2]))
}
private func sceneDot(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->Double { a.x*b.x+a.y*b.y+a.z*b.z }
private func sceneCross(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->SIMD3<Double> {
    .init(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
}

@Test func genericSceneParametersRejectInvalidOrExecutableFields() throws {
    let data=try JSONEncoder().encode(SceneSpec.chair)
    let text=String(decoding:data,as:UTF8.self)
    #expect(try SceneSpec.decodeModelResponse(text)==SceneSpec.chair)
    #expect(try SceneSpec.decodeModelResponse("```json\n"+text+"\n```")==SceneSpec.chair)
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(" "+String(repeating:" ",count:SceneSpec.maximumResponseBytes)+text)}
    var object=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
    object["script"]="print('no')"
    let extra=String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(extra)}
    object.removeValue(forKey:"script")
    var nodes=try #require(object["nodes"] as? [[String:Any]])
    nodes[0]["assetUrl"]="https://example.com/mesh.glb";object["nodes"]=nodes
    let extraNode=String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(extraNode)}
    var duplicate=SceneSpec.chair;duplicate.nodes[1].id=duplicate.nodes[0].id
    #expect(throws:CreationError.self){try duplicate.validate()}
    for bad in [Float.nan,Float.infinity,-Float.infinity,0,-1,2.51] {
        var spec=SceneSpec.chair;spec.nodes[0].size[0]=bad
        #expect(throws:CreationError.self){try spec.validate()}
    }
    var badColor=SceneSpec.chair;badColor.nodes[0].color="red"
    #expect(throws:CreationError.self){try badColor.validate()}
    var badRotation=SceneSpec.chair;badRotation.nodes[0].rotation=[0,0]
    #expect(throws:CreationError.self){try badRotation.validate()}
    var badMaterial=SceneSpec.chair;badMaterial.nodes[0].roughness=1.1
    #expect(throws:CreationError.self){try badMaterial.validate()}
    var badPosition=SceneSpec.chair;badPosition.nodes[0].position=[3.1,0,0]
    #expect(throws:CreationError.self){try badPosition.validate()}
    let excessive=(0...SceneSpec.maximumNodes).map { SceneNode(id:"part_\($0)",primitive:.box,position:[0,0,0],size:[1,1,1]) }
    #expect(throws:CreationError.self){try SceneSpec(name:"too many",nodes:excessive).validate()}
    #expect(throws:CreationError.self){try SceneSpec(name:"empty",nodes:[]).validate()}
    let duplicateKey="{\"name\":\"a\",\"name\":\"b\",\"nodes\":[]}"
    #expect(throws:CreationError.self){try SceneSpec.decodeModelResponse(duplicateKey)}
}

@Test func allNativePrimitivesHaveValidTopologyAndExactUnrotatedExtents() throws {
    for primitive in SceneNode.Primitive.allCases {
        var node=SceneNode.defaultNode(primitive:primitive,id:"part",position:[0.3,0.7,-0.2])
        node.size=[0.4,0.6,0.8]
        let mesh=try #require(SceneGenerator.generate(for:.init(name:"part",nodes:[node])).first)
        #expect(mesh.positions.count==mesh.normals.count)
        #expect(mesh.indices.count%3==0)
        #expect(mesh.positions.allSatisfy{$0.isFinite})
        #expect(mesh.normals.allSatisfy{$0.isFinite})
        #expect(mesh.indices.allSatisfy{Int($0)*3<mesh.positions.count})
        for axis in 0..<3 {
            let values=stride(from:axis,to:mesh.positions.count,by:3).map{mesh.positions[$0]}
            let low=try #require(values.min()),high=try #require(values.max())
            #expect(abs((high-low)-node.size[axis])<0.000001)
            #expect(abs((high+low)/2-node.position[axis])<0.000001)
        }
        for i in stride(from:0,to:mesh.normals.count,by:3) {
            let n=SIMD3<Double>(Double(mesh.normals[i]),Double(mesh.normals[i+1]),Double(mesh.normals[i+2]))
            #expect(abs(sceneDot(n,n)-1)<0.000001)
        }
        for i in stride(from:0,to:mesh.indices.count,by:3) {
            let a=mesh.indices[i],b=mesh.indices[i+1],c=mesh.indices[i+2]
            let face=sceneCross(point(mesh.positions,b)-point(mesh.positions,a),point(mesh.positions,c)-point(mesh.positions,a))
            #expect(sceneDot(face,face)>1e-16)
            let normal=point(mesh.normals,a)+point(mesh.normals,b)+point(mesh.normals,c)
            #expect(sceneDot(face,normal)>0)
        }
    }
}

@Test func spherePolesAreSingleVerticesAndTriangleFansAreNotDegenerate() throws {
    let node=SceneNode(id:"sphere",primitive:.sphere,position:[0,0,0],size:[1,1,1])
    let mesh=try #require(SceneGenerator.generate(for:.init(name:"sphere",nodes:[node])).first)
    #expect(mesh.positions.count/3==362)
    #expect(mesh.indices.count/3==720)
    let poles=stride(from:0,to:mesh.positions.count,by:3).filter{
        abs(mesh.positions[$0+1])==0.5 && abs(mesh.positions[$0])<0.000001 && abs(mesh.positions[$0+2])<0.000001
    }
    #expect(poles.count==2)
    for pole in poles { #expect(mesh.indices.filter{$0==UInt32(pole/3)}.count==24) }
}

@Test func nonuniformScaleAndRotationUseInverseTransposeNormals() throws {
    // A rotated ellipsoid is analytically testable: its normal is proportional
    // to inverse-square dimensions in its unrotated coordinate system.
    let node=SceneNode(id:"ellipse",primitive:.sphere,position:[1,0.7,-0.2],size:[0.4,0.8,1.2],rotation:[0,0,90])
    let mesh=try #require(SceneGenerator.generate(for:.init(name:"ellipse",nodes:[node])).first)
    for i in 0..<(mesh.positions.count/3) {
        let world=point(mesh.positions,UInt32(i))-SIMD3<Double>(1,0.7,-0.2)
        let local=SIMD3<Double>(world.y,-world.x,world.z)
        let gradient=SIMD3<Double>(local.x/pow(0.4,2),local.y/pow(0.8,2),local.z/pow(1.2,2))
        var expected=SIMD3<Double>(-gradient.y,gradient.x,gradient.z)
        expected /= sqrt(sceneDot(expected,expected))
        let normal=point(mesh.normals,UInt32(i))
        #expect(sceneDot(expected,normal)>0.999999)
    }
    let box=SceneNode(id:"box",primitive:.box,position:[1,2,3],size:[0.4,0.6,0.8],rotation:[0,0,90])
    let rotated=try #require(SceneGenerator.generate(for:.init(name:"box",nodes:[box])).first)
    let x=stride(from:0,to:rotated.positions.count,by:3).map{rotated.positions[$0]}
    let y=stride(from:1,to:rotated.positions.count,by:3).map{rotated.positions[$0]}
    #expect(abs((x.max()!-x.min()!)-0.6)<0.000001)
    #expect(abs((y.max()!-y.min()!)-0.4)<0.000001)
}

@Test func sceneBudgetsAndPresetIdentityAreDeterministic() throws {
    for preset in SceneSpec.presets {
        try preset.validate()
        let meshes=try SceneGenerator.generate(for:preset)
        #expect(meshes.count==preset.nodes.count)
        #expect(meshes.map(\.name)==preset.nodes.map(\.id))
        #expect(meshes == (try SceneGenerator.generate(for:preset)))
        #expect(meshes.reduce(0){$0+$1.positions.count/3}<=SceneGenerator.maximumVertices)
        #expect(meshes.reduce(0){$0+$1.indices.count}<=SceneGenerator.maximumIndices)
        #expect(Set(preset.nodes.map(\.primitive)).count>=2)
    }
    let worst=SceneSpec(name:"sixteen rings",nodes:(0..<16).map{.init(id:"ring_\($0)",primitive:.torus,position:[0,0,0],size:[2.5,2.5,2.5])})
    let meshes=try SceneGenerator.generate(for:worst)
    #expect(meshes.reduce(0){$0+$1.positions.count/3}==6_144)
    #expect(meshes.reduce(0){$0+$1.indices.count}==36_864)
}

@Test func scenePromptsPreserveExistingNodeIdsAndBoundRequestSize() throws {
    let prompt=try ScenePrompt.userRequest("把灯罩改成青色",currentSpec:.lamp)
    #expect(prompt.contains("\"id\":\"shade\""))
    #expect(prompt.contains("把灯罩改成青色"))
    #expect(ScenePrompt.system.contains("torus"))
    #expect(throws:CreationError.self){try ScenePrompt.userRequest("")}
    #expect(throws:CreationError.self){try ScenePrompt.userRequest(String(repeating:"a",count:2001))}
}

@Test func nativeSceneGenerationHonorsCancellation() async {
    let task=Task {
        withUnsafeCurrentTask{$0?.cancel()}
        return try SceneGenerator.generate(for:.robot)
    }
    do{_=try await task.value;Issue.record("Cancelled scene generation completed")}
    catch is CancellationError{}
    catch{Issue.record("Unexpected error: \(error)")}
}
