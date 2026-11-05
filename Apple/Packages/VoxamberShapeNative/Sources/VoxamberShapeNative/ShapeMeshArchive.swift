import Foundation
import VoxamberHy3D

/// Restorable source geometry uses standard GLB2, not a made-up placeholder
/// scene. This reader accepts the SDK's flattened POSITION/index layout.
/// Layout1 derives normals deterministically from source geometry; arbitrary
/// editor-supplied normals are not encoded by this source-mesh layout.
public enum ShapeMeshArchive {
    public static let formatID="org.khronos.gltf.binary"
    public static let version=2
    public static let geometryLayoutVersion=1

    public static func read(data:Data)throws->ShapeMeshBuffers {
        guard data.count<=ShapeArtifactLimits.maximumGLBBytes else {throw ShapeError.invalidGeometry}
        let mesh=try GLB.read(data:data)
        return try buffers(mesh)
    }
    public static func read(url:URL)throws->ShapeMeshBuffers {
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard url.isFileURL,values.isRegularFile==true,values.isSymbolicLink==false,
              let bytes=values.fileSize,bytes<=ShapeArtifactLimits.maximumGLBBytes else {throw ShapeError.invalidGeometry}
        return try read(data:Data(contentsOf:url))
    }
    public static func encode(_ buffers:ShapeMeshBuffers)throws->Data {
        let folder=FileManager.default.temporaryDirectory.appending(path:"VoxamberMeshArchive-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appending(path:"base-mesh.glb")
        var vertices:[SIMD3<Float>]=[];vertices.reserveCapacity(buffers.vertexCount)
        for i in stride(from:0,to:buffers.positions.count,by:3){vertices.append(.init(buffers.positions[i],buffers.positions[i+1],buffers.positions[i+2]))}
        var faces:[(UInt32,UInt32,UInt32)]=[];faces.reserveCapacity(buffers.triangleCount)
        for i in stride(from:0,to:buffers.indices.count,by:3){faces.append((buffers.indices[i],buffers.indices[i+1],buffers.indices[i+2]))}
        try GLB.write(Mesh(vertices:vertices,faces:faces),to:file)
        let bytes=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard bytes<=ShapeArtifactLimits.maximumGLBBytes else {throw ShapeError.invalidGeometry}
        return try Data(contentsOf:file)
    }
    public static func write(_ mesh:ShapeMeshBuffers,to url:URL)throws {
        guard url.isFileURL else {throw ShapeError.invalidGeometry}
        let temp=url.deletingLastPathComponent().appending(path:".base-mesh-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        try encode(mesh).write(to:temp,options:.withoutOverwriting)
        try ShapeAssetExporter.renameExclusive(temp,to:url)
    }

    static func buffers(_ mesh:Mesh,cancelled:@escaping()->Bool={false})throws->ShapeMeshBuffers {
        guard mesh.vertices.count<=ShapeArtifactLimits.maximumVertices,
              mesh.faces.count<=ShapeArtifactLimits.maximumTriangles else {throw ShapeError.invalidGeometry}
        let positions=mesh.vertices.flatMap{[$0.x,$0.y,$0.z]},indices=mesh.faces.flatMap{[$0.0,$0.1,$0.2]}
        let normals=try ShapeAssetExporter.vertexNormals(vertices:positions,faces:indices,isCancelled:cancelled)
            .flatMap{[$0.0,$0.1,$0.2]}
        return try ShapeMeshBuffers(positions:positions,normals:normals,indices:indices)
    }
}
