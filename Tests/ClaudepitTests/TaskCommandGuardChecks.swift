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
