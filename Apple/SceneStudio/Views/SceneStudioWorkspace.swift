import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor struct SceneStudioWorkspace: View {
    @Bindable var model: SceneStudioModel
    @State private var tab = 0
    @State private var importingFile = false
    @State private var pasteSheet = false
    @State private var codeSheet = false
    @State private var instructionsSheet = false
    @State private var legacyPreview: LegacySceneProject?
    @State private var arURL: ModelURL?
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular && !textSize.isAccessibilitySize {
                NavigationSplitView {
                    library.navigationTitle("作品")
                } detail: {
                    NavigationStack { creator.navigationTitle("维珀") }
                }
            } else {
                TabView(selection: $tab) {
                    Tab("创作", systemImage: "cube.transparent", value: 0) {
                        NavigationStack { creator.navigationTitle("维珀") }.accessibilityIdentifier("createTab")
                    }
                    Tab("作品", systemImage: "square.grid.2x2", value: 1) {
                        NavigationStack { library.navigationTitle("作品") }
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .fileImporter(isPresented: $importingFile,
            allowedContentTypes: [.javaScript, .plainText, .html, .sourceCode, .json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importFile(url); tab = 0 }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $pasteSheet) { SourceTextSheet(title: "粘贴 AI 场景代码", initial: "") { model.importText($0) } }
        .sheet(isPresented: $codeSheet) {
            SourceTextSheet(title: "编辑场景代码", initial: model.source) {
                model.source = $0; model.sourceWasEdited()
            }
        }
        .sheet(isPresented: $instructionsSheet) { authoringInstructions }
        .sheet(item: $legacyPreview) { project in
            NavigationStack { ModelViewport(url: project.usdzURL).navigationTitle(project.title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { legacyPreview = nil } } } }
        }
        .sheet(item: $arURL) { item in NativeQuickLook(url: item.url).ignoresSafeArea() }
        .alert("本次操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("复制错误") { UIPasteboard.general.string = model.errorMessage }
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text((model.errorMessage ?? "") + "\n可以把错误和场景代码交给你的 AI 修改后再导入。") }
    }

    private var creator: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("把你的想象\n带进三维世界").font(.largeTitle.bold())
                    Text("让你熟悉的 AI 创作场景，在这里生成、查看与分享。").foregroundStyle(.secondary)
                }.padding(.top, 12)
                if !model.pendingShares.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("收到分享").font(.headline)
                        ForEach(model.pendingShares) { item in
                            Button { model.acceptShared(item) } label: {
                                Label(item.originalFilename ?? "导入分享的代码", systemImage: "square.and.arrow.down")
                            }.disabled(model.busy)
                        }
                    }.sceneCard()
                }
                GlassEffectContainer(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack { importButtons }
                        VStack(alignment: .leading) { importButtons }
                    }
                }
                if model.source.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("先把创作说明发给你的 AI", systemImage: "sparkles").font(.headline)
                        Text("描述任何你想做的物体。将得到的场景代码复制回来，或从文件、系统分享导入。")
                            .foregroundStyle(.secondary)
                        Button("复制创作说明", systemImage: "doc.on.doc") { instructionsSheet = true }.buttonStyle(.glassProminent)
                        Button("看看示例场景", systemImage: "cube") { model.importExample() }
                            .disabled(model.busy).accessibilityIdentifier("importExample")
                    }.sceneCard()
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("作品名称", text: $model.title).font(.title3.bold()).accessibilityIdentifier("sourceTitle")
                        Label("已导入 \(ByteCountFormatter.string(fromByteCount: Int64(model.source.utf8.count), countStyle: .file)) 场景代码", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Button("查看或编辑代码", systemImage: "curlybraces") { codeSheet = true }.accessibilityIdentifier("codeEditor")
                        if model.editing != nil { Text("重新生成会保存当前作品的新版本。").font(.caption).foregroundStyle(.secondary) }
                    }.sceneCard().disabled(model.busy)
                }
                if let project = model.selected {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(project.title).font(.title3.bold())
                        ModelViewport(url: project.usdzURL).frame(minHeight: 300, idealHeight: 400)
                            .clipShape(.rect(cornerRadius: 20))
                        ViewThatFits(in: .horizontal) {
                            HStack { exports(project) }
                            VStack(alignment: .leading) { exports(project) }
                        }
                    }.sceneCard()
                }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }.padding(20).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .background { LinearGradient(colors: [.teal.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .center).ignoresSafeArea() }
        .safeAreaInset(edge: .bottom) { generationBar }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建", systemImage: "plus") { model.newProject() }.disabled(model.busy)
            }
        }
    }

    @ViewBuilder private var importButtons: some View {
        Button("粘贴代码", systemImage: "document.on.clipboard") { pasteSheet = true }
            .buttonStyle(.glass).disabled(model.busy).accessibilityIdentifier("importCode")
        Button("导入文件", systemImage: "folder") { importingFile = true }
            .buttonStyle(.glass).disabled(model.busy)
        Button("创作说明", systemImage: "sparkles") { instructionsSheet = true }.buttonStyle(.glass)
    }

    private var generationBar: some View {
        VStack(spacing: 10) {
            if model.busy {
                HStack {
                    ProgressView()
                    Text(model.stage).font(.subheadline)
                    if let date = model.startedAt { Text(date, style: .timer).monospacedDigit().font(.caption) }
                    Spacer()
                    Button("取消") { model.cancel() }.buttonStyle(.glass)
                }
            } else {
                Button(action: model.generateAndSave) {
                    Label("生成模型并保存", systemImage: "cube.transparent.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.glassProminent).disabled(model.source.isEmpty).accessibilityIdentifier("generateScene")
            }
        }.padding().background(.bar)
    }

    @ViewBuilder private func exports(_ project: ProgramProject) -> some View {
        ShareLink("USDZ", item: project.usdzURL).buttonStyle(.glass)
        ShareLink("GLB", item: project.glbURL).buttonStyle(.glass)
        ShareLink("场景代码", item: project.sourceURL).buttonStyle(.glass)
        Button("实景预览", systemImage: "arkit") { arURL = ModelURL(url: project.usdzURL) }.buttonStyle(.glass)
    }

    private var library: some View {
        List {
            if model.projects.isEmpty && model.legacyProjects.isEmpty {
                ContentUnavailableView("从第一件作品开始", systemImage: "cube.transparent",
                    description: Text("导入你的 AI 创作的场景代码，生成后会出现在这里。"))
            }
            ForEach(model.projects) { project in
                Button { model.open(project); tab = 0 } label: {
                    HStack(spacing: 14) {
                        SceneModelThumbnail(id: project.id, revision: project.revision, url: project.usdzURL, digest: project.usdzSHA256)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.title).font(.headline).foregroundStyle(.primary)
                            Text(project.updatedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(model.busy)
            }
            if !model.legacyProjects.isEmpty {
                Section("历史作品") {
                    ForEach(model.legacyProjects) { project in
                        VStack(alignment: .leading, spacing: 10) {
                            Button { legacyPreview = project } label: {
                                HStack {
                                    SceneModelThumbnail(id: project.id, revision: project.revision, url: project.usdzURL, digest: project.usdzSHA256)
                                    Text(project.title).foregroundStyle(.primary)
                                }
                            }
                            HStack { ShareLink("USDZ", item: project.usdzURL); ShareLink("GLB", item: project.glbURL) }.font(.caption)
                        }
                    }
                }
            }
        }.accessibilityIdentifier("library").overlay(alignment: .bottom) {
            if model.busy { ProgressView(model.stage).padding().background(.regularMaterial, in: .capsule) }
        }
    }

    private var authoringInstructions: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("使用你自己的 AI").font(.largeTitle.bold())
                    Text("ChatGPT、Gemini、Grok、Claude、Qwen、GLM、Kimi、DeepSeek 都可以。先复制下面的创作说明，再向它描述你的想法。")
                    Button("复制完整创作说明", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = instructions
                        model.notice = "创作说明已复制，可以粘贴给你的 AI。"
                    }.buttonStyle(.glassProminent)
                    Text(instructions).font(.callout).textSelection(.enabled)
                }.padding(22)
            }.navigationTitle("创作说明").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { instructionsSheet = false } } }
        }
    }

    private var instructions: String {
        guard let url = Bundle.main.url(forResource: "SceneAuthoringInstructions", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "创作说明暂未载入，请稍后重试。" }
        return value
    }
    private struct ModelURL: Identifiable { let url: URL; var id: URL { url } }
}

@MainActor private struct SceneModelThumbnail: View {
    let id: UUID
    let revision: UUID
    let url: URL
    let digest: String
    @State private var png: Data?
    @State private var failed = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.secondary.opacity(0.08))
            if let png, let image = UIImage(data: png) { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "cube").foregroundStyle(.secondary).accessibilityLabel("缩略图暂不可用") }
            else { ProgressView() }
        }.frame(width: 76, height: 76)
            .task(id: digest) {
                do {
                    let bytes = try await ProjectThumbnailService.shared.thumbnail(for:
                        .init(projectID: id, revision: revision, fileDigest: digest, fileURL: url))
                    try Task.checkCancellation(); png = bytes; failed = false
                } catch { if !Task.isCancelled { failed = true } }
            }
    }
}

@MainActor private struct SourceTextSheet: View {
    let title: String
    let initial: String
    let accept: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding()
                .accessibilityIdentifier("importSourceEditor")
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") { accept(text); dismiss() }.disabled(text.isEmpty || text.utf8.count > 4_194_304)
                            .accessibilityIdentifier("confirmSceneImport")
                    }
                }
        }.onAppear { text = initial }
    }
}

private extension View {
    func sceneCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }
}
