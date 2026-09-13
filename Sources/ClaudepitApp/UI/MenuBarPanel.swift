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
            usage
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 320)
        .onAppear { app.ensureUsageLoaded() }
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
    /// trailing dot for the agent backing a row, and the same click contract: a row with a pane to
    /// focus (`WorkItem.focusPane` — every agent row, and a task whose agent is blocked on a
    /// question) opens that pane in herdr; everything else navigates inside the app and brings the
    /// main window forward. The panel closes on its own either way, because whichever app ends up
    /// frontmost is not this one.
    private func row(_ item: WorkItem) -> some View {
        let herdrPane: String? = WorktreeResumer.available() ? item.focusPane : nil
        return Button {
            if let pane = herdrPane {
                let cwd = app.activePath?.path ?? NSHomeDirectory()
                Task {
                    await WorktreeResumer.focusPane(paneID: pane, cwd: cwd)
                    app.activateHerdrHost()   // herdr is a TUI — selecting the pane is only half
                }
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

    // MARK: - Usage

    /// The same limit bars as Home's Claude Code card, from the same cached snapshot.
    ///
    /// Reads `app.usageSnapshot` and nothing else — opening the panel never fetches. The numbers
    /// come from the CLI's own cache in `~/.claude.json`, which `AppState.ensureUsageLoaded()`
    /// reads once and then only re-reads when it has actually gone stale, so the age is shown
    /// beside the header rather than implied to be live.
    @ViewBuilder private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Usage").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let snap = app.usageSnapshot {
                    Text(snap.fetchedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(snap.isStale() ? Color.orange : .secondary)
                }
            }
            if let snap = app.usageSnapshot {
                UsageGaugeStack(gauges: snap.gauges, compact: true)
            } else {
                Text(app.claudeAuth?.needsSignIn == true
                     ? "Sign in to Claude Code to see your limits."
                     : "No usage data cached yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        workstream: buildWorkstream(attention: attention, agents: agents, tasks: app.tasks),
        // Shown only when nothing is running, so a quiet menu bar still reports something and
        // stays obviously clickable. Read from the cached snapshot — never a fetch.
        usage: app.usageSnapshot?.busiestGauge)
}

/// The status-bar label: one SF Symbol plus a count per `MenuBarSummary.segments`, so a glance
/// says both *what kind* of activity and *how much* — and, when something is waiting on you while
/// other agents keep working, says both at once (`✋1  ⚡2`) instead of hiding the working count
/// behind the raised hand.
///
/// **The label is one pre-rendered image, on purpose.** AppKit's status-item hosting keeps only
/// the first `Image` and `Text` of a `MenuBarExtra` label and drops the rest; worse, anything
/// *dynamic* loses its symbols entirely. All of this was measured on macOS 26:
///
/// - `HStack { icon; count; icon; count }` → renders the first pair only.
/// - `Text("\(Image(systemName: "hand.raised.fill"))1  \(Image(systemName: "bolt…"))2")` →
///   renders fully, but only while every interpolation is a **literal**; swap in a variable symbol
///   name or count and the glyphs vanish, leaving a bare "1  2".
/// - `Text(Image(…)) + Text(verbatim: count)` → same bare numbers, concatenation drops the images.
///
/// Compositing the symbols and counts into a single template `NSImage` sidesteps the whole budget:
/// it is one `Image`, it stays dynamic, and `isTemplate` keeps it tinted by the menu bar exactly
/// like the system items next to it (which is also why the states must differ by *shape* — a
/// SwiftUI tint would be discarded here).
struct MenuBarLabel: View {
    @ObservedObject var app: AppState

    var body: some View {
        let summary = menuBarSummary(app)
        Image(nsImage: MenuBarLabel.render(summary.segments))
            .accessibilityLabel(summary.headline)
            .help(summary.headline)
            // The status item is on screen from launch, whatever section the window shows, so this
            // is where the cached usage has to be loaded for the idle label to report it. Same
            // guarded call the panel makes: at most one cache read, and a fetch only when stale.
            .onAppear { app.ensureUsageLoaded() }
    }

    /// Draw the segments left to right into one template image sized to the menu bar's own font.
    static func render(_ segments: [MenuBarSummary.Segment]) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .medium)
        let drawn: [(symbol: NSImage?, count: NSAttributedString?)] = segments.map {
            (NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig),
             $0.count.map { NSAttributedString(string: $0, attributes: attrs) })
        }
        let gap: CGFloat = 2       // symbol → its own count
        let between: CGFloat = 7   // one segment → the next

        var width: CGFloat = 0
        for (index, part) in drawn.enumerated() {
            if index > 0 { width += between }
            width += (part.symbol?.size.width ?? 0)
            if let count = part.count { width += gap + count.size().width }
        }
        let height = max(drawn.compactMap { $0.symbol?.size.height }.max() ?? 16, font.pointSize + 4)

        let image = NSImage(size: NSSize(width: max(1, ceil(width)), height: ceil(height)),
                            flipped: false) { _ in
            var x: CGFloat = 0
            for (index, part) in drawn.enumerated() {
                if index > 0 { x += between }
                if let symbol = part.symbol {
                    symbol.draw(in: NSRect(x: x, y: (height - symbol.size.height) / 2,
                                           width: symbol.size.width, height: symbol.size.height),
                                from: .zero, operation: .sourceOver, fraction: 1)
                    x += symbol.size.width
                }
                if let count = part.count {
                    x += gap
                    count.draw(at: NSPoint(x: x, y: (height - count.size().height) / 2))
                    x += count.size().width
                }
            }
            return true
        }
        image.isTemplate = true   // let the menu bar tint it (light/dark, inactive, highlighted)
        return image
    }
}
