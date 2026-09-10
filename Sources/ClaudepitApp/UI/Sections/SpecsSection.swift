import SwiftUI
import ClaudepitCore

struct SpecFile: Identifiable, Equatable {
    var id: URL { path }
    let taskID: String
    let name: String
    let path: URL
    let modifiedAt: Date
}

struct SpecsSection: View {
    @ObservedObject var app: AppState
    @State private var specs: [SpecFile] = []
    @State private var selectedSpec: SpecFile?

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            listCard
        } detail: {
            detailCard
        }
        .onAppear {
            reload()
            applyFocusSpecPath()
            if selectedSpec == nil { selectedSpec = specs.first }
        }
        .onChange(of: app.focusSpecPath) { applyFocusSpecPath() }
        .onChange(of: app.tasksChangeToken) { reload() }
    }

    // MARK: List card

    private var listCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Specs").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider().opacity(0.15)

                if specs.isEmpty {
                    EmptyState("No specs yet — run the Spec phase on a task")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(specs) { spec in
                                specRow(spec)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func specRow(_ spec: SpecFile) -> some View {
        HStack(spacing: 0) {
            Button { selectedSpec = spec } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(spec.modifiedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                fileContextMenu(url: spec.path)
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
        .selectableRowBackground(isSelected: selectedSpec == spec)
    }

    // MARK: Detail card

    private var detailCard: some View {
        Group {
            if let spec = selectedSpec {
                SpecDetailView(spec: spec, app: app) { reload() }
            } else {
                GlassCard {
                    EmptyState("Select a spec")
                }
            }
        }
    }

    // MARK: Data

    private func applyFocusSpecPath() {
        guard let path = app.focusSpecPath else { return }
        reload()
        selectedSpec = specs.first { $0.path.path == path }
        app.focusSpecPath = nil
    }

    private func reload() {
        guard let base = app.activePath else { specs = []; return }
        let slug = Paths.slug(for: base)
        let root = Paths.tasksRoot(projectSlug: slug)
        let fm = FileManager.default
        guard let taskDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { specs = []; return }

        specs = taskDirs.compactMap { taskDir -> SpecFile? in
            let specURL = taskDir.appendingPathComponent("spec.md")
            guard fm.fileExists(atPath: specURL.path) else { return nil }
            let attrs = try? specURL.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = attrs?.contentModificationDate ?? Date.distantPast
            // Read task name from task.json; fallback to task dir name
            let taskID = taskDir.lastPathComponent
            let name = taskName(taskDir: taskDir) ?? taskID
            return SpecFile(taskID: taskID, name: name, path: specURL, modifiedAt: modified)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func taskName(taskDir: URL) -> String? {
        let taskFile = taskDir.appendingPathComponent("task.json")
        guard let data = try? Data(contentsOf: taskFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return name
    }
}
