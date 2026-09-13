import SwiftUI
import ClaudepitCore
import AppKit

struct HomeSection: View {
    @ObservedObject var app: AppState

    /// Width `HomeSection.body` was proposed, measured by the background probe on the root
    /// stack. `0` until the first measurement lands — `HomeLayout.columnWidths` returns nil
    /// there, so the very first frame renders single-column.
    @State private var contentWidth: CGFloat = 0

    @State private var showAllAttention = false

    private var attention: [AttentionItem] {
        buildAttention(tasks: app.tasks, worktrees: app.worktrees)
    }

    /// Deliberately unmemoized, like `attention`: both arrays are tiny, and a cache keyed on
    /// herdr-agent equality is more fragile than the recompute.
    private var liveAgents: [LiveAgentItem] {
        buildLiveAgents(agents: app.herdrAgents, tasks: app.tasks)
    }

    /// The two lists above, folded into the one list the card actually renders.
    private var workstream: [WorkItem] {
        buildWorkstream(attention: attention, agents: liveAgents, tasks: app.tasks)
    }

    var body: some View {
        LazyVStack(spacing: 16) {
            if app.activePath != nil {
                responsiveBody
            } else {
                welcomePanel
            }
        }
        // Load-bearing, and it must precede `.background`. `.background(...)` is sized to the
        // root stack's own reported frame, and a (Lazy)VStack reports max(child widths) — it
        // does not clamp to the proposal. In the two-column branch the HStack's children carry
        // fixed widths computed from the PREVIOUS contentWidth, so on a narrowing window the
        // stack keeps reporting the old width, the probe re-reports a stale value, and the
        // layout would widen but never narrow. This makes the measured frame equal the
        // proposed width regardless of child overflow.
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { contentWidth = proxy.size.width }
            }
        )
        .onAppear {
            app.reloadSessions()
            app.loadTasks()
            app.reloadUsageCaches(thenRefreshIfStale: true)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.setActivePath(url)
        }
    }

    // MARK: - Welcome panel (no active project)

    private var welcomePanel: some View {
        GlassCard {
            VStack(spacing: 14) {
                Image(systemName: "house")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Claudepit")
                    .font(.title2.bold())
                Text("A GUI for Claude Code — sessions, tasks, plans, and settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open…") { chooseFolder() }
                    .buttonStyle(.borderedProminent)
                if !app.recentPaths.isEmpty { recentsBlock }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
    }

    /// Recent projects list. One child of the outer `VStack(spacing: 14)` so the panel's
    /// spacing does not leak between rows — rows sit 2pt apart, matching `PathBar`.
    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().opacity(0.15).padding(.bottom, 6)
            Text("Recent Projects")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            ForEach(app.recentPaths, id: \.self) { p in recentRow(p) }
        }
        .frame(maxWidth: 320)
    }

    /// Mirrors `PathBar.recentPopover`'s row (PathBar.swift:83-105) without its
    /// checkmark/highlight branch, which keys off `p == app.activePath` and is dead here.
    private func recentRow(_ p: URL) -> some View {
        Button {
            app.setActivePath(p)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(p.lastPathComponent)
                    .font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Responsive region

    /// Two columns when the measured width allows it, one otherwise. Holds no content itself.
    /// `contentWidth` starts at 0, so the first frame after entering Home renders single-column
    /// and the next frame is two-column — accepted, not eliminated: removing it would need the
    /// width to outlive the view (an AppState field), which is out of scope.
    @ViewBuilder private var responsiveBody: some View {
        if let cols = HomeLayout.columnWidths(width: contentWidth) {
            HStack(alignment: .top, spacing: HomeLayout.columnSpacing) {
                leftColumn.frame(width: cols.left)
                rightColumn.frame(width: cols.right)
            }
        } else {
            VStack(spacing: 16) {
                tasksPipelineCard
                if !attention.isEmpty || !liveAgents.isEmpty { attentionCard }
                HomeUsageCard(app: app)
                HomeActivityCard(app: app)
            }
        }
    }

    /// The wide column carries the text-heavy activity feed; the narrow one gets the gauges
    /// and short lists. The reverse assignment left a tall void beside the feed — the right
    /// column was several screens of wrapped text while the left ended after two cards.
    /// Needs attention sits between Tasks and Recent at the same width (user's placement).
    private var leftColumn: some View {
        VStack(spacing: 16) {
            tasksPipelineCard
            if !attention.isEmpty || !liveAgents.isEmpty { attentionCard }
            HomeActivityCard(app: app)
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 16) {
            HomeUsageCard(app: app)
        }
    }

    // MARK: - Attention card

    /// One list, not two — a chip strip above the rows printed the same name twice. `buildWorkstream`
    /// orders it: each task that wants something from you, trailed by the agent running it (its
    /// status is also the task row's trailing dot), then the agents nothing else accounts for.
    /// Only the task row of such a pair counts as needing attention.
    ///
    /// `workstream` is an unmemoized recompute (as are the two lists feeding it), so bind it once:
    /// the old body read `attention` three times a frame, re-running `buildAttention` each time.
    private var attentionCard: some View {
        let rows = workstream
        let shown = showAllAttention ? rows : Array(rows.prefix(6))
        return GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Live Agents")
                    .font(.headline)
                    .padding(.bottom, 2)
                VStack(spacing: 0) {
                    ForEach(shown) { workRow($0) }
                }
                if rows.count > 6 {
                    Button(showAllAttention ? "Show less" : "+\(rows.count - 6) more") {
                        showAllAttention.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    /// A row with a pane to focus opens it in herdr on click (the same `WorktreeResumer.focusPane`
    /// behind every "Focus in Herdr" button); everything else navigates inside the app. Which is
    /// which is `WorkItem.focusPane`'s call, shared with the menu bar panel.
    private func workRow(_ item: WorkItem) -> some View {
        let herdrPane: String? = WorktreeResumer.available() ? item.focusPane : nil
        return Button {
            if let pane = herdrPane {
                let cwd = app.activePath?.path ?? NSHomeDirectory()
                Task {
                    await WorktreeResumer.focusPane(paneID: pane, cwd: cwd)
                    app.activateHerdrHost()   // herdr is a TUI — selecting the pane is only half
                }
            } else {
                jump(work: item.target)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: workIcon(item))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(workTint(item))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // A live agent backs this row — shown as one dot rather than a second row.
                if let status = item.agentStatus {
                    Circle()
                        .fill(status == Herdr.AgentState.blocked ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                        .help("herdr agent · \(status)")
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(herdrPane == nil && item.target == .none)
        .help(herdrPane.map { "Focus pane \($0) in herdr" } ?? "")
    }

    /// The raised hand is the app's "waiting for you" mark — the same one session rows use for a
    /// herdr agent resting at `blocked` (`SessionsSection.swift`). A dirty worktree gets the branch
    /// icon instead: it needs you, but not in the same way a stalled agent does.
    private func workIcon(_ item: WorkItem) -> String {
        switch item.kind {
        case .dirtyWorktree:  return "arrow.triangle.branch"
        case .attentionTask:  return "hand.raised.fill"
        case .agent:          return item.needsAttention ? "hand.raised.fill" : "terminal"
        }
    }

    private func workTint(_ item: WorkItem) -> Color {
        if let severity = item.severity { return dotColor(severity) }
        return item.needsAttention ? .orange : .green
    }

    private func dotColor(_ s: AttentionSeverity) -> Color {
        switch s {
        case .failed:         return TaskStatus.failed.color
        case .blocked:        return TaskStatus.blocked.color
        case .awaitingReview: return TaskStatus.awaitingReview.color
        case .dirtyWorktree:  return .orange
        }
    }

    private func jump(work target: WorkItem.Target) {
        switch target {
        case .task(let id):        app.focusTaskID = id; app.selected = .tasks
        case .worktree(let name):  app.focusWorktreeName = name; app.selected = .worktrees
        case .session(let id):     app.focusSessionID = id; app.selected = .sessions
        case .none:                break
        }
    }

    // MARK: - Tasks pipeline card

    /// Always seven columns, Backlog through Done, zero counts included. The strip used to hide
    /// itself unless some task carried a phase, which meant a backlog-only or done-only project saw
    /// a one-line apology instead of the shape of its own work — and `phase` is nil for exactly
    /// those two statuses, so they were the states most likely to hit it.
    private var tasksPipelineCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tasks").font(.headline)
                    Spacer()
                    // The quick-actions row that used to carry "New Task" is gone with the
                    // identity header, so the action lives on the card it belongs to. The columns
                    // below already open the Tasks board, each with its own filter preselected.
                    Button {
                        app.openNewTaskPanel = true
                        app.selected = .tasks
                    } label: {
                        // The app's standard tinted action button (see PluginsSection's
                        // "Reload Plugins"): caption text, 10pt glyph, blue-on-blue-15%.
                        HStack(spacing: 4) {
                            Image(systemName: Icon.add).font(.system(size: 10, weight: .medium))
                            Text("New Task").font(.caption).fontWeight(.medium)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Create a task")
                }
                HStack(spacing: 0) {
                    ForEach(buildTaskPipeline(tasks: app.tasks)) { pipelineColumn($0) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func pipelineColumn(_ bucket: TaskPipelineBucket) -> some View {
        let badgeBackground: Color = bucket.inFlight ? Color.accentColor.opacity(0.25)
                                                     : Color.white.opacity(0.06)
        return Button {
            // Both intents land in `TasksSection.applyPendingIntents()`, which preselects the
            // matching filter. The ends are statuses, the middle is a phase — see TaskPipelineBucket.
            switch bucket.kind {
            case .backlog:      app.focusTaskStatusFilter = .backlog
            case .done:         app.focusTaskStatusFilter = .done
            case .phase(let p): app.focusTaskPhase = p
            }
            app.selected = .tasks
        } label: {
            VStack(spacing: 4) {
                Text(bucket.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                ZStack {
                    Circle()
                        .fill(badgeBackground)
                        .frame(width: 30, height: 30)
                    Text("\(bucket.count)")
                        .font(.caption.bold())
                        .foregroundStyle(bucket.count == 0 ? .secondary : .primary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help("Show \(bucket.title) tasks")
    }

}
