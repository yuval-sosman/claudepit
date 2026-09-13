import Foundation
@testable import ClaudepitCore

/// ManagedInstaller against injected temp roots — the installers had no coverage before Stage 5
/// because they lived in the app target.
func managedInstallerChecks() -> [Bool] {
    var results: [Bool] = []
    let store = AppConfigStore()

    /// A fresh (globalClaudeDir, projectBase) pair with the project's editable copies seeded.
    func freshRoots() throws -> (g: URL, base: URL) {
        let root = try tempDir()
        let g = root.appending(path: "globalClaude")
        let base = root.appending(path: "proj")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store.seedIfNeeded(base)
        return (g, base)
    }

    func installer(_ g: URL, _ base: URL) -> ManagedInstaller {
        ManagedInstaller(appConfig: store, globalClaudeDir: g, base: base)
    }

    /// Every command string registered under `event` in the project's settings.json.
    func commands(_ base: URL, event: String) -> [String] {
        guard let obj = try? JSONFile.readObject(Paths.projectSettings(base)),
              let hooks = obj["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func hooksDict(_ base: URL) -> [String: Any] {
        (try? JSONFile.readObject(Paths.projectSettings(base)))?["hooks"] as? [String: Any] ?? [:]
    }

    // MARK: Install

    results.append(check("sync installs a 0o755 hook script and registers it in project settings") {
        let (g, base) = try freshRoots()
        installer(g, base).sync()
        let script = g.appending(path: Paths.summaryHookScriptName)
        try expect(FileManager.default.fileExists(atPath: script.path), "script written")
        let perms = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        try expectEqual(perms?.intValue ?? 0, 0o755, "script mode")
        try expectEqual(commands(base, event: "UserPromptSubmit"),
                        ["bash '\(script.path)'"], "registered command")
    })

    results.append(check("sync writes the script from the project's editable copy, not the builtin") {
        let (g, base) = try freshRoots()
        let c = ManagedConfig.byID("summary-hook")!
        try store.saveContent(base, c, "#!/bin/bash\necho custom\n")
        installer(g, base).sync()
        let onDisk = try String(contentsOf: g.appending(path: Paths.summaryHookScriptName), encoding: .utf8)
        try expectEqual(onDisk, "#!/bin/bash\necho custom\n", "edited copy installed")
    })

    results.append(check("second sync is byte-idempotent") {
        let (g, base) = try freshRoots()
        let inst = installer(g, base)
        inst.sync()
        let first = try Data(contentsOf: Paths.projectSettings(base))
        inst.sync()
        try expectEqual(try Data(contentsOf: Paths.projectSettings(base)), first, "settings unchanged")
    })

    results.append(check("sync registers memory hooks under Stop and StopFailure with the event argument") {
        let (g, base) = try freshRoots()
        installer(g, base).sync()
        let script = g.appending(path: Paths.memoryHookScriptName).path
        try expectEqual(commands(base, event: "Stop"), ["bash '\(script)' Stop"], "Stop")
        try expectEqual(commands(base, event: "StopFailure"), ["bash '\(script)' StopFailure"], "StopFailure")
    })

    results.append(check("installers register exactly the events ManagedArtifacts declares") {
        let (g, base) = try freshRoots()
        installer(g, base).sync()
        let present = Set(hooksDict(base).keys)
        for id in ["summary-hook", "memory-hook"] {
            for event in ManagedArtifacts.hookEvents(for: id) {
                try expect(present.contains(event), "\(id) registered \(event)")
            }
        }
        let declared = Set(ManagedArtifacts.hookEvents(for: "summary-hook")
                         + ManagedArtifacts.hookEvents(for: "memory-hook"))
        try expectEqual(present, declared, "no events beyond those declared")
    })

    // MARK: Cross-machine reconciliation

    results.append(check("a stale other-machine registration is replaced, not duplicated") {
        let (g, base) = try freshRoots()
        try FileManager.default.createDirectory(at: Paths.projectClaude(base), withIntermediateDirectories: true)
        let stale = "bash '/Users/someoneelse/.claude/\(Paths.summaryHookScriptName)'"
        try JSONFile.writeObject(["hooks": ["UserPromptSubmit": [
            ["matcher": "*", "hooks": [["type": "command", "command": stale]]]
        ]]], to: Paths.projectSettings(base))
        installer(g, base).sync()
        let cmds = commands(base, event: "UserPromptSubmit")
        try expectEqual(cmds.count, 1, "exactly one registration")
        try expect(!cmds.contains(stale), "foreign-home entry gone")
    })

    results.append(check("a foreign hook sharing the event is preserved") {
        let (g, base) = try freshRoots()
        try FileManager.default.createDirectory(at: Paths.projectClaude(base), withIntermediateDirectories: true)
        try JSONFile.writeObject(["hooks": ["UserPromptSubmit": [
            ["matcher": "*", "hooks": [["type": "command", "command": "echo not-ours"]]]
        ]], "existingUserKey": "keep-me"], to: Paths.projectSettings(base))
        installer(g, base).sync()
        try expect(commands(base, event: "UserPromptSubmit").contains("echo not-ours"), "foreign hook kept")
        let obj = try JSONFile.readObject(Paths.projectSettings(base))
        try expectEqual(obj["existingUserKey"] as? String, "keep-me", "unrelated key kept")
    })

    results.append(check("migrateGlobalSummaryHook strips foreign-home SessionStart + UserPromptSubmit") {
        let (g, base) = try freshRoots()
        let stale = "bash '/Users/someoneelse/.claude/\(Paths.summaryHookScriptName)'"
        try JSONFile.writeObject(["hooks": [
            "SessionStart": [["matcher": "*", "hooks": [["type": "command", "command": stale]]]],
            "UserPromptSubmit": [
                ["matcher": "*", "hooks": [["type": "command", "command": stale]]],
                ["matcher": "*", "hooks": [["type": "command", "command": "echo theirs"]]],
            ],
        ]], to: g.appending(path: "settings.json"))
        installer(g, base).sync()   // installSummaryHook runs the migration
        let obj = try JSONFile.readObject(g.appending(path: "settings.json"))
        let hooks = obj["hooks"] as? [String: Any] ?? [:]
        try expect(hooks["SessionStart"] == nil, "empty SessionStart removed")
        let ups = (hooks["UserPromptSubmit"] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        try expectEqual(ups, ["echo theirs"], "ours stripped globally, theirs kept")
    })

    // MARK: Settings keys

    results.append(check("systemPrompt.append and cleanupPeriodDays install then remove") {
        let (g, base) = try freshRoots()
        let inst = installer(g, base)
        inst.sync()
        var obj = try JSONFile.readObject(Paths.projectSettings(base))
        try expect((obj["systemPrompt.append"] as? String)?.isEmpty == false, "prompt installed")
        try expectEqual(obj["cleanupPeriodDays"] as? Int, 3650, "days installed")

        for c in ManagedConfig.catalog { store.setEnabled(base, c.id, false) }
        inst.sync()
        obj = try JSONFile.readObject(Paths.projectSettings(base))
        try expect(obj["systemPrompt.append"] == nil, "prompt removed")
        try expect(obj["cleanupPeriodDays"] == nil, "days removed")
    })

    results.append(check("toggle-off prunes our entry and drops the emptied event key") {
        let (g, base) = try freshRoots()
        let inst = installer(g, base)
        inst.sync()
        try expect(!commands(base, event: "Stop").isEmpty, "installed first")
        store.setEnabled(base, "memory-hook", false)
        inst.sync()
        try expect(hooksDict(base)["Stop"] == nil, "emptied event key removed")
    })

    results.append(check("toggle-off removes the task command file") {
        let (g, base) = try freshRoots()
        let inst = installer(g, base)
        inst.sync()
        let dest = Paths.projectClaude(base).appending(path: "commands/claudepit-task-plan.md")
        try expect(FileManager.default.fileExists(atPath: dest.path), "installed first")
        store.setEnabled(base, "task-plan", false)
        inst.sync()
        try expect(!FileManager.default.fileExists(atPath: dest.path), "removed on toggle off")
    })

    // MARK: Robustness

    results.append(check("sync re-asserts the exec bit without rewriting unchanged bytes") {
        let (g, base) = try freshRoots()
        let inst = installer(g, base)
        inst.sync()
        let script = g.appending(path: Paths.summaryHookScriptName)
        let before = try Data(contentsOf: script)
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o644, .modificationDate: stamp],
                                              ofItemAtPath: script.path)
        inst.sync()
        let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
        try expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o755, "exec bit repaired")
        try expectEqual(attrs[.modificationDate] as? Date, stamp, "bytes not rewritten")
        try expectEqual(try Data(contentsOf: script), before, "content unchanged")
    })

    results.append(check("invalid and missing settings.json are tolerated") {
        // Invalid: install overwrites from empty; remove leaves it alone.
        let (g1, base1) = try freshRoots()
        try FileManager.default.createDirectory(at: Paths.projectClaude(base1), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: Paths.projectSettings(base1))
        installer(g1, base1).sync()
        try expect(!commands(base1, event: "UserPromptSubmit").isEmpty, "recovered from invalid json")

        // Missing + everything disabled: the removers must not create the file.
        let (g2, base2) = try freshRoots()
        for c in ManagedConfig.catalog { store.setEnabled(base2, c.id, false) }
        installer(g2, base2).sync()
        try expect(!FileManager.default.fileExists(atPath: Paths.projectSettings(base2).path),
                   "removers don't create settings.json")
    })

    results.append(check("app-driven writes never leave .backup. files") {
        let (g, base) = try freshRoots()
        let inst = installer(g, base)
        inst.sync()
        for c in ManagedConfig.catalog { store.setEnabled(base, c.id, false) }
        inst.sync()
        let inClaude = try FileManager.default.contentsOfDirectory(atPath: Paths.projectClaude(base).path)
        try expect(inClaude.allSatisfy { !$0.contains(".backup.") }, "no backups in project .claude")
        let inGlobal = try FileManager.default.contentsOfDirectory(atPath: g.path)
        try expect(inGlobal.allSatisfy { !$0.contains(".backup.") }, "no backups in global claude dir")
    })

    // MARK: taskCommandBodies

    results.append(check("taskCommandBodies returns edited copies and honors toggles") {
        let (g, base) = try freshRoots()
        let plan = ManagedConfig.byID("task-plan")!
        try store.saveContent(base, plan, "EDITED PLAN\n")
        store.setEnabled(base, "task-review", false)
        let bodies = installer(g, base).taskCommandBodies()
        try expectEqual(bodies.count, HookScripts.taskCommands.count - 1, "disabled command excluded")
        try expect(!bodies.contains { $0.filename == "claudepit-task-review.md" }, "review excluded")
        try expectEqual(bodies.first { $0.filename == "claudepit-task-plan.md" }?.body,
                        "EDITED PLAN\n", "edited copy used")
        try expectEqual(bodies.first { $0.filename == "claudepit-task-spec.md" }?.body,
                        HookScripts.taskCommandSpec, "untouched copy is the builtin")
    })

    return results
}
