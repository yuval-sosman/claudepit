import Foundation

/// The kind of Claude-config artifact a managed config produces.
public enum ManagedConfigKind: String, Codable, Sendable {
    case shellScript       // *.sh installed to ~/.claude + registered in settings.json hooks
    case promptText        // markdown injected into settings.json (systemPrompt.append)
    case commandMarkdown   // *.md written to <project>/.claude/commands/
    case number            // integer written to a settings.json key (cleanupPeriodDays)
}

/// A single Claudepit-managed Claude-config artifact. Static catalog entry; the user's editable
/// copy + enabled/number state live in `<project>/.claude/claudepit-config/`.
public struct ManagedConfig: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String       // what it does + which file/key it writes
    public let kind: ManagedConfigKind
    public let filename: String     // editable-copy filename ("" for .number)
    public let builtinDefault: String
    public let defaultEnabled: Bool
    public let defaultNumber: Int?  // 3650 for cleanup-period, nil otherwise

    public static let catalog: [ManagedConfig] = [
        ManagedConfig(
            id: "summary-hook", title: "Session Summary Hook",
            detail: "Injects a running per-session bullet summary each turn. Resolved script installs to ~/.claude/claudepit-summary-hook.sh (shared by all projects — the last-activated project's copy wins) and is registered under UserPromptSubmit in this project's .claude/settings.json.",
            kind: .shellScript, filename: "summary-hook.sh",
            builtinDefault: HookScripts.summaryHook, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "memory-hook", title: "Memory End-of-Session Hook",
            detail: "Reminds Claude to write memory before the session ends, and triggers the dreaming consolidation at ≥10 writes. Resolved script installs to ~/.claude/claudepit-memory-hook.sh and is registered under Stop + StopFailure in this project's .claude/settings.json.",
            kind: .shellScript, filename: "memory-hook.sh",
            builtinDefault: HookScripts.memoryHook, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "memory-system-prompt", title: "Memory System Prompt",
            detail: "The Custom Memory Strategy appended to Claude's system prompt via systemPrompt.append in this project's .claude/settings.json.",
            kind: .promptText, filename: "memory-system-prompt.md",
            builtinDefault: HookScripts.memorySystemPrompt, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "task-brainstorm", title: "Task Command: Brainstorm",
            detail: "The /claudepit-task-brainstorm slash-command, written to this project's .claude/commands/.",
            kind: .commandMarkdown, filename: "claudepit-task-brainstorm.md",
            builtinDefault: HookScripts.taskCommandBrainstorm, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "task-spec", title: "Task Command: Spec",
            detail: "The /claudepit-task-spec slash-command, written to this project's .claude/commands/.",
            kind: .commandMarkdown, filename: "claudepit-task-spec.md",
            builtinDefault: HookScripts.taskCommandSpec, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "task-plan", title: "Task Command: Plan",
            detail: "The /claudepit-task-plan slash-command, written to this project's .claude/commands/.",
            kind: .commandMarkdown, filename: "claudepit-task-plan.md",
            builtinDefault: HookScripts.taskCommandPlan, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "task-implement", title: "Task Command: Implement",
            detail: "The /claudepit-task-implement slash-command, written to this project's .claude/commands/.",
            kind: .commandMarkdown, filename: "claudepit-task-implement.md",
            builtinDefault: HookScripts.taskCommandImplement, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "task-review", title: "Task Command: Review",
            detail: "The /claudepit-task-review slash-command, written to this project's .claude/commands/.",
            kind: .commandMarkdown, filename: "claudepit-task-review.md",
            builtinDefault: HookScripts.taskCommandReview, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "task-fix", title: "Task Command: Fix Findings",
            detail: "The /claudepit-task-fix slash-command, written to this project's .claude/commands/. Run instead of Implement by a task created from another task's review findings — there is no plan for Implement to follow.",
            kind: .commandMarkdown, filename: "claudepit-task-fix.md",
            builtinDefault: HookScripts.taskCommandFix, defaultEnabled: true, defaultNumber: nil),
        ManagedConfig(
            id: "cleanup-period", title: "Prevent Session Cleanup",
            detail: "Sets cleanupPeriodDays in this project's .claude/settings.json so Claude keeps old session transcripts (Claudepit reads them). Default 3650 (~10 years).",
            kind: .number, filename: "", builtinDefault: "", defaultEnabled: true, defaultNumber: 3650),
    ]

    public static func byID(_ id: String) -> ManagedConfig? { catalog.first { $0.id == id } }
}

public struct ManagedConfigState: Codable, Sendable {
    public var enabled: Bool
    public var cleanupPeriodDays: Int?
    /// Stable hash of the built-in default this copy was last seeded/reset from. Lets us
    /// auto-update an UNTOUCHED copy (file still matches this) while preserving user edits.
    public var seededHash: String?
    public init(enabled: Bool, cleanupPeriodDays: Int? = nil, seededHash: String? = nil) {
        self.enabled = enabled
        self.cleanupPeriodDays = cleanupPeriodDays
        self.seededHash = seededHash
    }
}

public struct AppConfigFile: Codable, Sendable {
    public var version: Int
    public var configs: [String: ManagedConfigState]
    public init(version: Int = 1, configs: [String: ManagedConfigState] = [:]) {
        self.version = version
        self.configs = configs
    }
}

/// Whether a config's editable copy still matches the built-in it was seeded from — i.e. whether
/// it is still eligible for auto-update.
public enum ManagedCopyStatus: Sendable {
    case untouched   // matches its seededHash → adopts a new built-in automatically
    case edited      // user-modified → auto-update paused until Reset to default
    case missing     // no copy on disk; the next seedIfNeeded recreates it
}

/// Per-project store for user-editable copies of the Claudepit-managed configs, plus their
/// enabled/number state (config.json). Installers read content/state from here instead of the
/// `HookScripts` constants, so user edits survive relaunches.
public struct AppConfigStore: Sendable {
    public init() {}

    private func editableURL(_ base: URL, _ c: ManagedConfig) -> URL {
        Paths.appConfigDir(base).appending(path: c.filename)
    }

    // MARK: Content (editable copies)

    /// Editable-copy content, falling back to the built-in default if missing/unreadable/empty.
    public func content(_ base: URL, _ c: ManagedConfig) -> String {
        guard !c.filename.isEmpty,
              let data = try? Data(contentsOf: editableURL(base, c)),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return c.builtinDefault }
        return text
    }

    public func saveContent(_ base: URL, _ c: ManagedConfig, _ text: String) throws {
        guard !c.filename.isEmpty else { return }
        let dir = Paths.appConfigDir(base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: editableURL(base, c), options: .atomic)
        // A user edit intentionally leaves seededHash pointing at the OLD built-in, so the file no
        // longer matches it — that's what marks the copy "touched" and protects it from auto-update.
    }

    public func resetToDefault(_ base: URL, _ c: ManagedConfig) throws {
        try saveContent(base, c, c.builtinDefault)
        setSeededHash(base, c.id, Self.hash(c.builtinDefault))   // realign: reset makes it untouched-at-current
    }

    // MARK: Auto-update status

    /// Status of `c`'s editable copy. Entries with no copy (`.number`) report `.untouched` — there
    /// is nothing on disk to diverge from the built-in.
    public func status(_ base: URL, _ c: ManagedConfig) -> ManagedCopyStatus {
        guard !c.filename.isEmpty else { return .untouched }
        guard let current = try? String(contentsOf: editableURL(base, c), encoding: .utf8) else {
            return .missing
        }
        return Self.copyStatus(current: current,
                               seededHash: load(base).configs[c.id]?.seededHash,
                               builtin: c.builtinDefault)
    }

    /// The untouched-vs-edited decision, shared by `status(_:_:)` and `seedIfNeeded` so the two can
    /// never disagree about what counts as a user edit.
    static func copyStatus(current: String, seededHash: String?, builtin: String) -> ManagedCopyStatus {
        guard let seededHash else {
            // Pre-hashing (or hand-created) copy: untouched only if it already equals the built-in.
            return hash(current) == hash(builtin) ? .untouched : .edited
        }
        return seededHash == hash(current) ? .untouched : .edited
    }

    /// Stable (run-independent) FNV-1a hash of a string. Used to detect whether an editable copy
    /// still matches the built-in it was seeded from.
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    #if DEBUG
    /// Test-only shims (assert harness lives in a separate target via @testable import).
    static func hashForTest(_ s: String) -> String { hash(s) }
    func setSeededHashForTest(_ base: URL, _ id: String, _ hash: String) { setSeededHash(base, id, hash) }
    #endif

    private func setSeededHash(_ base: URL, _ id: String, _ hash: String) {
        var file = load(base)
        var state = file.configs[id] ?? ManagedConfigState(enabled: ManagedConfig.byID(id)?.defaultEnabled ?? true)
        state.seededHash = hash
        file.configs[id] = state
        save(base, file)
    }

    // MARK: State (config.json)

    public func load(_ base: URL) -> AppConfigFile {
        guard let data = try? Data(contentsOf: Paths.appConfigFile(base)),
              let file = try? JSONDecoder().decode(AppConfigFile.self, from: data)
        else { return AppConfigFile() }
        return file
    }

    private func save(_ base: URL, _ file: AppConfigFile) {
        let dir = Paths.appConfigDir(base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: Paths.appConfigFile(base), options: .atomic)
    }

    public func isEnabled(_ base: URL, _ id: String) -> Bool {
        if let state = load(base).configs[id] { return state.enabled }
        return ManagedConfig.byID(id)?.defaultEnabled ?? false
    }

    public func setEnabled(_ base: URL, _ id: String, _ on: Bool) {
        var file = load(base)
        var state = file.configs[id] ?? ManagedConfigState(enabled: on)
        state.enabled = on
        file.configs[id] = state
        save(base, file)
    }

    public func cleanupPeriodDays(_ base: URL) -> Int {
        load(base).configs["cleanup-period"]?.cleanupPeriodDays
            ?? ManagedConfig.byID("cleanup-period")?.defaultNumber ?? 3650
    }

    public func setCleanupPeriodDays(_ base: URL, _ days: Int) {
        var file = load(base)
        var state = file.configs["cleanup-period"] ?? ManagedConfigState(enabled: true)
        state.cleanupPeriodDays = days
        file.configs["cleanup-period"] = state
        save(base, file)
    }

    // MARK: Seeding

    /// Seed missing copies AND auto-update any copy the user hasn't touched. For each file-backed
    /// config: if the file is missing, write the current built-in; if it still matches the built-in
    /// it was last seeded/reset from (untouched) but the built-in has since changed, overwrite it
    /// with the new built-in. A copy the user edited (file no longer matches its `seededHash`) is
    /// never overwritten. Runs on every launch/project-switch, so improvements reach untouched
    /// configs automatically. Also seeds config.json defaults on first run (migrating legacy
    /// `ProjectPrefs.memoryEnabled` into the two memory configs).
    public func seedIfNeeded(_ base: URL) {
        let dir = Paths.appConfigDir(base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var file = load(base)
        let firstRun = (try? Data(contentsOf: Paths.appConfigFile(base))) == nil
        let legacyMemory = firstRun ? ProjectPrefsStore.load(base).memoryEnabled : true

        for c in ManagedConfig.catalog {
            var state = file.configs[c.id] ?? {
                let enabled = (c.id == "memory-hook" || c.id == "memory-system-prompt")
                    ? legacyMemory : c.defaultEnabled
                return ManagedConfigState(enabled: enabled, cleanupPeriodDays: c.defaultNumber)
            }()

            if !c.filename.isEmpty {
                let url = editableURL(base, c)
                let builtinHash = Self.hash(c.builtinDefault)
                if let current = try? String(contentsOf: url, encoding: .utf8) {
                    switch Self.copyStatus(current: current, seededHash: state.seededHash,
                                           builtin: c.builtinDefault) {
                    case .untouched:
                        // Untouched by the user → adopt the current built-in, writing only when it
                        // actually changed so an unchanged relaunch doesn't churn the file.
                        if Self.hash(current) != builtinHash {
                            try? Data(c.builtinDefault.utf8).write(to: url, options: .atomic)
                        }
                        state.seededHash = builtinHash
                    case .edited, .missing:
                        // A copy the user touched is never overwritten, and its seededHash is left
                        // pointing at the older built-in so it stays out of auto-update.
                        break
                    }
                } else {
                    // Missing → seed with current built-in.
                    try? Data(c.builtinDefault.utf8).write(to: url, options: .atomic)
                    state.seededHash = builtinHash
                }
            }
            file.configs[c.id] = state
        }
        save(base, file)
    }
}
