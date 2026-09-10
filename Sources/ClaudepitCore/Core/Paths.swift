import Foundation

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static var globalClaude: URL { home.appending(path: ".claude") }
    public static var globalSettings: URL { globalClaude.appending(path: "settings.json") }
    /// Claude CLI's global MCP server definitions — ~/.claude.json (home dir, not inside ~/.claude/)
    public static var globalClaudeJson: URL { home.appending(path: ".claude.json") }
    public static var globalLocalSettings: URL { globalClaude.appending(path: "settings.local.json") }
    public static var globalSkills: URL { globalClaude.appending(path: "skills") }
    public static var globalCommands: URL { globalClaude.appending(path: "commands") }
    public static var globalAgents: URL { globalClaude.appending(path: "agents") }
    public static var pluginsRoot: URL { globalClaude.appending(path: "plugins") }
    public static var plansRoot: URL { globalClaude.appending(path: "plans") }
    public static var installedPlugins: URL { pluginsRoot.appending(path: "installed_plugins.json") }
    public static var knownMarketplaces: URL { pluginsRoot.appending(path: "known_marketplaces.json") }
    public static var stateFile: URL { globalClaude.appending(path: "claudepit-state.json") }
    /// Managed hook scripts. The filename is the stable identity used to recognise our own
    /// registrations across machines; the directory is re-derived from the current home.
    public static let summaryHookScriptName = "claudepit-summary-hook.sh"
    public static let memoryHookScriptName = "claudepit-memory-hook.sh"
    public static var summaryHookScript: URL { globalClaude.appending(path: summaryHookScriptName) }
    public static var memoryHookScript: URL { globalClaude.appending(path: memoryHookScriptName) }
    public static var groupsRoot: URL { globalClaude.appending(path: "claudepit-groups") }
    public static var topicsRoot: URL { globalClaude.appending(path: "claudepit-task-topics") }
    public static func groupsFile(projectSlug: String) -> URL {
        groupsRoot.appending(path: "\(projectSlug).json")
    }
    public static var projectsRoot: URL { globalClaude.appending(path: "projects") }
    public static func summaryDir(projectSlug: String) -> URL {
        projectsRoot.appending(path: projectSlug).appending(path: "summary")
    }
    public static func summaryFile(projectSlug: String, sessionID: String) -> URL {
        summaryDir(projectSlug: projectSlug).appending(path: "\(sessionID).json")
    }
    public static func memoryDir(projectSlug: String) -> URL {
        projectsRoot.appending(path: projectSlug).appending(path: "memory")
    }
    public static func memoryLogFile(projectSlug: String) -> URL {
        memoryDir(projectSlug: projectSlug).appending(path: "log.json")
    }
    public static func tasksRoot(projectSlug: String) -> URL {
        projectsRoot.appending(path: projectSlug).appending(path: "tasks")
    }
    public static func taskDir(projectSlug: String, id: String) -> URL {
        tasksRoot(projectSlug: projectSlug).appending(path: id)
    }
    public static func taskFile(projectSlug: String, id: String) -> URL {
        taskDir(projectSlug: projectSlug, id: id).appending(path: "task.json")
    }
    public static func taskAttachmentsDir(projectSlug: String, id: String) -> URL {
        taskDir(projectSlug: projectSlug, id: id).appending(path: "attachments")
    }
    public static func taskBrainstormFile(projectSlug: String, id: String) -> URL {
        // Brainstorm now produces a structured YAML deliverable (suggestions the user accepts one-by-one).
        taskDir(projectSlug: projectSlug, id: id).appending(path: "brainstorm.yaml")
    }

    public static func projectPrefs(projectSlug: String) -> URL {
        projectsRoot.appending(path: projectSlug).appending(path: "prefs.json")
    }

    /// Claude's per-project session dir name: absolute path with every `/` replaced by `-`.
    public static func slug(for base: URL) -> String {
        base.path(percentEncoded: false).replacingOccurrences(of: "/", with: "-")
    }

    /// Reverse of slug(for:): recovers the absolute project path from a slug.
    public static func projectPath(for slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: "/")
    }

    public static func projectClaude(_ base: URL) -> URL { base.appending(path: ".claude") }
    /// User-editable copies of Claudepit-managed configs (hooks, prompts, task commands, config.json).
    public static func appConfigDir(_ base: URL) -> URL { projectClaude(base).appending(path: "claudepit-config") }
    public static func appConfigFile(_ base: URL) -> URL { appConfigDir(base).appending(path: "config.json") }
    public static func projectSettings(_ base: URL) -> URL { projectClaude(base).appending(path: "settings.json") }
    public static func projectLocalSettings(_ base: URL) -> URL { projectClaude(base).appending(path: "settings.local.json") }
    /// Project MCP servers can be declared in `<project>/.mcp.json` (project root, not .claude/).
    public static func projectMcpJson(_ base: URL) -> URL { base.appending(path: ".mcp.json") }
}
