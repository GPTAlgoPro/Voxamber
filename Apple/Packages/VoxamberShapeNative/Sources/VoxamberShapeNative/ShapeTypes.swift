import Foundation
import CryptoKit

public enum ShapeArtifactLimits {
    public static let maximumVertices=2_000_000
    public static let maximumTriangles=4_000_000
    public static let maximumIndices=12_000_000
    public static let maximumGLBBytes=256*1024*1024
    public static let maximumUSDZBytes=512*1024*1024
    public static let maximumInputPNGBytes=32*1024*1024
}

public struct ShapeMeshBuffers: Sendable {
    public let positions: [Float]
    public let normals: [Float]
    public let indices: [UInt32]
    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    public init(positions:[Float],normals:[Float],indices:[UInt32]) throws {
        guard positions.count>=9, positions.count.isMultiple(of:3),
              normals.count==positions.count,indices.count>=3,indices.count.isMultiple(of:3),
              positions.count/3<=ShapeArtifactLimits.maximumVertices,
              indices.count<=ShapeArtifactLimits.maximumIndices,
              positions.allSatisfy(\.isFinite),normals.allSatisfy(\.isFinite),
              positions.count/3<=Int(UInt32.max),indices.allSatisfy({Int($0)<positions.count/3}) else {
            throw ShapeError.invalidGeometry
        }
        self.positions=positions;self.normals=normals;self.indices=indices
    }
}

public struct ShapeProgress: Sendable {
    public let stage:String
    public let fraction:Float
    public init(stage:String,fraction:Float) {self.stage=stage;self.fraction=fraction}
}

public struct ShapeStatistics: Codable, Sendable {
    public let durationSeconds:Double
    public let neuralSeconds:Double
    public let exportSeconds:Double
    public let mlxProcessPeakBytes:Int
    public let availableProcessBytesAtAdmission:UInt64?
}

public struct ShapeProvenance: Codable, Sendable {
    public let modelID:String
    public let modelSourceRevision:String
    public let modelPackSHA256:String
    public let configurationSHA256:String
    public let inputPNG_SHA256:String
    public let seed:UInt64
    public let steps:Int
    public let octreeResolution:Int
    public let latentCount:Int
    public let runtimeMLXVersion:String
    public let physicalScaleKnown:Bool
    public let weightParityWithOriginalRuntimeVerified:Bool
}

/// Integrity/count evidence from the real backend's artifact boundary. This is
/// neither a signature nor a visual-quality or numerical-parity acceptance.
public struct ShapeValidationReceipt:Codable,Sendable {
    public let version:Int
    public let baseMeshFormatID:String
    public let baseMeshFormatVersion:Int
    public let geometryLayoutVersion:Int
    public let vertexCount:Int
    public let triangleCount:Int
    public let indexCount:Int
    public let glbByteCount:Int
    public let usdzByteCount:Int
    public let glbSHA256:String
    public let usdzSHA256:String
    public let baseMeshUsesUnchangedGLB:Bool
    public let nativeGeometryValidated:Bool
    public let usdNativeImporterOpened:Bool
    public let actualNeuralWeightsUsed:Bool
}

public struct ShapeResult: Sendable {
    public let mesh:ShapeMeshBuffers
    public let glbData:Data
    public let usdzData:Data
    public let statistics:ShapeStatistics
    public let provenance:ShapeProvenance
    public let validationReceipt:ShapeValidationReceipt
    /// The unchanged generated geometry GLB is the base-mesh archive. A rendered
    /// material revision may differ later, while this original remains intact.
    public var baseMeshData:Data {glbData}
}

public enum ShapeEngineStatus:String,Codable,Sendable {case idle,running,cancelling,unloading}
public enum ShapeError:LocalizedError,Sendable {
    case busy,invalidInput,invalidConfiguration,modelUnavailable,modelMismatch,insufficientHeadroom,emptyShape,invalidGeometry,simulatorUnsupported
    public var errorDescription:String? {
        switch self {
        case .busy:"本机三维建模任务仍在处理中。"
        case .invalidInput:"请提供已经居中处理的512像素PNG主体图。"
        case .invalidConfiguration:"建模配置与当前模型版本不匹配。"
        case .modelUnavailable:"请先准备专用三维建模资源。"
        case .modelMismatch:"专用三维建模资源校验失败。"
        case .insufficientHeadroom:"当前可用内存不足，暂时无法开始三维建模。"
        case .emptyShape:"本次未能生成有效三维表面。"
        case .invalidGeometry:"生成的三维表面未通过完整性检查。"
        case .simulatorUnsupported:"本机三维模型生成需要真实Apple设备。"
        }
    }
}

public enum HunyuanShape21Configuration {
    public static let modelID="tencent/Hunyuan3D-2.1/hunyuan3d-dit-v2-1"
    public static let modelSourceRevision="0b94677654c57bb9a6b6845cd7b704ccf551d327"
    public static let modelPackBytes:Int64=2_490_378_616
    public static let modelPackSHA256="69cd908e83bbf51200c63a2a163e2dfd34d2be0571c33b92f4a922489c564842"
    public static let configurationSHA256="a9e9b66f0163a9b827d730633ac88f47fcc8e3071dcbb9ee12d88ef7537c5c6e"
    public static let minimumAvailableProcessBytes:UInt64=11*1_073_741_824/2
    public static var bundledYAML:String {
        get throws {
            guard let url=Bundle.module.url(forResource:"hunyuan-shape-2.1",withExtension:"yaml")
                ?? Bundle.module.url(forResource:"hunyuan-shape-2.1",withExtension:"yaml",subdirectory:"Resources") else {throw ShapeError.invalidConfiguration}
            let value=try String(contentsOf:url,encoding:.utf8)
            try validate(value);return value
        }
    }
    static func validate(_ text:String)throws {
        guard digest(Data(text.utf8))==configurationSHA256 else {throw ShapeError.invalidConfiguration}
    }
    static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}
