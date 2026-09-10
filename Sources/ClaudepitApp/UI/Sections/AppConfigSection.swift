import SwiftUI
import ClaudepitCore

/// App Settings page: lists every Claudepit-managed Claude-config, explains what it does and
/// where it writes, and lets the user enable/disable, edit, and reset each one (per-project).
struct AppConfigSection: View {
    @ObservedObject var app: AppState
    @State private var expandedID: String?
    @State private var editing: ManagedConfig?
    /// Bumped after any mutation to force the cards to re-read store state.
    @State private var refresh = 0

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                titleBar
                Divider().opacity(0.2)
                if app.activePath == nil {
                    EmptyState("Open a project to manage its Claude configuration.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ManagedConfig.catalog) { configCard($0) }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .sheet(item: $editing) { c in
            ConfigEditorSheet(base: app.activePath!, config: c, app: app) { refresh += 1 }
        }
        .onAppear { applyFocusManagedConfigID() }
        .onChange(of: app.focusManagedConfigID) { applyFocusManagedConfigID() }
    }

    /// Consume the one-shot deep link from a ManagedBadge / "Manage in App Settings": expand the
    /// named card, then clear the field so it doesn't re-fire.
    private func applyFocusManagedConfigID() {
        guard let id = app.focusManagedConfigID else { return }
        expandedID = id
        app.focusManagedConfigID = nil
    }

    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("App Settings").font(.title3).bold()
                Text("Claude configuration Claudepit installs for this project. Toggle, edit, or reset each item — your edits override the built-in default.")
                    .font(.caption).foregroundStyle(.secondary)
                if let base = app.activePath {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 9))
                        Text(Paths.appConfigDir(base).path)
                            .font(.caption2.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Text("— your editable copies. Claudepit installs from here, not from its built-ins.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Auto-update state of the entry's editable copy, shown in the card header. Suppressed for
    /// `.number` entries — they have no copy on disk, so there is nothing to auto-update.
    /// Takes the status rather than re-reading it: `status` hashes the file, so the card computes
    /// it once and shares it with the Reset helper text.
    @ViewBuilder
    private func statusBadge(_ c: ManagedConfig, _ status: ManagedCopyStatus) -> some View {
        if !c.filename.isEmpty {
            switch status {
            case .untouched: Pill("Default (auto-updates)", color: .secondary)
            case .edited:    Pill("Modified — auto-update paused", color: .orange)
            case .missing:   Pill("Not installed", color: .red)
            }
        }
    }

    /// Every file this entry writes, straight from `ManagedArtifacts` so the list can't drift from
    /// what the installer actually does. Paths are derived live from `Paths`, so they are correct
    /// on whatever machine this is.
    @ViewBuilder
    private func filesMap(_ base: URL, _ c: ManagedConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(ManagedArtifacts.writtenFiles(for: c, base: base).enumerated()), id: \.offset) { _, f in
                // A row for a file that isn't there yet (entry toggled off, or never installed)
                // would otherwise look live and do nothing when clicked.
                let exists = FileManager.default.fileExists(atPath: f.url.path)
                HStack(spacing: 8) {
                    Text(roleLabel(f))
                        .font(.caption2).bold()
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 140, alignment: .leading)
                    FilePathLabel(url: f.url)
                    if !exists {
                        Text("not installed").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    OpenInEditorButton(url: f.url)
                }
                .opacity(exists ? 1 : 0.55)
            }
        }
    }

    private func roleLabel(_ f: ManagedArtifacts.WrittenFile) -> String {
        switch f.role {
        case .editableCopy:     return "Editable copy"
        case .installedScript:  return "Script"
        case .installedCommand: return "Command"
        case .settings:         return f.detail
        }
    }

    private func configCard(_ c: ManagedConfig) -> some View {
        let base = app.activePath!
        let enabled = { app.appConfig.isEnabled(base, c.id) }
        // Computed once per card render (it reads and hashes the copy); `body` re-runs when
        // `refresh` bumps, so Edit/Reset still update it immediately.
        let status = app.appConfig.status(base, c)
        return ExpandableCard(
            expanded: Binding(
                get: { expandedID == c.id },
                set: { expandedID = $0 ? c.id : nil }
            ),
            header: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.callout).fontWeight(.medium)
                        Text(c.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    statusBadge(c, status)
                    PillToggle(isOn: enabled()) { on in
                        app.setConfigEnabled(c.id, on)
                        refresh += 1
                    }
                }
                .id(refresh)
            },
            detail: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SectionHeaderLabel("Writes to", icon: "doc")
                    filesMap(base, c)

                    if c.kind == .number {
                        cleanupControls(base)
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                editing = c
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                app.resetConfig(c)
                                refresh += 1
                            } label: {
                                Label("Reset to default", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)

                        if status == .edited {
                            Text("Reset restores the app default and re-enables auto-update.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .id(refresh)
            }
        )
    }

    @ViewBuilder
    private func cleanupControls(_ base: URL) -> some View {
        HStack(spacing: 8) {
            Text("Keep transcripts for")
                .font(.caption).foregroundStyle(.secondary)
            TextField("days", value: Binding(
                get: { app.appConfig.cleanupPeriodDays(base) },
                set: { app.setCleanupDays(max(1, $0)); refresh += 1 }
            ), format: .number)
            .frame(width: 80)
            .textFieldStyle(.roundedBorder)
            Text("days")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Plain-text editor sheet for a managed config's editable copy (adapted from JsonEditorSheet —
/// no JSON validation, since these are shell scripts / markdown).
private struct ConfigEditorSheet: View {
    let base: URL
    let config: ManagedConfig
    @ObservedObject var app: AppState
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.title).font(.subheadline).bold()
                    Text(Paths.appConfigDir(base).appending(path: config.filename).path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(text.components(separatedBy: "\n").count) lines")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.quaternary)
                Button("Reset to default") { text = config.builtinDefault }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().opacity(0.2)

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(.black.opacity(0.3))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            HStack(spacing: 5) {
                Image(systemName: Icon.info).font(.system(size: 10))
                Text("Saving pauses auto-update for this item until you Reset to default.")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
        .frame(minWidth: 680, minHeight: 540)
        .background(.ultraThinMaterial)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = app.appConfig.content(base, config)
        }
    }

    private func save() {
        try? app.appConfig.saveContent(base, config, text)
        app.syncManagedConfigs()
        onSaved()
        dismiss()
    }
}
