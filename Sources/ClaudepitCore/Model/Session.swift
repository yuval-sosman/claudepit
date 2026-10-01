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
    /// When the call was made and when its result came back (epoch seconds, from the records).
    public var startedAt: TimeInterval?
    public var finishedAt: TimeInterval?
    /// The CLI's structured result (`toolUseResult`): Bash stdout/stderr, an edit's real patch
    /// hunks, a Read's line range, an agent's launch record. Raw, read through the accessors below.
    public var detail: [String: Any]?
    /// Images the tool returned (a Read of a PNG, a screenshot tool).
    public var resultImages: [TranscriptImage] = []
    /// Text the CLI injected into the conversation on this call's behalf — a skill's SKILL.md body,
    /// a slash command's expansion — recorded as a meta user message pointing back at the call.
    public var injectedContent: String?
    /// Completion report of a call that ran in the background (an async Agent, a
    /// `run_in_background` Bash), delivered later as a task notification.
    public var completion: TaskNotification?

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

    /// Wall time from call to result, when both ends were recorded. A call that ran in the
    /// background runs until its completion report, not until the "launched" result.
    public var duration: TimeInterval? {
        guard let s = startedAt else { return nil }
        if let done = completion?.time, done >= s { return done - s }
        guard let f = finishedAt, f >= s else { return nil }
        return f - s
    }

    /// Still waiting on a result (the call is live, or the session ended mid-call).
    public var isPending: Bool { resultText == nil && completion == nil }

    /// A failure by any account: the result says so, or a background run reported one.
    public var failed: Bool {
        if isError == true { return true }
        if let c = completion?.status.lowercased(), c == "failed" || c == "error" || c == "killed" { return true }
        return false
    }

    /// True for the calls that change files — the ones a reader most needs to see.
    public var isFileChange: Bool {
        ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name)
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

/// An image carried in a transcript record (base64 in the JSONL).
public struct TranscriptImage {
    public let data: Data
    public let mediaType: String
    public init(data: Data, mediaType: String) { self.data = data; self.mediaType = mediaType }
}

/// A `<task-notification>` — how the CLI tells Claude a background task finished: an async
/// subagent, a `run_in_background` Bash, a Monitor event. `toolUseID` names the call that
/// launched it, which is how the transcript view reattaches the result to that call.
public struct TaskNotification: Equatable {
    public var taskID: String
    public var toolUseID: String?
    public var status: String
    public var summary: String
    public var result: String?
    public var outputFile: String?
    public var time: TimeInterval?

    public init(taskID: String, toolUseID: String?, status: String, summary: String,
                result: String?, outputFile: String?, time: TimeInterval? = nil) {
        self.taskID = taskID; self.toolUseID = toolUseID; self.status = status
        self.summary = summary; self.result = result; self.outputFile = outputFile; self.time = time
    }

    /// Parse the XML-ish envelope. nil when the text isn't a task notification.
    public static func parse(_ text: String) -> TaskNotification? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<task-notification>") else { return nil }
        // The envelope is XML, so its bodies arrive escaped (`-&gt;`, `&amp;&amp;`).
        func tag(_ name: String) -> String? {
            guard let a = t.range(of: "<\(name)>"),
                  let b = t.range(of: "</\(name)>", range: a.upperBound..<t.endIndex) else { return nil }
            return xmlUnescape(String(t[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return TaskNotification(
            taskID: tag("task-id") ?? "", toolUseID: tag("tool-use-id"),
            status: tag("status") ?? "", summary: tag("summary") ?? tag("event") ?? "",
            result: tag("result"), outputFile: tag("output-file"))
    }
}

/// `&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;` → the characters.
public func xmlUnescape(_ s: String) -> String {
    guard s.contains("&") else { return s }
    return s.replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// Terminal colour and style codes (`ESC[1m`, `ESC[22m`) removed — the CLI keeps them in
/// command output it recorded from the terminal.
public func stripANSI(_ s: String) -> String {
    guard s.contains("\u{1B}") else { return s }
    return s.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{1B}", with: "")
}

public struct HookExecution: Identifiable {
    /// How the CLI recorded the run (`hook_success`, `hook_non_blocking_error`, …, minus `hook_`).
    public enum Outcome: String, Equatable {
        case success, additionalContext, systemMessage, cancelled, nonBlockingError, blockingError, other
    }
    public let id: String
    public let hookName: String       // e.g. "SessionStart:clear"
    public let hookEvent: String      // e.g. "SessionStart"
    public var command: String?       // nil for hook_additional_context
    public var stdout: String?
    public var stderr: String?
    public var content: String?       // injected context / message body
    public var exitCode: Int?
    public var durationMs: Int?
    public var time: TimeInterval?
    public var outcome: Outcome = .success
    /// Set by a Stop hook that kept Claude going (`preventedContinuation` in its summary).
    public var preventedContinuation = false
    public var isError: Bool {
        outcome == .nonBlockingError || outcome == .blockingError
            || (exitCode ?? 0) != 0 || (stderr?.isEmpty == false)
    }

    public init(id: String, hookName: String, hookEvent: String, command: String?,
                stdout: String?, stderr: String?, content: String?,
                exitCode: Int?, durationMs: Int?) {
        self.id = id; self.hookName = hookName; self.hookEvent = hookEvent
        self.command = command; self.stdout = stdout; self.stderr = stderr
        self.content = content; self.exitCode = exitCode; self.durationMs = durationMs
    }

    /// The script a command runs, for a one-line label: `bash '/x/claudepit-memory-hook.sh' Stop`
    /// → `claudepit-memory-hook.sh`. Falls back to the command's first word.
    public var scriptName: String? {
        guard let command, !command.isEmpty else { return nil }
        let words = command.split(whereSeparator: { $0 == " " }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        if let path = words.first(where: { $0.contains("/") && !$0.hasPrefix("-") }),
           !["bash", "sh", "zsh", "python3", "node"].contains(path) {
            return (path as NSString).lastPathComponent
        }
        return words.first
    }
}

public struct TurnUsage: Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let model: String
    public var time: TimeInterval?
    /// The reasoning effort the call ran at (`xhigh`, `max`…), when the CLI recorded one.
    public var effort: String?
    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheWriteTokens: Int, model: String, time: TimeInterval? = nil, effort: String? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
        self.model = model; self.time = time; self.effort = effort
    }

    /// Everything the model read on this call: fresh input plus both cache sides.
    public var contextTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
}

public enum UserContentBlock {
    case text(String)
    case image(Data, mediaType: String)
    case imageFile(URL)
    case document(Data, mediaType: String, name: String?)
}

/// A user-role record that isn't a tool result — which is far more than what the person typed.
public struct UserMessage {
    public enum Kind: Equatable {
        /// Typed by the person (or sent as a prompt by an SDK / herdr).
        case prompt
        /// A slash command invocation (`<command-name>/model</command-name>…`).
        case command
        /// What a local command printed (`<local-command-stdout>`), kept as context.
        case commandOutput
        /// Text the model sees that nobody typed: an expanded command body, a system reminder.
        case meta
        /// A background task or async agent reporting back.
        case taskNotification
        /// Another agent's message — a subagent handing back its report.
        case peer
        /// The summary a compacted conversation continues from.
        case compactSummary
    }
    public var kind: Kind
    public var blocks: [UserContentBlock]
    public var time: TimeInterval?
    /// `.command`: the command name (`/model`) and its arguments.
    public var commandName: String?
    public var commandArgs: String?
    /// `.taskNotification`: the parsed envelope.
    public var notification: TaskNotification?
    /// `.peer`: the sender's id.
    public var sender: String?
    /// `.command`: what the command printed (`/model` → "Set model to …").
    public var commandOutput: String?
    /// `.command`: the prompt the command expanded into — what Claude actually received.
    public var expansion: String?
    /// Delivered mid-turn (typed or reported while Claude was working), so it opens no turn.
    public var isQueued = false
    /// Who the CLI says sent it (`human`, `coordinator`, `peer`, `task-notification`…), if recorded.
    public var originKind: String?
    /// The record's place in the conversation tree. Two prompts with one parent are a rewind:
    /// the person went back and sent the message again, and only the later branch continued.
    public var uuid: String?
    public var parentUUID: String?

    public init(kind: Kind = .prompt, blocks: [UserContentBlock], time: TimeInterval? = nil) {
        self.kind = kind; self.blocks = blocks; self.time = time
    }

    /// The text blocks joined — what a search or a copy should see.
    public var text: String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
    }

    /// Kinds that hand Claude something to act on, and so open a new turn.
    public var startsTurn: Bool {
        if isQueued { return false }
        switch kind {
        case .prompt, .command, .taskNotification, .peer: return true
        case .commandOutput, .meta, .compactSummary: return false
        }
    }
}

public struct AssistantText {
    public var text: String
    public var time: TimeInterval?
    public var model: String?
    public init(text: String, time: TimeInterval? = nil, model: String? = nil) {
        self.text = text; self.time = time; self.model = model
    }
}

/// A thinking block. Current models sign their thinking and the CLI records it empty — the
/// block still marks *that* Claude reasoned there, just not what it thought.
public struct ThinkingBlock {
    public var text: String
    public var time: TimeInterval?
    public init(text: String, time: TimeInterval? = nil) { self.text = text; self.time = time }
    public var isRedacted: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Something the CLI put into the model's context that no one typed: CLAUDE.md and memory
/// files, the environment block, the git status, skill and agent listings, plan-mode rules.
public struct ContextItem {
    /// One titled body inside an item — a single file of an `instructions` attachment, say.
    public struct Section {
        public var title: String
        public var subtitle: String?
        public var body: String
        public var path: String?
        public init(title: String, subtitle: String? = nil, body: String, path: String? = nil) {
            self.title = title; self.subtitle = subtitle; self.body = body; self.path = path
        }
    }
    /// The attachment's type as recorded (`instructions`, `environment`, …).
    public var type: String
    public var time: TimeInterval?
    public var title: String
    /// One line for the collapsed row.
    public var summary: String
    public var sections: [Section]
    /// The exact text the model received, when the CLI recorded it.
    public var rendered: String?
    /// The role it arrived under (`user` / `system`).
    public var role: String?
    /// The file the item is about, when it names one — a plan-mode item's plan file.
    public var path: String?

    public init(type: String, time: TimeInterval? = nil, title: String, summary: String,
                sections: [Section] = [], rendered: String? = nil, role: String? = nil,
                path: String? = nil) {
        self.type = type; self.time = time; self.title = title; self.summary = summary
        self.sections = sections; self.rendered = rendered; self.role = role; self.path = path
    }
}

/// The system prompt and tool list the CLI sent (its `prompt_snapshot`).
public struct SystemPromptSnapshot {
    public struct Tool {
        public var name: String
        public var description: String
        public init(name: String, description: String) { self.name = name; self.description = description }
    }
    public var time: TimeInterval?
    /// The prompt's sections in order; the CLI's cache-boundary marker is dropped.
    public var parts: [String]
    public var tools: [Tool]
    public var cliPrefix: String?
    public init(time: TimeInterval? = nil, parts: [String], tools: [Tool], cliPrefix: String? = nil) {
        self.time = time; self.parts = parts; self.tools = tools; self.cliPrefix = cliPrefix
    }
    public var characterCount: Int { parts.reduce(0) { $0 + $1.count } }
}

/// A system event worth a line of its own: a turn ending, a compaction, an API error.
public struct TranscriptNotice {
    public enum Kind: Equatable {
        case turnEnd, compaction, awaySummary, apiError, informational, interrupted
        case modeChange, scheduledWakeup, localCommand, other
    }
    public var kind: Kind
    public var time: TimeInterval?
    public var title: String
    public var detail: String?
    /// The CLI's level for it (`info`, `warning`, `error`, `suggestion`).
    public var level: String?
    public var durationMs: Int?
    /// `.turnEnd`: messages in the turn. `.compaction`: context before and after.
    public var messageCount: Int?
    public var preTokens: Int?
    public var postTokens: Int?

    public init(kind: Kind, time: TimeInterval? = nil, title: String, detail: String? = nil,
                level: String? = nil) {
        self.kind = kind; self.time = time; self.title = title; self.detail = detail; self.level = level
    }

    public var isError: Bool { kind == .apiError || level == "error" }
}

public enum SessionEvent: @unchecked Sendable {
    case userMessage(UserMessage)
    case assistantText(AssistantText)
    case thinking(ThinkingBlock)
    case tool(ToolInvocation)
    case hook(HookExecution)
    case context(ContextItem)
    case systemPrompt(SystemPromptSnapshot)
    case notice(TranscriptNotice)
    case attachment(Attachment)
    case turnUsage(TurnUsage)
}

/// Any attachment type the transcript view has no dedicated rendering for: the raw fields.
public struct Attachment: Identifiable {
    public let id: String
    public let type: String              // inner attachment type, e.g. "diagnostics"
    public let fields: [String: Any]     // everything except "type"
    public var time: TimeInterval?
    public init(id: String, type: String, fields: [String: Any], time: TimeInterval? = nil) {
        self.id = id; self.type = type; self.fields = fields; self.time = time
    }
}

/// Session-wide facts the records carry on every line: where it ran, on what, and in which modes.
public struct TranscriptMetadata: Equatable, Sendable {
    public var cwd: String?
    public var gitBranch: String?
    public var version: String?
    public var aiTitle: String?
    public var agentName: String?
    public var permissionMode: String?
    /// A subagent's transcript: its "user" messages come from the session that spawned it.
    public var isSidechain = false
    public var prLinks: [String] = []
    public var firstTime: TimeInterval?
    public var lastTime: TimeInterval?
    public init() {}
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
    /// Refreshed in place between rescans (`AppState.refreshSessionLiveness`), hence `var`.
    public var modifiedAt: Date
    public let turnCount: Int
    public var isActive: Bool
    public let subagents: [SubagentSummary]
    public var groupID: String?
    public var bulletSummary: SessionBulletSummary?
    /// The transcript's size on disk — an honest measure of how much happened in it.
    public var fileSize: Int = 0
    /// The working directory the session ran in, as its first user record states it.
    public var cwd: String?
    /// The Claudepit task phase this session ran, when it was one.
    public var task: SessionTaskRef?
    /// The group file this session's group lives in (`GroupStore` key): the open project's, or —
    /// across all projects — the project that owns the session's checkout.
    public var groupKey: String = ""

    public init(id: String, fileURL: URL, projectSlug: String, title: String,
                modifiedAt: Date, turnCount: Int, isActive: Bool,
                subagents: [SubagentSummary] = [], groupID: String? = nil,
                bulletSummary: SessionBulletSummary? = nil) {
        self.id = id; self.fileURL = fileURL; self.projectSlug = projectSlug
        self.title = title; self.modifiedAt = modifiedAt
        self.turnCount = turnCount; self.isActive = isActive
        self.subagents = subagents; self.groupID = groupID
        self.bulletSummary = bulletSummary
        self.groupKey = projectSlug
    }

    /// The session ran in a worktree checkout (`<project>/.claude/worktrees/<name>`).
    public var worktreeName: String? {
        guard let cwd, let r = cwd.range(of: "/.claude/worktrees/") else { return nil }
        return cwd[r.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// The project's folder name, for rows listed across all projects.
    public var projectName: String {
        if let cwd { return URL(filePath: ProjectFolders.ownerPath(ofCwd: cwd)).lastPathComponent }
        return ProjectFolders.ownerSlug(ofFolder: projectSlug)
    }
}
