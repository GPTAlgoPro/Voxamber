import Foundation

/// One whole-mesh linear Rec.709/sRGB material. RGBA factors are linear, not gamma-encoded
/// display colors. This does not claim generated texture or semantic editing.
public struct ShapeWholeMaterial:Codable,Sendable,Equatable {
    public let rgba:[Double]
    public let metallic:Double
    public let roughness:Double
    public init(rgba:[Double],metallic:Double,roughness:Double)throws {
        self.rgba=rgba;self.metallic=metallic;self.roughness=roughness;try validate()
    }
    func validate()throws {
        guard rgba.count==4,rgba.allSatisfy({$0.isFinite && (0...1).contains($0)}),
              metallic.isFinite,(0...1).contains(metallic),roughness.isFinite,(0...1).contains(roughness) else {throw ShapeEditError.invalidMaterial}
    }
}

public struct ShapeEditRecipe:Codable,Sendable,Equatable {
    public let formatVersion:Int
    public let translationXYZ:[Double]
    public let rotationXYZdegrees:[Double]
    public let positiveScaleXYZ:[Double]
    public let wholeMaterial:ShapeWholeMaterial?
    public init(translationXYZ:[Double]=[0,0,0],rotationXYZdegrees:[Double]=[0,0,0],
                positiveScaleXYZ:[Double]=[1,1,1],wholeMaterial:ShapeWholeMaterial?=nil)throws {
        formatVersion=1;self.translationXYZ=translationXYZ;self.rotationXYZdegrees=rotationXYZdegrees
        self.positiveScaleXYZ=positiveScaleXYZ;self.wholeMaterial=wholeMaterial;try validate()
    }
    func validate()throws {
        guard formatVersion==1,translationXYZ.count==3,rotationXYZdegrees.count==3,positiveScaleXYZ.count==3,
              translationXYZ.allSatisfy(\.isFinite),rotationXYZdegrees.allSatisfy(\.isFinite),
              positiveScaleXYZ.allSatisfy({$0.isFinite && $0>0}) else {throw ShapeEditError.invalidTransform}
        try wholeMaterial?.validate()
    }
}

public enum ShapeEditLimits {
    /// Model-coordinate bounds, not proof that normalized Shape units are metres.
    public static let maximumAbsoluteOutputCoordinate:Double=1_000_000
    public static let maximumOutputExtent:Double=1_000_000
}
public enum ShapeEditError:LocalizedError,Sendable {
    case invalidTransform,invalidMaterial,invalidBaseGeometry,outputOutOfRange,floatDegeneration,baseArchiveMismatch
    public var errorDescription:String? {
        switch self {
        case .invalidTransform:"变换必须使用有限数值和正数缩放。"
        case .invalidMaterial:"材质必须使用有效的颜色、金属度与粗糙度。"
        case .invalidBaseGeometry:"原始网格未通过编辑完整性检查。"
        case .outputOutOfRange:"变换后的坐标或尺寸超出导出范围。"
        case .floatDegeneration:"当前变换会使导出网格丢失浮点精度，请调整平移或缩放。"
        case .baseArchiveMismatch:"原始网格文件与编辑输入不一致。"
        }
    }
}

public struct ShapeEditValidationReceipt:Codable,Sendable {
    public let version:Int
    public let method:String
    public let baseMeshFormatID:String
    public let baseMeshFormatVersion:Int
    public let baseMeshSHA256:String
    public let recipeSHA256:String
    public let renderGeometryLayoutVersion:Int
    public let vertexCount:Int
    public let triangleCount:Int
    public let indexCount:Int
    public let glbByteCount:Int64
    public let usdzByteCount:Int64
    public let glbSHA256:String
    public let usdzSHA256:String
    public let boundsMinimum:[Float]
    public let boundsMaximum:[Float]
    public let topologyPreserved:Bool
    public let normalsInverseTransposeNormalized:Bool
    public let wholeMaterialApplied:Bool
    public let baseUnchanged:Bool
    public let actualNeuralWeightsUsed:Bool
}
public struct ShapeEditResult:Sendable {
    public let mesh:ShapeMeshBuffers
    public let glbData:Data
    public let usdzData:Data
    public let boundsMinimum:[Float]
    public let boundsMaximum:[Float]
    public let durationSeconds:Double
    public let validationReceipt:ShapeEditValidationReceipt
    public var statistics:ShapeEditStatistics {
        .init(vertexCount:mesh.vertexCount,triangleCount:mesh.triangleCount,indexCount:mesh.indices.count,
            meshCount:1,boundsMinimum:boundsMinimum,boundsMaximum:boundsMaximum,durationSeconds:durationSeconds)
    }
}
public struct ShapeEditStatistics:Codable,Sendable {
    public let vertexCount:Int
    public let triangleCount:Int
    public let indexCount:Int
    public let meshCount:Int
    public let boundsMinimum:[Float]
    public let boundsMaximum:[Float]
    public let durationSeconds:Double
}
