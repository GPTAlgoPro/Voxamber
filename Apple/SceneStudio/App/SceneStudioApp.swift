import SwiftUI
import UIKit

@main struct SceneStudioApp: App {
    @State private var model = SceneStudioModel()
    @State private var imports = SceneImportMonitor()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            SceneStudioWorkspace(model: model)
                .tint(.teal)
                .task(id: phase) {
                    if phase == .active {
                        try? imports.start()
                        await model.refresh()
                        await model.restoreDraft()
                    } else if phase == .background { imports.stop(); model.cancel() }
                }
                .task(id: imports.revision) {
                    if phase == .active { await model.refreshIncoming() }
                }
                .onOpenURL { url in model.importFile(url) }
                .onChange(of: model.busy) { _, busy in UIApplication.shared.isIdleTimerDisabled = busy }
                #if SCENE_QA
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--qa-native-import") {
                        await SceneStudioDeviceProbe.run(model: model)
                    }
                }
                #endif
        }
    }
}

enum StudioCopy {
    static func text(_ chinese: String, _ english: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
    }
}
