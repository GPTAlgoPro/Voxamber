import SwiftUI
import UIKit

struct ProjectLibrary: View {
    @Bindable var studio: StudioModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var deletion: CreationProject?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 150, maximum: 360), spacing: 16, alignment: .top)]
    }

    var body: some View {
        Group {
            if studio.projects.isEmpty {
                ContentUnavailableView {
                    Label(StudioCopy.text("留住每一次灵感", "Keep every idea"), systemImage: "square.stack.3d.up")
                } description: {
                    Text(StudioCopy.text("生成完成后，作品会自动保存在这里。", "Your finished creations are saved here automatically."))
                } actions: { Button(StudioCopy.text("开始创作", "Start creating")) { studio.tab = .create }.buttonStyle(.glassProminent) }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(studio.projects) { project in
                            ProjectThumbnailCard(project: project, store: studio.store, suspended: studio.busy,
                                open: { Task { await studio.open(project) } }, delete: { deletion = project })
                        }
                    }.padding(20)
                }
            }
        }
        .background { StudioBackground() }
        .navigationTitle(StudioCopy.text("作品库", "Creations"))
        .toolbar { Button(StudioCopy.text("新作品", "New creation"), systemImage: "plus") { studio.newCreation() }.disabled(studio.busy) }
        .disabled(studio.busy)
        .refreshable { await studio.refreshLibrary() }
        .confirmationDialog(StudioCopy.text("删除这件作品及其保存的版本？", "Delete this creation and its saved versions?"), isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let deletion { Button(StudioCopy.text("删除作品", "Delete creation"), role: .destructive) { Task { await studio.delete(deletion); self.deletion = nil } } }
        } message: { Text(StudioCopy.text("已经导出到其他位置的文件会保留。", "Files already exported to other locations are kept.")) }
    }
}

private struct ProjectThumbnailCard: View {
    let project: CreationProject
    let store: ProjectStore
    let suspended: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var image: UIImage?
    @State private var loadedIdentity: String?
    @State private var unavailable = false
    @State private var retry = 0

    private var identity: String { project.revision.uuidString + project.usdzSHA256 }
    private var request: ThumbnailRequest { .init(identity: identity, suspended: suspended, retry: retry) }
    private struct ThumbnailRequest: Equatable { let identity: String; let suspended: Bool; let retry: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.055))
                            if let image, loadedIdentity == identity {
                                Image(uiImage: image).resizable().scaledToFit().padding(12)
                            } else if unavailable || suspended {
                                Text(StudioCopy.text("预览稍后再试", "Preview unavailable"))
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                            } else {
                                ProgressView().accessibilityLabel(StudioCopy.text("载入作品预览", "Loading creation preview"))
                            }
                        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                        Text(project.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(project.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(project.name)
                .accessibilityHint(StudioCopy.text("打开这件三维作品", "Open this 3D creation"))

                Menu {
                    Button(StudioCopy.text("重新载入预览", "Reload preview"), systemImage: "arrow.clockwise") { retry += 1 }
                    Button(StudioCopy.text("删除作品", "Delete creation"), systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel(StudioCopy.text("作品选项：", "Options for ") + project.name)
                .padding(6)
            }
        }
        .task(id: request) {
            guard !Task.isCancelled else { return }
            image = nil; loadedIdentity = nil; unavailable = false
            guard !suspended else { return }
            let expected = identity
            do {
                let data = try await store.thumbnail(for: project)
                try Task.checkCancellation()
                guard expected == identity, let decoded = UIImage(data: data) else {
                    unavailable = true; return
                }
                loadedIdentity = expected; image = decoded
            } catch {
                guard !Task.isCancelled else { return }
                unavailable = true
            }
        }
    }
}
