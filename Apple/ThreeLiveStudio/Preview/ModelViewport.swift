import SwiftUI
import RealityKit
import QuickLook

struct ModelViewport: View {
    let url: URL
    @State private var errorMessage: String?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            do {
                let model = try await Entity(contentsOf: url)
                let bounds = model.visualBounds(relativeTo: nil)
                let longest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
                if longest > 0 {
                    let factor: Float = 0.65 / longest
                    model.scale = SIMD3(repeating: factor)
                    model.position = -bounds.center * factor
                }
                content.add(model)
                content.cameraTarget = model
            } catch { errorMessage = StudioCopy.text("预览暂不可用：", "Preview unavailable: ") + error.localizedDescription }
        }
        .realityViewCameraControls(.orbit)
        .id(url)
        .overlay {
            if let errorMessage { ContentUnavailableView(StudioCopy.text("无法打开预览", "Could not open preview"), systemImage: "cube", description: Text(errorMessage)) }
        }
        .accessibilityLabel(StudioCopy.text("三维模型预览，拖动旋转，双指缩放", "3D model preview. Drag to orbit, pinch to zoom."))
    }
}

struct NativeQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

