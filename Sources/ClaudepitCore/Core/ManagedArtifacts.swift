import Foundation

/// What each catalog entry concretely owns on disk: which settings keys it claims, which hook
/// events it registers under, which script it installs, and every file it writes.
///
/// Ownership is answered two ways, matching how the installers write. Hooks are recognised by
/// **value** — the command names one of our scripts, whatever home directory it points at (the
/// same cross-machine identity `HookRegistration` reconciles on). Settings keys are recognised by
/// **key plus layer** — we only ever claim them in the active project's `settings.json`, never in
/// the global layer or another project's.
public enum ManagedArtifacts {

    /// Why a managed config writes to a given file.
    public enum FileRole: String, Sendable {
        case editableCopy       // <project>/.claude/claudepit-config/<filename> — what we install from
        case installedScript    // ~/.claude/claudepit-*.sh
        case installedCommand   // <project>/.claude/commands/<filename>
        case settings           // a key or hook event inside <project>/.claude/settings.json
    }

    public struct WrittenFile: Sendable {
        public let url: URL
        public let role: FileRole
        /// The specific key/event inside the file, for `.settings` rows; empty otherwise.
        public let detail: String

        public init(url: URL, role: FileRole, detail: String = "") {
            self.url = url
            self.role = role
            self.detail = detail
        }
    }

    /// Top-level `settings.json` keys the entry writes into the active project's layer.
    public static func settingsKeys(for id: String) -> [String] {
        switch id {
        case "memory-system-prompt": return ["systemPrompt.append"]
        case "cleanup-period":       return ["cleanupPeriodDays"]
        default:                     return []
        }
    }

    /// Hook events the entry registers its script under.
    public static func hookEvents(for id: String) -> [String] {
        switch id {
        case "summary-hook": return ["UserPromptSubmit"]
        case "memory-hook":  return ["Stop", "StopFailure"]
        default:             return []
        }
    }

    /// Filename of the script the entry installs into `~/.claude` — the entry's cross-machine identity.
    public static func scriptName(for id: String) -> String? {
        switch id {
        case "summary-hook": return Paths.summaryHookScriptName
        case "memory-hook":  return Paths.memoryHookScriptName
        default:             return nil
        }
    }

    /// The entry that installed a hook `command`, or nil when the command isn't ours.
    public static func owner(ofHookCommand command: String) -> ManagedConfig? {
        ManagedConfig.catalog.first { c in
            guard let name = scriptName(for: c.id) else { return false }
            return HookRegistration.isManaged(command, scriptName: name)
        }
    }

    /// The entry that owns a top-level settings key — only in the active project's `settings.json`.
    public static func owner(ofSettingsKey key: String, sourceURL: URL, base: URL) -> ManagedConfig? {
        guard sourceURL.standardizedFileURL.path == Paths.projectSettings(base).standardizedFileURL.path
        else { return nil }
        return ManagedConfig.catalog.first { settingsKeys(for: $0.id).contains(key) }
    }

    /// Every file the entry writes, in install order, for the App Settings file map.
    ///
    /// `globalClaudeDir` matches `ManagedInstaller`'s so both can be pointed at the same temp roots
    /// in tests; every other path already derives from `base`.
    public static func writtenFiles(for c: ManagedConfig, base: URL,
                                    globalClaudeDir: URL = Paths.globalClaude) -> [WrittenFile] {
        var out: [WrittenFile] = []
        if !c.filename.isEmpty {
            out.append(WrittenFile(url: Paths.appConfigDir(base).appending(path: c.filename),
                                   role: .editableCopy))
        }
        if let name = scriptName(for: c.id) {
            out.append(WrittenFile(url: globalClaudeDir.appending(path: name), role: .installedScript))
        }
        if c.kind == .commandMarkdown {
            out.append(WrittenFile(
                url: Paths.projectClaude(base).appending(path: "commands").appending(path: c.filename),
                role: .installedCommand))
        }
        for event in hookEvents(for: c.id) {
            out.append(WrittenFile(url: Paths.projectSettings(base), role: .settings,
                                   detail: "hooks.\(event)"))
        }
        for key in settingsKeys(for: c.id) {
            out.append(WrittenFile(url: Paths.projectSettings(base), role: .settings, detail: key))
        }
        return out
    }
}
