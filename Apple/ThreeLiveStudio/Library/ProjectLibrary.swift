import SwiftUI

struct ProjectLibrary: View {
    @Bindable var studio: StudioModel
    @State private var deletion: CreationProject?

    var body: some View {
        Group {
            if studio.projects.isEmpty {
                ContentUnavailableView {
                    Label(StudioCopy.text("留住每一次灵感", "Keep every idea"), systemImage: "square.stack.3d.up")
                } description: {
                    Text(StudioCopy.text("生成完成后，作品会自动保存在这里。", "Your finished creations are saved here automatically."))
                } actions: { Button(StudioCopy.text("开始创作", "Start creating")) { studio.tab = .create }.buttonStyle(.glassProminent) }
            } else {
                List {
                    ForEach(studio.projects) { project in
                        Button { Task { await studio.open(project) } } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "cube.transparent")
                                    .font(.title2).foregroundStyle(StudioStyle.accent)
                                    .frame(width: 54, height: 54)
                                    .background(.teal.opacity(0.1), in: .rect(cornerRadius: 16))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(project.name).font(.headline).foregroundStyle(.primary)
                                    Text(project.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.padding(.vertical, 8)
                        }
                        .listRowBackground(Color.white.opacity(0.045))
                        .swipeActions { Button(StudioCopy.text("删除", "Delete"), role: .destructive) { deletion = project } }
                        .contextMenu { Button(StudioCopy.text("删除作品", "Delete creation"), role: .destructive) { deletion = project } }
                    }
                }.scrollContentBackground(.hidden)
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
