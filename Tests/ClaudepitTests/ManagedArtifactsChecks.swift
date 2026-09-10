import Foundation
@testable import ClaudepitCore

/// ManagedArtifacts — the ownership index behind the settings-tree badges. Hooks are matched by
/// value (any home directory), settings keys by key *and* layer.
func managedArtifactsChecks() -> [Bool] {
    var results: [Bool] = []
    let base = URL(filePath: "/tmp/claudepit-artifacts-check")

    // MARK: Hook ownership (value-based)

    results.append(check("a hook command is claimed whatever home it points at") {
        let here = "bash '\(Paths.summaryHookScript.path)'"
        let foreign = "bash '/Users/someoneelse/.claude/\(Paths.summaryHookScriptName)'"
        try expectEqual(ManagedArtifacts.owner(ofHookCommand: here)?.id, "summary-hook", "this machine")
        try expectEqual(ManagedArtifacts.owner(ofHookCommand: foreign)?.id, "summary-hook", "another machine")
    })

    results.append(check("an unrelated command is not claimed") {
        for cmd in ["echo hi", "bash '/Users/me/.claude/somebody-elses-hook.sh'", ""] {
            try expect(ManagedArtifacts.owner(ofHookCommand: cmd) == nil, "not claimed: \(cmd)")
        }
    })

    results.append(check("the two hook scripts never cross-match") {
        let summary = "bash '/any/home/.claude/\(Paths.summaryHookScriptName)'"
        let memory = "bash '/any/home/.claude/\(Paths.memoryHookScriptName)' Stop"
        try expectEqual(ManagedArtifacts.owner(ofHookCommand: summary)?.id, "summary-hook", "summary")
        try expectEqual(ManagedArtifacts.owner(ofHookCommand: memory)?.id, "memory-hook", "memory")
    })

    // MARK: Settings-key ownership (key + layer)

    results.append(check("a settings key is claimed only in the active project's settings.json") {
        try expectEqual(
            ManagedArtifacts.owner(ofSettingsKey: "cleanupPeriodDays",
                                   sourceURL: Paths.projectSettings(base), base: base)?.id,
            "cleanup-period", "claimed in project layer")
        try expect(
            ManagedArtifacts.owner(ofSettingsKey: "cleanupPeriodDays",
                                   sourceURL: Paths.globalSettings, base: base) == nil,
            "NOT claimed in the global layer")
        try expect(
            ManagedArtifacts.owner(ofSettingsKey: "systemPrompt.append",
                                   sourceURL: Paths.projectSettings(URL(filePath: "/tmp/other-project")),
                                   base: base) == nil,
            "NOT claimed in another project's layer")
    })

    results.append(check("an unmanaged settings key is never claimed") {
        try expect(ManagedArtifacts.owner(ofSettingsKey: "model",
                                          sourceURL: Paths.projectSettings(base), base: base) == nil,
                   "model not ours")
    })

    // MARK: Index tables

    results.append(check("settingsKeys / hookEvents / scriptName cover exactly the right entries") {
        try expectEqual(ManagedArtifacts.settingsKeys(for: "memory-system-prompt"), ["systemPrompt.append"], "prompt key")
        try expectEqual(ManagedArtifacts.settingsKeys(for: "cleanup-period"), ["cleanupPeriodDays"], "cleanup key")
        try expectEqual(ManagedArtifacts.settingsKeys(for: "summary-hook"), [], "hooks have no settings key")
        try expectEqual(ManagedArtifacts.hookEvents(for: "summary-hook"), ["UserPromptSubmit"], "summary events")
        try expectEqual(ManagedArtifacts.hookEvents(for: "memory-hook"), ["Stop", "StopFailure"], "memory events")
        try expectEqual(ManagedArtifacts.hookEvents(for: "task-plan"), [], "commands have no events")
        try expectEqual(ManagedArtifacts.scriptName(for: "summary-hook"), Paths.summaryHookScriptName, "summary script")
        try expectEqual(ManagedArtifacts.scriptName(for: "memory-hook"), Paths.memoryHookScriptName, "memory script")
        try expect(ManagedArtifacts.scriptName(for: "cleanup-period") == nil, "number entry has no script")
    })

    // MARK: writtenFiles

    results.append(check("writtenFiles matches the Paths derivations") {
        let c = ManagedConfig.byID("summary-hook")!
        let files = ManagedArtifacts.writtenFiles(for: c, base: base)
        try expectEqual(files.map(\.role), [.editableCopy, .installedScript, .settings], "roles in install order")
        try expectEqual(files[0].url, Paths.appConfigDir(base).appending(path: c.filename), "editable copy")
        try expectEqual(files[1].url, Paths.summaryHookScript, "installed script")
        try expectEqual(files[2].url, Paths.projectSettings(base), "settings file")
        try expectEqual(files[2].detail, "hooks.UserPromptSubmit", "settings detail")
    })

    results.append(check("writtenFiles honors an injected globalClaudeDir") {
        let g = URL(filePath: "/tmp/injected-global")
        let c = ManagedConfig.byID("memory-hook")!
        let files = ManagedArtifacts.writtenFiles(for: c, base: base, globalClaudeDir: g)
        let script = files.first { $0.role == .installedScript }
        try expectEqual(script?.url, g.appending(path: Paths.memoryHookScriptName), "script under injected root")
        // Everything else already derives from `base`, so it is unaffected.
        try expectEqual(files.first { $0.role == .editableCopy }?.url,
                        Paths.appConfigDir(base).appending(path: c.filename), "copy still under base")
        try expectEqual(files.filter { $0.role == .settings }.map(\.detail),
                        ["hooks.Stop", "hooks.StopFailure"], "one settings row per event")
    })

    results.append(check("writtenFiles shapes: command entry, number entry") {
        let cmd = ManagedArtifacts.writtenFiles(for: ManagedConfig.byID("task-plan")!, base: base)
        try expectEqual(cmd.map(\.role), [.editableCopy, .installedCommand], "command roles")
        try expectEqual(cmd[1].url,
                        Paths.projectClaude(base).appending(path: "commands/claudepit-task-plan.md"),
                        "installed command path")

        let num = ManagedArtifacts.writtenFiles(for: ManagedConfig.byID("cleanup-period")!, base: base)
        try expectEqual(num.map(\.role), [.settings], "number entry writes only a settings key")
        try expectEqual(num[0].detail, "cleanupPeriodDays", "the key")
    })

    results.append(check("every catalog entry writes at least one file") {
        for c in ManagedConfig.catalog {
            try expect(!ManagedArtifacts.writtenFiles(for: c, base: base).isEmpty, "\(c.id) has a file map")
        }
    })

    return results
}
