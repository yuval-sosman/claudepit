import Foundation

/// One line of Home's activity feed: what Claude recorded, when, and where it lives.
public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case memoryWrite, memoryDream, sessionSummary, spec, plan, taskDone }
    public enum Target: Equatable, Sendable {
        case memoryFile(String)   // MemoryGraph node id — a BARE filename, never a path
        case session(String)
        case spec(String)         // absolute path, consumed by `focusSpecPath`
        case plan(String)         // absolute path, consumed by `focusPlanPath`
        case task(String)         // task id, consumed by `focusTaskID`
    }
    public let id: String
    public let kind: Kind
    public let date: Date
    public let title: String
    public let detail: String?
    public let target: Target?
    /// Live right now — rendered as a small green dot. Only sessions can carry it today.
    public let isActive: Bool

    public init(id: String, kind: Kind, date: Date, title: String, detail: String?,
                target: Target?, isActive: Bool = false) {
        self.id = id; self.kind = kind; self.date = date
        self.title = title; self.detail = detail; self.target = target
        self.isActive = isActive
    }
}

/// A task deliverable that exists on disk, stamped with its file's modification date.
///
/// `planPath` points into `~/.claude/plans` (Claude's own plan file), `specPath` into the task's
/// folder — both are absolute, and both are reached by path rather than by id.
public struct TaskArtifact: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case spec, plan }
    public let kind: Kind
    public let taskID: String
    public let taskName: String
    public let path: String
    public let date: Date

    public init(kind: Kind, taskID: String, taskName: String, path: String, date: Date) {
        self.kind = kind; self.taskID = taskID; self.taskName = taskName
        self.path = path; self.date = date
    }
}

/// A file exactly as its section page lists it: absolute path, the display name that page
/// shows, and the file's modification date. The Recent feed mirrors the Plans/Specs/Memory
/// pages through these — whatever those pages list appears in the feed, time-sorted.
public struct PageFile: Equatable, Sendable {
    public let path: String
    public let name: String
    public let date: Date

    public init(path: String, name: String, date: Date) {
        self.path = path; self.name = name; self.date = date
    }
}

/// One entry per existing `links.specPath` / `links.planPath`.
///
/// The filesystem arrives as a closure so this stays pure: `modifiedAt` returns nil for a path that
/// is gone, and those are dropped — a link can outlive its file (a plan deleted out from under the
/// task, a worktree pruned), and a row pointing at nothing would dead-end the user.
public func collectTaskArtifacts(tasks: [ProjectTask],
                                 modifiedAt: (String) -> Date?) -> [TaskArtifact] {
    var out: [TaskArtifact] = []
    for t in tasks {
        if let p = t.links.specPath, let d = modifiedAt(p) {
            out.append(TaskArtifact(kind: .spec, taskID: t.id, taskName: t.name, path: p, date: d))
        }
        if let p = t.links.planPath, let d = modifiedAt(p) {
            out.append(TaskArtifact(kind: .plan, taskID: t.id, taskName: t.name, path: p, date: d))
        }
    }
    return out
}

/// Merges everything Home can say happened in this project into one newest-first feed: memory
/// writes and dreams, per-session bullet summaries, task specs and plans, and finished tasks.
///
/// Memory targets are normalized with `lastPathComponent` because `MemoryGraph` node ids are bare
/// filenames (`hooks.md`), and `focusMemoryFileID` is matched against those ids — a logged entry
/// that ever carried a path would silently fail to select anything.
///
/// Sessions without a bullet summary are skipped rather than dated by `modifiedAt`: with no
/// summary there is nothing to say about them, and the feed would fill with empty rows. The ones
/// that survive are dated by `max(updatedAt, modifiedAt)`, not by the summary alone — a session
/// still being typed into is live (green dot) while its last summary write may be hours old, and
/// dating it by the summary would sort a running session below stale rows and label it "6 hr. ago".
/// `planFiles`/`specFiles`/`memoryFiles` are the section pages' own listings (see `PageFile`).
/// A page file whose path is already covered by a task artifact is skipped — the artifact row
/// carries the task's name, which is the better title for the same file. A memory file is
/// skipped when a log entry touching it sits within `memoryLogTolerance` of its mtime: that
/// write was logged, and the log row's title/summary say more than a bare filename could.
public func buildActivityFeed(memoryLog: [MemoryLogEntry],
                              sessions: [SessionSummary],
                              artifacts: [TaskArtifact] = [],
                              planFiles: [PageFile] = [],
                              specFiles: [PageFile] = [],
                              memoryFiles: [PageFile] = [],
                              tasks: [ProjectTask] = [],
                              limit: Int = 20) -> [ActivityEntry] {
    let memoryLogTolerance: TimeInterval = 600
    var entries: [ActivityEntry] = []

    for e in memoryLog {
        let file = e.displayChanges.first.map { ($0.file as NSString).lastPathComponent }
        entries.append(ActivityEntry(
            id: "mem:\(e.id)",
            kind: e.type == .dream ? .memoryDream : .memoryWrite,
            date: e.date,
            title: e.displayTitle,
            detail: e.displaySummary,
            target: file.map { .memoryFile($0) }))
    }

    for f in memoryFiles {
        let filename = (f.path as NSString).lastPathComponent
        let logged = memoryLog.contains { e in
            abs(e.date.timeIntervalSince(f.date)) < memoryLogTolerance &&
            e.displayChanges.contains { ($0.file as NSString).lastPathComponent == filename }
        }
        guard !logged else { continue }
        entries.append(ActivityEntry(
            id: "memfile:\(filename)",
            kind: .memoryWrite,
            date: f.date,
            title: f.name,
            detail: "Memory updated",
            target: .memoryFile(filename)))
    }

    let linkedPaths = Set(artifacts.map(\.path))
    for f in planFiles where !linkedPaths.contains(f.path) {
        entries.append(ActivityEntry(
            id: "planfile:\(f.path)",
            kind: .plan,
            date: f.date,
            title: f.name,
            detail: "Plan",
            target: .plan(f.path)))
    }
    for f in specFiles where !linkedPaths.contains(f.path) {
        entries.append(ActivityEntry(
            id: "specfile:\(f.path)",
            kind: .spec,
            date: f.date,
            title: f.name,
            detail: "Spec",
            target: .spec(f.path)))
    }

    for s in sessions {
        guard let summary = s.bulletSummary else { continue }
        entries.append(ActivityEntry(
            id: "sess:\(s.id)",
            kind: .sessionSummary,
            date: max(summary.updatedAt, s.modifiedAt),
            title: s.title,
            detail: summary.bullets.first,
            target: .session(s.id),
            isActive: s.isActive))
    }

    for a in artifacts {
        entries.append(ActivityEntry(
            id: a.kind == .spec ? "spec:\(a.taskID)" : "plan:\(a.taskID)",
            kind: a.kind == .spec ? .spec : .plan,
            date: a.date,
            title: a.taskName,
            detail: a.kind == .spec ? "Spec" : "Plan",
            target: a.kind == .spec ? .spec(a.path) : .plan(a.path)))
    }

    // `updatedAt` is the only recency signal a finished task has — there is no `completedAt`.
    for t in tasks where t.status == .done {
        entries.append(ActivityEntry(
            id: "task:\(t.id)",
            kind: .taskDone,
            date: Date(timeIntervalSince1970: t.updatedAt),
            title: t.name,
            detail: "Task done",
            target: .task(t.id)))
    }

    // id breaks date ties so the feed doesn't reshuffle between identical reloads.
    return Array(entries.sorted {
        $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id
    }.prefix(limit))
}
