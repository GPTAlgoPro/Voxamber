import Foundation
import Testing
@testable import CreationCore

@Test func expandedBoundsMustRejectWorldFloatCollapsedSphere() throws {
    let node = SceneNode(id:"tiny_far",primitive:.sphere,position:[1000,1000,1000],size:[0.001,0.001,0.001])
    try node.validate() // The expanded SI parameter contract must admit it.
    let local = PrimitiveMesh.sphere()
    let positions = local.positions.flatMap { p -> [Float] in
        [Float(p.x * Double(node.size[0]) + Double(node.position[0])),
         Float(p.y * Double(node.size[1]) + Double(node.position[1])),
         Float(p.z * Double(node.size[2]) + Double(node.position[2]))]
    }
    let collapsed = scaleZeroAreaCount(positions:positions,indices:local.indices)
    #expect(collapsed == 64, "Witness reproduces the actual legacy Double-to-world-Float transform")
    print("Legacy world-Float sphere: \(collapsed) collapsed triangles of \(local.indices.count/3)")
    do {
        _ = try SceneGenerator.generate(for:.init(name:"precision",nodes:[node]))
        Issue.record("Precision-unsafe sphere was returned despite 64 collapsed world-space faces")
    } catch let error as CreationError {
        #expect(error.localizedDescription.contains("精度"), "Reject for world precision, not the former prototype bounds")
    }
    #expect(throws:CreationError.self) { try SceneGenerator.bounds(for:node) }
}

@Test func oneMillimetreSphereAtOriginRemainsValid() throws {
    let node = SceneNode(id:"tiny_near",primitive:.sphere,position:[0,0,0],size:[0.001,0.001,0.001])
    let mesh = try #require(SceneGenerator.generate(for:.init(name:"precision",nodes:[node])).first)
    #expect(scaleZeroAreaCount(positions:mesh.positions,indices:mesh.indices) == 0)
}

@Test func scaleLimitsSchemaAndPromptUseTheExpandedSIContract() throws {
    #expect(SceneLimits.dimensionRange == Float(0.001)...Float(100))
    #expect(SceneLimits.positionRange == Float(-1000)...Float(1000))
    #expect(SceneLimits.offsetRange == Float(-1000)...Float(1000))
    #expect(SceneSpec.maximumNodes == 32 && SceneSpec.maximumResponseBytes == 262_144)
    #expect(SceneGenerator.maximumVertices == 20_000 && SceneGenerator.maximumIndices == 80_000)
    let schema=try StrictJSONObject.decode(SceneGenerationSchema.jsonSchema())
    let defs=try #require(schema["$defs"] as? [String:Any])
    let dimensions=try #require((defs["dimensions"] as? [String:Any])?["properties"] as? [String:[String:Any]])
    #expect(dimensions["width"]?["minimum"] as? Double == 0.001)
    #expect(dimensions["height"]?["maximum"] as? Double == 100)
    let origin=try #require((defs["origin"] as? [String:Any])?["properties"] as? [String:[String:Any]])
    #expect(origin["x"]?["minimum"] as? Double == -1000)
    #expect(origin["z"]?["maximum"] as? Double == 1000)
    let attach=try #require((defs["attachment"] as? [String:Any])?["properties"] as? [String:[String:Any]])
    #expect(attach["yOffset"]?["minimum"] as? Double == -1000)
    #expect(attach["xOffset"]?["maximum"] as? Double == 1000)
    #expect((defs["latheProfile"] as? [String:Any])?["maxItems"] as? Int == 64)
    #expect((defs["meshVertices"] as? [String:Any])?["maxItems"] as? Int == 1024)
    #expect((defs["meshTriangles"] as? [String:Any])?["maxItems"] as? Int == 2048)
    #expect(ScenePrompt.system.contains("0.001到100.0米"))
    #expect(ScenePrompt.system.contains("1000.0"))
    let nominal=##"{"name":"millimetre","nodes":[{"id":"part","primitive":"box","dimensions":{"width":0.001,"height":0.001,"depth":0.001},"color":"#FFFFFF","origin":{"x":0,"y":0,"z":0}}]}"##
    let decoded=try ScenePlan.decodeModelResponse(nominal)
    #expect(decoded.nodes[0].size == [0.001,0.001,0.001])
    _=try SceneGenerator.generate(for:decoded)
}

@Test func allEightPrimitivesPassSafeScaleRotationAndCoordinateBoundaryMatrix() throws {
    for primitive in SceneNode.Primitive.allCases {
        for center:Float in [0,-1000,1000] {
            for dimensions:[Float] in [[1,1,1],[0.5,2,1.5],[100,80,60]] {
                var node=SceneNode.defaultNode(primitive:primitive,id:"shape",position:[center,center,center])
                node.size=dimensions;node.rotation=[17,-29,33]
                let mesh=try #require(SceneGenerator.generate(for:.init(name:"matrix",nodes:[node])).first)
                try assertScaleMesh(mesh)
                let bounds=try SceneGenerator.bounds(for:node)
                let finiteBounds=(bounds.minimum+bounds.maximum).allSatisfy { $0.isFinite }
                #expect(finiteBounds)
            }
        }
        var minimum=SceneNode.defaultNode(primitive:primitive,id:"millimetre",position:[0,0,0])
        minimum.size=[0.001,0.001,0.001];minimum.rotation=[17,-29,33]
        try assertScaleMesh(try #require(SceneGenerator.generate(for:.init(name:"minimum",nodes:[minimum])).first))
        // A simple far 1mm solid is still representable; do not reject the
        // entire lower-size/upper-position range just because the sphere fails.
        if primitive == .box {
            minimum.position=[1000,1000,1000];minimum.rotation=[0,0,0]
            try assertScaleMesh(try #require(SceneGenerator.generate(for:.init(name:"small_far_box",nodes:[minimum])).first))
        }
    }
}

@Test func legacyTwentyMillimetreScenesAndExpandedOldFailureValuesRemainValid() throws {
    for primitive in SceneNode.Primitive.allCases {
        for position:Float in [-3,0,3] {
            var node=SceneNode.defaultNode(primitive:primitive,id:"legacy",position:[position,position,position])
            node.size=[0.02,0.02,0.02];node.rotation=[13,17,-19]
            try assertScaleMesh(try #require(SceneGenerator.generate(for:.init(name:"legacy",nodes:[node])).first))
        }
    }
    // These are positive tests for values that the old tests deliberately
    // rejected. New invalid tests use the new explicit boundary instead.
    let expanded=SceneNode(id:"expanded",primitive:.box,position:[3.1,0,0],size:[2.51,0.01,3.5])
    try expanded.validate()
    try assertScaleMesh(try #require(SceneGenerator.generate(for:.init(name:"expanded",nodes:[expanded])).first))
    for preset in SceneSpec.presets {
        #expect(try ScenePlan.decodeModelResponse(ScenePlan.snapshot(preset)) == preset)
    }
}

@Test func aValidThreePointFiveMetreLatheIsGeometryEvidenceNotNeuralAircraftAcceptance() throws {
    var node=SceneNode.defaultNode(primitive:.lathe,id:"body",position:[0,0,0])
    node.size=[1.2,3.5,0.8]
    let scene=SceneSpec(name:"geometry-only scale fixture",nodes:[node])
    let decoded=try ScenePlan.decodeModelResponse(ScenePlan.snapshot(scene))
    #expect(decoded == scene)
    let bounds=try SceneGenerator.bounds(for:node)
    #expect(abs(bounds.height-3.5)<1e-6)
    try assertScaleMesh(try #require(SceneGenerator.generate(for:decoded).first))
}

@Test func expandedScaleStillRejectsInvalidNumbersBooleansAndGraphReferences() throws {
    let base=SceneNode(id:"valid",primitive:.box,position:[0,0,0],size:[1,1,1])
    for invalid in [Float.nan,Float.infinity,-Float.infinity,0,-1,SceneLimits.minimumDimension.nextDown,Float(100).nextUp] {
        var node=base;node.size[0]=invalid
        #expect(throws:CreationError.self) { try node.validate() }
    }
    for invalid in [Float.nan,Float.infinity,-Float.infinity,Float(1000).nextUp,Float(-1000).nextDown] {
        var node=base;node.position[0]=invalid
        #expect(throws:CreationError.self) { try node.validate() }
        node=base;node.parentID="parent";node.attachment = .inside;node.offset=[invalid,0,0]
        #expect(throws:CreationError.self) { try node.validate() }
    }
    for boundary:Float in [-1000,1000] {
        var node=base;node.parentID="parent";node.attachment = .inside;node.offset=[boundary,boundary,boundary]
        try node.validate()
    }
    let boolean=##"{"name":"invalid","nodes":[{"id":"a","primitive":"box","dimensions":{"width":true,"height":1,"depth":1},"color":"#FFFFFF"}]}"##
    let unknown=##"{"name":"invalid","nodes":[{"id":"a","primitive":"box","dimensions":{"width":1,"height":1,"depth":1},"color":"#FFFFFF","attach":{"parent":"missing","face":"top"}}]}"##
    for raw in [boolean,unknown] { #expect(throws:CreationError.self) { try ScenePlan.decodeModelResponse(raw) } }
}

@Test func expandedAttachmentChainsKeepNativeContactNormalsAndBudgets() throws {
    let scene=SceneSpec(name:"large chain",nodes:[
        .init(id:"top",primitive:.sphere,position:[0,0,0],size:[3.5,2.3,1.1],parentID:"stem",attachment:.top,offset:[-2,0,2]),
        .init(id:"stem",primitive:.cylinder,position:[0,0,0],size:[1,5,1],parentID:"base",attachment:.top,offset:[4,0,-5]),
        .init(id:"base",primitive:.box,position:[0,0,0],size:[20,10,20],offset:[0,0,0])
    ])
    let canonical=try SceneAttachmentResolver.resolve(scene)
    let byID=Dictionary(uniqueKeysWithValues:canonical.nodes.map { ($0.id,$0) })
    let base=try SceneGenerator.bounds(for:byID["base"]!),stem=try SceneGenerator.bounds(for:byID["stem"]!),top=try SceneGenerator.bounds(for:byID["top"]!)
    #expect(abs(stem.minimum[1]-base.maximum[1]+0.003)<1e-5)
    #expect(abs(top.minimum[1]-stem.maximum[1]+0.003)<1e-5)
    #expect(abs(base.minimum[1])<1e-5)
    let meshes=try SceneGenerator.generate(for:scene)
    for mesh in meshes { try assertScaleMesh(mesh) }
    #expect(meshes.reduce(0) { $0+$1.positions.count/3 } <= 20_000)
    #expect(meshes.reduce(0) { $0+$1.indices.count } <= 80_000)
    #expect(try SceneAttachmentResolver.resolve(canonical) == canonical)
    let excessive=SceneSpec(name:"resource budget",nodes:(0..<32).map {
        var node=SceneNode.defaultNode(primitive:.lathe,id:"part_\($0)",position:[0,0,0])
        node.profile=(0..<64).map { [Float($0%2+1),Float($0)] }
        return node
    })
    #expect(throws:CreationError.self) { try SceneGenerator.generate(for:excessive) }
}

@Test func worldMeshValidationRejectsBadIndexFiniteDataAndNormalBeforeAccess() throws {
    let p:[Float]=[0,0,0,1,0,0,0,1,0],n:[Float]=[0,0,1,0,0,1,0,0,1]
    try WorldMeshValidation.validate(positions:p,normals:n,indices:[0,1,2])
    #expect(throws:CreationError.self) { try WorldMeshValidation.validate(positions:p,normals:n,indices:[0,1,UInt32.max]) }
    #expect(throws:CreationError.self) { try WorldMeshValidation.validate(positions:p,normals:n,indices:[0,1]) }
    #expect(throws:CreationError.self) { try WorldMeshValidation.validate(positions:p,normals:n,indices:[0,0,2]) }
    var nonfinite=p;nonfinite[0] = .nan
    #expect(throws:CreationError.self) { try WorldMeshValidation.validate(positions:nonfinite,normals:n,indices:[0,1,2]) }
    var invalidNormal=n;invalidNormal[0] = .infinity
    #expect(throws:CreationError.self) { try WorldMeshValidation.validate(positions:p,normals:invalidNormal,indices:[0,1,2]) }
    #expect(throws:CreationError.self) { try WorldMeshValidation.validate(positions:p,normals:Array(repeating:0,count:9),indices:[0,1,2]) }
}

@Test func extremeNonuniformScaleNormalsMatchTheAnalyticEllipsoid() throws {
    let size:[Float]=[0.001,10,100]
    let node=SceneNode(id:"ellipsoid",primitive:.sphere,position:[0,0,0],size:size,rotation:[0,0,90])
    let mesh=try #require(SceneGenerator.generate(for:.init(name:"analytic normals",nodes:[node])).first)
    for start in stride(from:0,to:mesh.positions.count,by:3) {
        let world=SIMD3<Double>(Double(mesh.positions[start]),Double(mesh.positions[start+1]),Double(mesh.positions[start+2]))
        let local=SIMD3<Double>(world.y,-world.x,world.z)
        let gradient=SIMD3<Double>(local.x/pow(Double(size[0]),2),local.y/pow(Double(size[1]),2),local.z/pow(Double(size[2]),2))
        var expected=SIMD3<Double>(-gradient.y,gradient.x,gradient.z)
        expected /= sqrt(expected.x*expected.x+expected.y*expected.y+expected.z*expected.z)
        let n=SIMD3<Double>(Double(mesh.normals[start]),Double(mesh.normals[start+1]),Double(mesh.normals[start+2]))
        #expect(n.x*expected.x+n.y*expected.y+n.z*expected.z > 0.999999)
    }
}

private func assertScaleMesh(_ mesh:GeneratedMesh) throws {
    #expect(mesh.positions.count == mesh.normals.count)
    #expect(mesh.positions.allSatisfy(\.isFinite) && mesh.normals.allSatisfy(\.isFinite))
    #expect(mesh.indices.allSatisfy { Int($0)<mesh.positions.count/3 })
    #expect(scaleZeroAreaCount(positions:mesh.positions,indices:mesh.indices) == 0)
    for start in stride(from:0,to:mesh.normals.count,by:3) {
        let x=Double(mesh.normals[start]),y=Double(mesh.normals[start+1]),z=Double(mesh.normals[start+2])
        #expect(abs(x*x+y*y+z*z-1)<1e-5)
    }
    func vector(_ values:[Float],_ index:UInt32) -> SIMD3<Double> {
        let start=Int(index)*3
        return .init(Double(values[start]),Double(values[start+1]),Double(values[start+2]))
    }
    for start in stride(from:0,to:mesh.indices.count,by:3) {
        let a=mesh.indices[start],b=mesh.indices[start+1],c=mesh.indices[start+2]
        let u=vector(mesh.positions,b)-vector(mesh.positions,a),v=vector(mesh.positions,c)-vector(mesh.positions,a)
        let cross=SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
        let normal=vector(mesh.normals,a)+vector(mesh.normals,b)+vector(mesh.normals,c)
        #expect(cross.x*normal.x+cross.y*normal.y+cross.z*normal.z > 0)
    }
}

private func scaleZeroAreaCount(positions:[Float],indices:[UInt32]) -> Int {
    func p(_ index:UInt32) -> SIMD3<Double> {
        let offset=Int(index)*3
        return .init(Double(positions[offset]),Double(positions[offset+1]),Double(positions[offset+2]))
    }
    return stride(from:0,to:indices.count,by:3).filter { start in
        let a=p(indices[start]),b=p(indices[start+1]),c=p(indices[start+2])
        let u=b-a,v=c-a
        let cross=SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
        return cross.x*cross.x+cross.y*cross.y+cross.z*cross.z <= 0
    }.count
}
