import Foundation
import simd
import VoxamberHy3D

/// Pure CPU bake/export. Call on an owned background task and await it. Original
/// buffers/archive are immutable; edits never run weights or alter a base file.
public enum ShapeMeshEditor {
    public static func export(base:ShapeMeshBuffers,recipe:ShapeEditRecipe,
                              baseArchiveData:Data?=nil,
                              isCancelled:@escaping()->Bool={Task.isCancelled})throws->ShapeEditResult {
        let began=Date();try check(isCancelled);try recipe.validate()
        func point(_ values:[Float],_ index:UInt32)->SIMD3<Double>{let i=Int(index)*3;return SIMD3(Double(values[i]),Double(values[i+1]),Double(values[i+2]))}
        for i in stride(from:0,to:base.indices.count,by:3) {
            if i.isMultiple(of:4096*3){try check(isCancelled)}
            let p=point(base.positions,base.indices[i]),q=point(base.positions,base.indices[i+1]),r=point(base.positions,base.indices[i+2])
            let area=simd_length_squared(simd_cross(q-p,r-p))
            guard area.isFinite,area>0 else {throw ShapeEditError.invalidBaseGeometry}
        }
        let baseData:Data
        if let archive=baseArchiveData {
            let restored=try ShapeMeshArchive.read(data:archive)
            guard restored.positions==base.positions,restored.indices==base.indices,restored.normals==base.normals else {throw ShapeEditError.baseArchiveMismatch}
            baseData=archive
        } else {
            baseData=try ShapeMeshArchive.encode(base)
            guard try ShapeMeshArchive.read(data:baseData).normals==base.normals else {throw ShapeEditError.baseArchiveMismatch}
        }
        let baseHash=HunyuanShape21Configuration.digest(baseData)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let recipeHash=HunyuanShape21Configuration.digest(try encoder.encode(recipe))
        let scale=SIMD3(recipe.positiveScaleXYZ[0],recipe.positiveScaleXYZ[1],recipe.positiveScaleXYZ[2])
        let translation=SIMD3(recipe.translationXYZ[0],recipe.translationXYZ[1],recipe.translationXYZ[2])
        let angle=recipe.rotationXYZdegrees.map{$0.truncatingRemainder(dividingBy:360)*Double.pi/180}
        let sx=sin(angle[0]),cx=cos(angle[0]),sy=sin(angle[1]),cy=cos(angle[1]),sz=sin(angle[2]),cz=cos(angle[2])
        func rotate(_ p:SIMD3<Double>)->SIMD3<Double> {
            let x=SIMD3(p.x,cx*p.y-sx*p.z,sx*p.y+cx*p.z)
            let y=SIMD3(cy*x.x+sy*x.z,x.y,-sy*x.x+cy*x.z)
            return SIMD3(cz*y.x-sz*y.y,sz*y.x+cz*y.y,y.z)
        }
        func linear(_ p:SIMD3<Double>)->SIMD3<Double>{rotate(p*scale)}
        var positions=[Float]();positions.reserveCapacity(base.positions.count)
        var normals=[Float]();normals.reserveCapacity(base.normals.count)
        var lower=SIMD3<Float>(repeating:.infinity),upper=SIMD3<Float>(repeating:-.infinity)
        for i in stride(from:0,to:base.positions.count,by:3) {
            if i.isMultiple(of:4096*3){try check(isCancelled)}
            let p=linear(SIMD3(Double(base.positions[i]),Double(base.positions[i+1]),Double(base.positions[i+2])))+translation
            guard (0..<3).allSatisfy({p[$0].isFinite && abs(p[$0])<=ShapeEditLimits.maximumAbsoluteOutputCoordinate}) else {throw ShapeEditError.outputOutOfRange}
            let f=SIMD3(Float(p.x),Float(p.y),Float(p.z))
            guard f.x.isFinite,f.y.isFinite,f.z.isFinite else {throw ShapeEditError.outputOutOfRange}
            positions += [f.x,f.y,f.z];lower=simd_min(lower,f);upper=simd_max(upper,f)
            let original=SIMD3(Double(base.normals[i]),Double(base.normals[i+1]),Double(base.normals[i+2]))
            guard simd_length_squared(original)>0 else {throw ShapeEditError.invalidBaseGeometry}
            let n=rotate(original/scale),length=simd_length(n)
            guard length.isFinite,length>0 else {throw ShapeEditError.floatDegeneration}
            let unit=n/length,nf=SIMD3(Float(unit.x),Float(unit.y),Float(unit.z))
            guard nf.x.isFinite,nf.y.isFinite,nf.z.isFinite else {throw ShapeEditError.floatDegeneration}
            normals += [nf.x,nf.y,nf.z]
        }
        let extent=upper-lower
        guard (0..<3).allSatisfy({Double(extent[$0]).isFinite && Double(extent[$0])<=ShapeEditLimits.maximumOutputExtent}) else {throw ShapeEditError.outputOutOfRange}
        guard max(extent.x,max(extent.y,extent.z))>0 else {throw ShapeEditError.floatDegeneration}
        for i in stride(from:0,to:base.indices.count,by:3) {
            if i.isMultiple(of:4096*3){try check(isCancelled)}
            let a=base.indices[i],b=base.indices[i+1],c=base.indices[i+2]
            let p=point(base.positions,a),q=point(base.positions,b),r=point(base.positions,c)
            let before=simd_cross(q-p,r-p)
            guard simd_length_squared(before).isFinite,simd_length_squared(before)>0 else {throw ShapeEditError.invalidBaseGeometry}
            let expected=simd_cross(linear(q-p),linear(r-p))
            let fa=point(positions,a),fb=point(positions,b),fc=point(positions,c),actual=simd_cross(fb-fa,fc-fa)
            guard simd_length_squared(actual).isFinite,simd_length_squared(actual)>0,
                  simd_dot(expected,actual)>0 else {throw ShapeEditError.floatDegeneration}
        }
        let edited=try ShapeMeshBuffers(positions:positions,normals:normals,indices:base.indices)
        try check(isCancelled)
        let folder=FileManager.default.temporaryDirectory.appending(path:"VoxamberMeshEdit-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let glbURL=folder.appending(path:"edited.glb"),usdzURL=folder.appending(path:"edited.usdz")
        var vertices:[SIMD3<Float>]=[];vertices.reserveCapacity(edited.vertexCount)
        for i in stride(from:0,to:positions.count,by:3){vertices.append(SIMD3(positions[i],positions[i+1],positions[i+2]))}
        var faces:[(UInt32,UInt32,UInt32)]=[];faces.reserveCapacity(edited.triangleCount)
        for i in stride(from:0,to:base.indices.count,by:3){faces.append((base.indices[i],base.indices[i+1],base.indices[i+2]))}
        let material=recipe.wholeMaterial.map{GLB.Material(rgba:$0.rgba.map(Float.init),metallic:Float($0.metallic),roughness:Float($0.roughness))}
        try GLB.write(Mesh(vertices:vertices,faces:faces),to:glbURL,normals:normals,material:material,isCancelled:isCancelled)
        try ShapeAssetExporter.writeGeometryUSDZ(vertices:positions,faces:base.indices,normals:normals,
            material:recipe.wholeMaterial,to:usdzURL,isCancelled:isCancelled)
        try check(isCancelled)
        guard (try glbURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=ShapeArtifactLimits.maximumGLBBytes,
              (try usdzURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=ShapeArtifactLimits.maximumUSDZBytes else {throw ShapeError.invalidGeometry}
        let glb=try Data(contentsOf:glbURL),usdz=try Data(contentsOf:usdzURL)
        try check(isCancelled)
        guard HunyuanShape21Configuration.digest(baseData)==baseHash else {throw ShapeEditError.baseArchiveMismatch}
        let lo=[lower.x,lower.y,lower.z],hi=[upper.x,upper.y,upper.z]
        let receipt=ShapeEditValidationReceipt(version:1,method:"cpu-mesh-transform-material",baseMeshFormatID:ShapeMeshArchive.formatID,
            baseMeshFormatVersion:ShapeMeshArchive.version,baseMeshSHA256:baseHash,recipeSHA256:recipeHash,renderGeometryLayoutVersion:2,
            vertexCount:edited.vertexCount,triangleCount:edited.triangleCount,indexCount:edited.indices.count,
            glbByteCount:Int64(glb.count),usdzByteCount:Int64(usdz.count),glbSHA256:HunyuanShape21Configuration.digest(glb),
            usdzSHA256:HunyuanShape21Configuration.digest(usdz),boundsMinimum:lo,boundsMaximum:hi,topologyPreserved:true,
            normalsInverseTransposeNormalized:true,wholeMaterialApplied:recipe.wholeMaterial != nil,baseUnchanged:true,actualNeuralWeightsUsed:false)
        return ShapeEditResult(mesh:edited,glbData:glb,usdzData:usdz,boundsMinimum:lo,boundsMaximum:hi,
            durationSeconds:Date().timeIntervalSince(began),validationReceipt:receipt)
    }
    private static func check(_ cancelled:()->Bool)throws {if cancelled() || Task.isCancelled{throw CancellationError()}}
}
