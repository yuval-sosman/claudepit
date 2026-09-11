import Foundation

/// Makes disk match the managed-config catalog and the project's enable/edit state: writes the
/// hook scripts, reconciles their registrations, and installs the settings keys and task commands.
///
/// Extracted from `AppState` so it is testable — every path derives from `globalClaudeDir` and
/// `base` rather than from `Paths.home`, which is a `static let` and cannot be redirected.
public struct ManagedInstaller: Sendable {
    let appConfig: AppConfigStore
    let globalClaudeDir: URL
    let base: URL

    public init(appConfig: AppConfigStore,
                globalClaudeDir: URL = Paths.globalClaude,
                base: URL) {
        self.appConfig = appConfig
        self.globalClaudeDir = globalClaudeDir
        self.base = base
    }

    private var summaryHookScript: URL { globalClaudeDir.appending(path: Paths.summaryHookScriptName) }
    private var memoryHookScript: URL { globalClaudeDir.appending(path: Paths.memoryHookScriptName) }
    private var globalSettings: URL { globalClaudeDir.appending(path: "settings.json") }
    private var projectClaude: URL { Paths.projectClaude(base) }
    private var projectSettings: URL { Paths.projectSettings(base) }

    /// Install-when-on / remove-when-off for every managed config, reading content from AppConfigStore.
    public func sync() {
        for c in ManagedConfig.catalog {
            let on = appConfig.isEnabled(base, c.id)
            switch c.id {
            case "summary-hook":         on ? installSummaryHook() : removeSummaryHook()
            case "memory-hook":          on ? installMemoryHooks() : removeMemoryHooks()
            case "memory-system-prompt": on ? installMemorySystemPrompt() : removeMemorySystemPrompt()
            case "cleanup-period":       on ? installCleanupPeriod() : removeCleanupPeriod()
            default:
                if c.kind == .commandMarkdown {
                    on ? installTaskCommand(c) : removeTaskCommand(c)
                }
            }
        }
        // Retired commands: their catalog entries are gone, so install/remove above never touches
        // them — sweep copies an older build installed. Filesystem-derived (no UserDefaults flag),
        // so it heals every managed project this app opens, on any machine.
        for f in HookScripts.retiredTaskCommandFilenames {
            try? FileManager.default.removeItem(
                at: projectClaude.appending(path: "commands").appending(path: f))
        }
    }

    /// Enabled task commands with the project's editable-copy bodies — the single source worktree
    /// installs should use too, so a user edit isn't silently replaced by the built-in.
    public func taskCommandBodies() -> [(filename: String, body: String)] {
        ManagedConfig.catalog
            .filter { $0.kind == .commandMarkdown && appConfig.isEnabled(base, $0.id) }
            .map { ($0.filename, appConfig.content(base, $0)) }
    }

    // MARK: - Settings + script primitives

    /// Read → mutate → write one settings.json. `change` returns false to skip the write, which is
    /// where every installer's churn guard lives: an unchanged relaunch must not touch the file.
    /// Uses `JSONFile` for round-trip validation and an atomic write; no backup copy is made —
    /// these are app-driven writes, not user edits.
    @discardableResult
    private func mutateSettings(_ url: URL, createIfMissing: Bool,
                                _ change: (inout [String: Any]) -> Bool) -> Bool {
        var settings: [String: Any]
        if let existing = try? JSONFile.readObject(url) {
            settings = existing
        } else if createIfMissing {
            settings = [:]
        } else {
            return false
        }
        guard change(&settings) else { return false }
        try? JSONFile.writeObject(settings, to: url)
        return true
    }

    /// Overwrite-if-changed, so a relaunch that changes nothing doesn't churn the file. The exec
    /// bit is re-asserted every time regardless: an unzip, a restore, or a copy between machines
    /// can strip it while leaving the bytes intact, and a hook that isn't executable fails silently.
    private func writeScript(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if (try? Data(contentsOf: url)) != data {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func createProjectClaude() {
        try? FileManager.default.createDirectory(at: projectClaude, withIntermediateDirectories: true)
    }

    /// Leave `scriptName` registered exactly once under each of the entry's hook events. The events
    /// come from `ManagedArtifacts` so the installer and the ownership index cannot drift apart.
    /// `command` is built per event — the memory hook passes the event name as an argument, the
    /// summary hook doesn't.
    private func reconcileHooks(configID: String, scriptName: String, command: (String) -> String) {
        createProjectClaude()
        mutateSettings(projectSettings, createIfMissing: true) { settings in
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            var changed = false
            for event in ManagedArtifacts.hookEvents(for: configID) {
                let entries = hooks[event] as? [[String: Any]] ?? []
                // Reconcile rather than append-if-absent: a registration carried over from another
                // machine names the same script under a home that doesn't exist here, and must be
                // replaced, not sat beside. See HookRegistration.
                let (reconciled, didChange) = HookRegistration.reconcile(
                    entries, scriptName: scriptName, command: command(event))
                if didChange {
                    hooks[event] = reconciled
                    changed = true
                }
            }
            guard changed else { return false }
            settings["hooks"] = hooks
            return true
        }
    }

    /// Drop `scriptName` from each of the entry's hook events (toggle off). Pruning by script name
    /// also clears entries another machine left behind.
    private func pruneHooks(configID: String, scriptName: String) {
        mutateSettings(projectSettings, createIfMissing: false) { settings in
            guard var hooks = settings["hooks"] as? [String: Any] else { return false }
            var changed = false
            for event in ManagedArtifacts.hookEvents(for: configID) {
                guard let entries = hooks[event] as? [[String: Any]] else { continue }
                let (pruned, removed) = HookRegistration.prune(entries, scriptName: scriptName)
                if removed > 0 {
                    hooks[event] = pruned.isEmpty ? nil : pruned
                    changed = true
                }
            }
            guard changed else { return false }
            settings["hooks"] = hooks
            return true
        }
    }

    // MARK: - Summary hook

    private func installSummaryHook() {
        let hookPath = summaryHookScript

        // Write resolved script if missing or content changed (script stays in ~/.claude — it resolves
        // the project slug from cwd at runtime; only its *registration* is project-scoped). The source
        // is this project's editable copy under claudepit-config/.
        writeScript(appConfig.content(base, ManagedConfig.byID("summary-hook")!), to: hookPath)
        let hookCommand = "bash '\(hookPath.path)'"

        // Migrate: strip stale global registrations (old SessionStart + old global UserPromptSubmit).
        migrateGlobalSummaryHook()

        // Register under UserPromptSubmit in PROJECT settings (Claudepit-managed projects only).
        reconcileHooks(configID: "summary-hook",
                       scriptName: Paths.summaryHookScriptName) { _ in hookCommand }
    }

    /// Strip the summary hook's UserPromptSubmit registration from PROJECT settings (toggle off).
    private func removeSummaryHook() {
        pruneHooks(configID: "summary-hook", scriptName: Paths.summaryHookScriptName)
    }

    /// Remove the summary hook from GLOBAL settings (older builds registered it there under
    /// SessionStart, then UserPromptSubmit). It now lives in project settings only. Pruning by
    /// script name — not by exact command — also clears a registration another machine wrote,
    /// whose absolute path names a home that doesn't exist here.
    private func migrateGlobalSummaryHook() {
        mutateSettings(globalSettings, createIfMissing: false) { settings in
            guard var hooks = settings["hooks"] as? [String: Any] else { return false }
            var changed = false
            for event in ["SessionStart", "UserPromptSubmit"] {
                guard let entries = hooks[event] as? [[String: Any]] else { continue }
                let (pruned, removed) = HookRegistration.prune(
                    entries, scriptName: Paths.summaryHookScriptName)
                if removed > 0 {
                    hooks[event] = pruned.isEmpty ? nil : pruned
                    changed = true
                }
            }
            guard changed else { return false }
            settings["hooks"] = hooks
            return true
        }
    }

    // MARK: - Memory hooks + system prompt

    private func installMemoryHooks() {
        let hookPath = memoryHookScript
        writeScript(appConfig.content(base, ManagedConfig.byID("memory-hook")!), to: hookPath)
        reconcileHooks(configID: "memory-hook", scriptName: Paths.memoryHookScriptName) { event in
            "bash '\(hookPath.path)' \(event)"
        }
    }

    private func removeMemoryHooks() {
        pruneHooks(configID: "memory-hook", scriptName: Paths.memoryHookScriptName)
    }

    private func installMemorySystemPrompt() {
        createProjectClaude()
        let prompt = appConfig.content(base, ManagedConfig.byID("memory-system-prompt")!)
        mutateSettings(projectSettings, createIfMissing: true) { settings in
            guard (settings["systemPrompt.append"] as? String) != prompt else { return false }
            settings["systemPrompt.append"] = prompt
            return true
        }
    }

    private func removeMemorySystemPrompt() {
        mutateSettings(projectSettings, createIfMissing: false) { settings in
            guard settings["systemPrompt.append"] != nil else { return false }
            settings.removeValue(forKey: "systemPrompt.append")
            return true
        }
    }

    // MARK: - Cleanup period

    private func installCleanupPeriod() {
        createProjectClaude()
        let days = appConfig.cleanupPeriodDays(base)
        mutateSettings(projectSettings, createIfMissing: true) { settings in
            // Churn guard: only rewrite settings.json when the value actually changed.
            guard (settings["cleanupPeriodDays"] as? Int) != days else { return false }
            settings["cleanupPeriodDays"] = days
            return true
        }
    }

    private func removeCleanupPeriod() {
        mutateSettings(projectSettings, createIfMissing: false) { settings in
            guard settings["cleanupPeriodDays"] != nil else { return false }
            settings.removeValue(forKey: "cleanupPeriodDays")
            return true
        }
    }

    // MARK: - Task commands

    private func installTaskCommand(_ c: ManagedConfig) {
        let dir = projectClaude.appending(path: "commands")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: c.filename)
        let data = Data(appConfig.content(base, c).utf8)
        // overwrite-always (app-owned), but skip write if unchanged to avoid watcher churn
        if (try? Data(contentsOf: dest)) != data {
            try? data.write(to: dest)
        }
    }

    private func removeTaskCommand(_ c: ManagedConfig) {
        try? FileManager.default.removeItem(
            at: projectClaude.appending(path: "commands").appending(path: c.filename))
    }

    // MARK: - One-time migrations

    /// Records migrations whose "already done" state cannot be re-derived from the filesystem —
    /// they delete files this machine owns and leave nothing behind to detect on the next launch.
    /// A migration that *can* detect its own leftovers self-disables instead; see
    /// `migrateSummariesIfNeeded`.
    static let migrationsKey = "completedMigrations"

    private static func runOnce(_ id: String, _ defaults: UserDefaults, _ body: () -> Void) {
        var done = defaults.stringArray(forKey: migrationsKey) ?? []
        guard !done.contains(id) else { return }
        body()
        done.append(id)
        defaults.set(done, forKey: migrationsKey)
    }

    /// One-time: drop the old global task-command copies (now project-scoped) + the 4 pre-slash-command subagents.
    public static func migrateTaskCommandLocationsIfNeeded(globalClaudeDir: URL = Paths.globalClaude,
                                                           defaults: UserDefaults = .standard) {
        runOnce("task-command-locations", defaults) {
            let commands = globalClaudeDir.appending(path: "commands")
            let agents = globalClaudeDir.appending(path: "agents")
            for cmd in HookScripts.taskCommands {
                try? FileManager.default.removeItem(at: commands.appending(path: cmd.filename))
            }
            for name in HookScripts.oldTaskAgentFilenames {
                try? FileManager.default.removeItem(at: agents.appending(path: name))
            }
        }
    }

    /// One-time: move `claudepit-summaries/<slug>.json` into per-session `projects/<slug>/summary/`.
    ///
    /// Guarded only by the old directory's existence, deliberately: `~/.claude` travels between
    /// machines, so a `UserDefaults` "done" flag recorded on a launch where nothing was there
    /// would permanently strand summaries later restored from a backup or carried from another Mac.
    /// Once the migration succeeds it deletes `oldRoot`, so the check self-disables anyway.
    public static func migrateSummariesIfNeeded(globalClaudeDir: URL = Paths.globalClaude) {
        let oldRoot = globalClaudeDir.appending(path: "claudepit-summaries")
        guard FileManager.default.fileExists(atPath: oldRoot.path) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: oldRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let ps = try? dec.decode(ProjectSummaries.self, from: data) else { continue }
            let slug = file.deletingPathExtension().lastPathComponent
            let dir = globalClaudeDir.appending(path: "projects")
                .appending(path: slug).appending(path: "summary")
            guard (try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)) != nil else { continue }
            var allMigrated = true
            for (sessionID, entry) in ps.summaries {
                let dest = dir.appending(path: "\(sessionID).json")
                guard let encoded = try? enc.encode(entry) else { allMigrated = false; continue }
                if (try? encoded.write(to: dest, options: .atomic)) == nil { allMigrated = false }
            }
            if allMigrated { try? FileManager.default.removeItem(at: file) }
        }
        // Remove old directory if now empty
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: oldRoot.path)) ?? []
        if remaining.isEmpty { try? FileManager.default.removeItem(at: oldRoot) }
    }
}
