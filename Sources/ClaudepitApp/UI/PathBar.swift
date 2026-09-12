import SwiftUI
import AppKit

struct PathBar: View {
    @ObservedObject var app: AppState
    @State private var showRecentPopover = false

    var body: some View {
        GlassCard(content: {
            HStack(spacing: 10) {
                breadcrumbs
                Spacer()
                // Reveal lives here rather than in Home's quick actions: it acts on the project
                // the breadcrumb already names, and it is wanted from every section, not just Home.
                Button { if let base = app.activePath { NSWorkspace.shared.open(base) } } label: {
                    Image(systemName: Icon.revealInFinder)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open the project folder in Finder")
                .disabled(app.activePath == nil)
                Button { app.selected = .appConfig } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(app.selected == .appConfig ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help("App Settings")
                .disabled(app.activePath == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }, cornerRadius: 12)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            projectButton

            if let sessionCrumb = app.breadcrumbSessionCrumb, app.selected == .plans {
                // Cross-section trail: project › Sessions › session-title › Plans › plan-title
                chevron
                crumbButton("Sessions") { app.selected = .sessions }
                chevron
                crumbButton(truncate(sessionCrumb)) {
                    if let sid = app.breadcrumbSessionID {
                        app.focusSessionID = sid
                    }
                    app.selected = .sessions
                }
                chevron
                Text(app.selected.title).foregroundStyle(.secondary)
                if let item = selectedItemTitle {
                    chevron
                    Text(item).foregroundStyle(.secondary)
                }
            } else {
                // Normal trail: project › Section › item
                chevron
                Text(app.selected.title).foregroundStyle(.secondary)
                if let item = selectedItemTitle {
                    chevron
                    Text(item).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var projectButton: some View {
        Button {
            if !app.recentPaths.isEmpty { showRecentPopover = true }
        } label: {
            Text(app.activePath?.lastPathComponent ?? "No project")
                .bold()
                .foregroundStyle(app.recentPaths.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showRecentPopover, arrowEdge: .bottom) {
            recentPopover
        }
    }

    private var recentPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent Projects")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            Divider()
            ForEach(app.recentPaths, id: \.self) { p in
                Button {
                    app.setActivePath(p)
                    showRecentPopover = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(p.lastPathComponent)
                            .font(.subheadline)
                        Spacer()
                        if p == app.activePath {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(p == app.activePath ? Color.accentColor.opacity(0.1) : Color.clear)
            }
            Divider()
            Button {
                showRecentPopover = false
                chooseFolder()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Open Other…")
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
        .frame(width: 220)
    }

    private func crumbButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
    }

    private var selectedItemTitle: String? {
        switch app.selected {
        case .sessions:
            return app.selectedSessionID
                .flatMap { id in app.sessions.first { $0.id == id }?.title }
                .map(truncate)
        case .plans:
            return app.selectedPlanName.map(truncate)
        case .memory:
            return app.selectedMemoryTitle.map(truncate)
        default:
            return nil
        }
    }

    private func truncate(_ s: String) -> String {
        s.count > 24 ? String(s.prefix(24)) + "…" : s
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { app.setActivePath(url) }
    }
}
