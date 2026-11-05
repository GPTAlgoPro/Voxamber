#if os(macOS)
import AppKit
import SceneKit
import Metal
import CreationCore

/// Development evidence: import the actual exported USDZ through an Apple 3D consumer and render it.
@MainActor
enum ModelPreview {
    static func write(usdzURL: URL, meshes: [GeneratedMesh], destination: URL, front: Bool = false) throws {
        let scene = try SCNScene(url: usdzURL)
        var minimum = SIMD3<Float>(repeating: .infinity)
        var maximum = SIMD3<Float>(repeating: -.infinity)
        for mesh in meshes {
            for index in stride(from: 0, to: mesh.positions.count, by: 3) {
                for axis in 0..<3 {
                    minimum[axis] = min(minimum[axis], mesh.positions[index + axis])
                    maximum[axis] = max(maximum[axis], mesh.positions[index + axis])
                }
            }
        }
        let center = (minimum + maximum) / 2
        let extent = maximum - minimum
        let radius = max(extent.x, max(extent.y, extent.z)) / 2
        let distance = max(0.4, radius * 3.4)
        let direction = front ? SIMD3<Float>(0,0,1) : SIMD3<Float>(0.52,0.30,0.80)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 42
        camera.camera?.zNear = 0.001
        camera.camera?.zFar = 100
        camera.position = vector(center + direction * distance)
        camera.look(at: vector(center))
        scene.rootNode.addChildNode(camera)

        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
        key.light?.intensity = 1100
        key.position = vector(center + SIMD3<Float>(-2,3,4) * max(radius,0.3))
        scene.rootNode.addChildNode(key)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)
        scene.background.contents = NSColor(srgbRed: 0.94, green: 0.955, blue: 0.98, alpha: 1)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 900), antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: destination)
    }
    private static func vector(_ value: SIMD3<Float>) -> SCNVector3 { .init(value.x, value.y, value.z) }
}
#endif
