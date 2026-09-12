import SwiftUI
import AppKit
import ClaudepitCore

/// The dropdown behind the status-bar item (`MenuBarExtra`, `.window` style).
///
/// Deliberately a *view* of the same `AppState` the main window renders, not a second source of
/// truth: it builds `buildWorkstream` exactly as `HomeSection` does, so the count in the menu bar
/// and the "Needs attention" card can never disagree. Everything here is read-only — the only
/// mutations are the one-shot focus fields that drive navigation.
struct MenuBarPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        let summary = menuBarSummary(app)
        VStack(alignment: .leading, spacing: 0) {
            header(summary)
            Divider().padding(.horizontal, 12)
            if summary.rows.isEmpty {
                Text(app.activePath == nil ? "No project open." : "Nothing needs you right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(summary.rows) { row($0) }
                }
                .padding(.vertical, 4)
                if summary.overflow > 0 {
                    Text("+\(summary.overflow) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
            }
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private func header(_ summary: MenuBarSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.activePath?.lastPathComponent ?? "Claudepit")
                .font(.headline)
                .lineLimit(1)
            Text(summary.headline)
                .font(.caption)
                .foregroundStyle(summary.needsAttention ? Color.orange : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Rows

    /// Mirrors `HomeSection.workRow` — same icon vocabulary (raised hand = waiting on you), same
    /// trailing dot for the agent backing a row, and the same click contract: an agent row with a
    /// live pane focuses that pane in herdr, everything else navigates inside the app and brings
    /// the main window forward. The panel closes on its own either way, because whichever app ends
    /// up frontmost is not this one.
    ///
    /// The `kind == .agent` guard is not redundant with `paneID != nil`: `buildWorkstream` sets a
    /// pane id only on standalone agent rows, and an attention row that *folded* an agent in keeps
    /// its in-app target on purpose — clicking a blocked task should land on the task.
    private func row(_ item: WorkItem) -> some View {
        let herdrPane: String? =
            (item.kind == .agent && WorktreeResumer.available()) ? item.paneID : nil
        return Button {
            if let pane = herdrPane {
                let cwd = app.activePath?.path ?? NSHomeDirectory()
                Task { await WorktreeResumer.focusPane(paneID: pane, cwd: cwd) }
            } else {
                open(item.target)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(item))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint(item))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline).lineLimit(1)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let status = item.agentStatus {
                    Circle()
                        .fill(status == Herdr.AgentState.blocked ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(herdrPane == nil && item.target == .none)
        .help(herdrPane.map { "Focus pane \($0) in herdr" } ?? "")
    }

    private func icon(_ item: WorkItem) -> String {
        switch item.kind {
        case .dirtyWorktree:  return "arrow.triangle.branch"
        case .attentionTask:  return "hand.raised.fill"
        case .agent:          return item.needsAttention ? "hand.raised.fill" : "terminal"
        }
    }

    private func tint(_ item: WorkItem) -> Color {
        switch item.severity {
        case .failed?:          return TaskStatus.failed.color
        case .blocked?:         return TaskStatus.blocked.color
        case .awaitingReview?:  return TaskStatus.awaitingReview.color
        case .dirtyWorktree?:   return .orange
        case nil:               return item.needsAttention ? .orange : .green
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open Claudepit") { activateMainWindow() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            Button("Tasks") { focus { app.selected = .tasks } }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Navigation

    /// The same one-shot focus contract the in-app deep links use (see CLAUDE.md, "Focus Pattern").
    private func open(_ target: WorkItem.Target) {
        switch target {
        case .task(let id):       focus { app.focusTaskID = id;        app.selected = .tasks }
        case .worktree(let name): focus { app.focusWorktreeName = name; app.selected = .worktrees }
        case .session(let id):    focus { app.focusSessionID = id;      app.selected = .sessions }
        case .none:               break
        }
    }

    private func focus(_ navigate: () -> Void) {
        navigate()
        activateMainWindow()
    }

    /// Bring the real window forward. `MenuBarExtra`'s own panel is in `NSApp.windows` too and
    /// must not be mistaken for it — it neither becomes main nor carries a title.
    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
        main?.makeKeyAndOrderFront(nil)
    }
}

/// Shared by the panel and the status item's label so both describe the same state.
@MainActor func menuBarSummary(_ app: AppState) -> MenuBarSummary {
    let attention = buildAttention(tasks: app.tasks, worktrees: app.worktrees)
    let agents = buildLiveAgents(agents: app.herdrAgents, tasks: app.tasks)
    return buildMenuBarSummary(
        workstream: buildWorkstream(attention: attention, agents: agents, tasks: app.tasks))
}

/// The status-bar label: one SF Symbol plus a count per `MenuBarSummary.segments`, so a glance
/// says both *what kind* of activity and *how much* — and, when something is blocked while other
/// agents keep working, says both at once (`✋1 ⚡2`) instead of hiding the working count behind
/// the raised hand. `MenuBarExtra` renders `Text`/`Image` and stacks of them; anything richer
/// (a shape, a `Circle` badge) is silently dropped by AppKit's status-item hosting, and the image
/// is drawn as a template, so the states differ by symbol rather than by tint.
struct MenuBarLabel: View {
    @ObservedObject var app: AppState

    var body: some View {
        let summary = menuBarSummary(app)
        HStack(spacing: 5) {
            ForEach(summary.segments, id: \.symbol) { segment in
                HStack(spacing: 3) {
                    Image(systemName: segment.symbol)
                    if let count = segment.count { Text(count) }
                }
            }
        }
        .help(summary.headline)
    }
}
