import Foundation
import MLX
import VoxamberHy3D
#if os(iOS)
import os
#endif

/// Owns one real neural shape worker. Cancellation marks its cooperative token,
/// cancels the actual Task and awaits completion; it never abandons GPU work.
public actor ShapeEngine {
    private struct Job {let id:UUID;let token:ShapeCancellationToken;let task:Task<ShapeResult,Error>}
    private var active:Job?
    private var unloadCount=0
    public var status:ShapeEngineStatus {
        if unloadCount>0{return .unloading}
        guard let job=active else{return .idle}
        return job.token.isCancelled ? .cancelling : .running
    }
    public init() {}

    /// Input is a512² PNG preserving foreground alpha from image preparation.
    /// The original DINO preprocessor finds the alpha bbox, recenters with its
    /// trained border and composites white internally. Do not flatten alpha
    /// merely for display. This SDK does not run another segmentation model.
    public func generate(pngData:Data,shapePackURL:URL,configurationYAML:String,seed:UInt64,
                         onProgress:@escaping @Sendable(ShapeProgress)->Void={_ in}) async throws->ShapeResult {
        guard active==nil,unloadCount==0 else {throw ShapeError.busy}
        try Task.checkCancellation()
        #if targetEnvironment(simulator)
        throw ShapeError.simulatorUnsupported
        #endif
        try HunyuanShape21Configuration.validate(configurationYAML)
        _ = try PreparedShapeInput.decode(pngData)
        try ShapePackVerifier.preflight(shapePackURL)
        guard let lease=ShapeRuntimeLease.shared.acquire() else {throw ShapeError.busy}
        let id=UUID(),token=ShapeCancellationToken()
        let task=Task.detached(priority:.userInitiated) {
            defer {ShapeRuntimeLease.shared.release(lease)}
            return try ShapeBackend.run(pngData:pngData,url:shapePackURL,yaml:configurationYAML,
                seed:seed,token:token,onProgress:onProgress)
        }
        active=Job(id:id,token:token,task:task)
        defer {if active?.id==id{active=nil}}
        return try await withTaskCancellationHandler {
            let result=try await task.value
            try Task.checkCancellation()
            return result
        } onCancel:{token.cancel();task.cancel()}
    }

    public func cancel() {
        guard let active else{return}
        active.token.cancel();active.task.cancel()
    }

    /// Idle unload never initializes MLX/Metal merely to clear a cold cache.
    public func unload() async {
        unloadCount+=1
        defer {unloadCount-=1}
        if let job=active {
            job.token.cancel();job.task.cancel();_ = try? await job.task.value
            if active?.id==job.id {active=nil}
        }
    }
}

private enum ShapeBackend {
    static func run(pngData:Data,url:URL,yaml:String,seed:UInt64,token:ShapeCancellationToken,
                    onProgress:@escaping @Sendable(ShapeProgress)->Void)throws->ShapeResult {
        let began=Date();var hadRuntime=false
        defer {if hadRuntime{Stream.gpu.synchronize();Memory.clearCache()}}
        try token.check()
        onProgress(.init(stage:"Verifying shape model",fraction:0.01))
        try ShapePackVerifier.verify(url,cancellation:token)
        let available:UInt64?
        #if os(iOS)
        available=UInt64(os_proc_available_memory())
        guard available!>=HunyuanShape21Configuration.minimumAvailableProcessBytes else {throw ShapeError.insufficientHeadroom}
        #else
        available=nil
        #endif
        let image=try PreparedShapeInput.decode(pngData)
        let folder=FileManager.default.temporaryDirectory.appending(path:"VoxamberShape-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let glbURL=folder.appending(path:"model.glb"),usdzURL=folder.appending(path:"model.usdz")
        try token.check();onProgress(.init(stage:"Loading shape model",fraction:0.03))
        let neuralBegan=Date();hadRuntime=true
        do {
            try autoreleasepool {
                let generator=try ShapeGenerator(weightsURL:url,quantize:0,configurationYAML:yaml,
                    packedBits:4,numLatents:4096,cacheLimitMB:64,
                    executionStrategy:.constrainedMemory(moeTokenChunkSize:512))
                try token.check()
                do {
                    try generator.generateGLB(image:image,to:glbURL,steps:10,guidance:5,seed:seed,
                        resolution:192,octree:true,isCancelled:{token.isCancelled || Task.isCancelled},
                        onProgress:{p in onProgress(.init(stage:p.stage,fraction:0.05+p.fraction*0.82))})
                } catch {try token.check();throw error}
                try token.check()
            }
        } catch {try token.check();throw error}
        // Generator/tensors left scope before native artifact serialization.
        Stream.gpu.synchronize();Memory.clearCache()
        let neuralSeconds=Date().timeIntervalSince(neuralBegan),exportBegan=Date()
        try token.check();onProgress(.init(stage:"Encoding shape artifacts",fraction:0.90))
        let mesh=try GLB.read(glbURL)
        guard !mesh.vertices.isEmpty,!mesh.faces.isEmpty else {throw ShapeError.emptyShape}
        let buffers=try ShapeMeshArchive.buffers(mesh,cancelled:{token.isCancelled || Task.isCancelled})
        try ShapeAssetExporter.writeGeometryUSDZ(vertices:buffers.positions,faces:buffers.indices,normals:buffers.normals,
            to:usdzURL,isCancelled:{token.isCancelled || Task.isCancelled})
        try token.check()
        let glbBytes=try glbURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        let usdzBytes=try usdzURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard glbBytes<=ShapeArtifactLimits.maximumGLBBytes,usdzBytes<=ShapeArtifactLimits.maximumUSDZBytes else {throw ShapeError.invalidGeometry}
        let glb=try Data(contentsOf:glbURL),usdz=try Data(contentsOf:usdzURL)
        try token.check()
        let result=ShapeResult(mesh:buffers,glbData:glb,usdzData:usdz,
            statistics:.init(durationSeconds:Date().timeIntervalSince(began),neuralSeconds:neuralSeconds,
                exportSeconds:Date().timeIntervalSince(exportBegan),mlxProcessPeakBytes:Memory.peakMemory,
                availableProcessBytesAtAdmission:available),
            provenance:.init(modelID:HunyuanShape21Configuration.modelID,
                modelSourceRevision:HunyuanShape21Configuration.modelSourceRevision,
                modelPackSHA256:HunyuanShape21Configuration.modelPackSHA256,
                configurationSHA256:HunyuanShape21Configuration.configurationSHA256,
                inputPNG_SHA256:HunyuanShape21Configuration.digest(pngData),seed:seed,steps:10,
                octreeResolution:192,latentCount:4096,runtimeMLXVersion:"0.32.3",physicalScaleKnown:false,
                weightParityWithOriginalRuntimeVerified:false),
            validationReceipt:.init(version:1,baseMeshFormatID:ShapeMeshArchive.formatID,
                baseMeshFormatVersion:ShapeMeshArchive.version,geometryLayoutVersion:ShapeMeshArchive.geometryLayoutVersion,
                vertexCount:buffers.vertexCount,triangleCount:buffers.triangleCount,indexCount:buffers.indices.count,
                glbByteCount:glb.count,usdzByteCount:usdz.count,
                glbSHA256:HunyuanShape21Configuration.digest(glb),usdzSHA256:HunyuanShape21Configuration.digest(usdz),
                baseMeshUsesUnchangedGLB:true,nativeGeometryValidated:true,usdNativeImporterOpened:true,
                actualNeuralWeightsUsed:true))
        onProgress(.init(stage:"Shape artifacts complete",fraction:1));try token.check()
        return result
    }
}
