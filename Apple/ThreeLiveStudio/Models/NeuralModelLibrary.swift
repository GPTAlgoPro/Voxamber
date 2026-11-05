import SwiftUI
import UniformTypeIdentifiers

struct NeuralModelLibrary: View {
    @Bindable var manager: NeuralModelManager
    let generationBusy: Bool
    @State private var importing = false
    @State private var importGroup: NeuralModelGroup?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(StudioCopy.text("准备你的本机创作工具", "Prepare your on-device studio"))
                    .font(.title2.weight(.semibold))
                Text(StudioCopy.text("文字、参考图与三维形体分阶段处理。完整资源校验后才能开始创作。", "Text, reference images, and 3D shapes run in separate stages. All required resources must pass verification before creation starts."))
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(manager.groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(title(group.group)).font(.headline)
                            Spacer()
                            Image(systemName: group.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(group.installed ? StudioStyle.accent : .secondary)
                        }
                        Text(group.name).font(.subheadline).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: group.byteCount, countStyle: .file))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if !group.installed {
                            HStack {
                                if group.downloadAvailable {
                                    Button(StudioCopy.text("从 Apple 下载", "Download from Apple")) { manager.download(group: group.group) }
                                        .buttonStyle(.glassProminent)
                                }
                                Button(StudioCopy.text("导入完整文件夹", "Import resource folder")) {
                                    importGroup = group.group; importing = true
                                }.buttonStyle(.glass)
                            }.disabled(generationBusy || manager.busy)
                        }
                    }.studioCard()
                }
                if manager.busy {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(manager.stage).font(.subheadline)
                        ProgressView(value: manager.progress)
                        Button(StudioCopy.text("取消准备", "Cancel preparation"), role: .cancel) { manager.cancel() }
                            .buttonStyle(.glass)
                    }.studioCard()
                }
                if manager.ready {
                    Label(StudioCopy.text("本机创作工具已就绪", "On-device studio is ready"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(StudioStyle.accent)
                }
                if let error = manager.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background { StudioBackground() }
        .navigationTitle(StudioCopy.text("本机模型", "On-device models"))
        .refreshable { await manager.checkInstallation() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard let group = importGroup else { return }
            if case .success(let urls) = result, let directory = urls.first {
                manager.importModel(group: group, from: directory)
            }
        }
    }

    private func title(_ group: NeuralModelGroup) -> String {
        switch group {
        case .intent: StudioCopy.text("构想理解", "Understand your idea")
        case .image: StudioCopy.text("参考造型", "Create a reference")
        case .shape: StudioCopy.text("三维形体", "Generate a 3D shape")
        }
    }
}
