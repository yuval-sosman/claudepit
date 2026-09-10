import Foundation

public struct MCPServer: ConfigItem, Sendable {
    public let id: String            // server name
    public let command: String       // binary path for stdio, URL for http
    public let args: [String]
    public let transport: String?    // "stdio", "http", "sse", nil
    public let headers: [String: String]  // HTTP auth headers (from ~/.claude.json)
    public let enabled: Bool
    public let scope: Scope
    public let sourcePath: URL
    public let origin: Origin
    public var isOverridden: Bool
    public var displayName: String { id }

    public init(id: String, command: String, args: [String], transport: String?, headers: [String: String] = [:], enabled: Bool, scope: Scope, sourcePath: URL, origin: Origin, isOverridden: Bool = false) {
        self.id = id
        self.command = command
        self.args = args
        self.transport = transport
        self.headers = headers
        self.enabled = enabled
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
    }
}

public struct Skill: ConfigItem {
    public let id: String            // skill name
    public let description: String
    public let scope: Scope
    public let sourcePath: URL       // SKILL.md
    public let origin: Origin
    public var isOverridden: Bool
    public var meta: [String: String] = [:]   // all frontmatter keys
    public var bodyPreview: String = ""        // markdown after frontmatter, capped
    public var skillEnabled: Bool = true       // false when skillOverrides hides it from Claude
    public var displayName: String { id }

    public init(id: String, description: String, scope: Scope, sourcePath: URL, origin: Origin, isOverridden: Bool = false, meta: [String: String] = [:], bodyPreview: String = "", skillEnabled: Bool = true) {
        self.id = id
        self.description = description
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
        self.meta = meta
        self.bodyPreview = bodyPreview
        self.skillEnabled = skillEnabled
    }
}

public struct Command: ConfigItem {
    public let id: String            // command name (file stem)
    public let description: String
    public let scope: Scope
    public let sourcePath: URL       // .md file
    public let origin: Origin
    public var isOverridden: Bool
    public var meta: [String: String] = [:]   // all frontmatter keys
    public var bodyPreview: String = ""        // markdown after frontmatter, capped
    public var displayName: String { id }

    public init(id: String, description: String, scope: Scope, sourcePath: URL, origin: Origin, isOverridden: Bool = false, meta: [String: String] = [:], bodyPreview: String = "") {
        self.id = id
        self.description = description
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
        self.meta = meta
        self.bodyPreview = bodyPreview
    }
}

public struct Agent: ConfigItem {
    public let id: String
    public let description: String
    public let scope: Scope
    public let sourcePath: URL
    public let origin: Origin
    public var isOverridden: Bool
    public var meta: [String: String] = [:]   // all frontmatter keys
    public var bodyPreview: String = ""        // markdown after frontmatter, capped
    public var displayName: String { id }

    public init(id: String, description: String, scope: Scope, sourcePath: URL, origin: Origin, isOverridden: Bool = false, meta: [String: String] = [:], bodyPreview: String = "") {
        self.id = id
        self.description = description
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
        self.meta = meta
        self.bodyPreview = bodyPreview
    }
}

public struct Rule: ConfigItem {
    public let id: String            // file stem (e.g. "no-todos")
    public let scope: Scope
    public let sourcePath: URL       // the .md file
    public let origin: Origin
    public var isOverridden: Bool
    public var meta: [String: String] = [:]
    public var bodyPreview: String = ""
    public var paths: [String] = []  // parsed from frontmatter "paths:" YAML list
    public var displayName: String { id }

    public init(id: String, scope: Scope, sourcePath: URL, origin: Origin,
                isOverridden: Bool = false, meta: [String: String] = [:],
                bodyPreview: String = "", paths: [String] = []) {
        self.id = id
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
        self.meta = meta
        self.bodyPreview = bodyPreview
        self.paths = paths
    }
}

public struct Hook: ConfigItem {
    public let id: String            // "<event>:<index>"
    public let event: String         // e.g. SessionStart, PreToolUse
    public let matcher: String?
    public let command: String
    public let scope: Scope
    public let sourcePath: URL       // settings file it came from
    public let origin: Origin
    public var isOverridden: Bool
    public var displayName: String { event }

    public init(id: String, event: String, matcher: String?, command: String, scope: Scope, sourcePath: URL, origin: Origin, isOverridden: Bool = false) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.command = command
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
    }
}

public struct Plugin: ConfigItem {
    public let id: String            // "<name>@<marketplace>"
    public let name: String
    public let marketplace: String
    public let version: String
    public let enabled: Bool
    public let installPath: URL
    public let scope: Scope          // .plugin always
    public let sourcePath: URL       // plugin.json
    public let origin: Origin        // .plugin(id:)
    public var isOverridden: Bool
    public var displayName: String { name }
    // contribution counts, filled by scanner
    public var skillCount: Int
    public var commandCount: Int
    public var agentCount: Int
    public var mcpCount: Int
    public var hookCount: Int
    public var description: String?
    public var marketplaceURL: String?
    public var contributions: [PluginContribution]
    public var latestCachedVersion: String?
    public var marketplaceSource: String?
    public var projectPath: String?
    public var allInstalls: [PluginInstall]   // remote URL or local directory path
    public var globalEnabled: Bool?   // nil = no explicit entry in global settings
    public var projectEnabled: Bool?  // nil = no explicit entry in project settings
    public var updateAvailable: Bool {
        guard let latest = latestCachedVersion, version != "unknown" else { return false }
        return latest != version
    }

    public init(id: String, name: String, marketplace: String, version: String, enabled: Bool, installPath: URL, scope: Scope, sourcePath: URL, origin: Origin, isOverridden: Bool = false, skillCount: Int = 0, commandCount: Int = 0, agentCount: Int = 0, mcpCount: Int = 0, hookCount: Int = 0, description: String? = nil, marketplaceURL: String? = nil, contributions: [PluginContribution] = [], latestCachedVersion: String? = nil, marketplaceSource: String? = nil, projectPath: String? = nil, allInstalls: [PluginInstall] = []) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.enabled = enabled
        self.installPath = installPath
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
        self.skillCount = skillCount
        self.commandCount = commandCount
        self.agentCount = agentCount
        self.mcpCount = mcpCount
        self.hookCount = hookCount
        self.description = description
        self.marketplaceURL = marketplaceURL
        self.contributions = contributions
        self.latestCachedVersion = latestCachedVersion
        self.marketplaceSource = marketplaceSource
        self.projectPath = projectPath
        self.allInstalls = allInstalls
    }
}

/// One resolved key from settings.json across layers.
public struct SettingEntry: ConfigItem {
    public let id: String            // dotted key path e.g. "permissions.allow"
    public let valueSummary: String  // human string of the effective value
    public let scope: Scope          // winning layer
    public let sourcePath: URL
    public let origin: Origin
    public var isOverridden: Bool   // true if this key also set in a lower layer
    public var displayName: String { id }

    public init(id: String, valueSummary: String, scope: Scope, sourcePath: URL, origin: Origin = .user, isOverridden: Bool = false) {
        self.id = id
        self.valueSummary = valueSummary
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
    }
}

public struct EnvVar: ConfigItem {
    public let id: String            // var name
    public let rawValue: String
    public let scope: Scope
    public let sourcePath: URL
    public let origin: Origin
    public var isOverridden: Bool
    public var displayName: String { id }
    /// Masked if the name looks secret.
    public var displayValue: String {
        let upper = id.uppercased()
        let secret = ["TOKEN", "KEY", "SECRET", "PASSWORD"].contains { upper.contains($0) }
        guard secret, rawValue.count > 4 else { return rawValue }
        return "••••" + rawValue.suffix(4)
    }

    public init(id: String, rawValue: String, scope: Scope, sourcePath: URL, origin: Origin = .user, isOverridden: Bool = false) {
        self.id = id
        self.rawValue = rawValue
        self.scope = scope
        self.sourcePath = sourcePath
        self.origin = origin
        self.isOverridden = isOverridden
    }
}

public struct ModelConfig {
    public let effectiveModel: String        // resolved "model" or ANTHROPIC_MODEL
    public let sourcePath: URL
    public let scope: Scope
    public let haiku: String?
    public let sonnet: String?
    public let opus: String?   // ANTHROPIC_DEFAULT_*_MODEL
    public let baseURL: String?

    public init(effectiveModel: String, sourcePath: URL, scope: Scope, haiku: String?, sonnet: String?, opus: String?, baseURL: String?) {
        self.effectiveModel = effectiveModel
        self.sourcePath = sourcePath
        self.scope = scope
        self.haiku = haiku
        self.sonnet = sonnet
        self.opus = opus
        self.baseURL = baseURL
    }
}
