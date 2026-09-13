import SwiftUI
import ClaudepitCore

extension Priority {
    var color: Color {
        switch self {
        case .low: return .secondary; case .normal: return .blue
        case .high: return .orange; case .urgent: return .red
        }
    }
}

/// Live herdr state for a task's current phase agent.
enum TaskLiveState { case waiting, working, idle, none }

extension AppState {
    /// The live agent for the task's current phase, if herdr still has one.
    ///
    /// Matched by agent NAME first — `task-<id>-<phase>`, which TaskRunner owns — and only then by
    /// pane id, since panes get recycled between phases while names don't. Reads `herdrAgents`
    /// rather than `herdrSessions`: task agents carry no `agent_session`, so the session-keyed map
    /// never contains them (that mismatch is why the board's live state was dead).
    func liveState(of task: ProjectTask) -> TaskLiveState {
        let name = TaskRunner.agentName(id: task.id, phase: task.phase)
        var entry = herdrAgents.first { $0.name == name }
        if entry == nil, let pane = task.worktree?.paneID {
            entry = herdrAgents.first { $0.paneID == pane }
        }
        switch entry?.status {
        case Herdr.AgentState.working: return .working
        case Herdr.AgentState.blocked: return .waiting   // Claude rests at "blocked" when it asks you something
        case Herdr.AgentState.idle:    return .idle      // at its prompt — the turn is over
        default:                       return .none      // no agent / "unknown"
        }
    }
}

/// The ONE status a card shows — a small, clean set. The live-herdr signal (when
/// a pane is alive it wins — it's the real-time state) and the persisted task
/// status both fold into these. Raw value = sort rank (needs-you first, done last).
enum CardState: Int, CaseIterable {
    case waiting = 0     // needs you: agent blocked, or a finished phase with a decision outstanding
    case running = 1     // live agent generating OR a phase executing
    case failed = 2      // last phase failed — retry it
    case phaseDone = 3   // phase finished and you've dealt with it — send it to the next phase
    case notStarted = 4  // backlog — not started yet
    case done = 5        // whole task complete

    var color: Color {
        switch self {
        case .waiting:    return .orange
        case .running:    return .green
        case .failed:     return .red
        case .phaseDone:  return .mint
        case .notStarted: return .secondary
        case .done:       return .blue
        }
    }
    var label: String {
        switch self {
        case .waiting:    return "Waiting"
        case .running:    return "Running"
        case .failed:     return "Failed"
        case .phaseDone:  return "Phase done"
        case .notStarted: return "Not started"
        case .done:       return "Done"
        }
    }
    var help: String {
        switch self {
        case .waiting:    return "Needs you — the agent is asking something, or a phase stopped without producing its artifact"
        case .running:    return "A phase is actively running in herdr"
        case .failed:     return "Last phase failed — retry it"
        case .phaseDone:  return "This phase finished and nothing is pending from you — send it to the next phase"
        case .notStarted: return "Not started — still in the backlog"
        case .done:       return "Task complete"
        }
    }
    /// Waiting/failed need you to act, so they render bolder.
    var needsAttention: Bool { self == .waiting || self == .failed }
    var isRunning: Bool { self == .running }
}

extension AppState {
    /// Resolve the single merged card state.
    ///
    /// The terminal statuses decide on their own — a backlog/done/failed task is what it says it
    /// is, and a stale agent still sitting in its pane must not override that. For a task that is
    /// genuinely in flight, the live agent is the truth about *right now*: `working` → Running,
    /// `blocked` → Waiting. An `idle` agent (or none at all) tells us nothing the persisted status
    /// doesn't already say, so it defers to it.
    ///
    /// `.awaitingReview` deliberately splits in two via `phaseNeedsReview`: it means "the agent
    /// stopped", which is not the same as "you still owe it something". A phase that produced its
    /// deliverable reads Phase done — it does not stay Waiting until you open the file.
    func cardState(of task: ProjectTask) -> CardState {
        switch task.status {
        case .backlog: return .notStarted
        case .failed:  return .failed
        case .done:    return .done
        case .running, .blocked, .awaitingReview: break
        }
        switch liveState(of: task) {
        case .working:     return .running
        case .waiting:     return .waiting
        case .idle, .none: break
        }
        switch task.status {
        case .blocked:        return .waiting
        case .running:        return .running     // launching, or the agent hasn't surfaced yet
        case .awaitingReview: return task.phaseNeedsReview ? .waiting : .phaseDone
        default:              return .notStarted  // unreachable — the first switch took these
        }
    }
}

/// Shared task ordering used by both the list and the board.
@MainActor
func orderedBefore(_ a: ProjectTask, _ b: ProjectTask, sort: TasksSection.Sort, app: AppState) -> Bool {
    switch sort {
    case .attention:
        let sa = app.cardState(of: a).rawValue, sb = app.cardState(of: b).rawValue
        if sa != sb { return sa < sb }                       // needs-you first, done last
        if a.priority.rank != b.priority.rank { return a.priority.rank > b.priority.rank }
        return a.updatedAt > b.updatedAt
    case .priority:
        return a.priority.rank != b.priority.rank ? a.priority.rank > b.priority.rank : a.updatedAt > b.updatedAt
    case .updated:
        return a.updatedAt > b.updatedAt
    }
}

/// Shared task card used by both the list and the board.
struct TaskCardView: View {
    let task: ProjectTask
    @ObservedObject var app: AppState
    /// The board already groups cards by phase in a column, so it hides the
    /// redundant phase pill; the flat list shows it.
    var showPhase: Bool = true
    /// Tapping the "behind base" pill. Supplied by the board (select the task + arm the
    /// one-shot); nil in any other host, where the pill degrades to a tooltip-only badge.
    var onBehindTap: (() -> Void)? = nil

    private var blockers: [String] { TaskTransition.unmetDependencies(task, allTasks: app.tasks) }
    /// This task's worktree, if the last scan found it behind its base.
    private var behindWorktree: WorktreeInfo? {
        guard let p = task.worktree?.path else { return nil }
        return app.worktrees.first { $0.path == p && $0.isBehindBase }
    }
    @State private var showLegend = false

    var body: some View {
        let state = app.cardState(of: task)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(task.name).font(.callout).fontWeight(.medium).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { showLegend.toggle() } label: {
                    Image(systemName: Icon.info).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("What do these statuses mean?")
                .popover(isPresented: $showLegend, arrowEdge: .trailing) { CardStatusLegend() }
            }
            badgeRow
            HStack(spacing: 6) {
                // One merged indicator: colored dot (spinning arc when running) + short label.
                StatusDot(state: state)
                Text(state.label)
                    .font(.caption2)
                    .fontWeight(state.needsAttention ? .bold : .semibold)
                    .foregroundStyle(state.needsAttention ? AnyShapeStyle(state.color) : AnyShapeStyle(.secondary))
                    .help(state.help)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var badgeRow: some View {
        // FlowLayout so badges reflow onto a new line instead of colliding /
        // truncating when a card carries priority + phase + tags + blockers.
        FlowLayout(spacing: 5) {
            Pill(task.priority.label, color: task.priority.color, hPadding: 7, vPadding: 2)
            if task.hasSuggestions {
                Pill("v\((task.suggestions?.count ?? 0) + 1)", color: .purple, hPadding: 7, vPadding: 2)
                    .help("\((task.suggestions?.count ?? 0) + 1) versions")
            }
            if showPhase {
                Pill(task.phase?.shortTitle ?? (task.status == .done ? "Done" : "Backlog"),
                     color: .gray, hPadding: 7, vPadding: 2)
            }
            ForEach(task.tags.prefix(3), id: \.self) { tag in
                Pill(tag, color: .teal, hPadding: 7, vPadding: 2)
            }
            if !blockers.isEmpty {
                Pill("⛒ \(blockers.count)", color: .orange, hPadding: 7, vPadding: 2)
                    .help("Blocked by:\n" + blockers.map { id in
                        let t = app.tasks.first { $0.id == id }
                        return "• \(t?.name ?? id) (\(t?.status.label ?? "missing"))"
                    }.joined(separator: "\n"))
            }
            if let bwt = behindWorktree {
                // The live-agent guard is load-bearing: a herdr Claude agent mid-`implement`
                // has a clean tree between edits, so canUpdateFromBase alone would happily
                // merge under it while it holds the pre-merge file contents in context. The
                // pill stays VISIBLE (the staleness is worth knowing) but its action is off —
                // the same reasoning that makes ProjectTask.allowsMainEdit lock Edit.
                let live = task.status == .running || task.status == .blocked
                Button { onBehindTap?() } label: {
                    Pill("↓\(bwt.behindCount) behind \(bwt.baseBranch)", color: .orange,
                         hPadding: 7, vPadding: 2)
                }
                .buttonStyle(.plain)
                .disabled(onBehindTap == nil || live)
                .help(live
                      ? "\(bwt.behindCount) commit\(bwt.behindCount == 1 ? "" : "s") behind \(bwt.baseRef). An agent is working in this worktree — merge after it stops."
                      : "This worktree is \(bwt.behindCount) commit\(bwt.behindCount == 1 ? "" : "s") behind \(bwt.baseRef) — update it")
            }
        }
    }
}

/// The card status marker: a solid dot, or a spinning arc when the task is running.
struct StatusDot: View {
    let state: CardState
    @State private var spin = false

    var body: some View {
        if state.isRunning {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(state.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
                .help(state.help)
        } else {
            Circle().fill(state.color).frame(width: 8, height: 8).help(state.help)
        }
    }
}

/// Legend explaining every merged card state. Shown from the per-card (i) button.
struct CardStatusLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Task status").font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
            ForEach(CardState.allCases, id: \.self) { s in
                HStack(spacing: 8) {
                    StatusDot(state: s).frame(width: 10)
                    Text(s.label).font(.caption).fontWeight(.semibold).frame(width: 72, alignment: .leading)
                    Text(s.help).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
