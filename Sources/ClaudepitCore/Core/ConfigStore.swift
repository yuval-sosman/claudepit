import Foundation
import Combine

@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var mcpServers: [MCPServer] = []
    @Published public private(set) var skills: [Skill] = []
    @Published public private(set) var commands: [Command] = []
    @Published public private(set) var agents: [Agent] = []
    @Published public private(set) var rules: [Rule] = []
    @Published public private(set) var hooks: [Hook] = []
    @Published public private(set) var plugins: [Plugin] = []
    @Published public private(set) var envVars: [EnvVar] = []
    @Published public private(set) var settingEntries: [SettingEntry] = []
    @Published public private(set) var model: ModelConfig?
    /// Raw settings per layer, ordered global → project → projectLocal → local (ascending precedence).
    @Published public private(set) var settingsLayers: [SettingsLayer] = []

    public struct SettingsLayer {
        public let scope: Scope
        public let source: URL
        public let raw: [String: Any]
    }

    public init() {}

    public func reload(activePath: URL?) {
        var global = ConfigScanner(claudeDir: Paths.globalClaude, scope: .global).scan()
        // Global MCP servers live in ~/.claude.json (home dir), not settings.json.
        // Merge into global layer; settings.json entries take precedence.
        if let obj = try? JSONFile.readObject(Paths.globalClaudeJson) {
            let fromClaudeJson = ConfigScanner.parseMCP(obj, scope: .global, source: Paths.globalClaudeJson)
            let existing = Set(global.mcpServers.map(\.id))
            global.mcpServers += fromClaudeJson.filter { !existing.contains($0.id) }
        }
        let local  = ConfigScanner(claudeDir: Paths.globalClaude, scope: .local).scan()
        var project = LayerResult(); var projectLocal = LayerResult()
        if let base = activePath {
            project = ConfigScanner(claudeDir: Paths.projectClaude(base), scope: .project).scan()
            projectLocal = ConfigScanner(claudeDir: Paths.projectClaude(base), scope: .local).scan()
            // Project MCP servers can also come from <project>/.mcp.json (project root).
            // settings.json's mcpServers take precedence, so only add names not already present.
            let existing = Set(project.mcpServers.map(\.id))
            let fromMcpJson = ConfigScanner.parseMcpJsonFile(Paths.projectMcpJson(base), scope: .project)
            project.mcpServers += fromMcpJson.filter { !existing.contains($0.id) }
        }
        let globalEnabledDict = global.settings["enabledPlugins"] as? [String: Bool]
        var enabled = globalEnabledDict ?? [:]
        let projectEnabledDict = project.settings["enabledPlugins"] as? [String: Bool]
        if let p = projectEnabledDict { enabled.merge(p) { _, proj in proj } }
        if let pl = projectLocal.settings["enabledPlugins"] as? [String: Bool] { enabled.merge(pl) { _, local in local } }
        let (plugins, contribs) = PluginScanner(pluginsRoot: Paths.pluginsRoot, enabledPlugins: enabled).scan()

        let merged = Self.merge(global: global, project: project,
                                local: local, projectLocal: projectLocal,
                                plugins: plugins, contribs: contribs, activePath: activePath?.path)
        self.mcpServers = merged.mcp
        self.skills = Self.applySkillOverrides(merged.skills, project: project.settings, global: global.settings)
        self.commands = merged.commands
        self.agents = merged.agents
        self.rules = merged.rules
        self.hooks = merged.hooks
        self.envVars = merged.env
        self.settingEntries = merged.settings
        self.plugins = plugins.map { p in
            var out = p
            out.globalEnabled = globalEnabledDict?[p.id]
            out.projectEnabled = projectEnabledDict?[p.id]
            return out
        }
        self.model = merged.model

        var layers: [SettingsLayer] = []
        if let src = global.settingsSourcePath, !global.settings.isEmpty {
            layers.append(SettingsLayer(scope: .global, source: src, raw: global.settings))
        }
        if let src = project.settingsSourcePath, !project.settings.isEmpty {
            layers.append(SettingsLayer(scope: .project, source: src, raw: project.settings))
        }
        if let src = projectLocal.settingsSourcePath, !projectLocal.settings.isEmpty {
            layers.append(SettingsLayer(scope: .local, source: src, raw: projectLocal.settings))
        }
        if let src = local.settingsSourcePath, !local.settings.isEmpty {
            layers.append(SettingsLayer(scope: .local, source: src, raw: local.settings))
        }
        self.settingsLayers = layers
    }

    public struct Merged {
        public var mcp: [MCPServer]
        public var skills: [Skill]
        public var commands: [Command]
        public var agents: [Agent]
        public var rules: [Rule]
        public var hooks: [Hook]
        public var env: [EnvVar]
        public var settings: [SettingEntry]
        public var model: ModelConfig?

        public init(mcp: [MCPServer], skills: [Skill], commands: [Command], agents: [Agent], rules: [Rule], hooks: [Hook], env: [EnvVar], settings: [SettingEntry], model: ModelConfig?) {
            self.mcp = mcp
            self.skills = skills
            self.commands = commands
            self.agents = agents
            self.rules = rules
            self.hooks = hooks
            self.env = env
            self.settings = settings
            self.model = model
        }
    }

    /// Pure, testable. Layers ordered lowest→highest precedence: global, project, local, projectLocal.
    /// `activePath` gates plugin contributions: a plugin's skills/commands/etc. are only surfaced
    /// when the plugin is active for that project (global installs always; project/local only when
    /// their install path matches). Pass nil to include only globally-installed plugins' contributions.
    nonisolated public static func merge(global: LayerResult, project: LayerResult,
                                  local: LayerResult, projectLocal: LayerResult,
                                  plugins: [Plugin], contribs: [PluginContribution],
                                  activePath: String? = nil) -> Merged {
        // Ordered low→high. Later wins; earlier duplicates marked overridden.
        let layers = [global, project, local, projectLocal]

        // A plugin contribution is visible only if its owning plugin is active for activePath.
        let activePluginIDs = Set(plugins.filter { pluginActive($0, for: activePath) }.map(\.id))
        let visibleContribs = contribs.filter { activePluginIDs.contains($0.pluginID) }

        func mergeByKey<T: ConfigItem>(_ pick: (LayerResult) -> [T], key: (T) -> String,
                                       markOverridden: (T) -> T) -> [T] {
            var winner: [String: T] = [:]
            var order: [String] = []
            var overriddenLosers: [T] = []
            for layer in layers {
                for item in pick(layer) {
                    let k = key(item)
                    if let prev = winner[k] { overriddenLosers.append(markOverridden(prev)) }
                    else { order.append(k) }
                    winner[k] = item
                }
            }
            let winners = order.compactMap { winner[$0] }
            return winners + overriddenLosers
        }

        let mcp = mergeByKey({ $0.mcpServers }, key: { $0.id }, markOverridden: { var x = $0; x.isOverridden = true; return x })
                + visibleContribs.filter { $0.kind == .mcp }.map { pluginMCP($0, plugins) }
        let skills = mergeByKey({ $0.skills }, key: { $0.id }, markOverridden: { var x = $0; x.isOverridden = true; return x })
                + visibleContribs.filter { $0.kind == .skill }.map { pluginSkill($0, plugins) }
        let commands = mergeByKey({ $0.commands }, key: { $0.id }, markOverridden: { var x = $0; x.isOverridden = true; return x })
                + visibleContribs.filter { $0.kind == .command }.map { pluginCommand($0, plugins) }
        let agents = mergeByKey({ $0.agents }, key: { $0.id }, markOverridden: { var x = $0; x.isOverridden = true; return x })
                + visibleContribs.filter { $0.kind == .agent }.map { pluginAgent($0, plugins) }
        let rules = mergeByKey({ $0.rules }, key: { $0.id }, markOverridden: { var x = $0; x.isOverridden = true; return x })
        let hooks = mergeByKey({ $0.hooks }, key: { $0.id }, markOverridden: { var x = $0; x.isOverridden = true; return x })
        let env = mergeByKey({ $0.envVars }, key: { $0.id }, markOverridden: { var x = $0; x.isOverridden = true; return x })

        let settings = mergeSettings(layers)
        let model = resolveModel(global: global, project: project, local: local, projectLocal: projectLocal)
        return Merged(mcp: mcp, skills: skills, commands: commands, agents: agents, rules: rules,
                      hooks: hooks, env: env, settings: settings, model: model)
    }

    /// Is `p` active for `path`? Mirrors PluginsSection.isActive: global installs always apply;
    /// project/local installs apply only when their projectPath matches the active path.
    /// With no active path, only globally-installed plugins are active.
    nonisolated public static func pluginActive(_ p: Plugin, for path: String?) -> Bool {
        let installs = p.allInstalls.isEmpty
            ? [PluginInstall(scope: p.scope, projectPath: p.projectPath, installPath: p.installPath, version: p.version)]
            : p.allInstalls
        return installs.contains { install in
            switch install.scope {
            case .global: return true
            case .project: return path != nil && install.projectPath == path
            case .local: return path != nil && (install.projectPath == path || install.projectPath?.hasPrefix(path!) == true)
            default: return false
            }
        }
    }

    /// Set `skillEnabled` on each non-plugin skill from the effective `skillOverrides`
    /// (project settings win over global). A skill is disabled when its override is
    /// "user-invocable-only" or "off" — i.e. hidden from Claude's auto-invocation.
    nonisolated public static func applySkillOverrides(_ skills: [Skill], project: [String: Any], global: [String: Any]) -> [Skill] {
        let g = global["skillOverrides"] as? [String: String] ?? [:]
        let p = project["skillOverrides"] as? [String: String] ?? [:]
        return skills.map { s in
            guard s.origin.pluginID == nil else { return s }   // plugin skills use enabledPlugins
            let state = p[s.id] ?? g[s.id]
            let enabled = state == nil || state == "on"
            var out = s; out.skillEnabled = enabled; return out
        }
    }

    // plugin contribution → typed item (scope .plugin)
    nonisolated public static func pluginMCP(_ c: PluginContribution, _ ps: [Plugin]) -> MCPServer {
        MCPServer(id: c.name, command: "", args: [], transport: nil, enabled: true,
                  scope: .plugin, sourcePath: c.path, origin: .plugin(id: c.pluginID))
    }
    nonisolated public static func pluginSkill(_ c: PluginContribution, _ ps: [Plugin]) -> Skill {
        let p = Frontmatter.parseWithBody(c.path)
        return Skill(id: c.name, description: p.fields["description"] ?? c.description ?? "",
                     scope: .plugin, sourcePath: c.path, origin: .plugin(id: c.pluginID),
                     meta: p.fields, bodyPreview: p.body)
    }
    nonisolated public static func pluginCommand(_ c: PluginContribution, _ ps: [Plugin]) -> Command {
        let p = Frontmatter.parseWithBody(c.path)
        return Command(id: c.name, description: p.fields["description"] ?? c.description ?? "",
                       scope: .plugin, sourcePath: c.path, origin: .plugin(id: c.pluginID),
                       meta: p.fields, bodyPreview: p.body)
    }
    nonisolated public static func pluginAgent(_ c: PluginContribution, _ ps: [Plugin]) -> Agent {
        let p = Frontmatter.parseWithBody(c.path)
        return Agent(id: c.name, description: p.fields["description"] ?? c.description ?? "",
                     scope: .plugin, sourcePath: c.path, origin: .plugin(id: c.pluginID),
                     meta: p.fields, bodyPreview: p.body)
    }

    nonisolated public static func mergeSettings(_ layers: [LayerResult]) -> [SettingEntry] {
        // flatten top-level keys; last non-nil layer wins, earlier marked overridden
        var winner: [String: SettingEntry] = [:]; var order: [String] = []; var losers: [SettingEntry] = []
        let scopes: [Scope] = [.global, .project, .local, .local]  // matches [global, project, local, projectLocal]
        for (idx, layer) in layers.enumerated() {
            guard let src = layer.settingsSourcePath else { continue }
            let scope = scopes[idx]
            for (k, v) in layer.settings {
                let e = SettingEntry(id: k, valueSummary: summary(v), scope: scope, sourcePath: src)
                if let prev = winner[k] { var l = prev; l.isOverridden = true; losers.append(l) }
                else { order.append(k) }
                winner[k] = e
            }
        }
        return order.compactMap { winner[$0] } + losers
    }

    nonisolated public static func summary(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return "{\(d.count) keys}" }
        if let a = v as? [Any] { return "[\(a.count)]" }
        return "\(v)"
    }

    nonisolated public static func resolveModel(global: LayerResult, project: LayerResult,
                                         local: LayerResult, projectLocal: LayerResult) -> ModelConfig? {
        let layers = [projectLocal, local, project, global] // high→low
        let scopes: [Scope] = [.local, .local, .project, .global]
        for (idx, l) in layers.enumerated() {
            let env = l.settings["env"] as? [String: Any]
            // "model" key wins; else fall back to ANTHROPIC_MODEL env in the same layer
            let m = (l.settings["model"] as? String) ?? (env?["ANTHROPIC_MODEL"] as? String)
            if let m, let src = l.settingsSourcePath {
                return ModelConfig(effectiveModel: m, sourcePath: src, scope: scopes[idx],
                                   haiku: env?["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String,
                                   sonnet: env?["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String,
                                   opus: env?["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String,
                                   baseURL: env?["ANTHROPIC_BASE_URL"] as? String)
            }
        }
        return nil
    }
}
