import AppKit
import Foundation
import RealityKit
import simd

// An actual macOS RealityKit import/readback; this does not claim rendered UI or iPhone AR acceptance.
@main
struct RealityKitReadback {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fail("Usage: check-realitykit /absolute/path/model.usdz")
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("Input does not exist: \(url.path)")
        }
        _ = NSApplication.shared
        let start = Date()
        do {
            let entity = try await Entity(contentsOf: url)
            var entities = 0
            var modelEntities = 0
            var vertices = 0
            var triangles = 0
            var invalidValues = 0
            var modelDetails: [[String: Any]] = []

            func visit(_ node: Entity) {
                entities += 1
                let matrix = node.transform.matrix
                for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3] {
                    if !column.x.isFinite || !column.y.isFinite || !column.z.isFinite || !column.w.isFinite {
                        invalidValues += 1
                    }
                }
                if let component = node.components[ModelComponent.self] {
                    modelEntities += 1
                    var modelVertices = 0
                    var modelTriangles = 0
                    var modelNormals = 0
                    var parts = 0
                    for model in component.mesh.contents.models {
                        for part in model.parts {
                            parts += 1
                            let positions = part.positions.elements
                            modelVertices += positions.count
                            for p in positions where !p.x.isFinite || !p.y.isFinite || !p.z.isFinite {
                                invalidValues += 1
                            }
                            let normals = part.normals?.elements ?? []
                            modelNormals += normals.count
                            for n in normals where !n.x.isFinite || !n.y.isFinite || !n.z.isFinite {
                                invalidValues += 1
                            }
                            let indices = part.triangleIndices?.elements ?? []
                            modelTriangles += indices.count / 3
                            if indices.count % 3 != 0 { invalidValues += 1 }
                            if indices.contains(where: { Int($0) >= positions.count }) { invalidValues += 1 }
                        }
                    }
                    vertices += modelVertices
                    triangles += modelTriangles
                    modelDetails.append([
                        "name": node.name,
                        "vertices": modelVertices,
                        "triangles": modelTriangles,
                        "normals": modelNormals,
                        "parts": parts,
                        "materials": component.materials.count,
                        "materialTypes": component.materials.map { String(describing: type(of: $0)) }
                    ])
                }
                for child in node.children { visit(child) }
            }
            visit(entity)
            let bounds = entity.visualBounds(relativeTo: nil)
            let extents = bounds.extents
            let validBounds = !bounds.isEmpty && extents.x.isFinite && extents.y.isFinite && extents.z.isFinite
                && extents.x > 0 && extents.y > 0 && extents.z > 0
            let success = modelEntities > 0 && vertices > 0 && triangles > 0 && invalidValues == 0 && validBounds
            let result: [String: Any] = [
                "success": success,
                "engine": "Apple RealityKit Entity(contentsOf:)",
                "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                "input": url.path,
                "loadAndReadbackSeconds": Date().timeIntervalSince(start),
                "entities": entities,
                "modelEntities": modelEntities,
                "vertices": vertices,
                "triangles": triangles,
                "invalidValues": invalidValues,
                "boundsMetres": [
                    "min": [bounds.min.x, bounds.min.y, bounds.min.z],
                    "max": [bounds.max.x, bounds.max.y, bounds.max.z],
                    "extents": [extents.x, extents.y, extents.z]
                ],
                "models": modelDetails,
                "scope": "Native macOS import, mesh/material readback and finite bounds; no rendered UI or physical iPhone AR test"
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(success ? 0 : 1)
        } catch {
            fail(String(describing: error))
        }
    }

    static func fail(_ message: String) -> Never {
        let data = try! JSONSerialization.data(withJSONObject: ["success": false, "error": message], options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(1)
    }
}
