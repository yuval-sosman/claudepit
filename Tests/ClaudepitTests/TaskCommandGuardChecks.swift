import Foundation
@testable import ClaudepitCore

/// The pure half of the disabled-command guard: `phasePrompt` emits `/claudepit-task-<name>`
/// unconditionally, so before starting an agent `runPhase`/`openInHerdr` check the command is
/// actually installed. The decision is a pure function, so it is testable without herdr.
func taskCommandGuardChecks() -> [Bool] {
    var results: [Bool] = []
    let store = AppConfigStore()

    results.append(check("commandFilename matches every phase's slash-command") {
        let expected: [TaskPhase: String] = [
            .brainstorm: "claudepit-task-brainstorm.md",
            .writeSpec:  "claudepit-task-spec.md",
            .createPlan: "claudepit-task-plan.md",
            .implement:  "claudepit-task-implement.md",
            .codeReview: "claudepit-task-review.md",
        ]
        for (phase, filename) in expected {
            try expectEqual(TaskRunner.commandFilename(for: phase), filename, "\(phase.commandName)")
        }
    })

    results.append(check("a fix task swaps implement for the findings-driven fix command") {
        var fix = ProjectTask(id: "f1", plannedPhases: [.implement, .codeReview])
        fix.followUp = TaskFollowUp(parentTaskID: "p1", findingIDs: ["a"])
        try expectEqual(TaskRunner.commandFilename(for: .implement, task: fix),
                        "claudepit-task-fix.md", "fix task at implement")
        try expectEqual(TaskRunner.commandFilename(for: .codeReview, task: fix),
                        "claudepit-task-review.md", "its other phases are untouched")

        let plain = ProjectTask(id: "p2")
        try expectEqual(TaskRunner.commandFilename(for: .implement, task: plain),
                        "claudepit-task-implement.md", "an ordinary task still runs implement")

        // A follow-up the user put back on the full pipeline has a plan again, so it must get the
        // command that reads one.
        var full = fix
        full.plannedPhases = ProjectTask.defaultPhases
        try expect(!full.isFixTask, "planning createPlan opts back out of the fix command")
        try expectEqual(TaskRunner.commandFilename(for: .implement, task: full),
                        "claudepit-task-implement.md", "full follow-up runs implement")
    })

    results.append(check("the fix command is in the catalog and gated like the others") {
        let catalog = Set(ManagedConfig.catalog.filter { $0.kind == .commandMarkdown }.map(\.filename))
        try expect(catalog.contains("claudepit-task-fix.md"), "catalog has the fix command")

        let base = try tempDir()
        store.seedIfNeeded(base)
        var fix = ProjectTask(id: "f1", plannedPhases: [.implement, .codeReview])
        fix.followUp = TaskFollowUp(parentTaskID: "p1", findingIDs: ["a"])
        try expect(TaskRunner.commandAvailable(for: .implement, task: fix,
                                               in: TaskRunner.taskCommands(for: base)),
                   "available when enabled")
        store.setEnabled(base, "task-fix", false)
        let off = TaskRunner.taskCommands(for: base)
        try expect(!TaskRunner.commandAvailable(for: .implement, task: fix, in: off),
                   "unavailable once switched off")
        // Switching the fix command off must not take the ordinary implement phase with it.
        try expect(TaskRunner.commandAvailable(for: .implement, task: ProjectTask(id: "p2"), in: off),
                   "a normal implement is unaffected")
    })

    results.append(check("every phase's command filename exists in the catalog") {
        let catalog = Set(ManagedConfig.catalog.filter { $0.kind == .commandMarkdown }.map(\.filename))
        for phase in ProjectTask.defaultPhases {
            try expect(catalog.contains(TaskRunner.commandFilename(for: phase)),
                       "catalog has a command for \(phase.commandName)")
        }
    })

    results.append(check("commandAvailable is true for every phase when nothing is disabled") {
        let base = try tempDir()
        store.seedIfNeeded(base)
        let commands = TaskRunner.taskCommands(for: base)
        for phase in ProjectTask.defaultPhases {
            try expect(TaskRunner.commandAvailable(for: phase, in: commands),
                       "\(phase.commandName) available")
        }
    })

    results.append(check("commandAvailable is false for exactly the disabled phase") {
        let base = try tempDir()
        store.seedIfNeeded(base)
        store.setEnabled(base, "task-plan", false)
        let commands = TaskRunner.taskCommands(for: base)
        try expect(!TaskRunner.commandAvailable(for: .createPlan, in: commands),
                   "createPlan blocked — its command is switched off")
        for phase in ProjectTask.defaultPhases where phase != .createPlan {
            try expect(TaskRunner.commandAvailable(for: phase, in: commands),
                       "\(phase.commandName) still available")
        }
    })

    results.append(check("commandAvailable is false against an empty command set") {
        for phase in ProjectTask.defaultPhases {
            try expect(!TaskRunner.commandAvailable(for: phase, in: []), "\(phase.commandName) unavailable")
        }
    })

    return results
}
