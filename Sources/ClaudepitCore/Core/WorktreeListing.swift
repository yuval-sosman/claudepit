import Foundation

/// What a worktree is doing right now, in the words the Worktrees page uses. Derived from the scan
/// (`isActive`, the lock) plus herdr's agent list — never from a subprocess, so a view body may
/// ask for it.
public enum WorktreeActivity: Equatable, Sendable {
    /// Its session wrote to its transcript within `SessionScanner.activeWindow`.
    case running
    /// Something holds it but is quiet: a herdr agent (by name) sitting at its prompt, or a live
    /// process that locked it (nil name — the lock's pid is still alive).
    case open(agent: String?)
    /// A session ran here; nothing holds it now.
    case idle
    /// Nothing that ran here could be found — a worktree made by hand, or its transcripts are gone.
    case noSession

    public var label: String {
        switch self {
        case .running: return "Running now"
        case .open(let agent): return agent == nil ? "In use" : "Open in herdr"
        case .idle: return "Idle"
        case .noSession: return "No session"
        }
    }

    /// The tooltip: what the label is based on.
    public var detail: String {
        switch self {
        case .running: return "Its session wrote to its transcript in the last few minutes"
        case .open(let agent):
            return agent.map { "herdr agent \($0) is open in this worktree" }
                ?? "A running process holds this worktree's lock"
        case .idle: return "A session ran here; nothing is working in it now"
        case .noSession: return "No session that ran here could be found"
        }
    }

    public var isLive: Bool {
        switch self {
        case .running, .open: return true
        case .idle, .noSession: return false
        }
    }
}

/// The Worktrees page's list, decided here rather than in the view so it is testable
/// (`WorktreeListingChecks`): which group each worktree is in, what it is called, what one line
/// says about it, and what search matches.
public enum WorktreeListing {

    /// The list's sections, in display order: what needs the person, what is live, the rest.
    public enum Group: String, CaseIterable, Sendable {
        case attention, live, idle

        public var title: String {
            switch self {
            case .attention: return "Needs attention"
            case .live: return "Live"
            case .idle: return "Idle"
            }
        }
    }

    public struct Section: Identifiable, Equatable {
        public let group: Group
        public let items: [WorktreeInfo]
        public var id: String { group.rawValue }
    }

    /// `liveAgent`: the herdr agent whose cwd is this worktree, if any (`AppState.worktreeAgentName`).
    public static func activity(of wt: WorktreeInfo, liveAgent: String? = nil) -> WorktreeActivity {
        if wt.isActive { return .running }
        if let liveAgent { return .open(agent: liveAgent) }
        // A lock with no pid in its reason classifies as `.lockedLive(-1)` (it can't be proven
        // stale) — but nothing is known to hold it, so it does not make the worktree live.
        if case .lockedLive(let pid) = wt.lockState, pid > 0 { return .open(agent: nil) }
        return wt.ownerSessionID == nil ? .noSession : .idle
    }

    /// Attention first: a merge left half-done or a lock whose owner is gone waits on the person,
    /// whatever else is going on in the worktree. Uncommitted changes alone are not attention —
    /// an agent's worktree is dirty for most of its life.
    public static func group(of wt: WorktreeInfo, liveAgent: String? = nil) -> Group {
        if needsAttention(wt) { return .attention }
        return activity(of: wt, liveAgent: liveAgent).isLive ? .live : .idle
    }

    public static func needsAttention(_ wt: WorktreeInfo) -> Bool {
        if wt.mergeInProgress { return true }
        if case .lockedStale = wt.lockState { return true }
        return false
    }

    /// Why `needsAttention` is true, as a short phrase; nil when it isn't.
    public static func attentionReason(_ wt: WorktreeInfo) -> String? {
        if wt.mergeInProgress {
            let n = wt.conflictedFiles.count
            return n == 0 ? "Merge ready to commit" : "Merge conflict in \(n) file\(n == 1 ? "" : "s")"
        }
        if case .lockedStale = wt.lockState { return "Stale lock" }
        return nil
    }

    /// Non-empty groups in display order, each keeping the scan's order (stable as states change
    /// within a group). `taskNames` is keyed by worktree path; search reads it too.
    public static func sections(_ worktrees: [WorktreeInfo], query: String = "",
                                taskNames: [String: String] = [:],
                                liveAgents: [String: String] = [:]) -> [Section] {
        let shown = worktrees.filter { matches($0, query: query, taskName: taskNames[$0.path]) }
        let grouped = Dictionary(grouping: shown) { group(of: $0, liveAgent: liveAgents[$0.path]) }
        return Group.allCases.compactMap { g in
            guard let items = grouped[g], !items.isEmpty else { return nil }
            return Section(group: g, items: items)
        }
    }

    /// Every word of the query must appear in the name, the branch, the owning task's name or the
    /// path — the same rule as the other pages' search (`SearchText.matches`).
    public static func matches(_ wt: WorktreeInfo, query: String, taskName: String? = nil) -> Bool {
        SearchText.matches([wt.name, wt.branch, taskName ?? "", wt.path], query: query)
    }

    /// A task worktree's folder is `task-<id>-<slug>`, which reads worse than the task it belongs
    /// to; anything else keeps its folder name.
    public static func title(of wt: WorktreeInfo, taskName: String?) -> String {
        guard let taskName, !taskName.isEmpty else { return wt.name }
        return taskName
    }

    /// The short facts a row's meta line carries after its status, most actionable first. Empty
    /// counts are left out, so a clean, up-to-date worktree says nothing more.
    public static func facts(of wt: WorktreeInfo) -> [String] {
        var out: [String] = []
        if let reason = attentionReason(wt) { out.append(reason) }
        if wt.dirtyCount > 0 { out.append("\(wt.dirtyCount) change\(wt.dirtyCount == 1 ? "" : "s")") }
        if wt.isBehindBase { out.append("\(wt.behindCount) behind \(wt.baseBranch)") }
        if wt.aheadCount > 0 { out.append("\(wt.aheadCount) ahead") }
        return out
    }

    /// Tasks working in this checkout, the task that created it first. A fix task inherits its
    /// parent's worktree (CLAUDE.md, "Fix tasks"), so two tasks can share one.
    public static func tasks(in path: String, from tasks: [ProjectTask]) -> [ProjectTask] {
        let here = tasks.filter { $0.worktree?.path == path }
        return here.filter { $0.followUp == nil } + here.filter { $0.followUp != nil }
    }

    /// Task names by worktree path, for `sections`/`title`: the creating task's name per checkout.
    public static func taskNames(_ worktrees: [WorktreeInfo], tasks all: [ProjectTask]) -> [String: String] {
        var out: [String: String] = [:]
        for wt in worktrees {
            if let first = tasks(in: wt.path, from: all).first { out[wt.path] = first.name }
        }
        return out
    }

    /// The selection to fall back on when `removed` leaves the list: its neighbour below, else above.
    public static func neighbour(of removed: String, in order: [String]) -> String? {
        guard let i = order.firstIndex(of: removed) else { return order.first }
        if i + 1 < order.count { return order[i + 1] }
        return i > 0 ? order[i - 1] : nil
    }
}
