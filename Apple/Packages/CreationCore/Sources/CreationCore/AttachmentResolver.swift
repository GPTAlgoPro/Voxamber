import Foundation

/// Resolves a declarative part graph using real transformed geometry bounds.
/// Relations select fixed attachment operations; no model-generated code is evaluated.
public enum SceneAttachmentResolver {
    public static func resolve(_ spec: SceneSpec) throws -> SceneSpec {
        try spec.validate()
        guard spec.nodes.contains(where: { $0.parentID != nil || $0.attachment != nil || $0.offset != nil }) else { return spec }
        var nodes = spec.nodes
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        for node in nodes {
            if let parent = node.parentID, indices[parent] == nil {
                throw CreationError.invalidModelResponse("连接关系引用了不存在的父部件。")
            }
        }
        var resolved: Set<Int> = []
        for _ in nodes.indices {
            try Task.checkCancellation()
            var progressed = false
            for index in nodes.indices where !resolved.contains(index) {
                guard let parentID = spec.nodes[index].parentID else {
                    resolved.insert(index); progressed = true; continue
                }
                guard let parentIndex = indices[parentID], parentIndex != index,
                      let attachment = spec.nodes[index].attachment else {
                    throw CreationError.invalidModelResponse("部件连接关系不完整。")
                }
                guard resolved.contains(parentIndex) else { continue }
                let parent = try SceneGenerator.bounds(for: nodes[parentIndex])
                var child = stripped(nodes[index])
                child.position = [0,0,0]
                let relative = try SceneGenerator.bounds(for: child)
                let offset = (spec.nodes[index].offset ?? [0,0,0]).map(Double.init)
                var translation = (0..<3).map {
                    (parent.minimum[$0] + parent.maximum[$0]) / 2
                    - (relative.minimum[$0] + relative.maximum[$0]) / 2
                }
                func overlap(_ axis: Int) -> Double {
                    min(0.003, min(parent.maximum[axis] - parent.minimum[axis],
                                   relative.maximum[axis] - relative.minimum[axis]) * 0.1)
                }
                switch attachment {
                case .top:
                    translation[0] += offset[0]; translation[2] += offset[2]
                    translation[1] = parent.maximum[1] - relative.minimum[1] - overlap(1)
                case .bottom:
                    translation[0] += offset[0]; translation[2] += offset[2]
                    translation[1] = parent.minimum[1] - relative.maximum[1] + overlap(1)
                case .front:
                    translation[0] += offset[0]; translation[1] += offset[1]
                    translation[2] = parent.maximum[2] - relative.minimum[2] - overlap(2)
                case .back:
                    translation[0] += offset[0]; translation[1] += offset[1]
                    translation[2] = parent.minimum[2] - relative.maximum[2] + overlap(2)
                case .left:
                    translation[1] += offset[1]; translation[2] += offset[2]
                    translation[0] = parent.minimum[0] - relative.maximum[0] + overlap(0)
                case .right:
                    translation[1] += offset[1]; translation[2] += offset[2]
                    translation[0] = parent.maximum[0] - relative.minimum[0] - overlap(0)
                case .inside:
                    for axis in 0..<3 { translation[axis] += offset[axis] }
                }
                nodes[index].position = translation.map(Float.init)
                resolved.insert(index); progressed = true
            }
            if resolved.count == nodes.count { break }
            if !progressed { throw CreationError.invalidModelResponse("部件连接关系含有循环引用。") }
        }
        guard resolved.count == nodes.count else {
            throw CreationError.invalidModelResponse("部件连接关系无法求解。")
        }
        var minimumY = Double.infinity
        for node in nodes { minimumY = min(minimumY, try SceneGenerator.bounds(for: node).minimum[1]) }
        guard minimumY.isFinite else { throw CreationError.invalidModelResponse("部件连接几何无效。") }
        for index in nodes.indices {
            nodes[index].position[1] -= Float(minimumY)
            nodes[index] = stripped(nodes[index])
        }
        let canonical = SceneSpec(name: spec.name, nodes: nodes)
        try canonical.validate()
        return canonical
    }

    private static func stripped(_ node: SceneNode) -> SceneNode {
        var result = node
        result.parentID = nil; result.attachment = nil; result.offset = nil
        return result
    }
}
