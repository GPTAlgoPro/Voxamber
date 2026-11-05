import CreationCore

public enum DimensionTerm: Sendable, Equatable {
    case literal(Float)
    case variable(String)
}

public struct DraftDimensions: Sendable, Equatable {
    public let width: DimensionTerm
    public let height: DimensionTerm
    public let depth: DimensionTerm

    public init(width: DimensionTerm, height: DimensionTerm, depth: DimensionTerm) {
        self.width = width; self.height = height; self.depth = depth
    }

    var terms: [DimensionTerm] { [width, height, depth] }
}

/// No numeric SceneNode.size competes with the explicitly typed dimensions.
public struct MeasurementNodeDraft: Sendable, Equatable {
    public let id: String
    public let primitive: SceneNode.Primitive
    public let dimensions: DraftDimensions
    public let position: [Float]
    public let rotation: [Float]
    public let color: String
    public let metallic: Float
    public let roughness: Float
    public let profile: [[Float]]?
    public let path: [[Float]]?
    public let vertices: [[Float]]?
    public let triangles: [[UInt32]]?
    public let parentID: String?
    public let attachment: SceneNode.Attachment?
    public let offset: [Float]?

    public init(id: String, primitive: SceneNode.Primitive, dimensions: DraftDimensions,
                position: [Float], rotation: [Float], color: String, metallic: Float,
                roughness: Float, profile: [[Float]]? = nil, path: [[Float]]? = nil,
                vertices: [[Float]]? = nil, triangles: [[UInt32]]? = nil,
                parentID: String? = nil, attachment: SceneNode.Attachment? = nil,
                offset: [Float]? = nil) {
        self.id = id; self.primitive = primitive; self.dimensions = dimensions
        self.position = position; self.rotation = rotation; self.color = color
        self.metallic = metallic; self.roughness = roughness; self.profile = profile
        self.path = path; self.vertices = vertices; self.triangles = triangles
        self.parentID = parentID; self.attachment = attachment; self.offset = offset
    }

    func substituting(_ value: Float) -> SceneNode {
        SceneNode(id: id, primitive: primitive, position: position,
                  size: dimensions.terms.map { term in
                      switch term { case .literal(let number): number; case .variable: value }
                  }, rotation: rotation, color: color, metallic: metallic, roughness: roughness,
                  profile: profile, path: path, vertices: vertices, triangles: triangles,
                  parentID: parentID, attachment: attachment, offset: offset)
    }
}

public enum MeasurementAxis: Int, Sendable, Equatable { case x = 0, y = 1, z = 2 }

public enum MeasurementTarget: Sendable, Equatable {
    /// World-space maximum coordinate, not this node's declared dimension.
    case nodeMaximum(id: String, axis: MeasurementAxis)
    /// Actual scene AABB maximum minus minimum along the chosen axis.
    case sceneExtent(axis: MeasurementAxis)
}

/// Separate endpoints deliberately permit invalid input to throw instead of
/// trapping while constructing a reversed or nonfinite ClosedRange.
public struct ScalarInterval: Sendable, Equatable {
    public let lower: Float
    public let upper: Float
    public init(lower: Float, upper: Float) { self.lower = lower; self.upper = upper }
}

public struct MeasurementConstraint: Sendable, Equatable {
    public let variable: String
    public let target: MeasurementTarget
    public let targetMetres: Double
    public let interval: ScalarInterval
    public init(variable: String, target: MeasurementTarget, targetMetres: Double,
                interval: ScalarInterval) {
        self.variable = variable; self.target = target
        self.targetMetres = targetMetres; self.interval = interval
    }
}

public struct MeasurementDraft: Sendable, Equatable {
    public let name: String
    public let nodes: [MeasurementNodeDraft]
    /// Exactly one constraint; multiple variables/equations are outside this API.
    public let constraint: MeasurementConstraint
    public init(name: String, nodes: [MeasurementNodeDraft], constraint: MeasurementConstraint) {
        self.name = name; self.nodes = nodes; self.constraint = constraint
    }
}

public struct MeasurementEvaluation: Sendable, Equatable {
    public let variableValue: Float
    /// Only declared dimensions were substituted; original transforms/relations remain.
    public let declaredScene: SceneSpec
    /// Separate standard Core attachment/ground result, used for actual measurement.
    public let canonicalScene: SceneSpec
    public let measuredMetres: Double
}

public struct MeasurementSolution: Sendable, Equatable {
    public let evaluation: MeasurementEvaluation
    public let absoluteErrorMetres: Double
    public let iterations: Int
    public let evaluationCount: Int
}

public enum MeasurementKernelError: Error, Sendable, Equatable {
    case invalidConstraint
    case invalidInterval
    case invalidIterationBudget
    case conflictingVariable
    case unreferencedVariable
    case unknownTargetNode
    case invalidBounds
    case unbracketedTarget
    case underconstrainedEndpoints
    case floatCannotSubdivide
    case iterationBudgetExhausted
}
