import Foundation
import Testing
@testable import CreationCore

@Test func absoluteScenesKeepTheirExistingCoordinates() throws {
    let original = SceneSpec(name: "absolute", nodes: [
        .init(id: "floating", primitive: .box, position: [0,1,0], size: [0.2,0.2,0.2])
    ])
    #expect(try SceneAttachmentResolver.resolve(original) == original)
}

@Test func anExplicitGraphRootCanGroundASingleFreeStandingPart() throws {
    let input = SceneSpec(name: "single", nodes: [
        .init(id: "root", primitive: .sphere, position: [0,0,0], size: [0.4,0.4,0.4], offset: [0,0,0])
    ])
    let solved = try SceneAttachmentResolver.resolve(input)
    #expect(abs(try SceneGenerator.bounds(for: solved.nodes[0]).minimum[1]) < 0.00001)
    #expect(solved.nodes[0].offset == nil)
}

@Test func stackedPartsTouchAndCanonicalResolutionIsIdempotent() throws {
    let input = SceneSpec(name: "lamp", nodes: [
        .init(id: "base", primitive: .box, position: [0,0,0], size: [0.4,0.1,0.4], offset: [0,0,0]),
        .init(id: "stem", primitive: .cylinder, position: [0,0,0], size: [0.05,0.6,0.05],
              parentID: "base", attachment: .top, offset: [0,1,0]),
        .init(id: "shade", primitive: .cone, position: [0,0,0], size: [0.3,0.2,0.3],
              parentID: "stem", attachment: .top)
    ])
    let solved = try SceneAttachmentResolver.resolve(input)
    let base = try SceneGenerator.bounds(for: solved.nodes[0])
    let stem = try SceneGenerator.bounds(for: solved.nodes[1])
    let shade = try SceneGenerator.bounds(for: solved.nodes[2])
    #expect(abs(base.minimum[1]) < 0.00001)
    #expect(abs(stem.minimum[1] - (base.maximum[1] - 0.003)) < 0.00001)
    #expect(abs(shade.minimum[1] - (stem.maximum[1] - 0.003)) < 0.00001)
    #expect(solved.nodes.allSatisfy { $0.parentID == nil && $0.attachment == nil && $0.offset == nil })
    #expect(try SceneAttachmentResolver.resolve(solved) == solved)
    #expect(try SceneGenerator.generate(for: input) == SceneGenerator.generate(for: solved))
}

@Test func rotationsAndChildBeforeParentUseActualBounds() throws {
    let input = SceneSpec(name: "rotated", nodes: [
        .init(id: "child", primitive: .box, position: [0,0,0], size: [0.1,0.2,0.1],
              parentID: "parent", attachment: .top, offset: [0.02,0,0]),
        .init(id: "parent", primitive: .box, position: [0,0,0], size: [0.6,0.1,0.3], rotation: [0,0,90])
    ])
    let solved = try SceneAttachmentResolver.resolve(input)
    let child = try SceneGenerator.bounds(for: solved.nodes[0])
    let parent = try SceneGenerator.bounds(for: solved.nodes[1])
    #expect(abs(parent.height - 0.6) < 0.00001)
    #expect(abs(child.minimum[1] - (parent.maximum[1] - 0.003)) < 0.00001)
    #expect(abs(solved.nodes[0].position[0] - 0.02) < 0.00001)
}

@Test func frontEyesShareAVisibleFaceAndLegsReachGround() throws {
    let input = SceneSpec(name: "robot", nodes: [
        .init(id: "body", primitive: .box, position: [0,0,0], size: [0.4,0.4,0.3]),
        .init(id: "head", primitive: .box, position: [0,0,0], size: [0.3,0.3,0.3], parentID: "body", attachment: .top),
        .init(id: "eye_l", primitive: .sphere, position: [0,0,0], size: [0.05,0.05,0.05], parentID: "head", attachment: .front, offset: [-0.07,0.03,0]),
        .init(id: "eye_r", primitive: .sphere, position: [0,0,0], size: [0.05,0.05,0.05], parentID: "head", attachment: .front, offset: [0.07,0.03,0]),
        .init(id: "leg_l", primitive: .cylinder, position: [0,0,0], size: [0.07,0.4,0.07], parentID: "body", attachment: .bottom, offset: [-0.1,0,0]),
        .init(id: "leg_r", primitive: .cylinder, position: [0,0,0], size: [0.07,0.4,0.07], parentID: "body", attachment: .bottom, offset: [0.1,0,0])
    ])
    let solved = try SceneAttachmentResolver.resolve(input)
    let head = try SceneGenerator.bounds(for: solved.nodes[1])
    let leftEye = try SceneGenerator.bounds(for: solved.nodes[2])
    let rightEye = try SceneGenerator.bounds(for: solved.nodes[3])
    #expect(solved.nodes[2].position[2] == solved.nodes[3].position[2])
    #expect(leftEye.maximum[2] > head.maximum[2] && rightEye.maximum[2] > head.maximum[2])
    #expect(abs(try SceneGenerator.bounds(for: solved.nodes[4]).minimum[1]) < 0.00001)
    #expect(abs(try SceneGenerator.bounds(for: solved.nodes[5]).minimum[1]) < 0.00001)
}

@Test func brokenReferencesCyclesAndInvalidOffsetsAreRejected() {
    for input in [
        SceneSpec(name: "missing", nodes: [.init(id: "a", primitive: .box, position: [0,0,0], size: [0.2,0.2,0.2], parentID: "unknown", attachment: .top)]),
        SceneSpec(name: "cycle", nodes: [
            .init(id: "a", primitive: .box, position: [0,0,0], size: [0.2,0.2,0.2], parentID: "b", attachment: .top),
            .init(id: "b", primitive: .box, position: [0,0,0], size: [0.2,0.2,0.2], parentID: "a", attachment: .top)]),
        SceneSpec(name: "offset", nodes: [
            .init(id: "a", primitive: .box, position: [0,0,0], size: [0.2,0.2,0.2]),
            .init(id: "b", primitive: .box, position: [0,0,0], size: [0.2,0.2,0.2], parentID: "a", attachment: .top, offset: [.nan,0,0])])
    ] {
        #expect(throws: CreationError.self) { try SceneAttachmentResolver.resolve(input) }
    }
}
