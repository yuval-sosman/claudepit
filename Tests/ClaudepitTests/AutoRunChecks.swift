import Foundation
@testable import ClaudepitCore

/// Auto-run decision policy + unattended agent argv. All pure — no herdr, no filesystem.
func autoRunChecks() -> [Bool] {
    var results: [Bool] = []

    func task(_ id: String = "t1",
              status: TaskStatus = .backlog,
              phase: TaskPhase? = nil,
              planned: [TaskPhase] = ProjectTask.defaultPhases,
              autoRun: Bool? = true,
              retried: [TaskPhase]? = nil,
              dependsOn: [String] = [],
              links: TaskLinks = TaskLinks(),
              worktree: TaskWorktree? = nil,
              priority: Priority = .normal,
              updatedAt: TimeInterval = 0) -> ProjectTask {
        ProjectTask(id: id, name: "task \(id)", phase: phase, status: status,
                    priority: priority, dependsOn: dependsOn, plannedPhases: planned,
                    worktree: worktree, updatedAt: updatedAt,
                    links: links, autoRun: autoRun, autoRunRetried: retried)
    }
    /// Links that make `phaseNeedsReview` false for the given phase.
    func delivered(_ phase: TaskPhase) -> TaskLinks {
        var l = TaskLinks()
        switch phase {
        case .writeSpec:  l.specPath = "/tmp/spec.md"
        case .createPlan: l.planPath = "/tmp/plan.md"
        case .codeReview: l.reviewPath = "/tmp/review.md"
        case .brainstorm:
            l.brainstormSuggestions = [BrainstormSuggestion(id: "a", kind: .tag, value: "v",
                                                            rationale: "r", accepted: true)]
        case .implement: break
        }
        return l
    }
    func isHalt(_ step: AutoRun.Step) -> Bool {
        if case .halt = step { return true }
        return false
    }

    // MARK: - Phase walk

    results.append(check("brainstorm is skipped, never started") {
        let full = TaskPhase.allCases
        try expect(AutoRun.nextStep(task(planned: full), allTasks: []) == .start(.writeSpec),
                   "a full pipeline starts at writeSpec, not brainstorm")
        try expect(AutoRun.firstRunnablePhase(in: [.brainstorm, .writeSpec]) == .writeSpec,
                   "firstRunnablePhase skips brainstorm")
        try expect(AutoRun.nextRunnablePhase(after: nil, in: [.brainstorm, .writeSpec]) == .writeSpec,
                   "nextRunnablePhase steps over brainstorm")
        try expect(AutoRun.nextStep(task(), allTasks: []) == .start(.writeSpec),
                   "the default pipeline starts at writeSpec")
    })

    results.append(check("a task armed at a finished brainstorm jumps to the next real phase") {
        let t = task(status: .awaitingReview, phase: .brainstorm,
                     planned: TaskPhase.allCases, links: delivered(.brainstorm))
        try expect(AutoRun.nextStep(t, allTasks: []) == .start(.writeSpec), "brainstorm → writeSpec")
    })

    results.append(check("undecided brainstorm suggestions halt rather than being stepped past") {
        var pending = TaskLinks()
        pending.brainstormSuggestions = [BrainstormSuggestion(id: "a", kind: .tag, value: "v",
                                                              rationale: "r", accepted: nil)]
        let t = task(status: .awaitingReview, phase: .brainstorm,
                     planned: TaskPhase.allCases, links: pending)
        try expect(isHalt(AutoRun.nextStep(t, allTasks: [])),
                   "a phase that still needs the user is not one auto-run can skip")
    })

    results.append(check("the chain runs spec → plan → implement → review") {
        try expect(AutoRun.nextStep(task(status: .awaitingReview, phase: .writeSpec,
                                         links: delivered(.writeSpec)),
                                    allTasks: []) == .start(.createPlan), "spec → plan")
        try expect(AutoRun.nextStep(task(status: .awaitingReview, phase: .createPlan,
                                         links: delivered(.createPlan)),
                                    allTasks: []) == .start(.implement), "plan → implement")
        try expect(AutoRun.nextStep(task(status: .awaitingReview, phase: .implement),
                                    allTasks: []) == .start(.codeReview), "implement → review")
    })

    results.append(check("codeReview is the stop line and never advances to done") {
        let t = task(status: .awaitingReview, phase: .codeReview, links: delivered(.codeReview))
        let step = AutoRun.nextStep(t, allTasks: [])
        try expect(step == .finish(.reviewLanded), "review landed → finish")
        if case .start = step { try expect(false, "must not start another phase past review") }
    })

    results.append(check("a pipeline that ends before review stops instead of inventing a phase") {
        let t = task(status: .awaitingReview, phase: .implement, planned: [.writeSpec, .implement])
        try expect(AutoRun.nextStep(t, allTasks: []) == .finish(.pipelineExhausted),
                   "no next planned phase → finish, not start")
    })

    results.append(check("a pipeline of nothing but brainstorm halts") {
        try expect(isHalt(AutoRun.nextStep(task(planned: [.brainstorm]), allTasks: [])),
                   "nothing runnable → halt")
    })

    // MARK: - Retry budget

    results.append(check("a failed or stalled phase gets exactly one retry") {
        try expect(AutoRun.nextStep(task(status: .failed, phase: .implement),
                                    allTasks: []) == .retry(.implement), "failed → retry")
        try expect(AutoRun.nextStep(task(status: .blocked, phase: .implement),
                                    allTasks: []) == .retry(.implement), "blocked → retry")
        try expect(isHalt(AutoRun.nextStep(task(status: .failed, phase: .implement,
                                                retried: [.implement]), allTasks: [])),
                   "failed twice → halt")
        try expect(isHalt(AutoRun.nextStep(task(status: .blocked, phase: .implement,
                                                retried: [.implement]), allTasks: [])),
                   "stalled twice → halt")
    })

    results.append(check("the retry budget is per-phase, not per-task") {
        try expect(AutoRun.nextStep(task(status: .failed, phase: .implement, retried: [.writeSpec]),
                                    allTasks: []) == .retry(.implement),
                   "a spec retry does not spend implement's")
    })

    // MARK: - Guards

    results.append(check("an unarmed or in-flight task is left alone") {
        try expect(AutoRun.nextStep(task(status: .running, phase: .implement), allTasks: []) == .wait,
                   "running → wait")
        try expect(AutoRun.nextStep(task(autoRun: nil), allTasks: []) == .wait, "nil flag → wait")
        try expect(AutoRun.nextStep(task(status: .failed, phase: .implement, autoRun: false),
                                    allTasks: []) == .wait, "false flag → wait even when failed")
    })

    results.append(check("a done task disarms rather than re-entering") {
        try expect(AutoRun.nextStep(task(status: .done), allTasks: []) == .finish(.pipelineExhausted),
                   "done → finish")
    })

    results.append(check("an unmet dependency halts and names what it is waiting on") {
        let dep = ProjectTask(id: "dep", name: "dep", status: .running)
        let mine = task(dependsOn: ["dep"])
        guard case .halt(let why) = AutoRun.nextStep(mine, allTasks: [dep, mine]) else {
            try expect(false, "expected a halt"); return
        }
        try expect(why.contains("dep"), "the reason names the dependency, got: \(why)")
    })

    results.append(check("a busy shared checkout waits, it does not halt") {
        let wt = TaskWorktree(branch: "b", path: "/tmp/wt")
        let mine = task("mine", status: .awaitingReview, phase: .writeSpec,
                        links: delivered(.writeSpec), worktree: wt)
        let neighbour = ProjectTask(id: "nb", name: "nb", status: .running, worktree: wt)
        try expect(AutoRun.nextStep(mine, allTasks: [mine, neighbour]) == .wait,
                   "co-tenancy clears on its own, so wait rather than disarming")
    })

    // MARK: - One armed task per checkout

    results.append(check("selectStartable keeps one armed task per worktree") {
        let wt = TaskWorktree(branch: "b", path: "/tmp/wt")
        let low = task("low", worktree: wt, priority: .low, updatedAt: 5)
        let high = task("high", worktree: wt, priority: .high, updatedAt: 9)
        let free = task("free")
        let picked = AutoRun.selectStartable([low, high, free])
        try expect(picked.count == 2, "one per contended worktree plus the free task, got \(picked.count)")
        try expect(picked.contains { $0.id == "high" }, "higher priority wins the checkout")
        try expect(!picked.contains { $0.id == "low" }, "the loser is held back")
        try expect(picked.contains { $0.id == "free" }, "a task with no worktree contends with nobody")
        try expect(AutoRun.selectStartable([high, low, free]).map(\.id).sorted()
                   == picked.map(\.id).sorted(), "the choice is stable across input order")
    })

    // MARK: - Agent invocation

    results.append(check("an unarmed run's claude args are unchanged") {
        try expect(AutoRun.claudeArgs(for: task(autoRun: nil)).isEmpty, "nil flag adds nothing")
        try expect(AutoRun.claudeArgs(for: task(autoRun: false)).isEmpty, "false flag adds nothing")
    })

    results.append(check("disallowedTools is one comma-joined argument") {
        let args = AutoRun.claudeArgs(for: task())
        guard let i = args.firstIndex(of: "--disallowedTools") else {
            try expect(false, "--disallowedTools missing"); return
        }
        try expect(i + 1 < args.count, "--disallowedTools has no value")
        // One element, not three: the flag is variadic (`<tools...>`) and space-separating would
        // rely on the parser stopping at the next flag.
        try expect(args[i + 1] == "AskUserQuestion,EnterPlanMode,ExitPlanMode",
                   "expected one comma-joined value, got: \(args[i + 1])")
    })

    results.append(check("the composer appends a system prompt and no permission mode") {
        let args = AutoRun.claudeArgs(for: task())
        guard let i = args.firstIndex(of: "--append-system-prompt") else {
            try expect(false, "--append-system-prompt missing"); return
        }
        try expect(i + 1 < args.count && !args[i + 1].isEmpty, "the appended prompt is empty")
        // startAgent already passes --permission-mode; a second one would conflict, not override.
        try expect(!args.contains("--permission-mode"), "the composer must not set a permission mode")
    })

    results.append(check("the unattended prompt keeps its contract with the command bodies") {
        let p = AutoRun.unattendedSystemPrompt
        try expect(p.contains("CLAUDEPIT_ARTIFACT:"), "must demand the completion marker")
        try expect(p.contains("(Recommended)"), "must name the option the agent should take")
        try expect(p.contains("## Assumptions"), "must say where decisions get recorded")
        // The spec command makes AskUserQuestion mandatory, so merely forbidding the tool leaves
        // the agent following an instruction it cannot execute. This sentence overrides it.
        try expect(p.contains("decide instead"), "must override, not merely forbid")
        // It travels as an argv element to `herdr agent start`, which TYPES the command into the
        // pane's shell — a newline would submit the line early and the launch would fail.
        try expect(!p.contains("\n"), "must stay on one line")
    })

    return results
}
