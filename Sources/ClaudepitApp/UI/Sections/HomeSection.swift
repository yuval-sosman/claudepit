import SwiftUI
import ClaudepitCore
import AppKit

struct HomeSection: View {
    @ObservedObject var app: AppState
    @State private var plans: [PlanFile] = []

    /// Width `HomeSection.body` was proposed, measured by the background probe on the root
    /// stack. `0` until the first measurement lands — `HomeLayout.columnWidths` returns nil
    /// there, so the very first frame renders single-column.
    @State private var contentWidth: CGFloat = 0

    private var attention: [AttentionItem] {
        buildAttention(tasks: app.tasks, worktrees: app.worktrees)
    }

    var body: some View {
        LazyVStack(spacing: 16) {
            if app.activePath != nil {
                identityHeader
                if !attention.isEmpty { attentionCard }
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
            reloadPlans()
        }
        .onChange(of: app.plansChangeToken) { reloadPlans() }
        .onChange(of: app.activePath) { reloadPlans() }
    }

    // MARK: - Plans data

    private func reloadPlans() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Paths.plansRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { plans = []; return }
        plans = items
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> PlanFile? in
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = attrs?.contentModificationDate ?? Date.distantPast
                let name = url.deletingPathExtension().lastPathComponent
                return PlanFile(name: name, path: url, modifiedAt: modified)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
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

    // MARK: - Identity header

    @ViewBuilder private var identityHeader: some View {
        if let base = app.activePath {
            GlassCard {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(base.lastPathComponent)
                        .font(.headline)
                    Text(String(Paths.slug(for: base).prefix(40)))
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    HStack(spacing: 6) {
                        attentionBadge
                        capsuleChip("\(app.sessions.count) sessions")
                        capsuleChip("\(app.tasks.count) tasks")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
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
                recentCard.frame(width: cols.right)
            }
        } else {
            VStack(spacing: 16) {
                statsGridCard
                tasksPipelineCard
                recentCard
            }
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 16) {
            statsGridCard
            tasksPipelineCard
        }
    }

    @ViewBuilder private var attentionBadge: some View {
        if attention.isEmpty {
            Label("All clear", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let urgent = attention.contains { $0.severity == .failed || $0.severity == .blocked }
            Label("\(attention.count)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(urgent ? .red : .orange)
        }
    }

    private func capsuleChip(_ label: String) -> some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    // MARK: - Attention card

    private var attentionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Needs attention").font(.headline)
                VStack(spacing: 2) {
                    ForEach(attention.prefix(6)) { item in
                        attentionRow(item)
                    }
                }
                if attention.count > 6 {
                    Text("+\(attention.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        Button { jump(to: item.target) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(dotColor(item.severity))
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ s: AttentionSeverity) -> Color {
        switch s {
        case .failed:         return TaskStatus.failed.color
        case .blocked:        return TaskStatus.blocked.color
        case .awaitingReview: return TaskStatus.awaitingReview.color
        case .dirtyWorktree:  return .orange
        }
    }

    private func jump(to target: AttentionItem.Target) {
        switch target {
        case .task(let id):        app.focusTaskID = id; app.selected = .tasks
        case .worktree(let name):  app.focusWorktreeName = name; app.selected = .worktrees
        }
    }

    // MARK: - Stats grid card

    private var statsGridCard: some View {
        let doneCount = app.tasks.filter { $0.status == .done }.count
        let inFlight = app.tasks.filter {
            $0.status == .running || $0.status == .blocked || $0.status == .awaitingReview
        }.count
        let activeSessions = app.sessions.filter(\.isActive).count
        return GlassCard {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                alignment: .leading,
                spacing: 12
            ) {
                statTile("Tasks", "\(app.tasks.count)") { app.selected = .tasks }
                statTile("Done", "\(doneCount)/\(app.tasks.count)") { app.selected = .tasks }
                statTile("In Flight", "\(inFlight)") { app.selected = .tasks }
                statTile("Sessions", "\(app.sessions.count)") { app.selected = .sessions }
                statTile("Active", "\(activeSessions)") { app.selected = .sessions }
                statTile("Worktrees", "\(app.worktrees.count)") { app.selected = .worktrees }
                statTile("Plans", "\(plans.count)") { app.selected = .plans }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func statTile(_ label: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(value).font(.title3.bold())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tasks pipeline card

    private var tasksPipelineCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tasks").font(.headline)
                    Spacer()
                    Button("Open Tasks") { app.selected = .tasks }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }

                if app.tasks.isEmpty {
                    HStack {
                        Text("No tasks yet").foregroundStyle(.secondary)
                        Spacer()
                        Button("New Task") { app.selected = .tasks }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    HStack(spacing: 0) {
                        ForEach(TaskPhase.allCases, id: \.self) { phase in
                            taskPhaseColumn(phase)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func taskPhaseColumn(_ phase: TaskPhase) -> some View {
        let count = app.tasks.filter { $0.phase == phase }.count
        let inFlight = app.tasks.contains {
            $0.phase == phase && ($0.status == .running || $0.status == .blocked || $0.status == .awaitingReview)
        }
        let badgeBackground: Color = inFlight ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06)

        return Button { app.selected = .tasks } label: {
            VStack(spacing: 4) {
                Text(phase.shortTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                ZStack {
                    Circle()
                        .fill(badgeBackground)
                        .frame(width: 30, height: 30)
                    Text("\(count)")
                        .font(.caption.bold())
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent card (sessions digest + plans)

    private var recentCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent").font(.headline)

                // Newest session
                if app.sessions.isEmpty {
                    Text("No sessions recorded for this project.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let session = app.sessions.first {
                    let activeCount = app.sessions.filter(\.isActive).count
                    Button {
                        app.focusSessionID = session.id
                        app.selected = .sessions
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if activeCount > 0 {
                                Text("\(activeCount) active now")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if let summary = session.bulletSummary, !summary.bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(summary.bullets.prefix(4), id: \.self) { bullet in
                                HStack(alignment: .top, spacing: 4) {
                                    Text("·")
                                    Text(bullet)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Top plans
                if !plans.isEmpty {
                    Divider().opacity(0.15)
                    VStack(spacing: 0) {
                        ForEach(plans.prefix(5)) { plan in
                            Button {
                                app.focusPlanPath = plan.path.path
                                app.selected = .plans
                            } label: {
                                HStack {
                                    Text(plan.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(plan.modifiedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}
