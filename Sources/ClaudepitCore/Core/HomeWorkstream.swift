import Foundation

/// One row of Home's single "needs attention" list — a task that wants something from you, a dirty
/// worktree, or a herdr agent that is live right now.
///
/// This exists because attention items and live agents are largely the *same objects*: a blocked
/// task produces an attention item AND a blocked agent, and showing both meant the same name twice
/// in one card. A row folds the agent into the attention item it belongs to and keeps the agent's
/// status as a trailing signal rather than a second entry.
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
    /// The herdr pane hosting this agent — set on `.agent` rows, where a click focuses the
    /// pane in herdr rather than navigating inside the app.
    public let paneID: String?
    public let target: Target

    public init(id: String, kind: Kind, title: String, detail: String, needsAttention: Bool,
                severity: AttentionSeverity?, agentStatus: String?, paneID: String? = nil,
                target: Target) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.needsAttention = needsAttention; self.severity = severity
        self.agentStatus = agentStatus; self.paneID = paneID; self.target = target
    }
}

/// Folds `buildAttention`'s output and `buildLiveAgents`' output into one deduplicated list.
///
/// Takes both already-built arrays rather than raw tasks/agents so the two existing builders — and
/// their severity and blocked-first orderings — stay exactly as they are; this only merges.
///
/// Order: attention items in their own severity order, then unmatched **blocked** agents (also
/// waiting on a human), then working agents. The two orderings are never interleaved because they
/// are incommensurable — severity-then-recency has nothing to say about a herdr agent's name.
public func buildWorkstream(attention: [AttentionItem],
                            agents: [LiveAgentItem],
                            tasks: [ProjectTask]) -> [WorkItem] {
    var consumed = Set<String>()          // pane ids already folded into an attention row
    var rows: [WorkItem] = []

    for item in attention {
        var status: String? = nil
        var kind = WorkItem.Kind.attentionTask
        var target = WorkItem.Target.none

        switch item.target {
        case .task(let id):
            target = .task(id)
            // The agent running this very task is this row's live signal, not a row of its own.
            if let agent = agents.first(where: { $0.target == .task(id: id) && !consumed.contains($0.id) }) {
                consumed.insert(agent.id)
                status = agent.status
            }
        case .worktree(let name):
            kind = .dirtyWorktree
            target = .worktree(name)
        }

        rows.append(WorkItem(id: item.id, kind: kind, title: item.title, detail: item.reason,
                             needsAttention: true, severity: item.severity,
                             agentStatus: status, target: target))
    }

    var blocked: [WorkItem] = []
    var working: [WorkItem] = []
    for agent in agents where !consumed.contains(agent.id) {
        let isBlocked = agent.status == Herdr.AgentState.blocked
        let row = WorkItem(id: "agent:\(agent.id)", kind: .agent,
                           title: agentTitle(agent, tasks: tasks),
                           detail: agentDetail(agent, tasks: tasks),
                           needsAttention: isBlocked,
                           severity: nil,
                           agentStatus: agent.status,
                           paneID: agent.id,   // LiveAgentItem.id IS the pane id
                           target: agentTarget(agent))
        if isBlocked { blocked.append(row) } else { working.append(row) }
    }

    return rows + blocked + working
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
        return "\(agent.status) in \(phase.title)"
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
