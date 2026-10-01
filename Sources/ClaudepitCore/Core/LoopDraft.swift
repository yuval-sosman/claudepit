import Foundation

/// The New Loop dialog's choices and everything they imply — the exact text Claude will receive,
/// the schedule it becomes, when it fires, how long it lives, and every caveat the docs attach to
/// that combination. Computed here, not in the view, so what the dialog promises is tested.
public struct LoopDraft: Equatable, Sendable {
    public enum Cadence: Equatable, Sendable {
        /// `/loop <interval> …` — a fixed cron step.
        case interval(LoopInterval)
        /// `/loop …` without an interval: Claude picks each delay, 1 minute to 1 hour.
        case selfPaced
        /// Any cron expression. `/loop` only takes intervals, so this is asked for in words.
        case cron(String)
        /// One fire at a time, then gone.
        case once(Date)
    }

    public enum Task: Equatable, Sendable {
        case prompt(String)
        /// A slash command or skill, re-run each time.
        case command(name: String, args: String)
        /// Each fire hands the work to a subagent (an agent file), named in words — the form a
        /// real run delegated with on every fire (`AgentDelegation`). With `skipWhileRunning`, a
        /// fire whose previous run hasn't reported back starts no second one.
        case agent(name: String, task: String, skipWhileRunning: Bool)
        /// No prompt: `loop.md` when there is one, else the built-in maintenance prompt.
        case defaultPrompt
    }

    public enum Destination: Equatable, Sendable {
        /// A new Claude Code session in a herdr tab — the loop lives as long as it does.
        case newSession
        /// A Claude session already open in herdr (`target` is its pane).
        case existingSession(target: String, title: String)
        /// A Claude Code background session (`claude --bg`): no terminal, hosted by the CLI's
        /// supervisor — it keeps running after the terminal or this app closes and across sleep,
        /// and stops at shutdown. `claude agents` lists it; `claude attach <id>` opens it.
        case background
        /// Copy the text, to paste into any session.
        case copy
        /// `.claude/scheduled_tasks.json`.
        case durableFile
        /// A cloud routine, set up conversationally with `/schedule`.
        case cloud
    }

    public var cadence: Cadence = .interval(LoopInterval(10, .m))
    public var task: Task = .prompt("")
    public var destination: Destination = .newSession
    /// New session: `--permission-mode`. nil leaves the user's default.
    public var permissionMode: String? = "auto"
    /// New session: `--model` (an alias like `sonnet`). nil leaves the default.
    public var model: String?
    /// New session: `-n`. Empty picks one from the task.
    public var sessionName = ""
    /// New session: `--agent` — the whole session runs as this agent (its prompt, tools, model).
    public var sessionAgent: String?

    public init() {}

    /// The `--permission-mode` values, labelled — `manual` is the classic ask-for-everything.
    public static let permissionModes: [(id: String, label: String)] = [
        ("auto", "Auto"), ("acceptEdits", "Accept edits"), ("manual", "Ask every time"),
        ("dontAsk", "Don't ask (deny)"), ("bypassPermissions", "Bypass permissions"),
    ]
    public static let models: [(id: String?, label: String)] = [
        (nil, "Default model"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("fable", "Fable"), ("haiku", "Haiku"),
    ]

    /// What the task says, as it follows `/loop <interval>`. Empty for the default prompt.
    public var taskText: String {
        switch task {
        case .prompt(let p): return p.trimmingCharacters(in: .whitespacesAndNewlines)
        case .command(let name, let args):
            let n = name.trimmingCharacters(in: .whitespaces)
            let slash = n.isEmpty || n.hasPrefix("/") ? n : "/" + n
            let a = args.trimmingCharacters(in: .whitespacesAndNewlines)
            return a.isEmpty ? slash : "\(slash) \(a)"
        case .agent(let name, let task, let skip):
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            return AgentDelegation.sentence(agent: n, task: task, skipWhileRunning: skip)
        case .defaultPrompt: return ""
        }
    }

    /// The cron a fixed cadence becomes — the `/loop` table for an interval, the expression
    /// itself, or the pinned minute of a one-time fire.
    public func cron(calendar: Calendar = .cron) -> String? {
        switch cadence {
        case .interval(let i): return i.cron
        case .selfPaced: return nil
        case .cron(let c): return c.trimmingCharacters(in: .whitespaces)
        case .once(let d): return Self.pinnedCron(d, calendar: calendar)
        }
    }

    /// `M H D Mo *` — how a one-time fire is written (the CronCreate tool's own instructions).
    public static func pinnedCron(_ date: Date, calendar: Calendar = .cron) -> String {
        let c = calendar.dateComponents([.minute, .hour, .day, .month], from: date)
        return "\(c.minute ?? 0) \(c.hour ?? 0) \(c.day ?? 1) \(c.month ?? 1) *"
    }

    /// The message sent to Claude — exactly what the dialog shows. nil when there is nothing to
    /// send yet. `/loop` where it applies; for a cron schedule or a one-time fire, a precise
    /// request for the CronCreate call (`/loop` takes no cron), as the docs' "ask Claude directly".
    public func message(calendar: Calendar = .cron) -> String? {
        let text = taskText
        if case .agent = task, text.isEmpty { return nil }
        if destination == .cloud { return cloudMessage(calendar: calendar) }
        switch cadence {
        case .interval(let i):
            return text.isEmpty ? "/loop \(i.normalized.token)" : "/loop \(i.normalized.token) \(text)"
        case .selfPaced:
            return text.isEmpty ? "/loop" : "/loop \(text)"
        case .cron(let c):
            guard !text.isEmpty, CronExpression(c) != nil else { return nil }
            let cron = c.trimmingCharacters(in: .whitespaces)
            return "Use CronCreate to schedule a recurring task: cron \"\(cron)\" (\(CronExpression.humanize(cron)), "
                + "local time), recurring: true, with exactly this prompt: \(Self.quoted(text)). "
                + "Just schedule it — don't run it now — and tell me the job ID."
        case .once(let d):
            guard !text.isEmpty else { return nil }
            let cron = Self.pinnedCron(d, calendar: calendar)
            return "Use CronCreate to schedule a one-time task: cron \"\(cron)\" "
                + "(\(LoopCadence.describe(cron: cron, recurring: false).lowercased()), local time), recurring: false, "
                + "with exactly this prompt: \(Self.quoted(text)). Just schedule it — don't run it now — and tell me the job ID."
        }
    }

    /// `/schedule <when>: <what>` — the conversational way to make a cloud routine.
    func cloudMessage(calendar: Calendar) -> String? {
        let text = taskText
        guard !text.isEmpty else { return nil }
        let when: String
        switch cadence {
        case .interval(let i): when = "every \(i.normalized.spoken)"
        case .selfPaced: return nil
        case .cron(let c):
            guard CronExpression(c) != nil else { return nil }
            let human = CronExpression.humanize(c)
            when = human == c ? "on the cron schedule \(c)" : human.prefix(1).lowercased() + human.dropFirst()
        case .once(let d):
            when = LoopCadence.describe(cron: Self.pinnedCron(d, calendar: calendar), recurring: false).lowercased()
        }
        return "/schedule \(when): \(text)"
    }

    /// A JSON string literal — unambiguous however the prompt is quoted or broken across lines.
    static func quoted(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else { return "\"\(s)\"" }
        return String(array.dropFirst().dropLast())
    }

    /// The session name a new session gets: the one typed, else "loop: <task>".
    public var effectiveSessionName: String {
        let typed = sessionName.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let title: String
        switch task {
        case .defaultPrompt: title = "maintenance"
        case .agent(let name, let task, _):
            let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
            title = "\(name): \(line.trimmingCharacters(in: .whitespaces))"
        default: title = LoopPromptKind(prompt: taskText).title
        }
        let short = title.count > 40 ? String(title.prefix(39)) + "…" : title
        return "loop: \(short)"
    }

    /// The `claude` arguments for a new session, its id fixed in advance so the app finds its
    /// transcript (and so its loop) without guessing.
    public func claudeArguments(sessionID: String) -> [String] {
        var args = ["--session-id", sessionID, "-n", effectiveSessionName]
        if let mode = permissionMode { args += ["--permission-mode", mode] }
        if let model { args += ["--model", model] }
        if let agent = sessionAgent?.trimmingCharacters(in: .whitespaces), !agent.isEmpty { args += ["--agent", agent] }
        return args
    }

    /// The `claude` arguments that start the loop in a background session. `--bg` picks its own
    /// session id (it ignores `--session-id`, with a warning) and prints a short one —
    /// `BackgroundSession.jobID(fromOutput:)` — so the message goes in as the first prompt.
    public func backgroundArguments(message: String) -> [String] {
        var args = ["--bg", "--name", effectiveSessionName]
        if let mode = permissionMode { args += ["--permission-mode", mode] }
        if let model { args += ["--model", model] }
        if let agent = sessionAgent?.trimmingCharacters(in: .whitespaces), !agent.isEmpty { args += ["--agent", agent] }
        return args + [message]
    }

    /// The session this draft starts runs with these flags: a new herdr session or a background one.
    public var startsSession: Bool { destination == .newSession || destination == .background }
}

/// A `claude --bg` session as the CLI reports it: `backgrounded · 847a29dd · <name>` on stdout
/// (colour codes included), then the attach/logs/stop commands. The short id is the session id's
/// first 8 characters and the registry's `jobId`.
public enum BackgroundSession {
    public static func jobID(fromOutput output: String) -> String? {
        let plain = stripANSI(output)
        guard let line = plain.split(whereSeparator: \.isNewline).first(where: { $0.contains("backgrounded") }) else { return nil }
        return line.split(whereSeparator: { !$0.isHexDigit }).map(String.init).first { $0.count == 8 }
    }

    /// The commands the CLI prints for a background session.
    public static func attachCommand(_ id: String) -> String { "claude attach \(id)" }
    public static func stopCommand(_ id: String) -> String { "claude stop \(id)" }
}

// MARK: - Agents

/// An agent file (`.claude/agents/<name>.md`), as much of it as a loop needs: what to call it,
/// and the tools and model it brings — which decide whether a loop can run inside it.
public struct LoopAgent: Equatable, Sendable, Identifiable {
    /// The name Claude Code knows it by: the file's `name:` (else its stem), `plugin:name` for a plugin's.
    public var name: String
    public var description: String
    /// `model:` — nil or `inherit` runs on the session's model.
    public var model: String?
    /// `tools:` — nil when the field is absent: the agent inherits every tool.
    public var tools: [String]?
    public var disallowedTools: [String]
    /// "project", "user" or a plugin's name.
    public var scope: String
    public var id: String { name }

    public init(name: String, description: String = "", model: String? = nil, tools: [String]? = nil,
                disallowedTools: [String] = [], scope: String = "project") {
        self.name = name; self.description = description; self.model = model; self.tools = tools
        self.disallowedTools = disallowedTools; self.scope = scope
    }

    /// From frontmatter fields as `Frontmatter` reads them: `Read, Grep`, `[Read, Grep]`, or a
    /// YAML list (one item per line).
    public init(name: String, meta: [String: String], scope: String) {
        func list(_ key: String) -> [String]? {
            guard let raw = meta[key] else { return nil }
            return raw.split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t[]\"'")) }
                .filter { !$0.isEmpty }
        }
        let model = meta["model"]?.trimmingCharacters(in: .whitespaces)
        self.init(name: meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name, description: meta["description"] ?? "",
                  model: model == nil || model == "" || model == "inherit" ? nil : model,
                  tools: list("tools"), disallowedTools: list("disallowedTools") ?? list("disallowed-tools") ?? [],
                  scope: scope)
    }

    /// Whether a session or subagent running as this agent has `tool`. The Agent tool was once
    /// called Task, so either name grants it.
    public func allows(_ tool: String) -> Bool {
        let names = tool == "Agent" ? ["Agent", "Task"] : [tool]
        if disallowedTools.contains(where: { names.contains($0) }) { return false }
        guard let tools else { return true }
        return tools.contains { t in t == "*" || names.contains(t) }
    }

    /// Claude Code's own subagents, which any session can hand work to.
    public static let builtIns: [LoopAgent] = [
        LoopAgent(name: "general-purpose", description: "Claude Code's general agent: researches and carries out multi-step work",
                  scope: "built-in"),
        LoopAgent(name: "Explore", description: "Claude Code's fast, read-only search agent", scope: "built-in"),
        LoopAgent(name: "Plan", description: "Claude Code's planning agent: designs an approach without editing", scope: "built-in"),
    ]

    public var isBuiltIn: Bool { scope == "built-in" }

    /// "Read, Grep, Glob" — or "every tool" when the agent sets none.
    public var toolSummary: String {
        guard let tools else { return disallowedTools.isEmpty ? "every tool" : "every tool but \(disallowedTools.joined(separator: ", "))" }
        return tools.isEmpty ? "no tools" : tools.joined(separator: ", ")
    }
}

/// How a loop hands each fire's work to a subagent — written and read back in one place. Named in
/// words, the way a real `/loop 1m` delegated on its first run and on every fire. An `@agent-x`
/// mention is weaker on two counts, both seen in that run: Claude Code expands it only for a prompt
/// someone typed (fires skip attachments), and even then Claude first tried to message `x` as a
/// session.
public enum AgentDelegation {
    public static func sentence(agent: String, task: String, skipWhileRunning: Bool) -> String {
        var t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Review the diff" reads "…subagent to review the diff"; "PR …" or "API …" stay as typed.
        if let first = t.first, first.isUppercase, let second = t.dropFirst().first, second.isLowercase {
            t = first.lowercased() + t.dropFirst()
        }
        if let last = t.last, !".!?".contains(last) { t += "." }
        let s = "Use the \(agent) subagent to \(t)"
        return skipWhileRunning ? s + " " + skipClause(agent) : s
    }

    /// The guard against overlapping runs. An interactive session runs subagents in the background,
    /// so a fire's turn ends as soon as the agent starts; without this, a run longer than the
    /// interval gets a second copy alongside it. (A real run answered "Previous agent reported back.
    /// New … agent launched for this fire.")
    public static func skipClause(_ agent: String) -> String {
        "If the \(agent) you started at an earlier fire hasn't reported back yet, don't start another — say so in one line."
    }

    /// The agent, task and guard back out of a sentence `sentence` wrote — or one in its shape
    /// ("use the x agent to …").
    public static func parse(_ prompt: String) -> (agent: String, task: String, skipWhileRunning: Bool)? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = delegationRegex.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)),
              let nameRange = Range(m.range(at: 1), in: p), let taskRange = Range(m.range(at: 2), in: p) else { return nil }
        let agent = String(p[nameRange])
        var task = String(p[taskRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let clause = skipClause(agent)
        let skip = task.hasSuffix(clause)
        if skip { task = String(task.dropLast(clause.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (agent, task, skip)
    }

    /// `@agent-name …` or `@"name (agent)" …` anywhere in a prompt — a mention, which a fire leaves
    /// as plain text. Returns the agent and the prompt without the mention.
    public static func mention(in prompt: String) -> (agent: String, rest: String)? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = mentionRegex.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)),
              let whole = Range(m.range, in: p) else { return nil }
        let name = [1, 2].lazy.compactMap { Range(m.range(at: $0), in: p) }.first.map { String(p[$0]) } ?? ""
        guard !name.isEmpty else { return nil }
        var rest = p
        rest.removeSubrange(whole)
        rest = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, rest)
    }

    /// `@path` mentions of files (a token with a `/` or a `.`), which only a typed prompt attaches.
    public static func fileMentions(in prompt: String) -> [String] {
        fileMentionRegex.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).compactMap { m in
            Range(m.range(at: 1), in: prompt).map { String(prompt[$0]) }
        }.filter { ($0.contains("/") || $0.contains(".")) && !$0.hasPrefix("agent-") && $0 != "." }
    }

    private static let delegationRegex = try! NSRegularExpression(
        pattern: #"^use the ([A-Za-z0-9][A-Za-z0-9_.:-]*) (?:sub)?agent to (.+)$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let mentionRegex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=\s))@(?:agent-([A-Za-z0-9][A-Za-z0-9_.:-]*)|"([^"]+) \(agent\)")"#)
    private static let fileMentionRegex = try! NSRegularExpression(pattern: #"(?:^|(?<=\s))@([^\s@"]+)"#)
}

// MARK: - Preview

/// What a draft will do, for the dialog's right-hand side.
public struct LoopPreview: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case info, warning, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    /// A one-click change that resolves a note.
    public enum Fix: Equatable, Sendable {
        case interval(LoopInterval)
        case cron(String)
        case permissionMode(String)
        case cadence(LoopDraft.Cadence)
        case destination(LoopDraft.Destination)
        case task(LoopDraft.Task)
        /// The session's `--agent` (nil runs it as no agent).
        case sessionAgent(String?)
        /// The session's `--model` (nil leaves the default).
        case model(String?)
    }
    public struct Note: Equatable, Sendable, Identifiable {
        public var level: Level
        public var text: String
        public var fixes: [(label: String, fix: Fix)] = []
        public var id: String { text }
        public static func == (a: Note, b: Note) -> Bool {
            a.level == b.level && a.text == b.text && a.fixes.map(\.label) == b.fixes.map(\.label)
                && a.fixes.map(\.fix) == b.fixes.map(\.fix)
        }
    }

    /// Exactly what is sent (or copied).
    public var message: String?
    /// What the scheduler will hold, and the CLI's English for it.
    public var cron: String?
    public var cadence: String = ""
    /// `/loop` runs the task once right away, before the first scheduled fire.
    public var runsNow = false
    public var nextFires: [Date] = []
    /// Each fire may start up to this late (a fixed offset per task).
    public var maxDelay: TimeInterval?
    public var keepsCacheWarm = false
    /// How the schedule really behaves, beyond its cron: the every-5-minutes cache timing.
    public var scheduleNote: String?
    public var expiresAt: Date?
    public var notes: [Note] = []

    public var canSubmit: Bool { message != nil && !notes.contains { $0.level == .error } }
}

/// What the dialog knows about the machine and project, for `LoopDraft.preview`.
public struct LoopDraftContext: Sendable {
    public var now: Date
    public var capabilities: LoopCapabilities
    public var loopFile: LoopFile?
    public var herdrAvailable: Bool
    /// Skills and commands Claude could be asked to run, by `/name` — with whether Claude may
    /// invoke them itself (a scheduled fire can only run those).
    public var commands: [String: CommandAvailability]
    /// The project's and the user's agent files.
    public var agents: [LoopAgent]
    /// Why `/schedule` won't be there, from `claude auth status` — nil when it should be.
    public var scheduleUnavailable: String?
    public var calendar: Calendar

    public init(now: Date = Date(), capabilities: LoopCapabilities = LoopCapabilities(), loopFile: LoopFile? = nil,
                herdrAvailable: Bool = true, commands: [String: CommandAvailability] = [:], agents: [LoopAgent] = [],
                calendar: Calendar = .cron) {
        self.now = now; self.capabilities = capabilities; self.loopFile = loopFile
        self.herdrAvailable = herdrAvailable; self.commands = commands; self.agents = agents; self.calendar = calendar
    }

    /// An agent file by name, else one of Claude Code's own.
    public func agent(_ name: String) -> LoopAgent? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return agents.first { $0.name == n } ?? LoopAgent.builtIns.first { $0.name == n }
    }
}

public struct CommandAvailability: Equatable, Sendable {
    public var modelInvocable: Bool
    /// Why not, when it isn't.
    public var reason: String?
    public var description: String
    public init(modelInvocable: Bool, reason: String? = nil, description: String = "") {
        self.modelInvocable = modelInvocable; self.reason = reason; self.description = description
    }

    /// Built-in commands reach Claude as plain text when a loop fires them (docs). Not `/init` or
    /// `/security-review`, which Claude can run through the Skill tool, and not `/review`, an alias
    /// of the bundled `/code-review` skill.
    public static let builtIns: Set<String> = [
        "/clear", "/compact", "/config", "/cost", "/doctor", "/help", "/login", "/logout", "/model",
        "/permissions", "/resume", "/status", "/memory", "/agents", "/mcp", "/hooks", "/plugin", "/exit",
        "/rewind", "/context", "/usage", "/theme", "/vim", "/terminal-setup", "/add-dir", "/bug",
        "/export", "/release-notes", "/rename", "/statusline", "/goal", "/loop", "/schedule", "/fast", "/effort",
    ]
    /// Bundled skills only a person may run (`disable-model-invocation`) — the docs name `/verify`.
    public static let bundledManualOnly: Set<String> = ["/verify"]
    /// Claude Code's own commands and skills Claude can run itself, which no project file defines.
    public static let skillToolBuiltIns: Set<String> = ["/init", "/security-review", "/review", "/code-review"]
}

extension LoopDraft {
    public func preview(in ctx: LoopDraftContext) -> LoopPreview {
        var p = LoopPreview()
        let cal = ctx.calendar
        let jitter = ctx.capabilities.jitter
        p.message = message(calendar: cal)
        func note(_ level: LoopPreview.Level, _ text: String, _ fixes: [(String, LoopPreview.Fix)] = []) {
            p.notes.append(LoopPreview.Note(level: level, text: text, fixes: fixes.map { (label: $0.0, fix: $0.1) }))
        }
        func schedule(_ expr: CronExpression, recurring: Bool) {
            p.cron = expr.source
            p.cadence = CronExpression.humanize(expr.source)
            p.nextFires = expr.nextFires(after: ctx.now, count: 5, calendar: cal)
            guard recurring, destination != .cloud else { return }
            if let period = expr.period(after: ctx.now, calendar: cal), jitter.keepsCacheWarm(expr, period: period) {
                p.keepsCacheWarm = true
                p.scheduleNote = "Every 5 minutes fires \(LoopCadence.duration(period - jitter.cacheLead)) after the "
                    + "previous fire rather than on the clock, to stay inside the 5-minute prompt cache."
            } else if let delay = jitter.maxRecurringDelay(expr, from: ctx.now, calendar: cal), delay > 0 {
                p.maxDelay = delay
            }
            p.expiresAt = jitter.expiry(createdAt: ctx.now)
        }

        let inSession = destination != .cloud && destination != .copy && destination != .durableFile
        let viaScheduler = destination != .cloud

        // The machine.
        if viaScheduler {
            if let file = ctx.capabilities.disabledBy.first {
                note(destination == .copy ? .warning : .error,
                     "Scheduled tasks are switched off: CLAUDE_CODE_DISABLE_CRON is set in \(file.path(percentEncoded: false)).")
            } else if ctx.capabilities.cron.isKnownOff {
                note(.error, "This Claude Code has its scheduler switched off (its cached flags say so), so /loop isn't available.")
            }
        }

        // The task.
        switch task {
        case .prompt(let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note(.error, "Say what Claude should do each time.") }
        case .command(let name, _):
            let n = name.trimmingCharacters(in: .whitespaces)
            let key = n.hasPrefix("/") ? n : "/" + n
            if n.isEmpty || n == "/" {
                note(.error, "Pick a command or skill to run.")
            } else if key.hasPrefix("/mcp__") {
                note(.warning, "\(key) is an MCP prompt — a scheduled fire hands it to Claude as plain text instead of running it.")
            } else if CommandAvailability.builtIns.contains(key) {
                note(.warning, "\(key) is a built-in command — a scheduled fire hands it to Claude as plain text instead of running it.")
            } else if CommandAvailability.bundledManualOnly.contains(key) {
                note(.warning, "\(key) is a bundled skill only you can run (disable-model-invocation) — a scheduled fire "
                     + "hands it to Claude as plain text instead of running it.")
            } else if let rule = ctx.capabilities.skillDenyRule(for: key) {
                note(.warning, "\(key) is denied to Claude by “\(rule.rule)” in \(rule.file.path(percentEncoded: false)) — "
                     + "each fire would arrive as plain text.")
            } else if let info = ctx.commands[key], !info.modelInvocable {
                note(.warning, "\(key) can't be run by Claude on its own (\(info.reason ?? "not model-invocable")) — "
                     + "each fire would arrive as plain text.")
            } else if !ctx.commands.isEmpty, ctx.commands[key] == nil, !CommandAvailability.skillToolBuiltIns.contains(key) {
                note(.info, "\(key) isn't a skill or command this app found in the project — check the spelling.")
            }
        case .agent(let name, let text, let skip):
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { note(.error, "Pick the agent each fire hands the work to."); break }
            let info = ctx.agent(n)
            if info == nil, !ctx.agents.isEmpty {
                note(.warning, "\(n) isn't an agent this app found in .claude/agents (the project's or yours) — check the name.")
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note(.error, "Say what \(n) should do each time — a sentence is enough; its own instructions do the rest.")
            }
            let brings = info.map { a in a.isBuiltIn ? "built into Claude Code" : (a.model.map { "\($0), " } ?? "") + "tools: \(a.toolSummary)" }
            note(.info, "Each fire starts a fresh \(n)\(brings.map { " (\($0))" } ?? "") with its own instructions and an empty "
                 + "context. Only its report comes back into the loop's session, so that session stays small however long the loop runs.")
            if destination != .cloud {
                note(.info, "In an interactive session subagents run in the background: a fire's turn ends as soon as \(n) "
                     + "starts, and its report arrives as a turn of its own. The loop's iterations show both.")
                var recurring = true
                if case .once = cadence { recurring = false }
                if case .selfPaced = cadence { recurring = false }
                if !skip, recurring {
                    note(.warning, "Without the guard, a run that outlasts the interval gets a second \(n) started alongside it.",
                         [("Skip a fire while one runs", .task(.agent(name: n, task: text, skipWhileRunning: true)))])
                }
            } else if let info {
                if info.scope == "user" {
                    note(.warning, "A cloud routine runs from a fresh clone of the repository, and \(n) is one of your own agents "
                         + "(~/.claude/agents) — it won't be there.")
                } else if info.scope == "project" {
                    note(.info, "A cloud routine runs from a fresh clone: \(n) is there only if .claude/agents/ is committed.")
                }
            }
        case .defaultPrompt:
            switch cadence {
            case .cron, .once:
                note(.error, "loop.md and the built-in prompt run only through /loop — pick an interval or self-paced.")
            default:
                if let file = ctx.loopFile {
                    note(.info, "Runs the tasks in \(file.scope == .project ? "this project's" : "your") loop.md "
                         + "(\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))). "
                         + "Edits take effect at the next iteration.")
                    if file.isTruncated {
                        note(.warning, "loop.md is over 25,000 bytes — Claude reads only the first 25,000.")
                    }
                } else {
                    note(.info, "Runs the built-in maintenance prompt: continue unfinished work, tend this branch's PR "
                         + "(review comments, failed CI, merge conflicts), then cleanup passes. It never starts new "
                         + "initiatives, and pushes or deletes only what the conversation already authorized.")
                    if ctx.capabilities.maintenancePrompt.isKnownOff {
                        note(.warning, "This Claude Code has the built-in loop prompt switched off — add a loop.md, or give a prompt.")
                    }
                }
            }
        }

        // The schedule.
        switch cadence {
        case .interval(let i):
            p.runsNow = destination != .cloud && destination != .durableFile
            if i.value < 1 {
                note(.error, "An interval must be at least 1.")
                break
            }
            if i.unit == .s {
                note(.info, "Cron counts whole minutes, so \(i.token) becomes \(i.normalized.token).")
            }
            if !i.isClean {
                let alts = i.cleanAlternatives
                note(destination == .durableFile ? .error : .warning,
                     "\(i.normalized.spoken.capitalizedFirst) doesn't divide evenly into cron steps (the gaps would be "
                     + "uneven), so /loop rounds it to the nearest clean interval and says which. Pick one yourself:",
                     alts.map { ($0.token, .interval($0)) })
            }
            if i.minutes >= 60, destination != .cloud, destination != .durableFile {
                note(.info, "For an hour or more, /loop may first ask whether to set this up as a cloud routine "
                     + "instead — answer it in the session, or choose Cloud routine below.",
                     [("Use a cloud routine", .destination(.cloud))])
            }
            if destination == .cloud, i.minutes < 60 {
                note(.error, "Cloud routines run at most once an hour.", [("Every 1h", .interval(LoopInterval(1, .h)))])
            }
            if let cron = i.cron, let expr = CronExpression(cron) {
                schedule(expr, recurring: true)
            }
        case .selfPaced:
            p.runsNow = true
            p.cadence = "Self-paced"
            if destination == .durableFile || destination == .cloud {
                note(.error, destination == .cloud ? "A cloud routine needs a fixed schedule." :
                        "Only a fixed schedule can be saved to the task file.")
            } else {
                note(.info, "Claude runs it now, then after each iteration picks the next delay — 1 minute to 1 hour — "
                     + "and says why. It may watch for an event (Monitor) instead of polling, and ends the loop itself "
                     + "when the work is done. Press Esc in the session while it waits to stop it.")
                // The docs: jitter doesn't apply to a self-paced loop, but the seven-day expiry does.
                p.expiresAt = jitter.expiry(createdAt: ctx.now)
            }
            if ctx.capabilities.selfPaced.isKnownOff {
                note(.warning, "This Claude Code has self-paced loops switched off — /loop would need an interval.")
            }
            let parsed = LoopArguments.parse(taskText)
            if !taskText.isEmpty, let i = parsed.interval {
                note(.warning, parsed.rule == 1
                     ? "Your prompt starts with “\(i.token)” — /loop reads that as the interval, so this wouldn't be self-paced."
                     : "Your prompt ends with “every \(i.spoken)” — /loop reads that as the interval, so this wouldn't be self-paced.",
                     [("Use every \(i.normalized.token)", .cadence(.interval(i)))])
            }
        case .cron(let text):
            switch CronExpression.validate(text) {
            case .invalid(_, let message):
                note(.error, message)
            case .valid(let expr):
                schedule(expr, recurring: true)
                if let m = expr.fixedMinute, m == 0 || m == 30 {
                    var fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
                    let off = m == 0 ? 3 : 33
                    fields[0] = "\(off)"
                    note(.info, "Fires on :\(m == 0 ? "00" : "30") — when every other schedule does. The CLI suggests "
                         + "an off minute unless you need that exact time.",
                         [("Use :\(CronExpression.pad2(off))", .cron(fields.joined(separator: " ")))])
                }
            }
        case .once(let date):
            if date <= ctx.now {
                note(.error, "That time has passed.")
            } else if date.timeIntervalSince(ctx.now) > 365 * 86_400 {
                note(.error, "More than a year away — cron has no year, so it can't be pinned that far.")
            } else {
                let cron = Self.pinnedCron(date, calendar: cal)
                p.cron = cron
                p.cadence = LoopCadence.describe(cron: cron, recurring: false)
                if let expr = CronExpression(cron), let at = expr.next(after: ctx.now, calendar: cal) {
                    p.nextFires = [at]
                    if cal.component(.minute, from: at) % jitter.oneShotMinuteMod == 0, jitter.oneShotMax > 0 {
                        note(.info, "On the hour or half hour, a one-time task fires up to \(LoopCadence.duration(jitter.oneShotMax)) early.")
                    }
                }
                if inSession {
                    note(.info, "It fires only if its session is still open then — and idle. If the session is closed "
                         + "and resumed before then, it comes back.")
                }
            }
        }

        // @-mentions: Claude Code expands them (attaches the file, nudges toward the agent) only in a
        // prompt someone sends — a fire skips attachments, so at every fire they're plain text.
        let mentionText: String? = {
            switch task {
            case .prompt(let p): return p
            case .command(_, let a): return a
            case .agent(_, let t, _): return t
            case .defaultPrompt: return nil
            }
        }()
        if let text = mentionText, destination != .cloud {
            let sent = p.runsNow ? " (only the run you send gets it)" : ""
            if let m = AgentDelegation.mention(in: text) {
                var fixes: [(String, LoopPreview.Fix)] = []
                if case .prompt = task, !m.rest.isEmpty {
                    fixes = [("Hand each fire to \(m.agent)", .task(.agent(name: m.agent, task: m.rest, skipWhileRunning: true)))]
                }
                note(.warning, "A fire doesn't expand @-mentions: at every fire “@agent-\(m.agent)” reaches Claude as plain "
                     + "text. In a real run Claude tried to message \(m.agent) as a session instead — even on the run that was "
                     + "sent. Naming the agent in words worked on every fire.", fixes)
            }
            let files = AgentDelegation.fileMentions(in: text)
            if let first = files.first {
                note(.info, "A fire doesn't attach @-mentioned files: at each fire Claude sees just “@\(first)”"
                     + "\(files.count > 1 ? " (and \(files.count - 1) more)" : "") and reads it if it needs to\(sent).")
            }
        }

        // A session that runs as an agent has only that agent's tools — /loop included.
        if startsSession, let sa = sessionAgent?.trimmingCharacters(in: .whitespaces), !sa.isEmpty {
            let a = ctx.agent(sa)
            if a == nil, !ctx.agents.isEmpty {
                note(.warning, "\(sa) isn't an agent this app found in .claude/agents (the project's or yours) — check the name.")
            }
            let modelLine = model.map { " — on \($0), which overrides the agent's own model" }
                ?? a?.model.map { " — on its own model, \($0)" } ?? ""
            note(.info, "The session runs as \(sa): its instructions replace Claude Code's default system prompt, and "
                 + "its tools are all the session has, at every fire\(modelLine).")
            if let a {
                var scheduler = "CronCreate"
                if case .selfPaced = cadence { scheduler = "ScheduleWakeup" }
                if !a.allows(scheduler) {
                    note(.error, "\(sa)'s tools don't include \(scheduler), so nothing can be scheduled in a session that runs "
                         + "as it (a real run got “No such tool available: \(scheduler)”). Add \(scheduler) to its tools, or "
                         + "run the session as no agent.",
                         [("Run as no agent", .sessionAgent(nil))])
                } else if scheduler == "CronCreate", !a.allows("CronDelete") {
                    note(.warning, "\(sa) can't call CronDelete, so the session can't cancel the loop when asked — close the session to stop it.")
                }
                if case .agent(let name, _, _) = task, !name.trimmingCharacters(in: .whitespaces).isEmpty, !a.allows("Agent") {
                    note(.error, "\(sa) has no Agent tool, so it can't hand fires to \(name). Add Agent to its tools, or run "
                         + "the session as no agent.",
                         [("Run as no agent", .sessionAgent(nil))])
                }
            }
        }

        // A session loop's first fire hours away needs the session open — and idle — until then.
        if inSession, destination != .durableFile, !p.runsNow, let first = p.nextFires.first,
           first.timeIntervalSince(ctx.now) > 3 * 3600 {
            note(.warning, "Its first fire is \(LoopCadence.duration(first.timeIntervalSince(ctx.now))) away — the "
                 + "session has to still be open then. A cloud routine or a Desktop scheduled task doesn't need one.",
                 [("Use a cloud routine", .destination(.cloud))])
        }

        // Where it runs.
        if startsSession {
            if destination == .newSession, !ctx.herdrAvailable {
                note(.error, "herdr isn't installed — copy the command and paste it into a session instead.")
            }
            if permissionMode == nil || permissionMode == "manual" {
                note(.warning, "In this mode each fire stops at its first permission prompt until you answer it. "
                     + "Auto keeps most fires moving (Claude Code still asks for commands its safety checks flag); "
                     + "Don't ask never waits — a call that would ask fails instead.", [("Use Auto", .permissionMode("auto"))])
            }
            if permissionMode == "bypassPermissions" {
                note(.warning, "Bypass permissions lets every fire run any tool without asking.")
            }
            // Two real sessions started with --permission-mode auto: on the default model it took;
            // on Haiku the session recorded `default` — the ask-every-time mode — without a word.
            let agentModel = sessionAgent.flatMap { ctx.agent($0) }?.model
            if permissionMode == "auto", let effective = model ?? agentModel, effective.lowercased().contains("haiku") {
                let whose = model == nil ? "\(sessionAgent ?? "the agent")'s model is Haiku" : "Haiku"
                note(.warning, "Auto mode isn't available on Haiku: with \(whose), Claude Code quietly starts the session in "
                     + "its ask-every-time mode instead, so each fire stops at its first permission prompt.",
                     model == nil ? [("Use Sonnet", .model("sonnet"))] : [("Use the default model", .model(nil)), ("Use Sonnet", .model("sonnet"))])
            }
        }
        switch destination {
        case .newSession:
            note(.info, "The loop lives in that session: it fires only while the session is open and idle, missed fires "
                 + "don't catch up, and closing the session stops it.")
        case .background:
            note(.info, "A background session has no terminal: the loop keeps firing after you close the terminal or "
                 + "Claudepit, and across sleep — shutdown stops it (resuming brings cron loops back). The page shows it; "
                 + "Attach opens it in herdr to answer a prompt or talk to it.")
            if permissionMode != "dontAsk", permissionMode != "bypassPermissions" {
                note(.info, "A permission prompt waits until you attach — the page marks the loop “Needs you” meanwhile.")
            }
            if permissionMode == "auto" {
                note(.info, "Auto in a background session needs auto mode opted in once — if Claude Code refuses, run "
                     + "claude --permission-mode auto once in a terminal.")
            }
            if permissionMode == "bypassPermissions" {
                note(.info, "Bypass in a background session needs its disclaimer accepted once — if Claude Code refuses, "
                     + "run claude --dangerously-skip-permissions once in a terminal.")
            }
        case .existingSession(_, let title):
            note(.info, "Sent to “\(title)” as a message — it's acted on when that session is idle. A session holds at most 50 scheduled tasks.")
        case .copy:
            note(.info, "Paste it into any Claude Code session; the loop then belongs to that session.")
        case .durableFile:
            if case .defaultPrompt = task {
                note(.error, "The task file needs a prompt — loop.md and the built-in prompt run only through /loop.")
            }
            if ctx.capabilities.durable.isKnownOff {
                note(.error, "This Claude Code has durable tasks switched off (its cached tengu_kairos_cron_durable flag), "
                     + "so it never reads .claude/scheduled_tasks.json — a task saved there would never run.")
            }
            note(.info, "Survives restarts, but runs only while a Claude Code session is open in this folder (the one "
                 + "holding .claude/scheduled_tasks.lock) — not in other checkouts or worktrees.")
        case .cloud:
            if case .defaultPrompt = task { note(.error, "A cloud routine needs a prompt.") }
            if let why = ctx.scheduleUnavailable {
                note(.error, why + " /schedule needs a claude.ai subscription login (docs) — or create the routine at "
                     + "claude.ai/code/routines.")
            }
            note(.info, "Runs on Anthropic's cloud from a fresh clone of the repository — no local files or local MCP "
                 + "servers, no permission prompts. /schedule asks a few questions before saving it to your account.")
        }

        if p.message == nil, !p.notes.contains(where: { $0.level == .error }) {
            note(.error, "Nothing to send yet.")
        }
        p.notes.sort { $0.level > $1.level }
        return p

    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
