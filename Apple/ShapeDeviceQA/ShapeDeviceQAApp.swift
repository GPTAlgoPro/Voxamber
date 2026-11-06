import SwiftUI
import Observation
import UIKit

@MainActor @Observable final class ShapeQAState: NeuralShapeProbeState {
    var busy = false
    var errorMessage: String?
    var notice: String?
    var stage = "三维模型真机验收"
    var elapsed: TimeInterval = 0
}

@main struct ShapeDeviceQAApp: App {
    @State private var state = ShapeQAState()
    @State private var operation: Task<Void, Never>?
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 20) {
                Text("维珀 · 三维验收").font(.title.bold())
                Text("专用测试 App，结果保存在独立诊断目录。")
                Text(state.stage).font(.headline)
                Text("\(state.elapsed, format: .number.precision(.fractionLength(1))) 秒").monospacedDigit()
                if state.busy { ProgressView(); Button("取消") { operation?.cancel() } }
                if let notice = state.notice { Text(notice) }
                if let error = state.errorMessage { Text(error).foregroundStyle(.red) }
                PhoneNativePreviewPanel(isGenerationBusy: state.busy)
            }
            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onChange(of: phase) { _, value in
                if value == .background { operation?.cancel(); UIApplication.shared.isIdleTimerDisabled = false }
                else if value == .active { UIApplication.shared.isIdleTimerDisabled = true }
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                let fullPipeline = arguments.contains("--qa-native-klein")
                guard fullPipeline || arguments.contains("--qa-neural-shape") else { return }
                let previous = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
                let owned = Task {
                    if fullPipeline { await NativePipelineDeviceProbe.run(studio: state) }
                    else { await NeuralShapeDeviceProbe.run(studio: state) }
                }
                operation = owned
                await withTaskCancellationHandler { await owned.value } onCancel: { owned.cancel() }
                operation = nil
                UIApplication.shared.isIdleTimerDisabled = previous
            }
        }
    }
}
