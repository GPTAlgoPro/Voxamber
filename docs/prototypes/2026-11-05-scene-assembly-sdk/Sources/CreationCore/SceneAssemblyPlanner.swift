/// Coordinates model-independent planning without retrying or repairing output.
public enum SceneAssemblyPlanner {
    public static func generate(
        request: String,
        generate: @escaping @Sendable (SceneCreationCall) async throws -> String,
        onPhase: @escaping @Sendable (SceneCreationPhase) async -> Void = { _ in }
    ) async throws -> SceneSpec {
        try Task.checkCancellation()
        let outlineCall = try SceneAssemblyProtocol.outlineRequest(request)
        let outlineResponse = try await perform(outlineCall, phase: .outline,
                                                generate: generate, onPhase: onPhase)
        let outline = try SceneAssemblyOutline.decodeModelResponse(outlineResponse)

        try Task.checkCancellation()
        let placement: SceneAssemblyPlacement
        if outline.parts.allSatisfy({ $0.parent == nil }) {
            // With no relationships, the only valid placement is an empty list.
            await onPhase(.placement)
            try Task.checkCancellation()
            placement = try SceneAssemblyPlacement(anchors: [], outline: outline)
        } else {
            let placementCall = try SceneAssemblyProtocol.placementRequest(request, outline: outline)
            let placementResponse = try await perform(placementCall, phase: .placement,
                                                      generate: generate, onPhase: onPhase)
            placement = try SceneAssemblyPlacement.decodeModelResponse(placementResponse, outline: outline)
        }

        try Task.checkCancellation()
        let geometryCall = try SceneAssemblyProtocol.geometryRequest(request, outline: outline, placement: placement)
        let geometryResponse = try await perform(geometryCall, phase: .geometry,
                                                 generate: generate, onPhase: onPhase)
        let scene = try SceneAssemblyProtocol.decodeGeometryResponse(geometryResponse,
                                                                     outline: outline, placement: placement)
        try Task.checkCancellation()
        return scene
    }

    private static func perform(
        _ call: SceneCreationCall,
        phase: SceneCreationPhase,
        generate: @Sendable (SceneCreationCall) async throws -> String,
        onPhase: @Sendable (SceneCreationPhase) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        await onPhase(phase)
        try Task.checkCancellation()
        let response = try await generate(call)
        try Task.checkCancellation()
        return response
    }
}
