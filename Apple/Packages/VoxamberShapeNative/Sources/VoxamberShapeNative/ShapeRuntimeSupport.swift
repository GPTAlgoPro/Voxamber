import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import Darwin

final class ShapeCancellationToken:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    var isCancelled:Bool {lock.withLock{cancelled}}
    func cancel(){lock.withLock{cancelled=true}}
    func check()throws {if isCancelled || Task.isCancelled {throw CancellationError()}}
}

/// A process-wide lease prevents multiple SDK instances loading Shape at once.
final class ShapeRuntimeLease:@unchecked Sendable {
    static let shared=ShapeRuntimeLease()
    private let lock=NSLock()
    private var owner:UUID?
    func acquire()->UUID? {lock.withLock{guard owner==nil else{return nil};let id=UUID();owner=id;return id}}
    func release(_ id:UUID){lock.withLock{if owner==id{owner=nil}}}
}

enum PreparedShapeInput {
    static func decode(_ data:Data)throws->CGImage {
        guard data.count>=33,data.count<=ShapeArtifactLimits.maximumInputPNGBytes,
              data.starts(with:[137,80,78,71,13,10,26,10]),
              let source=CGImageSourceCreateWithData(data as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              properties[kCGImagePropertyPixelWidth] as? Int==512,
              properties[kCGImagePropertyPixelHeight] as? Int==512,
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw ShapeError.invalidInput}
        return image
    }
}

enum ShapePackVerifier {
    static func preflight(_ url:URL)throws {
        guard url.isFileURL,
              let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),
              values.isRegularFile==true,values.isSymbolicLink==false else {throw ShapeError.modelUnavailable}
        guard Int64(values.fileSize ?? -1)==HunyuanShape21Configuration.modelPackBytes else {throw ShapeError.modelMismatch}
    }
    static func verify(_ url:URL,cancellation:ShapeCancellationToken)throws {
        try verifyFile(url,bytes:HunyuanShape21Configuration.modelPackBytes,
            expectedSHA256:HunyuanShape21Configuration.modelPackSHA256,cancellation:cancellation)
    }
    static func verifyFile(_ url:URL,bytes:Int64,expectedSHA256:String,cancellation:ShapeCancellationToken)throws {
        try cancellation.check()
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor>=0 else {throw ShapeError.modelUnavailable}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer {try? handle.close()}
        var before=stat();guard fstat(descriptor,&before)==0,(before.st_mode&S_IFMT)==S_IFREG,
            before.st_size==bytes else {throw ShapeError.modelMismatch}
        var hash=SHA256();var done=false
        while !done {
            try cancellation.check()
            try autoreleasepool {
                let chunk=try handle.read(upToCount:1_048_576) ?? Data()
                if chunk.isEmpty{done=true}else{hash.update(data:chunk)}
            }
        }
        var after=stat();guard fstat(descriptor,&after)==0,before.st_dev==after.st_dev,
            before.st_ino==after.st_ino,before.st_size==after.st_size,
            before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec,
            hash.finalize().map({String(format:"%02x",$0)}).joined()==expectedSHA256 else {throw ShapeError.modelMismatch}
    }
}
