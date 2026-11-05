import SwiftUI
import CreationCore
#if DEBUG
import CryptoKit
#endif

struct CreationWorkspace: View {
    @Bindable var studio: StudioModel
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var quickLook: PreviewItem?
    @FocusState private var promptFocused: Bool

    var body: some View {
        Group {
            if #available(iOS 27.1, *), widthClass == .regular, !typeSize.isAccessibilitySize {
                ArrangementView {
                    ScrollView { composer.padding(24) }
                } secondary: {
                    preview.padding(24)
                }
                // Keep both panes when Duo rotates into a tall arrangement.
                .arrangementViewStyle(.split)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        hero
                        composer
                        preview.frame(minHeight: 320, idealHeight: 360)
                    }.padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background { StudioBackground(animated: !studio.busy) }
        .navigationTitle(StudioCopy.appName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(StudioCopy.text("新作品", "New creation"), systemImage: "plus") { studio.newCreation() }
                    .disabled(studio.busy)
            }
        }
        .safeAreaBar(edge: .bottom) { actionBar }
        .sheet(item: $quickLook) { item in NativeQuickLook(url: item.url).ignoresSafeArea() }
        .onChange(of: studio.prompt) { _, _ in studio.persistDraft() }
        .onChange(of: studio.sceneSpec) { _, _ in studio.persistDraft() }
        .duoVerificationProbe(studio)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(StudioCopy.text("把想象，\n塑成你的世界。", "Give your imagination\na new dimension."))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(StudioCopy.text("描述、塑造、预览，让灵感成为三维。", "Describe, shape, and preview your ideas in 3D."))
                .font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(StudioCopy.text("构想", "Your idea"), systemImage: "sparkle").font(.headline)
                Spacer()
                Label(studio.models.installed ? StudioCopy.text("本机 AI", "On-device AI") : StudioCopy.text("离线创作", "Offline creation"), systemImage: "iphone")
                    .font(.caption).foregroundStyle(StudioStyle.accent)
            }
            TextField(StudioCopy.text("描述你想创造的形状、结构与材质……", "Describe the form, structure, and materials you imagine…"), text: $studio.prompt, axis: .vertical)
                .lineLimit(3...7)
                .font(.body)
                .focused($promptFocused)
                .padding(16)
                .background(.black.opacity(0.18), in: .rect(cornerRadius: 18))
                .accessibilityIdentifier("creationPrompt")
                .accessibilityLabel(StudioCopy.text("创作描述", "Creation description"))
                .disabled(studio.busy)
            Text(StudioCopy.text("想做什么，就描述它。你也可以继续描述修改。", "Describe any idea, then keep refining it in your own words."))
                .font(.footnote).foregroundStyle(.secondary)
            Text(StudioCopy.text("灵感起点", "Inspiration starters")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            presetButtons
            DisclosureGroup(StudioCopy.text("编辑模型", "Edit model"), isExpanded: $studio.showParameters) {
                SceneParameters(scene: Binding(get: { studio.sceneSpec ?? .chair }, set: { studio.sceneSpec = $0 })).padding(.top, 14)
            }.font(.subheadline.weight(.medium)).disabled(studio.busy)
            if let notice = studio.notice {
                Label(StudioCopy.status(notice), systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(StudioStyle.accent)
                    .accessibilityIdentifier("creationNotice")
            }
        }.studioCard()
    }

    private var presetButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { presetContent }
            VStack(alignment: .leading, spacing: 10) { presetContent }
        }
    }

    @ViewBuilder private var presetContent: some View {
        ForEach(SceneSpec.presets, id: \.name) { preset in
            Button {
                promptFocused = false; studio.selectScenePreset(preset)
            } label: {
                Label(preset.shortTitle, systemImage: preset.symbol).font(.subheadline.weight(.medium))
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("scene-preset-" + preset.name)
            .disabled(studio.busy)
        }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            HStack {
                Text(studio.assets?.project.name ?? StudioCopy.text("你的创作空间", "Your creative space")).font(.headline)
                Spacer()
                if studio.hasUnbuiltChanges, studio.assets != nil {
                    Text(StudioCopy.text("修改待生成", "Changes not generated")).font(.caption).foregroundStyle(.orange)
                }
            }
            if let assets = studio.assets {
                ModelViewport(url: assets.usdzURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: 20))
                    .accessibilityIdentifier("modelViewport")
                HStack {
                    Text(StudioCopy.text("拖动旋转 · 双指缩放", "Drag to rotate · Pinch to zoom")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(StudioCopy.text("米制模型", "Dimensions in meters")).font(.caption).foregroundStyle(.secondary)
                }
                GlassEffectContainer {
                    HStack(spacing: 12) {
                        Button(StudioCopy.text("实景预览", "View in your space"), systemImage: "arkit") { quickLook = PreviewItem(url: assets.usdzURL) }
                            .accessibilityIdentifier("openAR")
                        Menu {
                            ShareLink(item: assets.usdzURL) { Text(StudioCopy.text("导出 USDZ", "Export USDZ")) }
                            ShareLink(item: assets.glbURL) { Text(StudioCopy.text("导出 GLB", "Export GLB")) }
                            ShareLink(items: [assets.usdzURL, assets.glbURL]) { Text(StudioCopy.text("导出两个格式", "Export both formats")) }
                        } label: { Label(StudioCopy.text("导出", "Export"), systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("exportMenu")
                    }.buttonStyle(.glass).disabled(!studio.canExport)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 72, weight: .ultraLight))
                        .foregroundStyle(StudioStyle.accent.gradient)
                    Text(StudioCopy.text("从一段描述开始", "Start with an idea")).font(.title3.weight(.medium))
                    Text(StudioCopy.text("也可以从灵感示例出发，编辑形状与材质。", "Or explore a starter, then shape its form and materials."))
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
            }
        }.studioCard().frame(maxHeight: .infinity)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if studio.busy {
                HStack(spacing: 12) {
                    ProgressView().tint(StudioStyle.accent)
                    VStack(alignment: .leading) {
                        Text(StudioCopy.status(studio.stage)).font(.subheadline.weight(.medium))
                        Text("\(studio.elapsed, format: .number.precision(.fractionLength(1))) s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(StudioCopy.text("取消", "Cancel"), role: .cancel) { studio.cancel() }.buttonStyle(.glass)
                        .accessibilityIdentifier("cancelGeneration")
                }.accessibilityElement(children: .contain)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { generationActions }
                    VStack(spacing: 10) { generationActions }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private var generationActions: some View {
        Button {
            promptFocused = false; ensureGenericScene(); studio.generate(usingAI: true)
        } label: {
            Label(studio.models.installed ? StudioCopy.text("AI 生成并保存", "Create and save with AI") : StudioCopy.text("安装本机 AI", "Install on-device AI"), systemImage: "sparkles")
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }.buttonStyle(.glassProminent)
            .accessibilityIdentifier("generateAI")
            .disabled(studio.models.busy)
        Button {
            promptFocused = false; ensureGenericScene(); studio.generate(usingAI: false)
        } label: {
            Text(StudioCopy.text("按参数生成", "Generate from edits")).padding(.vertical, 6)
        }.buttonStyle(.glass)
            .accessibilityIdentifier("generateParameters")
    }

    private func ensureGenericScene() {
        // Older documents may have no general-purpose editable scene.
        if studio.sceneSpec == nil { studio.sceneSpec = StudioModel.blankScene }
    }
}

private struct PreviewItem: Identifiable { let id = UUID(); let url: URL }

private extension View {
    @ViewBuilder
    func duoVerificationProbe(_ studio: StudioModel) -> some View {
        #if DEBUG
        if #available(iOS 27.1, *), ProcessInfo.processInfo.arguments.contains("--duo-qa") {
            modifier(DuoVerificationProbe(studio: studio))
        } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
@available(iOS 27.1, *)
@MainActor
private struct DuoVerificationProbe: ViewModifier {
    let studio: StudioModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @State private var size = CGSize.zero
    @State private var angle: Double?
    @State private var hingeState: String?
    @State private var records: [Entry] = []

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { value in
                size = value; record("geometry")
            }
            .onHingeChange { _, context in
                angle = context.hinge?.angle.degrees
                hingeState = context.hinge.map { String(describing: $0.status) }
                record("hinge")
            }
            .onAppear { record("appear") }
            .onChange(of: studio.prompt) { _, _ in record("prompt") }
            .onChange(of: studio.showParameters) { _, _ in record("editor") }
            .onChange(of: phase) { _, _ in record("scenePhase") }
    }

    private func record(_ reason: String) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try? encoder.encode(CreativeState(scene: studio.sceneSpec, prompt: studio.prompt))
        let hash = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        records.append(Entry(reason: reason, time: Date().timeIntervalSince1970,
            pid: ProcessInfo.processInfo.processIdentifier, width: size.width, height: size.height,
            horizontalSizeClass: sizeClass == .regular ? "regular" : "compact",
            scenePhase: String(describing: phase), hingeAngleDegrees: angle, hingeState: hingeState,
            creativeStateSHA256: hash, editorExpanded: studio.showParameters,
            selectedTab: String(describing: studio.tab), busy: studio.busy))
        if records.count > 128 { records.removeFirst(records.count - 128) }
        let url = URL.documentsDirectory.appending(path: "Measurements/duo-layout-probe.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(records).write(to: url, options: .atomic)
        } catch { /* Developer-only evidence never changes the app's layout or workflow. */ }
    }

    private struct CreativeState: Encodable { let scene: SceneSpec?; let prompt: String }
    private struct Entry: Encodable {
        let reason: String; let time: Double; let pid: Int32; let width: Double; let height: Double
        let horizontalSizeClass: String; let scenePhase: String; let hingeAngleDegrees: Double?
        let hingeState: String?; let creativeStateSHA256: String?; let editorExpanded: Bool
        let selectedTab: String; let busy: Bool
    }
}
#endif
