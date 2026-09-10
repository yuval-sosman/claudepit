import Foundation

public enum ToolClass: Equatable {
    case builtin
    case mcp(server: String, tool: String)
    case agent(type: String)
    case skill(name: String)
}

public struct ToolInvocation: Identifiable {
    public let id: String
    public let name: String
    public let toolClass: ToolClass
    public let argSummary: String
    public let input: [String: Any]
    public var resultText: String?
    public var isError: Bool?

    public init(id: String, name: String, toolClass: ToolClass, argSummary: String,
                input: [String: Any], resultText: String?, isError: Bool?) {
        self.id = id; self.name = name; self.toolClass = toolClass
        self.argSummary = argSummary; self.input = input
        self.resultText = resultText; self.isError = isError
    }

    public var displayName: String {
        switch toolClass {
        case .builtin:                    return name
        case .mcp(let s, let t):          return "mcp__\(s) (\(t))"
        case .agent(let type):            return "Agent → \(type)"
        case .skill(let n):               return "Skill: \(n)"
        }
    }

    /// Label used for the counts tally (coarser than displayName — groups an MCP server's tools).
    public var countLabel: String {
        switch toolClass {
        case .builtin:            return name
        case .mcp(let s, _):      return "mcp__\(s)"
        case .agent(let type):    return "Agent → \(type)"
        case .skill:              return "Skill"
        }
    }

    public static func classify(name: String, input: [String: Any]) -> (ToolClass, String) {
        func str(_ k: String) -> String? { input[k] as? String }
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst("mcp__".count).split(separator: "__", maxSplits: 1)
            let server = parts.first.map(String.init) ?? name
            let tool = parts.count > 1 ? String(parts[1]) : ""
            return (.mcp(server: server, tool: tool), firstStringValue(input))
        }
        if name == "Agent" || name == "Task" {
            let type = str("subagent_type") ?? "?"
            return (.agent(type: type), str("description") ?? str("prompt") ?? "")
        }
        if name == "Skill" {
            let n = str("skill") ?? "?"
            return (.skill(name: n), n)
        }
        // built-in: pick the most useful arg
        let summary = str("command") ?? str("file_path") ?? str("pattern")
            ?? str("query") ?? str("description") ?? firstStringValue(input)
        return (.builtin, summary)
    }

    private static func firstStringValue(_ input: [String: Any]) -> String {
        for k in input.keys.sorted() { if let v = input[k] as? String { return v } }
        return ""
    }

    public static func counts(_ invocations: [ToolInvocation]) -> [(label: String, count: Int)] {
        var tally: [String: Int] = [:]
        for inv in invocations { tally[inv.countLabel, default: 0] += 1 }
        return tally.map { (label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}

public struct HookExecution: Identifiable {
    public let id: String
    public let hookName: String       // e.g. "SessionStart:clear"
    public let hookEvent: String      // e.g. "SessionStart"
    public let command: String?       // nil for hook_additional_context
    public let stdout: String?
    public let stderr: String?
    public let content: String?       // injected context / message body
    public let exitCode: Int?
    public let durationMs: Int?
    public var isError: Bool { (exitCode ?? 0) != 0 || (stderr?.isEmpty == false) }

    public init(id: String, hookName: String, hookEvent: String, command: String?,
                stdout: String?, stderr: String?, content: String?,
                exitCode: Int?, durationMs: Int?) {
        self.id = id; self.hookName = hookName; self.hookEvent = hookEvent
        self.command = command; self.stdout = stdout; self.stderr = stderr
        self.content = content; self.exitCode = exitCode; self.durationMs = durationMs
    }
}

public struct TurnUsage: Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let model: String
    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheWriteTokens: Int, model: String) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
        self.model = model
    }
}

public enum UserContentBlock {
    case text(String)
    case image(Data, mediaType: String)
    case imageFile(URL)
    case document(Data, mediaType: String, name: String?)
}

public enum SessionEvent: @unchecked Sendable {
    case userMessage([UserContentBlock])
    case assistantText(String)
    case tool(ToolInvocation)
    case systemNote(String)
    case hook(HookExecution)
    case attachment(Attachment)
    case turnUsage(TurnUsage)
}

/// Any non-hook attachment: the raw fields, rendered generically as pretty JSON.
public struct Attachment: Identifiable {
    public let id: String
    public let type: String              // inner attachment type, e.g. "diagnostics"
    public let fields: [String: Any]     // everything except "type"
    public init(id: String, type: String, fields: [String: Any]) {
        self.id = id; self.type = type; self.fields = fields
    }
}

public struct SubagentSummary: Identifiable {
    public let id: String           // agentId (e.g. "a28481c977d3f8aed")
    public let toolUseId: String    // matches tool_use.id in parent JSONL
    public let agentType: String    // e.g. "Explore", "general-purpose"
    public let description: String
    public let spawnDepth: Int
    public let fileURL: URL

    public init(id: String, toolUseId: String, agentType: String, description: String,
                spawnDepth: Int, fileURL: URL) {
        self.id = id; self.toolUseId = toolUseId; self.agentType = agentType
        self.description = description; self.spawnDepth = spawnDepth; self.fileURL = fileURL
    }
}

public struct SessionSummary: Identifiable {
    public let id: String            // session uuid (file stem)
    public let fileURL: URL
    public let projectSlug: String
    public let title: String
    public let modifiedAt: Date
    public let turnCount: Int
    public var isActive: Bool
    public let subagents: [SubagentSummary]
    public var groupID: String?
    public var bulletSummary: SessionBulletSummary?

    public init(id: String, fileURL: URL, projectSlug: String, title: String,
                modifiedAt: Date, turnCount: Int, isActive: Bool,
                subagents: [SubagentSummary] = [], groupID: String? = nil,
                bulletSummary: SessionBulletSummary? = nil) {
        self.id = id; self.fileURL = fileURL; self.projectSlug = projectSlug
        self.title = title; self.modifiedAt = modifiedAt
        self.turnCount = turnCount; self.isActive = isActive
        self.subagents = subagents; self.groupID = groupID
        self.bulletSummary = bulletSummary
    }
}
