import Foundation
@testable import ClaudepitCore

func homeWorkstreamChecks() -> [Bool] {
    var results: [Bool] = []

    func attention(_ id: String, _ title: String, _ reason: String,
                   _ severity: AttentionSeverity, target: AttentionItem.Target) -> AttentionItem {
        AttentionItem(id: id, target: target, title: title, reason: reason,
                      severity: severity, sortKey: 0)
    }
    func agent(_ pane: String, _ name: String, _ status: String,
               target: LiveAgentItem.Target) -> LiveAgentItem {
        LiveAgentItem(id: pane, name: name, status: status, target: target)
    }
    func task(_ id: String, _ name: String, phase: TaskPhase?) -> ProjectTask {
        ProjectTask(id: id, name: name, phase: phase, status: .running)
    }

    results.append(check("an agent row carries its pane id; an unbacked attention row carries none") {
        let out = buildWorkstream(
            attention: [attention("task:t1", "test", "blocked", .blocked, target: .task("t1"))],
            agents: [agent("w4:pA", "w4:pA", "working", target: .none)],
            tasks: [])
        try expectEqual(out.first { $0.kind == .agent }?.paneID, "w4:pA", "pane id for herdr focus")
        let task = out.first { $0.kind == .attentionTask }
        try expect(task?.paneID == nil, "no agent runs this task")
        try expect(task?.focusPane == nil, "so it navigates in-app")
    })

    results.append(check("a terminal title beats the pane name on an unmatched agent row") {
        let titled = LiveAgentItem(id: "w4:pA", name: "w4:pA", status: "working",
                                   title: "fix-worktree-project-slug", target: .none)
        let out = buildWorkstream(attention: [], agents: [titled], tasks: [])
        try expectEqual(out.first?.title, "fix-worktree-project-slug", "title is the readable name")
        try expectEqual(out.first?.detail, "working · w4:pA", "pane name demoted to the detail")
    })

    results.append(check("no terminal title → pane name stays the title, detail stays plain") {
        let bare = LiveAgentItem(id: "w4:pB", name: "w4:pB", status: "blocked", target: .none)
        let out = buildWorkstream(attention: [], agents: [bare], tasks: [])
        try expectEqual(out.first?.title, "w4:pB", "falls back to the herdr name")
        try expectEqual(out.first?.detail, "blocked", "no duplicated pane name")
    })

    results.append(check("a task agent keeps the task's own name even when a title exists") {
        let t = task("t1", "Redesign Home", phase: .implement)
        let a = LiveAgentItem(id: "p1", name: "task-t1-implement", status: "working",
                              title: "some-terminal-title", target: .task(id: "t1"))
        let out = buildWorkstream(attention: [], agents: [a], tasks: [t])
        try expectEqual(out.first?.title, "Redesign Home", "task name wins")
        try expectEqual(out.first?.detail, "working in Implement · p1", "phase phrasing plus the pane")
    })

    results.append(check("a blocked task is listed beside its agent, and both reach the pane") {
        // Both rows on purpose: the task row names the work, the agent row names the pane. Folding
        // them left no row that could open herdr, which is the only place a blocked task moves.
        let out = buildWorkstream(
            attention: [attention("task:t1", "test", "blocked in Brainstorm", .blocked, target: .task("t1"))],
            agents: [agent("p1", "task-t1-brainstorm", "blocked", target: .task(id: "t1"))],
            tasks: [task("t1", "test", phase: .brainstorm)])
        try expectEqual(out.map(\.id), ["task:t1", "agent:p1"], "task row, then its agent")
        try expectEqual(out[0].detail, "blocked in Brainstorm", "attention reason on the task row")
        try expectEqual(out[0].agentStatus, "blocked", "the agent is also the row's live signal")
        try expect(out[0].needsAttention, "still needs attention")
        try expectEqual(out[0].focusPane, "p1", "a blocked task clicks through to the pane")
        try expectEqual(out[1].detail, "blocked in Brainstorm · p1", "the pane tells the rows apart")
        try expectEqual(out[1].focusPane, "p1", "so does its agent")
        try expect(!out[1].needsAttention, "the pair is one need — the task row owns it")
    })

    results.append(check("answering in herdr drops the task out of needs-attention at once") {
        // The persisted status still says .blocked until TaskRunner's next poll; the live agent is
        // the truth, so the row must not keep claiming "needs you" after you replied.
        let out = buildWorkstream(
            attention: [attention("task:t1", "test", "blocked in Brainstorm", .blocked, target: .task("t1"))],
            agents: [agent("p1", "task-t1-brainstorm", "working", target: .task(id: "t1"))],
            tasks: [task("t1", "test", phase: .brainstorm)])
        try expectEqual(out.map(\.id), ["agent:p1"], "only the working agent is left")
        try expect(!out[0].needsAttention, "and it is not waiting on you")
    })

    results.append(check("a failed task keeps its in-app target even with a live pane") {
        // Retry lives in the app; only a *blocked* agent means the pane is where you are needed.
        let out = buildWorkstream(
            attention: [attention("task:t1", "test", "failed in Implement", .failed, target: .task("t1"))],
            agents: [agent("p1", "task-t1-implement", "idle", target: .task(id: "t1"))],
            tasks: [task("t1", "test", phase: .implement)])
        try expectEqual(out[0].paneID, "p1", "the pane is known")
        try expect(out[0].focusPane == nil, "but the row still opens the task")
    })

    results.append(check("an agent with no attention item of its own becomes its own row") {
        let out = buildWorkstream(
            attention: [],
            agents: [agent("p1", "task-t1-implement", "working", target: .task(id: "t1"))],
            tasks: [task("t1", "Redesign Home", phase: .implement)])
        try expectEqual(out.count, 1, "one row")
        guard let row = out.first else { throw CheckFailure(message: "no row") }
        try expectEqual(row.id, "agent:p1", "namespaced by pane id")
        try expectEqual(row.title, "Redesign Home", "task name, not task-t1-implement")
        try expectEqual(row.detail, "working in Implement · p1", "mirrors the attention phrasing")
        try expect(!row.needsAttention, "a working agent is not waiting on you")
        try expect(row.target == .task("t1"), "task target")
    })

    results.append(check("attention rows first, then blocked agents, then working agents") {
        let out = buildWorkstream(
            attention: [attention("task:t1", "failing", "failed in Implement", .failed, target: .task("t1"))],
            agents: [agent("p-work", "w", "working", target: .none),
                     agent("p-block", "b", "blocked", target: .none)],
            tasks: [])
        try expectEqual(out.map(\.id), ["task:t1", "agent:p-block", "agent:p-work"], "waiting work floats up")
        try expect(out[1].needsAttention, "a blocked agent is waiting on a human")
        try expect(!out[2].needsAttention, "a working agent is not")
    })

    results.append(check("a dirty worktree keeps its own kind and target") {
        let out = buildWorkstream(
            attention: [attention("worktree:wt", "wt", "2 uncommitted files", .dirtyWorktree,
                                  target: .worktree("wt"))],
            agents: [], tasks: [])
        guard let row = out.first else { throw CheckFailure(message: "no row") }
        try expect(row.kind == .dirtyWorktree, "kind")
        try expect(row.target == .worktree("wt"), "target")
        try expect(row.agentStatus == nil, "no agent backs a worktree")
    })

    results.append(check("a session agent resolves to its session and keeps its raw name") {
        let out = buildWorkstream(
            attention: [], agents: [agent("p1", "w4:pA", "working", target: .session(id: "s-1"))], tasks: [])
        guard let row = out.first else { throw CheckFailure(message: "no row") }
        try expectEqual(row.title, "w4:pA", "no task to rename it")
        try expectEqual(row.detail, "working", "no phase to name")
        try expect(row.target == .session("s-1"), "session target")
    })

    results.append(check("two attention tasks never consume the same agent") {
        // `consumed` is keyed by pane id; without it a single agent could decorate every row.
        let out = buildWorkstream(
            attention: [attention("task:t1", "one", "blocked in Implement", .blocked, target: .task("t1")),
                        attention("task:t2", "two", "blocked in Implement", .blocked, target: .task("t2"))],
            agents: [agent("p1", "task-t1-implement", "blocked", target: .task(id: "t1"))],
            tasks: [])
        try expectEqual(out.map(\.id), ["task:t1", "agent:p1", "task:t2"],
                        "t1 and its agent, then t2 with none left to claim")
        try expectEqual(out[0].agentStatus, "blocked", "t1 got the agent")
        try expect(out[2].agentStatus == nil, "t2 did not")
    })

    results.append(check("neither source → an empty list") {
        try expectEqual(buildWorkstream(attention: [], agents: [], tasks: []).count, 0, "empty")
    })

    return results
}
