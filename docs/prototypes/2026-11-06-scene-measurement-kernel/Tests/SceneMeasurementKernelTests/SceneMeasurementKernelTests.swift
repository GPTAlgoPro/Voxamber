import Foundation
import Testing
import CreationCore
@testable import SceneMeasurementKernel

@Suite struct SceneMeasurementKernelTests {
    @Test func totalHeightUsesNativeAttachmentOverlapAndGrounding() throws {
        let input = draft([
            part("n0", height: .literal(0.2), width: .literal(0.5), offset: [0,0,0]),
            part("n1", height: .variable("v"), parent: "n0", face: .top),
            part("n2", height: .literal(0.15), parent: "n1", face: .top)
        ], target: .sceneExtent(axis: .y), metres: 1.2)
        let result = try SceneMeasurementSolver.solve(input)
        #expect(abs(Double(result.evaluation.variableValue) - 0.856) < 0.0011)
        #expect(result.absoluteErrorMetres <= 0.001)
        let meshes = try SceneGenerator.generate(for: result.evaluation.declaredScene)
        let y = meshes.flatMap { mesh in stride(from: 1, to: mesh.positions.count, by: 3).map { Double(mesh.positions[$0]) } }
        #expect(abs((try #require(y.max())) - (try #require(y.min())) - 1.2) <= 0.001)
        #expect(result.evaluation.declaredScene.nodes[1].position == [0,0,0])
        #expect(result.evaluation.declaredScene.nodes[1].parentID == "n0")
        #expect(result.evaluation.canonicalScene.nodes[1].parentID == nil)
        #expect(result.evaluationCount == result.iterations + 3)
        #expect(result.evaluationCount <= 35)
    }

    @Test func onlyExplicitlyNamedNodeSurfaceIsMeasured() throws {
        let input = draft([
            part("n0", height: .variable("v"), position: [0,0.2,0]),
            part("n1", height: .literal(0.4), position: [1,1.2,0])
        ], target: .nodeMaximum(id: "n0", axis: .y), metres: 0.6)
        let solved = try SceneMeasurementSolver.solve(input)
        #expect(abs(Double(solved.evaluation.variableValue) - 0.8) < 0.0021)
        let other = try SceneGenerator.bounds(for: solved.evaluation.canonicalScene.nodes[1])
        #expect(other.maximum[1] > 1.3)
        #expect(abs(solved.evaluation.measuredMetres - 0.6) <= 0.001)
    }

    @Test func multipleDimensionsExplicitlyShareOneUnknownWithoutIDHeuristics() throws {
        let input = draft([
            part("q", height: .literal(0.12), width: .literal(0.6), depth: .literal(0.6), offset: [0,0,0]),
            part("a7", height: .variable("v"), parent: "q", face: .bottom, offset: [-0.2,0,-0.2]),
            part("z2", height: .variable("v"), parent: "q", face: .bottom, offset: [0.2,0,-0.2]),
            part("b9", height: .variable("v"), parent: "q", face: .bottom, offset: [-0.2,0,0.2]),
            part("c4", height: .variable("v"), parent: "q", face: .bottom, offset: [0.2,0,0.2])
        ], target: .sceneExtent(axis: .y), metres: 0.9)
        let solved = try SceneMeasurementSolver.solve(input)
        let sizes = solved.evaluation.declaredScene.nodes.dropFirst().map { $0.size[1] }
        #expect(Set(sizes).count == 1)
        #expect(abs(Double(try #require(sizes.first)) - 0.783) < 0.0011)
        #expect(solved.absoluteErrorMetres <= 0.001)
    }

    @Test func nonAxisAlignedBoundsUseActualRotationRatherThanHeightField() throws {
        let angle = 37.0 * Double.pi / 180
        let target = (0.6 * sin(angle) + 1.2 * cos(angle)) / 2
        let input = draft([part("p", height: .variable("v"), width: .literal(0.6),
                                rotation: [0,0,37])],
                          target: .nodeMaximum(id: "p", axis: .y), metres: target)
        let solved = try SceneMeasurementSolver.solve(input)
        #expect(abs(Double(solved.evaluation.variableValue) - 1.2) < 0.003)
        #expect(abs(solved.evaluation.measuredMetres - target) <= 0.001)
        #expect(solved.evaluation.declaredScene.nodes[0].rotation == [0,0,37])
    }

    @Test func freeformMeasurementUsesTheRealAsymmetricRotatedMesh() throws {
        let polygon: [[Float]] = [[0,0],[2,0],[1.4,1],[0,0.5]]
        let node = part("f", height: .variable("v"), primitive: .extrusion,
                        rotation: [15,-20,31], profile: polygon)
        let probe = draft([node], target: .nodeMaximum(id: "f", axis: .y), metres: 0.5)
        let reference = SceneNode(id: "f", primitive: .extrusion, position: [0,0,0],
                                  size: [0.3,1.1,0.3], rotation: [15,-20,31],
                                  color: "#3487AB", metallic: 0.23, roughness: 0.61, profile: polygon)
        let target = try SceneGenerator.bounds(for: reference).maximum[1]
        let input = MeasurementDraft(name: probe.name, nodes: probe.nodes,
                                    constraint: .init(variable: "v", target: probe.constraint.target,
                                                      targetMetres: target, interval: probe.constraint.interval))
        let solved = try SceneMeasurementSolver.solve(input)
        #expect(abs(solved.evaluation.measuredMetres - target) <= 0.001)
        #expect(abs(Double(solved.evaluation.variableValue) - 1.1) < 0.005)
        #expect(solved.evaluation.declaredScene.nodes[0].profile == polygon)
        #expect(abs(target - 1.1) > 0.1)
    }

    @Test func multipleAbsoluteRootsAndEveryUnspecifiedFieldRemainUnchanged() throws {
        let polygon: [[Float]] = [[0,0],[1,0],[0,1]]
        let variable = part("r0", height: .variable("v"), width: .literal(0.4),
                            position: [-0.8,0.4,0.2], rotation: [12,-7,19])
        let fixed = part("r1", height: .literal(0.35), primitive: .extrusion,
                         position: [1.2,0.7,-0.3], rotation: [-8,13,4], profile: polygon)
        let input = draft([variable,fixed], target: .sceneExtent(axis: .y), metres: 1.1)
        let before = input
        let solved = try SceneMeasurementSolver.solve(input)
        #expect(input == before)
        let declared = solved.evaluation.declaredScene
        #expect(declared.nodes[0].position == variable.position)
        #expect(declared.nodes[0].rotation == variable.rotation)
        #expect(declared.nodes[0].size[0] == 0.4 && declared.nodes[0].size[2] == 0.3)
        #expect(declared.nodes[0].color == variable.color)
        #expect(declared.nodes[0].metallic == variable.metallic)
        #expect(declared.nodes[0].roughness == variable.roughness)
        let expectedFixed = SceneNode(id: "r1", primitive: .extrusion, position: [1.2,0.7,-0.3],
                                      size: [0.3,0.35,0.3], rotation: [-8,13,4],
                                      color: "#3487AB", metallic: 0.23, roughness: 0.61, profile: polygon)
        #expect(declared.nodes[1] == expectedFixed)
        #expect(solved.evaluation.canonicalScene == declared)
    }

    @Test func aContinuousNonmonotonicBracketReturnsOneVerifiedRootOnly() throws {
        // Rotated triangle max Y is |1-v|/(2*sqrt(2)), not a monotonic function.
        let node = part("u", height: .variable("v"), width: .literal(1), primitive: .extrusion,
                        rotation: [0,0,45], profile: [[0,0],[1,0],[0,1]])
        let input = draft([node], target: .nodeMaximum(id: "u", axis: .y), metres: 0.3,
                          lower: 0.2, upper: 2)
        let atLower = try SceneMeasurementSolver.evaluate(input, at: 0.2).measuredMetres
        let atValley = try SceneMeasurementSolver.evaluate(input, at: 1).measuredMetres
        let atUpper = try SceneMeasurementSolver.evaluate(input, at: 2).measuredMetres
        #expect(atValley < atLower && atValley < atUpper)
        let solved = try SceneMeasurementSolver.solve(input)
        #expect(solved.evaluation.variableValue > 1)
        #expect(abs(Double(solved.evaluation.variableValue) - (1 + 0.6 * sqrt(2))) < 0.004)
        #expect(solved.absoluteErrorMetres <= 0.001)
    }

    @Test(arguments: [MeasurementAxis.x, .z])
    func explicitHorizontalAxesUseTheirOwnDimensions(axis: MeasurementAxis) throws {
        let node = part("a", height: .literal(0.4),
                        width: axis == .x ? .variable("v") : .literal(0.3),
                        depth: axis == .z ? .variable("v") : .literal(0.3),
                        position: [-0.3,0.1,0.5])
        let input = draft([node], target: .sceneExtent(axis: axis), metres: 1.15)
        let solved = try SceneMeasurementSolver.solve(input)
        #expect(solved.absoluteErrorMetres <= 0.001)
        #expect(abs(Double(solved.evaluation.variableValue) - 1.15) < 0.0011)
        #expect(solved.evaluation.declaredScene.nodes[0].position == node.position)
        #expect(solved.evaluation.declaredScene.nodes[0].size[1] == 0.4)
    }

    @Test func multipleRootsWithRelationsKeepCoreWholeForestGrounding() throws {
        let input = draft([
            part("r0", height: .literal(0.2), position: [-1,0,0]),
            part("r1", height: .literal(0.4), position: [1,0.8,0]),
            part("a", height: .variable("v"), parent: "r0", face: .top),
            part("b", height: .literal(0.15), parent: "r1", face: .top)
        ], target: .sceneExtent(axis: .y), metres: 1.4)
        let solved = try SceneMeasurementSolver.solve(input)
        #expect(solved.absoluteErrorMetres <= 0.001)
        #expect(solved.evaluation.declaredScene.nodes.map(\.id) == ["r0","r1","a","b"])
        #expect(solved.evaluation.declaredScene.nodes[0].position == [-1,0,0])
        #expect(solved.evaluation.declaredScene.nodes[1].position == [1,0.8,0])
        let canonical = solved.evaluation.canonicalScene
        #expect(canonical.nodes.count == 4)
        #expect(abs(Double(canonical.nodes[1].position[1] - canonical.nodes[0].position[1]) - 0.8) < 1e-6)
        #expect(canonical.nodes[0].position[0] == -1 && canonical.nodes[1].position[0] == 1)
        let minimum = try canonical.nodes.map { try SceneGenerator.bounds(for: $0).minimum[1] }.min()
        #expect(abs(try #require(minimum)) < 1e-6)
    }

    @Test func unbracketedInteriorRootsAreConservativelyRejected() {
        let node = part("u", height: .variable("v"), width: .literal(1), primitive: .extrusion,
                        rotation: [0,0,45], profile: [[0,0],[1,0],[0,1]])
        let input = draft([node], target: .nodeMaximum(id: "u", axis: .y), metres: 0.2,
                          lower: 0.2, upper: 2)
        #expect(throws: MeasurementKernelError.unbracketedTarget) { try SceneMeasurementSolver.solve(input) }
    }

    @Test func constantMeasurementCannotInventAnUnrelatedDimensionChange() {
        let node = part("c", height: .literal(1), depth: .variable("v"))
        #expect(throws: MeasurementKernelError.underconstrainedEndpoints) {
            try SceneMeasurementSolver.solve(draft([node], target: .nodeMaximum(id: "c", axis: .y), metres: 0.5))
        }
        #expect(throws: MeasurementKernelError.unbracketedTarget) {
            try SceneMeasurementSolver.solve(draft([node], target: .nodeMaximum(id: "c", axis: .y), metres: 0.8))
        }
    }

    @Test func unreachableTargetAndInsufficientIterationBudgetThrow() {
        let node = part("c", height: .variable("v"))
        #expect(throws: MeasurementKernelError.unbracketedTarget) {
            try SceneMeasurementSolver.solve(draft([node], target: .sceneExtent(axis: .y), metres: 10))
        }
        #expect(throws: MeasurementKernelError.iterationBudgetExhausted) {
            try SceneMeasurementSolver.solve(draft([node], target: .sceneExtent(axis: .y), metres: 1.234), maximumIterations: 1)
        }
        #expect(throws: MeasurementKernelError.invalidIterationBudget) {
            try SceneMeasurementSolver.solve(draft([node], target: .sceneExtent(axis: .y), metres: 1), maximumIterations: 65)
        }
    }

    @Test func badIntervalsAndOutOfCoreDimensionBoundsAreNeverClipped() {
        let node = part("c", height: .variable("v"))
        for (lower, upper): (Float, Float) in [(1,1),(2,1),(.nan,1),(0,1),(-1,1),(1,.infinity)] {
            #expect(throws: MeasurementKernelError.invalidInterval) {
                try SceneMeasurementSolver.solve(draft([node], target: .sceneExtent(axis: .y), metres: 1,
                                                       lower: lower, upper: upper))
            }
        }
        for (lower, upper): (Float, Float) in [(0.01,1),(0.2,2.6)] {
            #expect(throws: CreationError.self) {
                try SceneMeasurementSolver.solve(draft([node], target: .sceneExtent(axis: .y), metres: 1,
                                                       lower: lower, upper: upper))
            }
        }
        let input = draft([node], target: .sceneExtent(axis: .y), metres: 1)
        for value: Float in [0.19, 1.81, .nan, .infinity] {
            #expect(throws: MeasurementKernelError.invalidInterval) {
                try SceneMeasurementSolver.evaluate(input, at: value)
            }
        }
    }

    @Test func variablesAndTargetsMustBeExplicitUnambiguousAndReferenced() {
        #expect(throws: MeasurementKernelError.unreferencedVariable) {
            try SceneMeasurementSolver.solve(draft([part("p", height: .literal(1))], target: .sceneExtent(axis: .y), metres: 1))
        }
        #expect(throws: MeasurementKernelError.conflictingVariable) {
            try SceneMeasurementSolver.solve(draft([part("p", height: .variable("v"), depth: .variable("other"))],
                                                   target: .sceneExtent(axis: .y), metres: 1))
        }
        #expect(throws: MeasurementKernelError.unknownTargetNode) {
            try SceneMeasurementSolver.solve(draft([part("p", height: .variable("v"))],
                                                   target: .nodeMaximum(id: "absent", axis: .y), metres: 1))
        }
        #expect(throws: MeasurementKernelError.invalidConstraint) {
            try SceneMeasurementSolver.solve(draft([part("p", height: .variable("v"))], target: .sceneExtent(axis: .y), metres: .nan))
        }
    }

    @Test func duplicateIDsMissingParentsCyclesAndInvalidMeshAreRejected() {
        let repeated = part("p", height: .variable("v"))
        let invalids = [
            [repeated,repeated],
            [part("p", height: .variable("v"), parent: "absent", face: .top)],
            [part("p", height: .variable("v"), parent: "q", face: .top),
             part("q", height: .literal(0.2), parent: "p", face: .top)],
            [part("p", height: .variable("v"), primitive: .mesh,
                  vertices: [[0,0,0],[1,0,0],[0,1,0]], triangles: [[0,1,4]])]
        ]
        for nodes in invalids {
            #expect(throws: CreationError.self) {
                try SceneMeasurementSolver.solve(draft(nodes, target: .sceneExtent(axis: .y), metres: 1))
            }
        }
    }

    @Test func nodeAndActualAggregateGeometryBudgetsRemainEnforced() {
        let tooMany = (0..<33).map { part("p\($0)", height: .variable("v")) }
        #expect(throws: CreationError.self) {
            try SceneMeasurementSolver.solve(draft(tooMany, target: .sceneExtent(axis: .y), metres: 1))
        }
        let profile = (0..<64).map { [Float($0 % 2 + 1), Float($0)] }
        let expensive = (0..<32).map { part("p\($0)", height: .variable("v"), primitive: .lathe, profile: profile) }
        do {
            _ = try SceneMeasurementSolver.solve(draft(expensive, target: .sceneExtent(axis: .y), metres: 1))
            Issue.record("Aggregate native mesh budget must reject this request")
        } catch let error as CreationError {
            if case .budgetExceeded = error { } else { Issue.record("Expected aggregate resource failure, got \(error)") }
        } catch { Issue.record("Unexpected error \(error)") }
    }

    @Test func cancellationReturnsNoSyntheticSolution() async {
        let input = draft([part("p", height: .variable("v"))], target: .sceneExtent(axis: .y), metres: 1.23)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SceneMeasurementSolver.solve(input)
        }
        do { _ = try await task.value; Issue.record("Cancelled solver must not publish a scene") }
        catch is CancellationError { }
        catch { Issue.record("Expected cancellation, got \(error)") }
    }
}

private func part(_ id: String, height: DimensionTerm, width: DimensionTerm = .literal(0.3),
                  depth: DimensionTerm = .literal(0.3), primitive: SceneNode.Primitive = .box,
                  position: [Float] = [0,0,0], rotation: [Float] = [0,0,0], profile: [[Float]]? = nil,
                  vertices: [[Float]]? = nil, triangles: [[UInt32]]? = nil, parent: String? = nil,
                  face: SceneNode.Attachment? = nil, offset: [Float]? = nil) -> MeasurementNodeDraft {
    .init(id: id, primitive: primitive, dimensions: .init(width: width, height: height, depth: depth),
          position: position, rotation: rotation, color: "#3487AB", metallic: 0.23, roughness: 0.61,
          profile: profile, vertices: vertices, triangles: triangles, parentID: parent,
          attachment: face, offset: offset)
}

private func draft(_ nodes: [MeasurementNodeDraft], target: MeasurementTarget, metres: Double,
                   lower: Float = 0.2, upper: Float = 1.8) -> MeasurementDraft {
    .init(name: "Synthetic explicit constraint", nodes: nodes,
          constraint: .init(variable: "v", target: target, targetMetres: metres,
                            interval: .init(lower: lower, upper: upper)))
}
