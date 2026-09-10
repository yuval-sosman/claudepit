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

/// Live herdr state for a task's current phase pane. Rank orders "needs attention" first.
enum TaskLiveState: Int { case waiting = 0, working = 1, none = 2 }

extension AppState {
    /// Match the live agent by paneID (works for all phases; sessionIDs are only captured on implement).
    /// Claude Code rests at "blocked" whenever it awaits input, so blocked == waiting-for-user.
    func liveState(of task: ProjectTask) -> TaskLiveState {
        guard let pane = task.worktree?.paneID,
              let s = herdrSessions.values.first(where: { $0.paneID == pane })?.status
        else { return .none }
        return s == "blocked" ? .waiting : (s == "working" ? .working : .none)
    }
}

/// The ONE status a card shows — a small, clean set. The live-herdr signal (when
/// a pane is alive it wins — it's the real-time state) and the persisted task
/// status both fold into these. Raw value = sort rank (needs-you first, done last).
enum CardState: Int, CaseIterable {
    case waiting = 0     // needs you: agent blocked, phase awaiting review, or dependency-blocked
    case running = 1     // live agent generating OR a phase executing
    case failed = 2      // last phase failed — retry it
    case notStarted = 3  // backlog — not started yet
    case done = 4        // complete

    var color: Color {
        switch self {
        case .waiting:    return .orange
        case .running:    return .green
        case .failed:     return .red
        case .notStarted: return .secondary
        case .done:       return .blue
        }
    }
    var label: String {
        switch self {
        case .waiting:    return "Waiting"
        case .running:    return "Running"
        case .failed:     return "Failed"
        case .notStarted: return "Not started"
        case .done:       return "Done"
        }
    }
    var help: String {
        switch self {
        case .waiting:    return "Needs you — agent is waiting for input, or a phase finished and is ready to review"
        case .running:    return "A phase is actively running in herdr"
        case .failed:     return "Last phase failed — retry it"
        case .notStarted: return "Not started — still in the backlog"
        case .done:       return "Task complete"
        }
    }
    /// Waiting/failed need you to act, so they render bolder.
    var needsAttention: Bool { self == .waiting || self == .failed }
    var isRunning: Bool { self == .running }
}

extension AppState {
    /// Resolve the single merged card state. Live herdr state wins over persisted status.
    func cardState(of task: ProjectTask) -> CardState {
        switch liveState(of: task) {
        case .waiting: return .waiting     // agent blocked at prompt → needs you
        case .working: return .running     // agent generating
        case .none: break
        }
        switch task.status {
        case .backlog:                        return .notStarted
        case .running:                        return .running
        case .awaitingReview, .blocked:       return .waiting   // both need your action
        case .failed:                         return .failed
        case .done:                           return .done
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

    private var blockers: [String] { TaskTransition.unmetDependencies(task, allTasks: app.tasks) }
    @State private var showLegend = false

    var body: some View {
        let state = app.cardState(of: task)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // One merged indicator: colored dot (spinning arc when running) + short label.
                StatusDot(state: state)
                Text(state.label)
                    .font(.caption2)
                    .fontWeight(state.needsAttention ? .bold : .semibold)
                    .foregroundStyle(state.needsAttention ? AnyShapeStyle(state.color) : AnyShapeStyle(.secondary))
                    .help(state.help)
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
