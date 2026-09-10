import SwiftUI
import ClaudepitCore
import AppKit

struct HomeSection: View {
    @ObservedObject var app: AppState
    @State private var plans: [PlanFile] = []

    private var attention: [AttentionItem] {
        buildAttention(tasks: app.tasks, worktrees: app.worktrees)
    }

    var body: some View {
        LazyVStack(spacing: 16) {
            identityCard
            if !attention.isEmpty { attentionCard }
            if app.activePath != nil {
                statsStripCard
                tasksPipelineCard
                recentCard
            }
        }
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

    // MARK: - Identity card

    private var identityCard: some View {
        GlassCard {
            if let base = app.activePath {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(base.lastPathComponent)
                            .font(.title2)
                            .bold()
                        Text(String(Paths.slug(for: base).prefix(40)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fontDesign(.monospaced)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        attentionBadge
                        capsuleChip("\(app.sessions.count) sessions")
                        capsuleChip("\(app.tasks.count) tasks")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 10) {
                    Text("Open a project to get started")
                        .foregroundStyle(.secondary)
                    Button("Open…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            app.setActivePath(url)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
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
                VStack(spacing: 4) {
                    ForEach(attention.prefix(6)) { item in
                        Button { jump(to: item.target) } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(dotColor(item.severity))
                                    .frame(width: 8, height: 8)
                                Text(item.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
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

    // MARK: - Stats strip card

    private var statsStripCard: some View {
        let doneCount = app.tasks.filter { $0.status == .done }.count
        let inFlight = app.tasks.filter {
            $0.status == .running || $0.status == .blocked || $0.status == .awaitingReview
        }.count
        let activeSessions = app.sessions.filter(\.isActive).count
        return GlassCard {
            HStack(spacing: 0) {
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
