import SwiftUI
import ClaudepitCore

struct ClaudeMdFile: Identifiable, Equatable {
    var id: URL { path }
    let name: String      // relative path from activePath, e.g. "CLAUDE.md" or ".claude/CLAUDE.md"
    let path: URL
    let modifiedAt: Date
}

struct ClaudeMdSection: View {
    @ObservedObject var app: AppState
    @State private var files: [ClaudeMdFile] = []
    @State private var selectedFile: ClaudeMdFile?

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            listCard
        } detail: {
            detailCard
        }
        .onAppear {
            reload()
            applyFocusClaudeMdPath()
            if selectedFile == nil { selectedFile = files.first }
        }
        .onChange(of: app.focusClaudeMdPath) { applyFocusClaudeMdPath() }
        .onChange(of: app.claudeMdChangeToken) { reload() }
        .onChange(of: app.activePath) { reload() }
    }

    // MARK: List card

    private var listCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                HStack {
                    Text("CLAUDE.md").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider().opacity(0.15)

                if files.isEmpty {
                    EmptyState("No CLAUDE.md files found in this project")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(files) { file in
                                fileRow(file)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func fileRow(_ file: ClaudeMdFile) -> some View {
        HStack(spacing: 0) {
            Button { selectedFile = file } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(file.modifiedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                fileContextMenu(url: file.path)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 8)
        }
        .selectableRowBackground(isSelected: selectedFile == file)
    }

    // MARK: Detail card

    private var detailCard: some View {
        Group {
            if let file = selectedFile {
                ClaudeMdDetailView(file: file, app: app) { reload() }
            } else {
                GlassCard {
                    EmptyState("Select a file")
                }
            }
        }
    }

    // MARK: Data

    private func applyFocusClaudeMdPath() {
        guard let path = app.focusClaudeMdPath else { return }
        reload()
        selectedFile = files.first { $0.path.path == path }
        app.focusClaudeMdPath = nil
    }

    private func reload() {
        guard let base = app.activePath else { files = []; return }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { files = []; return }

        var found: [ClaudeMdFile] = []
        for case let url as URL in enumerator {
            // ponytail: depth cap at 5 to skip deep node_modules etc.
            if (enumerator.level) > 5 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "CLAUDE.md" else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let rel = url.path.hasPrefix(base.path + "/")
                ? String(url.path.dropFirst(base.path.count + 1))
                : url.lastPathComponent
            found.append(ClaudeMdFile(name: rel, path: url, modifiedAt: modified))
        }

        // Sort: root CLAUDE.md first, then by depth (fewest slashes), then alphabetically
        files = found.sorted {
            let aDepth = $0.name.components(separatedBy: "/").count
            let bDepth = $1.name.components(separatedBy: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            return $0.name < $1.name
        }
    }
}
