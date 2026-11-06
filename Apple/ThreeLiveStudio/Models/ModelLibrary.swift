import SwiftUI
import UniformTypeIdentifiers

struct ModelLibrary: View {
    @Bindable var manager: ModelManager
    let generationBusy: Bool
    @State private var importing = false
    @State private var deleting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "cpu").font(.largeTitle).foregroundStyle(StudioStyle.accent)
                    Text(StudioCopy.text("灵感在本机，\n作品也在本机。", "Your ideas stay here.\nSo do your creations."))
                        .font(.largeTitle.weight(.semibold))
                    Text(StudioCopy.text("首次安装需要网络。安装后，AI 理解、三维造型、编辑和保存都可离线完成。", "Connect once to install the model. Then describe, create, edit, and save in 3D offline."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text(StudioCopy.text(ModelManager.modelName, "Qwen3.5 · 4B INT4")).font(.headline); Spacer(); Image(systemName: manager.installed ? "checkmark.seal.fill" : "arrow.down.circle").foregroundStyle(StudioStyle.accent) }
                    Text(StudioCopy.status(manager.status)).font(.subheadline).accessibilityIdentifier("modelStatus")
                    Text(StudioCopy.text("约 3.1GB · 安装后可离线创作", "About 3.1 GB · Create offline after installation")).font(.caption).foregroundStyle(.secondary)
                    if manager.busy {
                        ProgressView(value: manager.progress)
                        Text(manager.progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                        Button(StudioCopy.text("取消下载", "Cancel download")) { manager.cancelDownload() }.buttonStyle(.glass)
                    } else if manager.installed {
                        if manager.loaded { Button(StudioCopy.text("释放运行内存", "Free working memory")) { Task { await manager.unload() } }.buttonStyle(.glass).disabled(generationBusy) }
                        Button(StudioCopy.text("移除模型", "Remove model"), role: .destructive) { deleting = true }.disabled(generationBusy)
                    } else {
                        Button(StudioCopy.text("下载 Apple 素材 · 3.1GB", "Download Apple assets · 3.1 GB"), systemImage: "arrow.down.circle") { manager.download() }
                            .buttonStyle(.glassProminent).disabled(!manager.eligible || generationBusy)
                            .accessibilityIdentifier("downloadModel")
                        Button(StudioCopy.text("从文件导入", "Import from Files"), systemImage: "folder") { importing = true }
                            .buttonStyle(.glass).disabled(!manager.eligible || generationBusy)
                    }
                    if !manager.eligible {
                        Text(StudioCopy.text("本机 AI 需要受支持的 12GB 或以上内存设备。你仍可从灵感示例与模型编辑开始创作。", "On-device AI requires a supported device with at least 12 GB of memory. You can still create with inspiration starters and the model editor."))
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let error = manager.errorMessage { Text(error).font(.footnote).foregroundStyle(.orange) }
                }.studioCard()
                VStack(alignment: .leading, spacing: 12) {
                    Label(StudioCopy.text("你的创作留在本机", "Your creations stay on this device"), systemImage: "lock.shield")
                    Text(StudioCopy.text("模型下载后会验证完整性。你的描述、作品和运行记录保存在这台设备中。", "Model files are checked for integrity after download. Your descriptions, creations, and run records are stored on this device."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(versionLabel).font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        OpenSourceLicensesView()
                    } label: {
                        Label(StudioCopy.text("开源许可", "Open-source licenses"), systemImage: "doc.text")
                    }.font(.footnote)
                    Link(StudioCopy.text("模型来源与许可", "Model source and license"), destination: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-4B-4bit")!)
                        .font(.footnote)
                    Link(StudioCopy.text("隐私政策", "Privacy policy"), destination: URL(string: StudioCopy.isEnglish
                        ? "https://gptalgopro.github.io/Voxamber-Website/en/privacy/"
                        : "https://gptalgopro.github.io/Voxamber-Website/privacy/")!).font(.footnote)
                    Link(StudioCopy.text("帮助与支持", "Help and support"), destination: URL(string: StudioCopy.isEnglish
                        ? "https://gptalgopro.github.io/Voxamber-Website/en/support/"
                        : "https://gptalgopro.github.io/Voxamber-Website/support/")!).font(.footnote)
                }.studioCard()
            }.padding(24).frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
        }
        .background { StudioBackground() }
        .navigationTitle(StudioCopy.text("本机模型", "On-device model"))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result { case .success(let url): manager.importModel(url); case .failure(let error): manager.errorMessage = error.localizedDescription }
        }
        .confirmationDialog(StudioCopy.text("移除本机 AI 模型？", "Remove the on-device AI model?"), isPresented: $deleting, titleVisibility: .visible) {
            Button(StudioCopy.text("移除模型", "Remove model"), role: .destructive) { Task { await manager.remove() } }
        } message: { Text(StudioCopy.text("作品和参数会保留。再次使用 AI 时需要重新安装模型。", "Your creations and edits are kept. Reinstall the model to use AI again.")) }
    }

    private var versionLabel: String {
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""
        return "\(StudioCopy.appName) · \(version) (\(build))"
    }
}

struct OpenSourceLicensesView: View {
    private let licenses=["MLX-Swift","MLX-Swift-LM","Swift-Transformers","XGrammar","PicoJSON","DLPack","Qwen-Model",
        "Apple-SDXL","SDXL-Model","OpenAI-CLIP","Hunyuan3D-Swift-MIT","Hunyuan3D-Swift-ThirdParty",
        "Snap3D-ThirdPartyNotices","Tencent-Hunyuan-3D-2.1-Pinned-LICENSE",
        "Tencent-Hunyuan-3D-2.1-Pinned-NOTICE","Tencent-Hunyuan-3D-2.1-License"]
    var body: some View {
        List {
            ForEach(licenses,id:\.self) { name in
                NavigationLink(name) { BundledLicenseView(name:name) }
            }
        }
        .scrollContentBackground(.hidden)
        .background { StudioBackground() }
        .navigationTitle(StudioCopy.text("模型与开源许可", "Model and open-source licenses"))
    }
}

private struct BundledLicenseView: View {
    let name:String
    var body: some View {
        ScrollView {
            Text(contents).font(.footnote.monospaced()).textSelection(.enabled)
                .frame(maxWidth:.infinity,alignment:.leading).padding(20)
        }
        .background { StudioBackground() }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
    private var contents:String {
        let url=Bundle.main.url(forResource:name,withExtension:"txt",subdirectory:"Licenses")
            ?? Bundle.main.url(forResource:name,withExtension:"txt")
        guard let url,let text=try? String(contentsOf:url,encoding:.utf8) else {
            return StudioCopy.text("无法读取许可文本，请重新安装 App。", "The license text could not be read. Please reinstall the app.")
        }
        return text
    }
}
