import Foundation

/// Severity ordering for the Home "needs attention" list. Higher = more severe.
public enum AttentionSeverity: Int, Comparable {
    case dirtyWorktree = 0, awaitingReview = 1, blocked = 2, failed = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct AttentionItem: Identifiable, Equatable {
    public enum Target: Equatable { case task(String), worktree(String) }
    public let id: String            // "task:<id>" / "worktree:<name>"
    public let target: Target
    public let title: String
    public let reason: String
    public let severity: AttentionSeverity
    public let sortKey: TimeInterval // updatedAt for tasks; 0 for worktrees — tiebreak, higher first
}

/// Pure builder: which tasks/worktrees need attention, sorted severity-first then updatedAt-desc.
/// Only failed/blocked/awaitingReview tasks and dirty worktrees qualify; backlog/running/done
/// tasks and clean worktrees are excluded. An `.awaitingReview` phase with nothing left to decide
/// (`phaseNeedsReview == false`) drops out too — it finished, it isn't asking for anything.
/// Caller takes `.prefix(6)` for display.
public func buildAttention(tasks: [ProjectTask], worktrees: [WorktreeInfo]) -> [AttentionItem] {
    var items: [AttentionItem] = []

    for t in tasks {
        let severity: AttentionSeverity
        switch t.status {
        case .failed:         severity = .failed
        case .blocked:        severity = .blocked
        case .awaitingReview:
            guard t.phaseNeedsReview else { continue }
            severity = .awaitingReview
        case .backlog, .running, .done: continue
        }
        let reason = "\(t.status.label) in \(t.phase?.title ?? "…")"
        items.append(AttentionItem(id: "task:\(t.id)", target: .task(t.id),
                                   title: t.name, reason: reason,
                                   severity: severity, sortKey: t.updatedAt))
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
