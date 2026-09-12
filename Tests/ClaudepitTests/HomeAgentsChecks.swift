import Foundation
@testable import ClaudepitCore

func homeAgentsChecks() -> [Bool] {
    var results: [Bool] = []

    func agent(_ name: String?, pane: String, status: String, session: String? = nil) -> Herdr.AgentEntry {
        Herdr.AgentEntry(sessionID: session, name: name, paneID: pane, status: status)
    }
    func task(_ id: String, phase: TaskPhase?) -> ProjectTask {
        ProjectTask(id: id, name: "t-\(id)", phase: phase, status: .running)
    }

    results.append(check("exact agentName match resolves to that task") {
        let t = task("abc", phase: .implement)
        let name = TaskRunner.agentName(id: "abc", phase: .implement)
        let items = buildLiveAgents(agents: [agent(name, pane: "p1", status: "working")], tasks: [t])
        try expectEqual(items.count, 1, "one item")
        try expect(items[0].target == .task(id: "abc"), "target is the task")
        try expectEqual(items[0].id, "p1", "id is the pane id")
        try expectEqual(items[0].name, name, "raw herdr name preserved")
    })

    results.append(check("terminal title passes through to the item") {
        let entry = Herdr.AgentEntry(sessionID: nil, name: nil, paneID: "p9", status: "working",
                                     title: "fix-worktree-project-slug", cwd: "/tmp/x")
        let items = buildLiveAgents(agents: [entry], tasks: [])
        try expectEqual(items.first?.title, "fix-worktree-project-slug", "title carried")
        try expectEqual(items.first?.name, "p9", "unnamed agent still keyed by pane id")
    })

    results.append(check("task-<id>- prefix resolves an agent left over from an earlier phase") {
        // The task has moved on to codeReview; its pane still hosts the implement agent.
        let t = task("abc", phase: .codeReview)
        let stale = TaskRunner.agentName(id: "abc", phase: .implement)
        let items = buildLiveAgents(agents: [agent(stale, pane: "p1", status: "working")], tasks: [t])
        try expect(items.first?.target == .task(id: "abc"), "prefix match still finds the task")
    })

    results.append(check("exact match beats the prefix match when both are candidates") {
        let exact = task("abc", phase: .codeReview)
        let prefixOnly = task("ab", phase: .writeSpec)
        let name = TaskRunner.agentName(id: "abc", phase: .codeReview)
        let items = buildLiveAgents(agents: [agent(name, pane: "p1", status: "working")],
                                    tasks: [prefixOnly, exact])
        try expect(items.first?.target == .task(id: "abc"), "exact-name task wins over list order")
    })

    results.append(check("a session-bound agent with no task resolves to its session") {
        let items = buildLiveAgents(
            agents: [agent("claude", pane: "p1", status: "working", session: "s-1")], tasks: [])
        try expect(items.first?.target == .session(id: "s-1"), "session target")
    })

    results.append(check("an agent bound to neither is .none") {
        let items = buildLiveAgents(agents: [agent("shell", pane: "p1", status: "blocked")], tasks: [])
        try expect(items.first?.target == LiveAgentItem.Target.none, "no target")
    })

    results.append(check("a nameless agent falls back to its pane id and never matches a task") {
        let t = task("abc", phase: .implement)
        let items = buildLiveAgents(agents: [agent(nil, pane: "p9", status: "working")], tasks: [t])
        try expectEqual(items.first?.name, "p9", "name falls back to pane id")
        try expect(items.first?.target == LiveAgentItem.Target.none, "no accidental task match")
    })

    results.append(check("idle / unknown / done are filtered out") {
        let agents = [
            agent("a", pane: "p1", status: Herdr.AgentState.idle),
            agent("b", pane: "p2", status: "unknown"),
            agent("c", pane: "p3", status: Herdr.AgentState.done),
            agent("d", pane: "p4", status: Herdr.AgentState.working),
        ]
        let items = buildLiveAgents(agents: agents, tasks: [])
        try expectEqual(items.map(\.id), ["p4"], "only the working agent")
    })

    results.append(check("blocked sorts before working, name-ordered inside each tier") {
        let agents = [
            agent("z-work", pane: "p1", status: "working"),
            agent("a-work", pane: "p2", status: "working"),
            agent("z-block", pane: "p3", status: "blocked"),
            agent("a-block", pane: "p4", status: "blocked"),
        ]
        let items = buildLiveAgents(agents: agents, tasks: [])
        try expectEqual(items.map(\.name), ["a-block", "z-block", "a-work", "z-work"], "order")
    })

    results.append(check("an empty agent list yields an empty strip") {
        try expectEqual(buildLiveAgents(agents: [], tasks: [task("a", phase: .implement)]).count, 0, "empty")
    })

    return results
}
