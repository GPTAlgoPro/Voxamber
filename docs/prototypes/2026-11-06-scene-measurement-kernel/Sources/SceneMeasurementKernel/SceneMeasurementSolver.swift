import Foundation
import CreationCore

public enum SceneMeasurementSolver {
    public static let toleranceMetres: Double = 0.001

    /// Finds one endpoint-bracketed, remeasured root. No monotonicity or
    /// uniqueness claim, no dimensional expressions, and no changes to literals.
    public static func solve(_ draft: MeasurementDraft,
                             maximumIterations: Int = 32) throws -> MeasurementSolution {
        try Task.checkCancellation()
        guard (1...64).contains(maximumIterations) else {
            throw MeasurementKernelError.invalidIterationBudget
        }
        try validate(draft)
        var evaluations = 0
        func sample(_ value: Float) throws -> MeasurementEvaluation {
            try Task.checkCancellation()
            evaluations += 1
            return try evaluateValidated(draft, at: value)
        }
        func finish(_ value: Float, iterations: Int) throws -> MeasurementSolution {
            // Deliberately independent final Core generation/measurement.
            let result = try sample(value)
            let error = abs(result.measuredMetres - draft.constraint.targetMetres)
            guard error.isFinite, error <= toleranceMetres else {
                throw MeasurementKernelError.iterationBudgetExhausted
            }
            try Task.checkCancellation()
            return .init(evaluation: result, absoluteErrorMetres: error,
                         iterations: iterations, evaluationCount: evaluations)
        }

        var lower = draft.constraint.interval.lower
        var upper = draft.constraint.interval.upper
        var lowerResidual = try sample(lower).measuredMetres - draft.constraint.targetMetres
        let upperResidual = try sample(upper).measuredMetres - draft.constraint.targetMetres
        guard lowerResidual.isFinite, upperResidual.isFinite else {
            throw MeasurementKernelError.invalidBounds
        }
        let lowerMatches = abs(lowerResidual) <= toleranceMetres
        let upperMatches = abs(upperResidual) <= toleranceMetres
        guard !(lowerMatches && upperMatches) else {
            throw MeasurementKernelError.underconstrainedEndpoints
        }
        if lowerMatches { return try finish(lower, iterations: 0) }
        if upperMatches { return try finish(upper, iterations: 0) }
        guard oppositeSigns(lowerResidual, upperResidual) else {
            throw MeasurementKernelError.unbracketedTarget
        }

        for iteration in 1...maximumIterations {
            try Task.checkCancellation()
            let middle = Float(Double(lower) + (Double(upper) - Double(lower)) / 2)
            guard middle > lower, middle < upper else {
                throw MeasurementKernelError.floatCannotSubdivide
            }
            let residual = try sample(middle).measuredMetres - draft.constraint.targetMetres
            guard residual.isFinite else { throw MeasurementKernelError.invalidBounds }
            if abs(residual) <= toleranceMetres { return try finish(middle, iterations: iteration) }
            // Opposite-sign bracketing also works for a continuous nonmonotonic
            // function; it does not enumerate additional roots.
            if oppositeSigns(lowerResidual, residual) { upper = middle }
            else { lower = middle; lowerResidual = residual }
        }
        throw MeasurementKernelError.iterationBudgetExhausted
    }

    public static func evaluate(_ draft: MeasurementDraft,
                                at value: Float) throws -> MeasurementEvaluation {
        try Task.checkCancellation()
        try validate(draft)
        return try evaluateValidated(draft, at: value)
    }

    private static func validate(_ draft: MeasurementDraft) throws {
        let constraint = draft.constraint
        let name = constraint.variable
        guard !name.isEmpty, name.utf8.count <= 64, name.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 95
        }), constraint.targetMetres.isFinite else { throw MeasurementKernelError.invalidConstraint }
        if case .sceneExtent = constraint.target, constraint.targetMetres <= 0 {
            throw MeasurementKernelError.invalidConstraint
        }
        let interval = constraint.interval
        guard interval.lower.isFinite, interval.upper.isFinite,
              interval.lower > 0, interval.lower < interval.upper else {
            throw MeasurementKernelError.invalidInterval
        }
        // Keep the public production Core resource contract before traversing input.
        guard (1...SceneSpec.maximumNodes).contains(draft.nodes.count) else {
            throw CreationError.budgetExceeded("每件作品须包含 1–32 个部件。")
        }
        var references = 0
        for node in draft.nodes {
            try Task.checkCancellation()
            for term in node.dimensions.terms {
                if case .variable(let identifier) = term {
                    guard identifier == name else { throw MeasurementKernelError.conflictingVariable }
                    references += 1
                }
            }
        }
        guard references > 0 else { throw MeasurementKernelError.unreferencedVariable }
        if case .nodeMaximum(let id, _) = constraint.target,
           !draft.nodes.contains(where: { $0.id == id }) {
            throw MeasurementKernelError.unknownTargetNode
        }
        // The declared scalar interval must fit the existing Core dimension
        // contract at both ends; never clip it to make a request acceptable.
        for endpoint in [interval.lower, interval.upper] {
            try Task.checkCancellation()
            try SceneSpec(name: draft.name, nodes: draft.nodes.map {
                $0.substituting(endpoint)
            }).validate()
        }
    }

    private static func evaluateValidated(_ draft: MeasurementDraft,
                                          at value: Float) throws -> MeasurementEvaluation {
        try Task.checkCancellation()
        guard value.isFinite, value >= draft.constraint.interval.lower,
              value <= draft.constraint.interval.upper else { throw MeasurementKernelError.invalidInterval }
        let nodes = try draft.nodes.map { node in
            try Task.checkCancellation()
            return node.substituting(value)
        }
        let declared = SceneSpec(name: draft.name, nodes: nodes)
        try declared.validate()
        let canonical = try SceneAttachmentResolver.resolve(declared)
        try Task.checkCancellation()
        // Includes aggregate geometry budgets, not merely one node's bounds.
        let meshes = try SceneGenerator.generate(for: canonical)
        guard meshes.count == canonical.nodes.count else { throw MeasurementKernelError.invalidBounds }
        var lower = [Double](repeating: .infinity, count: 3)
        var upper = [Double](repeating: -.infinity, count: 3)
        var selectedUpper: [Double]?
        for (index, mesh) in meshes.enumerated() {
            try Task.checkCancellation()
            guard !mesh.positions.isEmpty, mesh.positions.count % 3 == 0 else {
                throw MeasurementKernelError.invalidBounds
            }
            var nodeUpper = [Double](repeating: -.infinity, count: 3)
            for (offset, value) in mesh.positions.enumerated() {
                if offset % 768 == 0 { try Task.checkCancellation() }
                guard value.isFinite else { throw MeasurementKernelError.invalidBounds }
                let axis = offset % 3, number = Double(value)
                lower[axis] = min(lower[axis], number)
                upper[axis] = max(upper[axis], number)
                nodeUpper[axis] = max(nodeUpper[axis], number)
            }
            if case .nodeMaximum(let id, _) = draft.constraint.target,
               canonical.nodes[index].id == id { selectedUpper = nodeUpper }
        }
        guard (lower + upper).allSatisfy(\.isFinite) else { throw MeasurementKernelError.invalidBounds }
        let measured: Double
        switch draft.constraint.target {
        case .nodeMaximum(_, let axis):
            guard let selectedUpper else { throw MeasurementKernelError.unknownTargetNode }
            measured = selectedUpper[axis.rawValue]
        case .sceneExtent(let axis): measured = upper[axis.rawValue] - lower[axis.rawValue]
        }
        guard measured.isFinite else { throw MeasurementKernelError.invalidBounds }
        try Task.checkCancellation()
        return .init(variableValue: value, declaredScene: declared,
                     canonicalScene: canonical, measuredMetres: measured)
    }

    private static func oppositeSigns(_ a: Double, _ b: Double) -> Bool {
        (a < 0 && b > 0) || (a > 0 && b < 0)
    }
}
