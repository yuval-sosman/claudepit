import Foundation
@testable import ClaudepitCore

/// `TaskRunner.phasePrompt` is what every phase agent actually reads, so its shape is contractual:
/// the slash-command alone on line 1 (Claude Code passes everything after it as `$ARGUMENTS`), an
/// explicit pointer to that command, then a readable brief whose `## Paths` block still carries the
/// `key=value` lines the command bodies look up by name.
func taskPromptChecks() -> [Bool] {
    var results: [Bool] = []
    let slug = "-Users-someone-Dev-proj"

    /// Every phase planned (the shape AppState.startPhase produces once brainstorm is inserted).
    let allPhases = TaskPhase.allCases

    func task() -> ProjectTask {
        ProjectTask(id: "abc123", name: "Redesign the Home dashboard",
                    topic: "home", description: "The needs-attention card is buried below the fold.",
                    priority: .high, tags: ["ui", "home"], plannedPhases: allPhases,
                    requirements: ["Move needs-attention above the fold", "Keep the card grid responsive"])
    }

    results.append(check("line 1 is the phase slash-command, alone") {
        for phase in allPhases {
            let lines = TaskRunner.phasePrompt(task(), phase: phase, projectSlug: slug)
                .components(separatedBy: "\n")
            try expectEqual(lines.first, "/claudepit-task-\(phase.commandName)", "\(phase.commandName) line 1")
            try expectEqual(lines.count > 1 ? lines[1] : "x", "", "\(phase.commandName) blank line 2")
        }
    })

    results.append(check("the brief names the command as the phase's instruction set") {
        for phase in allPhases {
            let p = TaskRunner.phasePrompt(task(), phase: phase, projectSlug: slug)
            try expect(p.contains("`/claudepit-task-\(phase.commandName)` (invoked on the first line)"),
                       "\(phase.commandName) points at its command")
            try expect(p.contains("**\(phase.title)** phase"), "\(phase.commandName) names the phase")
        }
    })

    results.append(check("every phase numbers itself within the task's pipeline") {
        let phases = allPhases
        for (i, phase) in phases.enumerated() {
            let p = TaskRunner.phasePrompt(task(), phase: phase, projectSlug: slug)
            try expect(p.contains("(step \(i + 1) of \(phases.count))"), "\(phase.commandName) step number")
        }
    })

    results.append(check("paths are one key=value per line under a Paths heading") {
        var t = task()
        t.links.planPath = "/plans/2026-09-11-home.md"
        let p = TaskRunner.phasePrompt(t, phase: .createPlan, projectSlug: slug)
        try expect(p.contains("\n## Paths (absolute — use exactly as given)\n"), "heading")
        for key in ["taskDir=", "plansDir=", "brainstormPath=", "specPath=", "planPath=",
                    "reviewPath=", "worktreePath=", "today="] {
            try expect(p.contains("\n\(key)"), "\(key) starts its own line")
        }
        // The old format packed every pair onto line 1; nothing may share a line now.
        let pathLines = p.components(separatedBy: "\n").filter { $0.contains("=") && !$0.hasPrefix("-") }
        for line in pathLines {
            try expect(!line.contains(" ") || line.contains("/"), "no packed kv blob: \(line)")
        }
    })

    results.append(check("brainstorm gets the task definition and no downstream paths") {
        let p = TaskRunner.phasePrompt(task(), phase: .brainstorm, projectSlug: slug)
        try expect(p.contains("\n## Task\nRedesign the Home dashboard\n"), "task heading + name")
        try expect(p.contains("Topic: home"), "topic")
        try expect(p.contains("Priority: High"), "priority")
        try expect(p.contains("Tags: ui, home"), "tags")
        try expect(p.contains("\n## Description\nThe needs-attention card is buried below the fold."), "description")
        try expect(p.contains("\n## Requirements\n- Move needs-attention above the fold\n- Keep the card grid responsive"),
                   "requirements as a list")
        for key in ["specPath=", "planPath=", "plansDir=", "reviewPath=", "worktreePath="] {
            try expect(!p.contains(key), "brainstorm omits \(key)")
        }
    })

    results.append(check("downstream phases argue from spec/plan, not a repeated definition") {
        for phase in [TaskPhase.createPlan, .implement, .codeReview] {
            let p = TaskRunner.phasePrompt(task(), phase: phase, projectSlug: slug)
            try expect(p.contains("\n## Task\nRedesign the Home dashboard"), "\(phase.commandName) keeps the name")
            try expect(!p.contains("## Requirements"), "\(phase.commandName) omits requirements")
            try expect(!p.contains("## Description"), "\(phase.commandName) omits description")
        }
    })

    results.append(check("an artifact that does not exist yet is named in words, not a bare key=") {
        let p = TaskRunner.phasePrompt(task(), phase: .implement, projectSlug: slug)
        try expect(!p.contains("\nplanPath=\n") && !p.hasSuffix("planPath="), "no empty planPath= line")
        try expect(p.contains("Not produced yet (no file exists for these): planPath."), "stated in words")
    })

    results.append(check("a multi-word name is never emitted as a key=value pair") {
        let p = TaskRunner.phasePrompt(task(), phase: .writeSpec, projectSlug: slug)
        try expect(!p.contains("name=Redesign"), "no unparseable name= pair")
    })

    results.append(check("empty optional facts are omitted, empty required ones are labelled") {
        let bare = ProjectTask(id: "zz", name: "", description: "  ",
                               plannedPhases: allPhases, requirements: [])
        let p = TaskRunner.phasePrompt(bare, phase: .brainstorm, projectSlug: slug)
        try expect(p.contains("_(unnamed — see the description)_"), "unnamed placeholder")
        try expect(p.contains("_(none given — clarify with the user)_"), "empty description placeholder")
        try expect(p.contains("_(none recorded yet)_"), "empty requirements placeholder")
        try expect(!p.contains("Topic:"), "no empty topic line")
        try expect(!p.contains("Priority:"), "no default priority line")
        try expect(!p.contains("Tags:"), "no empty tags line")
    })

    // MARK: - Fix tasks (created from another task's review findings)

    func fixTask() -> ProjectTask {
        var t = ProjectTask(id: "fix99", name: "Fix 3 review findings from \"Home feed\"",
                            priority: .normal, plannedPhases: [.implement, .codeReview],
                            requirements: ["[MED] Tie-break test cannot fail",
                                           "[LOW] Blank first bullet renders an empty row"])
        t.description = "From the code review of \"Home feed\":\n\n- **[MED]** Tie-break test cannot fail"
        t.worktree = TaskWorktree(branch: "task/par1-home", path: "/tmp/wt-home")
        t.followUp = TaskFollowUp(parentTaskID: "par1", findingIDs: ["a", "b", "c"],
                                  resumeSessionID: "sess-a",
                                  parentReviewPath: "/tmp/par1/review.md",
                                  parentSpecPath: "/tmp/par1/spec.md")
        return t
    }

    results.append(check("a fix task's implement phase invokes the fix command") {
        let lines = TaskRunner.phasePrompt(fixTask(), phase: .implement, projectSlug: slug)
            .components(separatedBy: "\n")
        try expectEqual(lines.first, "/claudepit-task-fix", "line 1")
        try expectEqual(lines.count > 1 ? lines[1] : "x", "", "blank line 2")
    })

    results.append(check("a fix task gets the findings as its brief") {
        // The whole point: implement normally argues from a spec and a plan, and a fix task has
        // neither — without this it would receive a name and nothing else.
        let p = TaskRunner.phasePrompt(fixTask(), phase: .implement, projectSlug: slug)
        try expect(p.contains("## Description"), "has a description")
        try expect(p.contains("## Requirements"), "has requirements")
        for r in fixTask().requirements { try expect(p.contains(r), "carries \(r)") }
    })

    results.append(check("a fix task's paths point at the parent, not at files nobody will write") {
        let p = TaskRunner.phasePrompt(fixTask(), phase: .implement, projectSlug: slug)
        try expect(p.contains("parentReviewPath=/tmp/par1/review.md"), "parent review")
        try expect(p.contains("parentSpecPath=/tmp/par1/spec.md"), "parent spec")
        try expect(p.contains("worktreePath=/tmp/wt-home"), "the parent's worktree")
        try expect(p.contains("fixPath="), "where to write the report")
        try expect(!p.contains("planPath"), "no planPath — a fix task never has one")
        try expect(!p.contains("plansDir"), "no plansDir either")
    })

    results.append(check("a missing parent artifact is stated, never emitted as a bare key") {
        var t = fixTask()
        t.followUp?.parentSpecPath = nil
        let p = TaskRunner.phasePrompt(t, phase: .implement, projectSlug: slug)
        try expect(!p.contains("parentSpecPath=\n"), "no bare key the agent would resolve against cwd")
        try expect(p.contains("Not produced yet"), "named in the missing list instead")
    })

    results.append(check("an ordinary implement prompt is unchanged by any of this") {
        let p = TaskRunner.phasePrompt(task(), phase: .implement, projectSlug: slug)
        try expectEqual(p.components(separatedBy: "\n").first, "/claudepit-task-implement", "line 1")
        try expect(p.contains("planPath"), "still told about its plan path")
        try expect(!p.contains("## Description"), "still argues from the spec, not the description")
        try expect(!p.contains("parentReviewPath"), "no follow-up keys")
    })

    results.append(check("the unattended section appears only for an armed task") {
        var armed = task(); armed.autoRun = true
        for phase in allPhases {
            let on = TaskRunner.phasePrompt(armed, phase: phase, projectSlug: slug)
            try expect(on.contains("## Unattended run"), "\(phase.commandName) armed carries the section")
            let off = TaskRunner.phasePrompt(task(), phase: phase, projectSlug: slug)
            try expect(!off.contains("## Unattended run"), "\(phase.commandName) unarmed does not")
        }
    })

    results.append(check("the unattended section never migrates onto line 1") {
        var armed = task(); armed.autoRun = true
        for phase in allPhases {
            let lines = TaskRunner.phasePrompt(armed, phase: phase, projectSlug: slug)
                .components(separatedBy: "\n")
            try expectEqual(lines.first, "/claudepit-task-\(phase.commandName)",
                            "\(phase.commandName) line 1 still the bare slash-command")
        }
    })

    results.append(check("the unattended section stays above the Paths block") {
        var armed = task(); armed.autoRun = true
        let p = TaskRunner.phasePrompt(armed, phase: .writeSpec, projectSlug: slug)
        guard let u = p.range(of: "## Unattended run"), let k = p.range(of: "## Paths") else {
            try expect(false, "both sections must be present"); return
        }
        try expect(u.lowerBound < k.lowerBound, "key=value pairs stay the last thing in the prompt")
    })

    return results
}
