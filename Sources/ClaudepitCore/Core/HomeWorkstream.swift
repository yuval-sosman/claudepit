import Foundation

/// One row of Home's single "needs attention" list — a task that wants something from you, a dirty
/// worktree, or a herdr agent that is live right now.
///
/// A task and the agent running it are listed as **two rows**, not one. Folding them (which this
/// did until 2026-09-12) hid the only row that could take you to the pane: a blocked task showed
/// as a single in-app row, so clicking it opened the task detail — which says nothing but "Waiting
/// on your reply in Herdr". The rows are told apart by their subtitles (the task's phase reason vs
/// the agent's pane) and by where they click through to, see `focusPane`.
public struct WorkItem: Identifiable, Equatable {
    public enum Target: Equatable { case task(String), worktree(String), session(String), none }
    public enum Kind: Equatable { case attentionTask, dirtyWorktree, agent }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    /// Drives the raised-hand icon and the sort: this row is waiting on a human.
    public let needsAttention: Bool
    public let severity: AttentionSeverity?   // nil on a row that is only a live agent
    public let agentStatus: String?           // herdr status when an agent backs this row
    /// The herdr pane behind this row — the agent's own pane on an `.agent` row, and the pane of
    /// the agent running the task on an attention row.
    public let paneID: String?
    public let target: Target

    public init(id: String, kind: Kind, title: String, detail: String, needsAttention: Bool,
                severity: AttentionSeverity?, agentStatus: String?, paneID: String? = nil,
                target: Target) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.needsAttention = needsAttention; self.severity = severity
        self.agentStatus = agentStatus; self.paneID = paneID; self.target = target
    }

    /// The pane a click on this row should focus in herdr, or nil to navigate inside the app.
    ///
    /// An agent row always focuses its own pane. A *task* row does too when its agent is
    /// `blocked` — the agent is literally sitting on a question, and the in-app task detail has
    /// nothing to offer there but the sentence "Waiting on your reply in Herdr". Every other
    /// attention row (a failed task with its Retry button, an agent that merely finished, a dirty
    /// worktree) still belongs in the app.
    ///
    /// Both Home and the menu bar panel route clicks through this, so the two can't drift; the
    /// caller still gates on `WorktreeResumer.available()`, which touches the filesystem.
    public var focusPane: String? {
        guard let paneID else { return nil }
        if kind == .agent { return paneID }
        return agentStatus == Herdr.AgentState.blocked ? paneID : nil
    }
}

/// Folds `buildAttention`'s output and `buildLiveAgents`' output into one list.
///
/// Takes both already-built arrays rather than raw tasks/agents so the two existing builders — and
/// their severity and blocked-first orderings — stay exactly as they are; this only merges.
///
/// A task's agent is **matched** to its attention row but is no longer folded away: it follows
/// that row as its own entry, so the pane is always one click from the list. Only the task row
/// counts as needing attention, though — the pair is one need, not two.
///
/// Order: attention items in their own severity order (each trailed by its agent), then unmatched
/// **blocked** agents (also waiting on a human), then working agents. The two orderings are never interleaved because they
/// are incommensurable — severity-then-recency has nothing to say about a herdr agent's name.
public func buildWorkstream(attention: [AttentionItem],
                            agents: [LiveAgentItem],
                            tasks: [ProjectTask]) -> [WorkItem] {
    var matched = Set<String>()           // pane ids already claimed by an attention row
    var rows: [WorkItem] = []

    for item in attention {
        var backing: LiveAgentItem? = nil
        var kind = WorkItem.Kind.attentionTask
        var target = WorkItem.Target.none

        switch item.target {
        case .task(let id):
            target = .task(id)
            // The agent running this very task is this row's live signal — and the pane a click
            // on it opens when that agent is blocked.
            if let agent = agents.first(where: { $0.target == .task(id: id) && !matched.contains($0.id) }) {
                matched.insert(agent.id)
                backing = agent
            }
        case .worktree(let name):
            kind = .dirtyWorktree
            target = .worktree(name)
        }

        // Its agent went back to work, so the task is not waiting on anyone — drop the attention
        // row and let the agent's own row report it as working. The persisted status lags here:
        // `TaskRunner.resolveBlocked` only flips `.blocked` → `.running` on the next poll, and
        // until it does this row would keep claiming "needs you" right after you answered it.
        if let backing, backing.status == Herdr.AgentState.working {
            matched.remove(backing.id)   // hand it back so the agent loop still lists it
            continue
        }

        rows.append(WorkItem(id: item.id, kind: kind, title: item.title, detail: item.reason,
                             needsAttention: true, severity: item.severity,
                             agentStatus: backing?.status, paneID: backing?.id, target: target))
        // The agent's own row goes directly under the task it runs — same need, two ways in (the
        // task in the app, the pane in herdr). `needsAttention` is false on purpose: the row above
        // already owns that need, and counting both would badge one blocked task as two.
        if let backing {
            rows.append(agentRow(backing, tasks: tasks, needsAttention: false))
        }
    }

    var blocked: [WorkItem] = []
    var working: [WorkItem] = []
    for agent in agents where !matched.contains(agent.id) {
        let isBlocked = agent.status == Herdr.AgentState.blocked
        let row = agentRow(agent, tasks: tasks, needsAttention: isBlocked)
        if isBlocked { blocked.append(row) } else { working.append(row) }
    }

    return rows + blocked + working
}

private func agentRow(_ agent: LiveAgentItem, tasks: [ProjectTask], needsAttention: Bool) -> WorkItem {
    WorkItem(id: "agent:\(agent.id)", kind: .agent,
             title: agentTitle(agent, tasks: tasks),
             detail: agentDetail(agent, tasks: tasks),
             needsAttention: needsAttention,
             severity: nil,
             agentStatus: agent.status,
             paneID: agent.id,   // LiveAgentItem.id IS the pane id
             target: agentTarget(agent))
}

/// Task agents are named `task-<id>-<phase>`, which means nothing to a reader — show the task's own
/// name instead. Everything else prefers the terminal title (the Claude session's own topic,
/// e.g. "fix-worktree-project-slug") over the raw herdr name, which is usually just a pane id.
private func agentTitle(_ agent: LiveAgentItem, tasks: [ProjectTask]) -> String {
    if case .task(let id) = agent.target, let task = tasks.first(where: { $0.id == id }) {
        return task.name
    }
    return agent.title ?? agent.name
}

/// Mirrors `buildAttention`'s "<status> in <phase>" phrasing so both halves of the list read alike.
/// When a terminal title takes the top line, the pane name moves down here — the row must stay
/// findable in herdr.
private func agentDetail(_ agent: LiveAgentItem, tasks: [ProjectTask]) -> String {
    if case .task(let id) = agent.target,
       let phase = tasks.first(where: { $0.id == id })?.phase {
        // The pane is what separates this row from the task's own attention row above it, which
        // carries the same name and the same "<status> in <phase>" reason.
        return "\(agent.status) in \(phase.title) · \(agent.id)"
    }
    return agent.title != nil ? "\(agent.status) · \(agent.name)" : agent.status
}

private func agentTarget(_ agent: LiveAgentItem) -> WorkItem.Target {
    switch agent.target {
    case .task(let id):    return .task(id)
    case .session(let id): return .session(id)
    case .none:            return .none
    }
}
