import SwiftUI
import ClaudepitCore

/// Kanban board. Dragging a card onto a phase column executes that phase.
struct TaskBoardView: View {
    let tasks: [ProjectTask]
    @ObservedObject var app: AppState
    var sort: TasksSection.Sort = .priority
    var onSelect: (String) -> Void

    // nil phase == Backlog; .done handled by status.
    private let columns: [(title: String, phase: TaskPhase?, done: Bool)] = [
        ("Backlog", nil, false),
        ("Brainstorm", .brainstorm, false), ("Spec", .writeSpec, false),
        ("Plan", .createPlan, false), ("Implement", .implement, false),
        ("Review", .codeReview, false),
        ("Done", nil, true),
    ]

    @State private var pendingOverwrite: (task: ProjectTask, phase: TaskPhase)? = nil
    @State private var targetedColumnTitle: String? = nil

    var body: some View {
        ScrollView([.horizontal]) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(columns, id: \.title) { col in column(col) }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .alert("Re-run \(pendingOverwrite?.phase.title ?? "phase")?", isPresented: Binding(
            get: { pendingOverwrite != nil }, set: { if !$0 { pendingOverwrite = nil } })) {
            Button("Cancel", role: .cancel) { pendingOverwrite = nil }
            Button("Re-run", role: .destructive) {
                if let p = pendingOverwrite { app.moveTask(p.task, toPhase: p.phase) }
                pendingOverwrite = nil
            }
        } message: {
            Text("This overwrites the existing artifact for that phase; the reviewed version isn't restored on drag-back.")
        }
    }

    private func cards(for col: (title: String, phase: TaskPhase?, done: Bool)) -> [ProjectTask] {
        tasks.filter { t in
            if col.done { return t.status == .done }
            if t.status == .done { return false }
            return col.phase == nil ? t.phase == nil : t.phase == col.phase
        }.sorted { orderedBefore($0, $1, sort: sort, app: app) }
    }

    private func column(_ col: (title: String, phase: TaskPhase?, done: Bool)) -> some View {
        let items = cards(for: col)
        let isTargeted = targetedColumnTitle == col.title
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(col.title).font(.caption).fontWeight(.bold)
                    .foregroundStyle(.secondary).textCase(.uppercase).tracking(0.5)
                Text("\(items.count)")
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.white.opacity(0.08), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)

            if items.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(isTargeted ? Color.accentColor.opacity(0.7) : .white.opacity(0.10))
                    .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(Text("Drop here").font(.caption2).foregroundStyle(.tertiary))
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ForEach(items) { task in
                    Button { onSelect(task.id) } label: {
                        TaskCardView(task: task, app: app, showPhase: false,
                                     onBehindTap: {
                                         app.pendingWorktreeUpdatePath = task.worktree?.path
                                         onSelect(task.id)
                                     })
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .draggable(task.id)
                    // On the outer Button, so the whole card is the right-click hit area.
                    .taskContextMenu(task, app: app)
                }
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isTargeted ? Color.accentColor.opacity(0.07) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isTargeted ? Color.accentColor.opacity(0.5) : .white.opacity(0.06), lineWidth: isTargeted ? 1.5 : 1))
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: String.self) { ids, _ in drop(ids, to: col) } isTargeted: { targeted in
            targetedColumnTitle = targeted ? col.title : (targetedColumnTitle == col.title ? nil : targetedColumnTitle)
        }
    }

    private func drop(_ ids: [String], to col: (title: String, phase: TaskPhase?, done: Bool)) -> Bool {
        guard let id = ids.first, let task = tasks.first(where: { $0.id == id }) else { return false }
        if col.done { app.markTaskDone(task); return true }
        guard let phase = col.phase else { app.moveTask(task, toPhase: nil); return true }
        // moveTask no-ops unless not-running & canRun; reject up front so the drop shows as rejected.
        guard task.status != .running, task.status != .done, TaskTransition.canRun(task, allTasks: app.tasks) else { return false }
        if hasArtifact(task, phase) {
            guard pendingOverwrite == nil else { return false }   // don't clobber a pending confirm
            pendingOverwrite = (task, phase)
        } else { app.moveTask(task, toPhase: phase) }
        return true
    }

    private func hasArtifact(_ task: ProjectTask, _ phase: TaskPhase) -> Bool {
        switch phase {
        case .brainstorm: return task.links.brainstormPath != nil
        case .writeSpec:  return task.links.specPath != nil
        case .createPlan: return task.links.planPath != nil
        case .codeReview: return task.links.reviewPath != nil
        case .implement: return false
        }
    }
}
