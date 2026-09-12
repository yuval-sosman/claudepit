import SwiftUI
import ClaudepitCore

/// Home's activity card: one merged, newest-first list of everything this project recorded —
/// session summaries, memory writes and dreaming consolidations, task specs and plans, and
/// finished tasks. There is no featured row on top: the most recent item simply sits first, and
/// a live session wears a small green dot.
///
/// Every source is already on `AppState` — `memoryLog`/`memoryFiles` arrive with
/// `reloadMemory()` inside `reload()`, sessions carry their `bulletSummary`, `taskArtifacts`
/// and `specFiles` are stamped by `loadTasks()`, and `planFiles` by `reloadPlanFiles()` — so
/// this card adds no refresh work and does no filesystem I/O of its own.
/// It lives in the WIDE column: feed rows are text and need the room to survive truncation.
struct HomeActivityCard: View {
    @ObservedObject var app: AppState
    @State private var expanded = false

    /// Collapsed shows 20; expanding reveals up to 40 and no further, so a long-lived project
    /// can't turn Home into an endless scroll. Built once at the cap and sliced for display, so
    /// the "+N more" label knows how many are actually being withheld.
    private static let collapsedCount = 20
    private static let maxCount = 40

    private var allEntries: [ActivityEntry] {
        buildActivityFeed(memoryLog: app.memoryLog,
                          sessions: app.sessions,
                          artifacts: app.taskArtifacts,
                          planFiles: app.planFiles,
                          specFiles: app.specFiles,
                          memoryFiles: app.memoryFiles,
                          tasks: app.tasks,
                          limit: Self.maxCount)
    }

    var body: some View {
        let entries = allEntries
        let shown = expanded ? entries : Array(entries.prefix(Self.collapsedCount))
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent").font(.headline)
                if entries.isEmpty {
                    Text("Nothing recorded yet for this project.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown) { activityRow($0) }
                    }
                    if entries.count > Self.collapsedCount {
                        Button(expanded ? "Show less" : "+\(entries.count - Self.collapsedCount) more") {
                            expanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func activityRow(_ entry: ActivityEntry) -> some View {
        Button { jump(entry.target) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(entry.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if entry.isActive {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                        }
                        Text(entry.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    if let detail = entry.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // Single abbreviated unit ("6 hr. ago") — the two-unit `style: .relative`
                // spelling reads like a stopwatch, and tertiary was illegible on glass.
                Text(entry.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.title)
        .disabled(entry.target == nil)
    }

    private func icon(_ kind: ActivityEntry.Kind) -> String {
        switch kind {
        case .memoryWrite:    return Section.memory.systemImage
        case .memoryDream:    return "moon.zzz"
        case .sessionSummary: return Section.sessions.systemImage
        case .spec:           return Section.specs.systemImage
        case .plan:           return Section.plans.systemImage
        case .taskDone:       return "checkmark.circle"
        }
    }

    private func jump(_ target: ActivityEntry.Target?) {
        switch target {
        case .memoryFile(let name): app.focusMemoryFileID = name; app.selected = .memory
        case .session(let id):      app.focusSessionID = id; app.selected = .sessions
        case .spec(let path):       app.focusSpecPath = path; app.selected = .specs
        case .plan(let path):       app.focusPlanPath = path; app.selected = .plans
        case .task(let id):         app.focusTaskID = id; app.selected = .tasks
        case nil:                   break
        }
    }
}
