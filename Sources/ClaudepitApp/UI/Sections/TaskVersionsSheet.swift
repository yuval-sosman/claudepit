import SwiftUI
import ClaudepitCore

/// Compare / edit / apply / promote a task's suggestion versions against its main version.
/// Two-pane layout. Left = Main (pinned) + suggestions with a "N changed" badge. Right = the shared
/// `VersionComparePane`. Read-only unless the task is in Backlog.
struct TaskVersionsSheet: View {
    let taskID: String
    @ObservedObject var app: AppState
    var onClose: () -> Void

    @State private var selectedID: String?
    @State private var draft: TaskVersion?

    private var task: ProjectTask? { app.tasks.first { $0.id == taskID } }
    private var editable: Bool { task?.status == .backlog }
    private var suggestions: [TaskVersion] { task?.suggestions ?? [] }
    private var main: TaskVersion? { task?.mainVersion }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if !editable {
                Label("Versions are locked once the task leaves Backlog — view only.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(.orange.opacity(0.08))
            }
            HStack(spacing: 0) {
                versionList.frame(width: 240).frame(maxHeight: .infinity)
                Divider().opacity(0.2)
                comparePanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial)
        .onAppear { if selectedID == nil { select(suggestions.first?.id) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 15)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Compare versions").font(.headline)
                Text(task?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Left: version list (Main pinned + suggestions)

    private var versionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                mainRow
                Text("SUGGESTIONS").font(.caption2).fontWeight(.bold).foregroundStyle(.secondary)
                    .tracking(0.6).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                if suggestions.isEmpty {
                    Text("No suggestions yet.\nOpen a task and use New Draft to propose changes.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                } else {
                    ForEach(suggestions) { v in versionRow(v) }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var mainRow: some View {
        let isSel = selectedID == nil
        return HStack(spacing: 8) {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            Text("Main version").font(.caption.weight(.semibold))
                .foregroundStyle(isSel ? .primary : .secondary)
            Spacer()
            Text("live").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSel ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { select(nil) }
        .padding(.horizontal, 6)
    }

    private func versionRow(_ v: TaskVersion) -> some View {
        let isSel = selectedID == v.id
        let n = main.map { v.changedFields(vs: $0).count } ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name.isEmpty ? (v.label.isEmpty ? "Untitled" : v.label) : v.name)
                    .font(.caption).foregroundStyle(isSel ? .primary : .secondary).lineLimit(1)
                HStack(spacing: 5) {
                    if n == 0 {
                        Text("no changes").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text("\(n) changed").font(.caption2).foregroundStyle(Color.accentColor)
                    }
                    if !v.label.isEmpty { Text("· \(v.label)").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Spacer()
            if editable {
                Button { app.deleteSuggestion(task!, id: v.id) } label: {
                    Image(systemName: "trash").font(.caption2).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Delete version")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSel ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { select(v.id) }
        .padding(.horizontal, 6)
    }

    // MARK: - Right: compare panel

    @ViewBuilder
    private var comparePanel: some View {
        if selectedID == nil {
            mainPreview
        } else if let m = main, draft != nil {
            VersionComparePane(
                main: m,
                draft: Binding(get: { draft ?? m }, set: { d in draft = d; if let t = task { app.updateSuggestion(t, d) } }),
                editable: editable,
                headerTitle: draft?.name.isEmpty == false ? draft!.name : "This suggestion",
                onApplyField: { f in if let d = draft { app.acceptField(task!, d, f) } },
                onPromote: { if let d = draft { app.promoteToMain(task!, d); select(nil) } },
                depName: depName
            )
        } else {
            Text("Select a version").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Read-only view of Main when it's selected in the list.
    private var mainPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text("Main version").font(.title3.bold())
                    Spacer()
                    Text("the live task").font(.caption).foregroundStyle(.secondary)
                }
                if let m = main {
                    readOnlyRow("Summary", m.name)
                    readOnlyRow("Topic", m.topic.isEmpty ? "—" : m.topic)
                    readOnlyRow("Description", m.description.isEmpty ? "—" : m.description)
                    readOnlyRow("Requirements", m.requirements.isEmpty ? "—" : m.requirements.joined(separator: "\n"))
                    readOnlyRow("Priority", m.priority.label)
                    readOnlyRow("Label", m.tags.isEmpty ? "—" : m.tags.joined(separator: ", "))
                    readOnlyRow("Dependencies", m.dependsOn.isEmpty ? "—" : m.dependsOn.map(depName).joined(separator: ", "))
                }
                Text("Select a suggestion on the left to compare and apply its changes here.")
                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
            }
            .padding(18).frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func readOnlyRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.5)
            Text(value).font(.callout).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - State

    private func select(_ id: String?) {
        selectedID = id
        draft = id == nil ? nil : suggestions.first { $0.id == id }
    }

    private func depName(_ id: String) -> String { app.tasks.first { $0.id == id }?.name ?? id }
}
