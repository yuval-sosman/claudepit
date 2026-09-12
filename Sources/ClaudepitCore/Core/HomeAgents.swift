import Foundation

/// One herdr agent worth showing on Home, resolved to the app object it belongs to.
public struct LiveAgentItem: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case task(id: String)
        case session(id: String)
        case none
    }
    public let id: String        // pane id — unique per agent, unlike the name
    public let name: String      // raw herdr agent name; the card substitutes a task's own name
    public let status: String    // `Herdr.AgentState` value
    /// Terminal title (the Claude session's own topic) — the readable name for an agent that
    /// is neither a task nor herdr-named.
    public let title: String?
    public let target: Target

    public init(id: String, name: String, status: String, title: String? = nil, target: Target) {
        self.id = id; self.name = name; self.status = status
        self.title = title; self.target = target
    }
}

/// Pure builder for Home's live-agents strip.
///
/// Only `working` and `blocked` are shown: `idle` means "back at its prompt", which every
/// finished and every never-started agent reports, and `unknown` says nothing at all. `done` is
/// matched for completeness but herdr's Claude manifest never emits it.
///
/// Task matching is two-step. The exact `TaskRunner.agentName` for the task's *current* phase
/// wins; failing that, the `task-<id>-` prefix claims agents left over from an earlier phase,
/// whose panes outlive the phase change. Only then does a session-bound agent resolve to its
/// session — task agents carry no `agent_session` at all, so the order matters for correctness,
/// not just precedence.
public func buildLiveAgents(agents: [Herdr.AgentEntry], tasks: [ProjectTask]) -> [LiveAgentItem] {
    let live = [Herdr.AgentState.working, Herdr.AgentState.blocked]
    let items: [LiveAgentItem] = agents.compactMap { agent in
        guard live.contains(agent.status) else { return nil }
        let name = agent.name ?? agent.paneID
        return LiveAgentItem(id: agent.paneID, name: name, status: agent.status,
                             title: agent.title,
                             target: resolveTarget(agent: agent, name: name, tasks: tasks))
    }
    // Blocked first — it's the one that needs a human — then working, name-ordered inside each.
    return items.sorted {
        let a = rank($0.status), b = rank($1.status)
        return a != b ? a < b : $0.name < $1.name
    }
}

private func resolveTarget(agent: Herdr.AgentEntry, name: String, tasks: [ProjectTask]) -> LiveAgentItem.Target {
    if agent.name != nil {
        if let exact = tasks.first(where: { TaskRunner.agentName(id: $0.id, phase: $0.phase) == name }) {
            return .task(id: exact.id)
        }
        if let stale = tasks.first(where: { name.hasPrefix("task-\($0.id)-") }) {
            return .task(id: stale.id)
        }
    }
    if let sid = agent.sessionID { return .session(id: sid) }
    return .none
}

private func rank(_ status: String) -> Int {
    status == Herdr.AgentState.blocked ? 0 : 1
}
