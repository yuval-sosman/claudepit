import Foundation
@testable import ClaudepitCore

func homeAttentionChecks() -> [Bool] {
    var results: [Bool] = []

    /// `.writeSpec` with no `specPath`: an `.awaitingReview` task that genuinely still wants you.
    /// (One that produced its artifact is finished and deliberately drops out — see below.)
    func task(_ id: String, _ status: TaskStatus, updated: TimeInterval = 0) -> ProjectTask {
        ProjectTask(id: id, name: id, phase: .writeSpec, status: status, updatedAt: updated)
    }
    func wt(_ name: String, dirty: Int) -> WorktreeInfo {
        WorktreeInfo(name: name, path: "/tmp/\(name)", branch: "b", head: "h",
                     isLocked: false, dirtyCount: dirty, aheadCount: 0)
    }

    results.append(check("only failed/blocked/awaitingReview tasks + dirty worktrees included") {
        let tasks = [
            task("f", .failed), task("bl", .blocked), task("ar", .awaitingReview),
            task("bk", .backlog), task("run", .running), task("dn", .done),
        ]
        let worktrees = [wt("dirty", dirty: 2), wt("clean", dirty: 0)]
        let items = buildAttention(tasks: tasks, worktrees: worktrees)
        let ids = Set(items.map(\.id))
        try expectEqual(ids, ["task:f", "task:bl", "task:ar", "worktree:dirty"], "included set")
    })

    results.append(check("a phase that produced its artifact drops out of Needs Attention") {
        var done = task("done", .awaitingReview)
        done.links.specPath = "/t/spec.md"
        let items = buildAttention(tasks: [done, task("pending", .awaitingReview)], worktrees: [])
        try expectEqual(Set(items.map(\.id)), ["task:pending"], "only the spec that was never written")
    })

    results.append(check("a fully-reviewed brainstorm drops out of Needs Attention") {
        func brainstorm(_ id: String, pending: Bool) -> ProjectTask {
            var t = ProjectTask(id: id, name: id, phase: .brainstorm, status: .awaitingReview)
            t.links.brainstormSuggestions = [
                BrainstormSuggestion(id: "s", kind: .tag, value: "v", rationale: "", accepted: pending ? nil : true)
            ]
            return t
        }
        let items = buildAttention(tasks: [brainstorm("pend", pending: true),
                                           brainstorm("reviewed", pending: false)], worktrees: [])
        try expectEqual(Set(items.map(\.id)), ["task:pend"], "only the one with a pending decision")
    })

    results.append(check("severity sort: failed > blocked > awaitingReview > dirtyWorktree") {
        let tasks = [task("ar", .awaitingReview), task("f", .failed), task("bl", .blocked)]
        let items = buildAttention(tasks: tasks, worktrees: [wt("d", dirty: 1)])
        try expectEqual(items.map(\.id), ["task:f", "task:bl", "task:ar", "worktree:d"], "order")
    })

    results.append(check("updatedAt tiebreak within a tier: higher first") {
        let tasks = [task("old", .failed, updated: 100), task("new", .failed, updated: 200)]
        let items = buildAttention(tasks: tasks, worktrees: [])
        try expectEqual(items.map(\.id), ["task:new", "task:old"], "newer failed first")
    })

    return results
}
