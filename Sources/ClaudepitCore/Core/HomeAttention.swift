import Foundation

/// Severity ordering for the Home "needs attention" list. Higher = more severe.
public enum AttentionSeverity: Int, Comparable {
    case dirtyWorktree = 0, awaitingReview = 1, blocked = 2, failed = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct AttentionItem: Identifiable, Equatable {
    public enum Target: Equatable { case task(String), worktree(String), loop(String) }
    public let id: String            // "task:<id>" / "worktree:<name>" / "loop:<id>"
    public let target: Target
    public let title: String
    public let reason: String
    public let severity: AttentionSeverity
    public let sortKey: TimeInterval // updatedAt for tasks; 0 for worktrees — tiebreak, higher first
    /// The herdr pane the need sits in, when the item knows it (a loop's session) — matched to its
    /// live agent row the way a task's agent is.
    public let paneID: String?

    public init(id: String, target: Target, title: String, reason: String, severity: AttentionSeverity,
                sortKey: TimeInterval, paneID: String? = nil) {
        self.id = id; self.target = target; self.title = title; self.reason = reason
        self.severity = severity; self.sortKey = sortKey; self.paneID = paneID
    }
}

/// A loop whose session stopped on a permission prompt or a question: nothing fires until someone
/// answers — the silent way an unattended loop dies, so it belongs on Home and in the menu bar.
public struct LoopAttention: Equatable, Sendable {
    public let id: String
    public let title: String
    public let reason: String
    public let paneID: String?
    public let since: Date

    public init(id: String, title: String, reason: String, paneID: String?, since: Date) {
        self.id = id; self.title = title; self.reason = reason; self.paneID = paneID; self.since = since
    }
}

/// Pure builder: which tasks/worktrees need attention, sorted severity-first then updatedAt-desc.
/// Only failed/blocked/awaitingReview tasks and dirty worktrees qualify; backlog/running/done
/// tasks and clean worktrees are excluded. An `.awaitingReview` phase with nothing left to decide
/// (`phaseNeedsReview == false`) drops out too — it finished, it isn't asking for anything.
/// Caller takes `.prefix(6)` for display.
public func buildAttention(tasks: [ProjectTask], worktrees: [WorktreeInfo],
                           loops: [LoopAttention] = []) -> [AttentionItem] {
    var items: [AttentionItem] = []

    for t in tasks {
        let severity: AttentionSeverity
        switch t.status {
        case .failed:         severity = .failed
        case .blocked:        severity = .blocked
        case .awaitingReview:
            // A halted auto-run stays visible even when the phase itself wants nothing: the user
            // asked for an unattended run to Code Review and it stopped short of that.
            if t.autoRunHaltReason != nil { severity = .blocked; break }
            guard t.phaseNeedsReview else { continue }
            severity = .awaitingReview
        case .backlog, .running, .done: continue
        }
        let reason = t.autoRunHaltReason.map { "Auto-run stopped: \($0)" }
            ?? "\(t.status.label) in \(t.phase?.title ?? "…")"
        items.append(AttentionItem(id: "task:\(t.id)", target: .task(t.id),
                                   title: t.name, reason: reason,
                                   severity: severity, sortKey: t.updatedAt))
    }

    for l in loops {
        items.append(AttentionItem(id: "loop:\(l.id)", target: .loop(l.id), title: l.title, reason: l.reason,
                                   severity: .blocked, sortKey: l.since.timeIntervalSince1970, paneID: l.paneID))
    }

    for w in worktrees where w.dirtyCount > 0 {
        let reason = "\(w.dirtyCount) uncommitted file\(w.dirtyCount == 1 ? "" : "s")"
        items.append(AttentionItem(id: "worktree:\(w.name)", target: .worktree(w.name),
                                   title: w.name, reason: reason,
                                   severity: .dirtyWorktree, sortKey: 0))
    }

    // Severity desc, then updatedAt desc within a tier.
    return items.sorted {
        $0.severity != $1.severity ? $0.severity > $1.severity : $0.sortKey > $1.sortKey
    }
}
