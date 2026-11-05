import SwiftUI

@main
struct ThreeLiveStudioApp: App {
    @State private var studio = StudioModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StudioRoot(studio: studio)
                .tint(StudioStyle.accent)
                .preferredColorScheme(.dark)
                .task { await studio.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { studio.enterBackground() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    studio.handleMemoryPressure()
                }
        }
    }
}

struct StudioRoot: View {
    @Bindable var studio: StudioModel

    var body: some View {
        TabView(selection: $studio.tab) {
            Tab(StudioCopy.text("创作", "Create"), systemImage: "sparkles", value: .create) {
                NavigationStack { CreationWorkspace(studio: studio) }
            }
            Tab(StudioCopy.text("作品", "Creations"), systemImage: "square.grid.2x2", value: .library) {
                NavigationStack { ProjectLibrary(studio: studio) }
            }
            Tab(StudioCopy.text("本机模型", "On-device AI"), systemImage: "cpu", value: .models) {
                NavigationStack { NeuralModelLibrary(manager: studio.neuralModels, generationBusy: studio.busy) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .alert(StudioCopy.text("未能完成", "Could not complete"), isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button(StudioCopy.text("好", "OK"), role: .cancel) { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
    }
}
