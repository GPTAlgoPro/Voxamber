import Foundation
import Testing
@testable import CreationCore

@Suite struct SceneAssemblyPlannerTests {
    private static let request = "A small sphere on the front-right of a plain cube."
    private static let outline = #"{"name":"Synthetic","parts":[{"id":"root","primitive":"box","purpose":"main body"},{"id":"tip","primitive":"sphere","purpose":"front-right decoration","parent":"root","face":"top"}]}"#
    private static let placement = #"{"anchors":[{"id":"tip","anchor":"frontRight"}]}"#
    private static let geometry = ##"{"name":"Synthetic","nodes":[{"id":"root","primitive":"box","dimensions":{"width":1,"height":1,"depth":1},"color":"#123456"},{"id":"tip","primitive":"sphere","dimensions":{"width":0.2,"height":0.2,"depth":0.2},"color":"#ABCDEF","attach":{"parent":"root","face":"top","anchor":"frontRight"}}]}"##

    @Test func threeFreshCallsUseTheirPredecessorsAndReturnCanonicalGeometry() async throws {
        let fake = FakeAssemblyGenerator(responses: [Self.outline, Self.placement, Self.geometry])
        let scene = try await SceneAssemblyPlanner.generate(request: Self.request,
            generate: { try await fake.generate($0) }, onPhase: { await fake.phase($0) })
        let outline = try SceneAssemblyOutline.decodeModelResponse(Self.outline)
        let placement = try SceneAssemblyPlacement.decodeModelResponse(Self.placement, outline: outline)
        let calls = await fake.calls
        #expect(calls == [
            try SceneAssemblyProtocol.outlineRequest(Self.request),
            try SceneAssemblyProtocol.placementRequest(Self.request, outline: outline),
            try SceneAssemblyProtocol.geometryRequest(Self.request, outline: outline, placement: placement)
        ])
        #expect(await fake.events == ["phase:outline", "generate:1", "phase:placement", "generate:2", "phase:geometry", "generate:3"])
        // The prior native contract owns grounding and the 3 mm attachment
        // overlap; the planner must preserve that behavior rather than replace it.
        let legacyPlan = ##"{"name":"Synthetic","nodes":[{"id":"root","primitive":"box","dimensions":{"width":1,"height":1,"depth":1},"color":"#123456"},{"id":"tip","primitive":"sphere","dimensions":{"width":0.2,"height":0.2,"depth":0.2},"color":"#ABCDEF","attach":{"parent":"root","face":"top","xOffset":0.4,"zOffset":0.4}}]}"##
        let expected = try SceneSpec.decodeModelResponse(legacyPlan)
        #expect(scene == expected)
        #expect(scene.nodes.allSatisfy { $0.parentID == nil && $0.attachment == nil && $0.offset == nil })
        #expect(try SceneGenerator.generate(for: scene) == SceneGenerator.generate(for: expected))
    }

    @Test func invalidOutlineStopsBeforePlacementWithoutReplacingIt() async {
        let cycle = #"{"name":"Synthetic","parts":[{"id":"root","primitive":"box","purpose":"body","parent":"root","face":"top"}]}"#
        let fake = FakeAssemblyGenerator(responses: [cycle, Self.placement, Self.geometry])
        do {
            _ = try await SceneAssemblyPlanner.generate(request: Self.request,
                generate: { try await fake.generate($0) }, onPhase: { await fake.phase($0) })
            Issue.record("Invalid outline was accepted or replaced by a fallback")
        } catch is CreationError {} catch { Issue.record("Decoder error was replaced: \(error)") }
        #expect(await fake.calls.count == 1)
        #expect(await fake.events == ["phase:outline", "generate:1"])
    }

    @Test func malformedSpatialChoicePreventsGeometryGeneration() async {
        // topRight is incompatible with the explicitly declared top face.
        let invalid = #"{"anchors":[{"id":"tip","anchor":"topRight"}]}"#
        let fake = FakeAssemblyGenerator(responses: [Self.outline, invalid, Self.geometry])
        do {
            _ = try await SceneAssemblyPlanner.generate(request: Self.request,
                generate: { try await fake.generate($0) }, onPhase: { await fake.phase($0) })
            Issue.record("Invalid placement produced a scene")
        } catch is CreationError {} catch { Issue.record("Decoder error was replaced: \(error)") }
        #expect(await fake.calls.count == 2)
        #expect(await fake.events == ["phase:outline", "generate:1", "phase:placement", "generate:2"])
    }

    @Test func invalidFinalGeometryReturnsAnErrorAndNoScene() async {
        let invalid = Self.geometry.replacingOccurrences(of: #""width":0.2"#, with: #""width":0"#)
        let fake = FakeAssemblyGenerator(responses: [Self.outline, Self.placement, invalid])
        do {
            _ = try await SceneAssemblyPlanner.generate(request: Self.request,
                generate: { try await fake.generate($0) })
            Issue.record("Invalid final geometry was returned or repaired")
        } catch is CreationError {} catch { Issue.record("Decoder error was replaced: \(error)") }
        #expect(await fake.calls.count == 3)
    }

    @Test func cancellationBetweenPhasesPreventsTheGeometryCall() async {
        let fake = FakeAssemblyGenerator(responses: [Self.outline, Self.placement, Self.geometry])
        let task = Task {
            try await SceneAssemblyPlanner.generate(request: Self.request,
                generate: { try await fake.generate($0) }, onPhase: { phase in
                    await fake.phase(phase)
                    if phase == .geometry { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        do { _ = try await task.value; Issue.record("Cancelled planning returned a scene") }
        catch is CancellationError {} catch { Issue.record("Cancellation was replaced: \(error)") }
        #expect(await fake.calls.count == 2)
        #expect(await fake.events.last == "phase:geometry")
    }

    @Test func alreadyCancelledPlanningDoesNotEmitPhasesOrModelCalls() async {
        let fake = FakeAssemblyGenerator(responses: [Self.outline, Self.placement, Self.geometry])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SceneAssemblyPlanner.generate(request: Self.request,
                generate: { try await fake.generate($0) }, onPhase: { await fake.phase($0) })
        }
        do { _ = try await task.value; Issue.record("Cancelled planning started") }
        catch is CancellationError {} catch { Issue.record("Cancellation was replaced: \(error)") }
        #expect(await fake.calls.isEmpty)
        #expect(await fake.events.isEmpty)
    }

    @Test func cancellationAfterAnAwaitedModelResponsePrecedesDecoding() async {
        let fake = FakeAssemblyGenerator(responses: ["not JSON"])
        let task = Task {
            try await SceneAssemblyPlanner.generate(request: Self.request, generate: { call in
                let response = try await fake.generate(call)
                withUnsafeCurrentTask { $0?.cancel() }
                return response
            })
        }
        do { _ = try await task.value; Issue.record("Cancelled response was decoded or returned") }
        catch is CancellationError {} catch { Issue.record("Cancellation lost to decoder: \(error)") }
        #expect(await fake.calls.count == 1)
    }

    @Test func rootOnlyOutlineUsesTheUniqueEmptyPlacementWithoutAModelCall() async throws {
        let outlineText = #"{"name":"Solo","parts":[{"id":"shape","primitive":"box","purpose":"a single generic volume"}]}"#
        let geometry = ##"{"name":"Solo","nodes":[{"id":"shape","primitive":"box","dimensions":{"width":1,"height":1,"depth":1},"color":"#123456"}]}"##
        let fake = FakeAssemblyGenerator(responses: [outlineText, geometry])
        let scene = try await SceneAssemblyPlanner.generate(request: "One simple volume.",
            generate: { try await fake.generate($0) }, onPhase: { await fake.phase($0) })
        let outline = try SceneAssemblyOutline.decodeModelResponse(outlineText)
        let emptyPlacement = try SceneAssemblyPlacement(anchors: [], outline: outline)
        #expect(await fake.calls == [
            try SceneAssemblyProtocol.outlineRequest("One simple volume."),
            try SceneAssemblyProtocol.geometryRequest("One simple volume.", outline: outline, placement: emptyPlacement)
        ])
        #expect(await fake.events == ["phase:outline", "generate:1", "phase:placement", "phase:geometry", "generate:2"])
        #expect(scene == SceneSpec(name: "Solo", nodes: [
            SceneNode(id: "shape", primitive: .box, position: [0, 0.5, 0], size: [1, 1, 1], color: "#123456")
        ]))
    }

    @Test func cancellationDuringEmptyPlacementStillPreventsGeometry() async {
        let outline = #"{"name":"Solo","parts":[{"id":"shape","primitive":"box","purpose":"one volume"}]}"#
        let fake = FakeAssemblyGenerator(responses: [outline, Self.geometry])
        let task = Task {
            try await SceneAssemblyPlanner.generate(request: "One simple volume.",
                generate: { try await fake.generate($0) }, onPhase: { phase in
                    await fake.phase(phase)
                    if phase == .placement { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        do { _ = try await task.value; Issue.record("Cancelled empty-placement path generated geometry") }
        catch is CancellationError {} catch { Issue.record("Cancellation was replaced: \(error)") }
        #expect(await fake.calls.count == 1)
        #expect(await fake.events.last == "phase:placement")
    }

    @Test func phaseCallbackFinishesBeforeItsModelCallStarts() async throws {
        let fake = FakeAssemblyGenerator(responses: [Self.outline, Self.placement, Self.geometry])
        let gate = AssemblyPhaseGate()
        let task = Task {
            try await SceneAssemblyPlanner.generate(request: Self.request,
                generate: { try await fake.generate($0) }, onPhase: { phase in
                    if phase == .outline { await gate.pause() }
                    await fake.phase(phase)
                })
        }
        await gate.waitForEntry()
        #expect(await fake.calls.isEmpty, "A suspended phase callback must not leave unowned generation running")
        await gate.release()
        _ = try await task.value
        #expect(await fake.calls.count == 3)
    }

    @Test func generatorErrorsPropagateWithoutASecondAttempt() async {
        let fake = FakeAssemblyGenerator(responses: [], failure: .declared)
        do {
            _ = try await SceneAssemblyPlanner.generate(request: Self.request,
                generate: { try await fake.generate($0) })
            Issue.record("Generator failure returned a scene")
        } catch AssemblyGeneratorFailure.declared {} catch { Issue.record("Generator error was replaced: \(error)") }
        #expect(await fake.calls.count == 1)
    }
}

private enum AssemblyGeneratorFailure: Error { case declared, unexpectedExtraCall }

private actor FakeAssemblyGenerator {
    private let responses: [String]
    private let failure: AssemblyGeneratorFailure?
    private(set) var calls: [SceneCreationCall] = []
    private(set) var events: [String] = []

    init(responses: [String], failure: AssemblyGeneratorFailure? = nil) {
        self.responses = responses; self.failure = failure
    }

    func phase(_ value: SceneCreationPhase) { events.append("phase:" + value.rawValue) }

    func generate(_ call: SceneCreationCall) throws -> String {
        calls.append(call)
        events.append("generate:\(calls.count)")
        if let failure { throw failure }
        guard calls.count <= responses.count else { throw AssemblyGeneratorFailure.unexpectedExtraCall }
        return responses[calls.count - 1]
    }
}

private actor AssemblyPhaseGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() { continuation?.resume(); continuation = nil }
}
