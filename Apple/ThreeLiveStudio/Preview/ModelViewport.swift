import SwiftUI
import RealityKit
import QuickLook
import Observation

@MainActor
struct ModelViewport: View {
    let url: URL
    @State private var loadState: ModelPreviewLoadState
    @State private var retryID = UUID()

    init(url: URL, loadState: ModelPreviewLoadState = ModelPreviewLoadState()) {
        self.url = url
        _loadState = State(initialValue: loadState)
    }

    var body: some View {
        RealityView { content in
            content.camera = .virtual
        } update: { content in
            let model = loadState.url == url ? loadState.entity : nil
            for existing in Array(content.entities) where existing !== model {
                content.remove(existing)
            }
            if let model {
                if !content.entities.contains(where: { $0 === model }) { content.add(model) }
                content.cameraTarget = model
            } else { content.cameraTarget = nil }
        }
        .realityViewCameraControls(.orbit)
        .id(url)
        .task(id: PreviewRequest(url: url, retryID: retryID)) { await loadState.load(url: url) }
        .overlay {
            if loadState.url == url {
                switch loadState.phase {
                case .idle, .loading:
                    ProgressView(StudioCopy.text("正在打开预览", "Opening preview"))
                        .allowsHitTesting(false)
                case .failed:
                    ContentUnavailableView {
                        Label(StudioCopy.text("无法打开预览", "Could not open preview"), systemImage: "cube")
                    } description: {
                        Text(loadState.errorMessage ?? StudioCopy.text("预览暂不可用。", "Preview is unavailable."))
                    } actions: { retryButton }
                case .cancelled:
                    VStack(spacing: 12) {
                        Text(StudioCopy.text("预览已暂停", "Preview paused")).foregroundStyle(.secondary)
                        retryButton
                    }
                case .ready: EmptyView()
                }
            }
        }
        .accessibilityLabel(StudioCopy.text("三维模型预览，拖动旋转，双指缩放", "3D model preview. Drag to orbit, pinch to zoom."))
    }

    private var retryButton: some View {
        Button(StudioCopy.text("重新加载预览", "Reload preview"), systemImage: "arrow.clockwise") {
            retryID = UUID()
        }.buttonStyle(.glass).accessibilityIdentifier("retryModelPreview")
    }

    private struct PreviewRequest: Equatable { let url: URL; let retryID: UUID }
}

/// Asset loading follows the visible view's task, rather than RealityView's
/// asynchronous make callback. Superseded/cancelled loads never publish errors
/// or entities over the current request, and every new attempt clears old errors.
@MainActor @Observable
final class ModelPreviewLoadState {
    enum Phase: Equatable { case idle, loading, ready, cancelled, failed }
    typealias EntityLoader = @MainActor (URL) async throws -> Entity
    private(set) var url: URL?
    private(set) var entity: Entity?
    private(set) var phase = Phase.idle
    private(set) var errorMessage: String?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private let loadEntity: EntityLoader

    init(loadEntity: @escaping EntityLoader = { try await Entity(contentsOf: $0) }) {
        self.loadEntity = loadEntity
    }

    func load(url: URL) async {
        // A cancelled task that has not entered yet cannot supersede newer work.
        guard !Task.isCancelled else { return }
        let id = UUID()
        requestID = id
        self.url = url
        entity = nil
        errorMessage = nil
        phase = .loading
        do {
            let loaded = try await loadEntity(url)
            try Task.checkCancellation()
            guard requestID == id else { return }
            let bounds = loaded.visualBounds(relativeTo: nil)
            let longest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
            if longest > 0 {
                let factor: Float = 0.65 / longest
                loaded.scale = SIMD3(repeating: factor)
                loaded.position = -bounds.center * factor
            }
            entity = loaded
            phase = .ready
        } catch {
            guard requestID == id else { return }
            let failure = error as NSError
            let cancellation = CancellationError() as NSError
            if Task.isCancelled || error is CancellationError ||
                (failure.domain == cancellation.domain && failure.code == cancellation.code) {
                phase = .cancelled
                return
            }
            errorMessage = error.localizedDescription
            phase = .failed
        }
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

