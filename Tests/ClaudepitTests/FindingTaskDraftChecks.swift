import Foundation
@testable import ClaudepitCore

/// `FindingTaskDraft` is the single source of truth for what a task built from review findings
/// looks like — the sheet's one-click create and the pre-filled form both go through it, so a
/// disagreement between them would be a bug the user only notices after the task runs.
func findingTaskDraftChecks() -> [Bool] {
    var results: [Bool] = []

    func finding(_ sev: String, _ title: String, _ detail: String = "detail") -> ReviewFinding {
        ReviewFinding(id: "id-\(title)", title: title, detail: detail, severity: sev)
    }
    func parent() -> ProjectTask {
        var t = ProjectTask(id: "par1", name: "Show every session in Recent",
                            topic: "home", tags: ["ui"])
        t.links.sessionIDs = ["sess-a", "sess-b"]
        t.links.reviewPath = "/tmp/review.md"
        t.links.specPath = "/tmp/spec.md"
        t.worktree = TaskWorktree(branch: "task/par1-x", path: "/tmp/wt", paneID: "p1", tabID: "t1")
        return t
    }

    results.append(check("severity maps to priority, unknown never above low") {
        try expectEqual(FindingTaskDraft.priority(for: "high"), .high, "high")
        try expectEqual(FindingTaskDraft.priority(for: "med"), .normal, "med")
        try expectEqual(FindingTaskDraft.priority(for: "medium"), .normal, "medium")
        try expectEqual(FindingTaskDraft.priority(for: "low"), .low, "low")
        try expectEqual(FindingTaskDraft.priority(for: "banana"), .low, "unknown → low")
    })

    results.append(check("a set takes its highest severity") {
        let set = [finding("low", "a"), finding("high", "b"), finding("med", "c")]
        try expectEqual(FindingTaskDraft.priority(for: set), .high, "max")
        try expectEqual(FindingTaskDraft.priority(for: [finding("low", "a")]), .low, "single low")
        try expectEqual(FindingTaskDraft.priority(for: []), .low, "empty → low")
    })

    results.append(check("sorted puts high first and is stable within a severity") {
        let set = [finding("low", "a"), finding("high", "b"), finding("low", "c"), finding("med", "d")]
        try expectEqual(FindingTaskDraft.sorted(set).map(\.title), ["b", "d", "a", "c"], "order")
    })

    results.append(check("one finding keeps its own title; several become a named batch") {
        try expectEqual(FindingTaskDraft.name(for: [finding("med", "Tie-break test cannot fail")],
                                              parentName: "Parent"),
                        "Tie-break test cannot fail", "single")
        let three = [finding("low", "a"), finding("low", "b"), finding("low", "c")]
        try expectEqual(FindingTaskDraft.name(for: three, parentName: "Recent feed"),
                        "Fix 3 review findings from \"Recent feed\"", "batch")
        try expectEqual(FindingTaskDraft.name(for: three, parentName: "  "),
                        "Fix 3 review findings", "no parent name → no dangling from")
    })

    results.append(check("description names the parent and carries every title and detail") {
        let set = [finding("high", "Alpha", "alpha detail"), finding("low", "Beta", "beta detail")]
        let d = FindingTaskDraft.description(for: set, parentName: "Recent feed")
        try expect(d.contains("the code review of \"Recent feed\""), "names the parent")
        for f in set {
            try expect(d.contains(f.title), "has \(f.title)")
            try expect(d.contains(f.detail), "has \(f.title)'s detail")
        }
        try expect(d.contains("**[HIGH]** Alpha"), "severity pill in the bullet")
        // High first, regardless of the order they arrived in.
        try expect(d.range(of: "Alpha")!.lowerBound < d.range(of: "Beta")!.lowerBound, "sorted")
    })

    results.append(check("a multi-line detail stays inside its bullet") {
        let d = FindingTaskDraft.description(for: [finding("low", "A", "line one\n\nline two")],
                                             parentName: "P")
        try expect(d.contains("  line one"), "first line indented")
        try expect(d.contains("  line two"), "later line indented too")
    })

    results.append(check("one requirement per finding, severity-prefixed") {
        let set = [finding("low", "a"), finding("high", "b")]
        try expectEqual(FindingTaskDraft.requirements(for: set), ["[HIGH] b", "[LOW] a"], "reqs")
    })

    results.append(check("fix drafts carry no dependency; full drafts depend on the parent") {
        let set = [finding("med", "a")]
        let p = parent()
        try expect(FindingTaskDraft.version(for: set, parent: p, fixNow: true).dependsOn.isEmpty,
                   "fix has no dependency — canRun would gate it on a parent stuck in Review")
        try expectEqual(FindingTaskDraft.version(for: set, parent: p, fixNow: false).dependsOn,
                        [p.id], "full depends on the parent")
    })

    results.append(check("a draft inherits the parent's topic, tags and priority") {
        let v = FindingTaskDraft.version(for: [finding("high", "a")], parent: parent(), fixNow: true)
        try expectEqual(v.topic, "home", "topic")
        try expectEqual(v.tags, ["ui"], "tags")
        try expectEqual(v.priority, .high, "priority from severity")
    })

    results.append(check("planned phases: fix skips the prep phases but keeps a review") {
        try expectEqual(FindingTaskDraft.plannedPhases(fixNow: true), [.implement, .codeReview], "fix")
        try expectEqual(FindingTaskDraft.plannedPhases(fixNow: false), ProjectTask.defaultPhases, "full")
    })

    results.append(check("a fix task's first phase is implement") {
        let phases = FindingTaskDraft.plannedPhases(fixNow: true)
        // runPhase falls back to plannedPhases.first for a task with no phase set.
        try expectEqual(TaskTransition.nextPlannedPhase(after: nil, in: phases), .implement, "first")
        try expectEqual(TaskTransition.nextPlannedPhase(after: .implement, in: phases), .codeReview, "then review")
        try expect(TaskTransition.nextPlannedPhase(after: .codeReview, in: phases) == nil, "then done")
    })

    // MARK: - The whole task shape

    results.append(check("a fix task is implement-first, dependency-free, in the parent's worktree") {
        let p = parent()
        let set = [finding("med", "a"), finding("low", "b")]
        let t = FindingTaskDraft.task(for: set, parent: p, fixNow: true, now: 99, id: "kid1")

        try expectEqual(t.plannedPhases, [.implement, .codeReview], "skips brainstorm/spec/plan")
        try expect(t.dependsOn.isEmpty,
                   "no dependency — canRun would gate it on a parent that never leaves Review")
        try expectEqual(t.status, .backlog, "starts in Backlog")
        try expect(t.phase == nil, "phase nil so Home's pipeline counts it once")
        try expect(t.isFixTask, "runs the fix command")

        // The code under review is uncommitted in the parent's checkout.
        try expectEqual(t.worktree?.path, p.worktree?.path, "inherits the worktree path")
        try expectEqual(t.worktree?.branch, p.worktree?.branch, "and its branch")
        try expect(t.worktree?.paneID == nil && t.worktree?.tabID == nil,
                   "but not its pane/tab — each phase opens its own")

        try expectEqual(t.followUp?.parentTaskID, p.id, "links back to the parent")
        try expectEqual(t.followUp?.findingIDs, set.map(\.id), "records which findings it covers")
        try expectEqual(t.followUp?.resumeSessionID, "sess-b", "resumes the LAST implement session")
        try expectEqual(t.followUp?.parentReviewPath, "/tmp/review.md", "carries the review")
        try expectEqual(t.followUp?.parentSpecPath, "/tmp/spec.md", "and the spec")
        try expectEqual(t.createdAt, 99, "stamped from the injected clock")
    })

    results.append(check("a full task takes the normal pipeline and stays out of the worktree") {
        let p = parent()
        let t = FindingTaskDraft.task(for: [finding("med", "a")], parent: p, fixNow: false, now: 1)
        try expectEqual(t.plannedPhases, ProjectTask.defaultPhases, "full pipeline")
        try expectEqual(t.dependsOn, [p.id], "depends on the parent")
        try expect(t.worktree == nil, "forks its own worktree when it eventually runs")
        try expect(t.followUp == nil, "and is not a continuation")
        try expect(!t.isFixTask, "so it runs the plan-centric implement command")
    })

    results.append(check("a parent with no worktree or session still yields a usable fix task") {
        let bare = ProjectTask(id: "bare", name: "Bare")
        let t = FindingTaskDraft.task(for: [finding("high", "a")], parent: bare, fixNow: true, now: 1)
        try expect(t.worktree == nil, "nothing to inherit")
        try expect(t.followUp?.resumeSessionID == nil, "nothing to resume")
        try expect(t.isFixTask, "still runs the fix command — it just starts clean")
    })

    return results
}
