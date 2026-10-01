import Foundation

// The transcript view's model: the parser's events arranged as turns of display rows, each row
// tagged with the filter categories it answers to, plus per-turn and session totals. Pure — no
// SwiftUI — so the grouping, filtering and search rules are checked in `TranscriptModelChecks`.
//
// A *turn* is everything from one thing that hands Claude work (a prompt, a slash command, a
// background task reporting back, another agent's message) up to the next. Its rows are:
//   header  — the message that opened it (or "Session start" for what came before any)
//   items   — Claude's text, thinking, tool calls, injected context, hooks, system notices
//   footer  — how long it took and what it cost (unfiltered view only)
//
// Rows are keyed by event index (`e12`, `r40`, `h3`), stable while the parser appends, so a
// live-tailed transcript keeps its scroll position and expansion state. (The one exception is the
// parser moving a late-written prompt ahead of its reply, which shifts the few rows after it.)

/// What the filter bar can narrow to. A row answers to every category it belongs to — a failed
/// Edit is a tool, an edit and an error.
public enum TranscriptFilter: String, CaseIterable, Identifiable, Sendable {
    case prompts, responses, thinking, tools, edits, plans, tasks, questions, subagents, skills
    case context, hooks, system, errors
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .prompts:   return "You"
        case .responses: return "Responses"
        case .thinking:  return "Thinking"
        case .tools:     return "Tools"
        case .edits:     return "Edits"
        case .plans:     return "Plans"
        case .tasks:     return "Tasks"
        case .questions: return "Questions"
        case .subagents: return "Subagents"
        case .skills:    return "Skills"
        case .context:   return "Context"
        case .hooks:     return "Hooks"
        case .system:    return "System"
        case .errors:    return "Errors"
        }
    }
}

/// A row worth a mark on the transcript's timeline rail, by kind. Raw order is draw order:
/// where marks overlap, the later kind is drawn on top, so a failure is never hidden.
public enum TranscriptLandmark: Int, CaseIterable, Comparable, Sendable {
    case report, command, prompt, task, skill, subagent, question, edit, plan, compaction, error

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Starts a turn, or is a prompt sent mid-turn: drawn wide.
    public var startsTurn: Bool { self == .prompt || self == .command || self == .report }
}

/// A stretch of the session during which one task-list item was in progress: opened by its
/// `TaskUpdate(in_progress)`, closed by its completed/deleted update or by another task starting.
public struct TranscriptTaskSpan: Equatable, Sendable {
    public let taskID: String
    public let label: String
    /// Event indices, inclusive.
    public let start: Int
    public let end: Int
    public init(taskID: String, label: String, start: Int, end: Int) {
        self.taskID = taskID; self.label = label; self.start = start; self.end = end
    }
}

public struct TranscriptRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The message that opened turn `turn` — or, with no prompt, the session's preamble.
        case turnHeader
        /// A user-role message that opens no turn: an injected meta message, a command's output,
        /// a compaction summary, something queued mid-turn.
        case message(Int)
        case assistant(Int)
        /// Consecutive thinking blocks that carry text.
        case thinking([Int])
        case tool(Int)
        /// Consecutive routine calls (reads, searches, shell), folded into one line.
        case toolRun([Int])
        /// Consecutive injected-context items.
        case context([Int])
        case systemPrompt(Int)
        case hook(Int)
        case notice(Int)
        case attachment(Int)
        case turnFooter
    }
    public let id: String
    public let turn: Int
    public let kind: Kind
    public let filters: Set<TranscriptFilter>

    public init(id: String, turn: Int, kind: Kind, filters: Set<TranscriptFilter>) {
        self.id = id; self.turn = turn; self.kind = kind; self.filters = filters
    }

    /// The event indices this row draws on.
    public var eventIndices: [Int] {
        switch kind {
        case .turnHeader, .turnFooter: return []
        case .message(let i), .assistant(let i), .tool(let i), .systemPrompt(let i),
             .hook(let i), .notice(let i), .attachment(let i): return [i]
        case .thinking(let a), .toolRun(let a), .context(let a): return a
        }
    }
}

public struct TranscriptTurn: Identifiable, Equatable, Sendable {
    public enum Opener: Equatable, Sendable { case preamble, prompt, command, notification, peer }
    public let index: Int
    public var id: String { "h\(index)" }
    /// The number a reader sees: 1 for the first turn that hands Claude work (the preamble,
    /// when there is one, is 0).
    public var number = 0
    public var opener: Opener
    /// The event that opened the turn; nil for the preamble.
    public var promptIndex: Int?
    /// One line for outlines and the timeline rail.
    public var label: String
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    /// The CLI's own measure when it wrote one (`turn_duration`), else first-to-last record.
    public var durationMs: Int?
    public var apiCalls = 0
    public var inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheWriteTokens = 0
    /// Distinct models, in the order the turn used them.
    public var models: [String] = []
    public var effort: String?
    public var toolCalls = 0, failedTools = 0, edits = 0, subagents = 0
    /// Plan writes and approvals, AskUserQuestion calls, skill loads and task-list updates.
    public var plans = 0, questions = 0, skills = 0, tasks = 0
    /// Thinking blocks, including the signed ones recorded without text.
    public var thinkingBlocks = 0
    public var errors = 0
    /// Context the turn's last API call read — the window as the turn ended.
    public var contextAtEnd = 0
    /// The events the turn spans, opener included.
    public var eventRange: ClosedRange<Int>?
    /// On a branch the person abandoned by rewinding: its prompt was sent again (as turn
    /// `replacedBy`) from the same point, and the conversation continued from there instead.
    public var rewound = false
    public var replacedBy: Int?

    public init(index: Int, opener: Opener, promptIndex: Int?, label: String) {
        self.index = index; self.opener = opener; self.promptIndex = promptIndex; self.label = label
    }

    public var hasActivity: Bool { apiCalls > 0 || toolCalls > 0 }
}

public struct TranscriptStats: Equatable, Sendable {
    public var prompts = 0, turns = 0, toolCalls = 0, failedTools = 0, errors = 0
    public var apiCalls = 0, subagents = 0, compactions = 0
    public var inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheWriteTokens = 0
    /// Distinct files written or edited.
    public var filesChanged = 0
    public var models: [String] = []
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    public init() {}
}

public struct TranscriptModel: @unchecked Sendable {
    public let events: [SessionEvent]
    public let metadata: TranscriptMetadata
    /// Bumped by whoever rebuilds the model for a live view, so the view can tell a rebuild
    /// that changed events in place (a result landing) from no change at all.
    public var generation = 0
    public private(set) var turns: [TranscriptTurn] = []
    /// Every row of the unfiltered view, in order, with runs folded.
    public private(set) var rows: [TranscriptRow] = []
    /// How many rows answer to each filter (runs dissolved, so a count is of real items).
    public private(set) var counts: [TranscriptFilter: Int] = [:]
    public private(set) var stats = TranscriptStats()
    /// Hook runs that belong to a tool call (Pre/PostToolUse), by tool id — shown on the call.
    public private(set) var hooksByTool: [String: [Int]] = [:]
    /// Context items the CLI tied to a tool call (a Read's truncation notice), by tool id.
    public private(set) var contextByTool: [String: [Int]] = [:]
    /// A subagent's id (from its Agent call's launch record) → that call's tool-use id, so a
    /// report the subagent sends back can name and link the call that started it.
    public private(set) var agentCallByAgentID: [String: String] = [:]
    /// Task id → subject and latest status, from TaskCreate/TaskUpdate.
    public private(set) var taskSubjects: [String: String] = [:]
    public private(set) var taskStatus: [String: String] = [:]
    /// Task id → the event that created it, and the spans during which tasks were in progress.
    public private(set) var taskCreateEvent: [String: Int] = [:]
    public private(set) var taskSpans: [TranscriptTaskSpan] = []
    /// The session's last TaskList / TodoWrite — the latest full picture of the task list.
    public private(set) var lastTaskListEvent: Int?
    /// The events that carry a plan's Ask / Plans links: every Write of a plan file — and, for a
    /// plan this session never writes (only edits or presents), its first such call, so it can
    /// still be opened. Every plan row used to carry them (each edit, the approval, plan-mode
    /// context); by request they now sit on the Write alone.
    public private(set) var planLinkEvents: [Int: String] = [:]
    /// Where plan files live; a write there is a plan, not an ordinary edit.
    public let plansRoot: String
    /// Lowercased searchable text per event (capped per event), built on first use. Building it
    /// for every event up front was ~60% of a transcript load (it re-serialises every tool input),
    /// paid again on each live rebuild, for a search box most loads never touch.
    private let search = SearchBlobs()

    /// Routine calls fold into a run once this many are consecutive.
    public static let runThreshold = 4
    /// Calls a reader needs to see individually, never folded: changes, delegation, questions,
    /// plan and task milestones.
    public static let keyTools: Set<String> = [
        "Edit", "MultiEdit", "Write", "NotebookEdit", "Agent", "Task", "Skill", "AskUserQuestion",
        "ExitPlanMode", "EnterPlanMode", "TaskCreate", "TaskUpdate", "TodoWrite", "SendMessage",
    ]

    public init(events: [SessionEvent], metadata: TranscriptMetadata = TranscriptMetadata(),
                plansRoot: String = Paths.plansRoot.path) {
        self.events = events
        self.metadata = metadata
        self.plansRoot = plansRoot
        build()
    }

    /// The plan file a call wrote, edited or presented for approval, if any.
    public func planPath(of inv: ToolInvocation) -> String? {
        switch inv.name {
        case "Write", "Edit", "MultiEdit":
            guard let p = inv.input["file_path"] as? String, isPlanFile(p) else { return nil }
            return p
        case "ExitPlanMode":
            return (inv.detail?["filePath"] as? String) ?? (inv.input["planFilePath"] as? String)
        default:
            return nil
        }
    }

    /// The plan file whose links the event at `index` carries (see `planLinkEvents`).
    public func planLinkPath(at index: Int) -> String? { planLinkEvents[index] }

    private mutating func collectPlanLinks() {
        var written = Set<String>()
        var firstTouch: [String: Int] = [:]
        planLinkEvents = [:]
        for (i, e) in events.enumerated() {
            guard case .tool(let inv) = e, let path = planPath(of: inv) else { continue }
            if firstTouch[path] == nil { firstTouch[path] = i }
            if inv.name == "Write" {
                planLinkEvents[i] = path
                written.insert(path)
            }
        }
        for (path, touched) in firstTouch where !written.contains(path) { planLinkEvents[touched] = path }
    }

    public func isPlanFile(_ path: String) -> Bool {
        path.hasPrefix(plansRoot.hasSuffix("/") ? plansRoot : plansRoot + "/") && path.hasSuffix(".md")
    }

    /// The task span an event falls inside, if any (spans never overlap).
    public func taskSpan(containing event: Int) -> TranscriptTaskSpan? {
        var lo = 0, hi = taskSpans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = taskSpans[mid]
            if event < s.start { hi = mid - 1 } else if event > s.end { lo = mid + 1 } else { return s }
        }
        return nil
    }

    /// Position of a span among all spans — what its colour cycles on.
    public func taskSpanIndex(_ span: TranscriptTaskSpan) -> Int {
        taskSpans.firstIndex(of: span) ?? 0
    }

    static let taskTools: Set<String> = ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskStop", "TodoWrite"]

    // MARK: - Filtering

    /// The rows to show for a filter set and search. With neither, it is `rows` with each run the
    /// reader expanded followed by its calls. With either, runs dissolve
    /// into their calls, a row stays when it answers a selected filter *and* matches the query,
    /// turn headers stay as anchors for turns that kept something (or for their own match when
    /// Prompts is selected), and footers go.
    public func visibleRows(filters: Set<TranscriptFilter> = [], query: String = "",
                            runExpanded: (String) -> Bool = { _ in false }) -> [TranscriptRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if filters.isEmpty && q.isEmpty {
            var out: [TranscriptRow] = []
            out.reserveCapacity(rows.count)
            for row in rows {
                out.append(row)
                if case .toolRun(let members) = row.kind, runExpanded(row.id) {
                    out.append(contentsOf: members.map { toolRow($0, turn: row.turn) })
                }
            }
            return out
        }
        var out: [TranscriptRow] = []
        var pendingHeader: TranscriptRow?
        for row in rows {
            switch row.kind {
            case .turnHeader:
                pendingHeader = nil
                let own = headerMatches(row, filters: filters, query: q)
                if own { out.append(row) } else { pendingHeader = row }
            case .turnFooter:
                continue
            case .toolRun(let members):
                for i in members {
                    let r = toolRow(i, turn: row.turn)
                    if matches(r, filters: filters, query: q) {
                        if let h = pendingHeader { out.append(h); pendingHeader = nil }
                        out.append(r)
                    }
                }
            default:
                if matches(row, filters: filters, query: q) {
                    if let h = pendingHeader { out.append(h); pendingHeader = nil }
                    out.append(row)
                }
            }
        }
        return out
    }

    private func headerMatches(_ row: TranscriptRow, filters: Set<TranscriptFilter>, query q: String) -> Bool {
        let filterOK = filters.isEmpty ? !q.isEmpty : !filters.isDisjoint(with: row.filters)
        guard filterOK else { return false }
        guard !q.isEmpty else { return true }
        guard let i = turns[row.turn].promptIndex else { return false }
        return search.blob(i, in: events).contains(q)
    }

    private func matches(_ row: TranscriptRow, filters: Set<TranscriptFilter>, query q: String) -> Bool {
        if !filters.isEmpty && filters.isDisjoint(with: row.filters) { return false }
        if q.isEmpty { return true }
        return row.eventIndices.contains { search.blob($0, in: events).contains(q) }
            || attachedIndices(row).contains { search.blob($0, in: events).contains(q) }
    }

    /// Hooks and context shown inside a tool row — a search must see them too.
    private func attachedIndices(_ row: TranscriptRow) -> [Int] {
        guard case .tool(let i) = row.kind, case .tool(let inv) = events[i] else { return [] }
        return (hooksByTool[inv.id] ?? []) + (contextByTool[inv.id] ?? [])
    }

    /// The run a folded call sits in, so a link to the call can unfold it first.
    public func runID(containing eventIndex: Int) -> String? { runOfEvent[eventIndex] }
    private var runOfEvent: [Int: String] = [:]

    // MARK: - Build

    private mutating func build() {
        collectAttachments()
        collectTasks()
        collectPlanLinks()

        var turn = TranscriptTurn(index: 0, opener: .preamble, promptIndex: nil, label: "Session start")
        var turnFirstEvent = 0
        var turnRows: [TranscriptRow] = []
        var pending: [Int] = []          // routine tool calls not yet placed
        var thinkingRun: [Int] = []
        var contextRun: [Int] = []
        var turnEndMs: Int?
        var changedFiles = Set<String>()
        var sessionModels: [String] = []

        func flushTools() {
            guard !pending.isEmpty else { return }
            if pending.count >= Self.runThreshold {
                let members = pending
                let filters = members.reduce(into: Set<TranscriptFilter>()) { $0.formUnion(toolFilters($1)) }
                let id = "r\(members[0])"
                for m in members { runOfEvent[m] = id }
                turnRows.append(TranscriptRow(id: id, turn: turn.index, kind: .toolRun(members), filters: filters))
            } else {
                turnRows.append(contentsOf: pending.map { toolRow($0, turn: turn.index) })
            }
            pending = []
        }
        func flushThinking() {
            guard !thinkingRun.isEmpty else { return }
            turnRows.append(TranscriptRow(id: "k\(thinkingRun[0])", turn: turn.index, kind: .thinking(thinkingRun), filters: [.thinking]))
            thinkingRun = []
        }
        func flushContext() {
            guard !contextRun.isEmpty else { return }
            var f: Set<TranscriptFilter> = [.context]
            if contextRun.contains(where: { if case .context(let c) = events[$0] { return Self.isPlanContext(c) } else { return false } }) {
                f.insert(.plans)
            }
            turnRows.append(TranscriptRow(id: "c\(contextRun[0])", turn: turn.index, kind: .context(contextRun), filters: f))
            contextRun = []
        }
        func flushAll() { flushTools(); flushThinking(); flushContext() }

        func closeTurn(before next: Int) {
            flushAll()
            if next > turnFirstEvent { turn.eventRange = turnFirstEvent...(next - 1) }
            // Only a turn that did something has a duration worth showing — an idle command
            // "turn" would otherwise span to whatever the CLI recorded next, minutes later.
            if let ms = turnEndMs { turn.durationMs = ms }
            else if turn.hasActivity, let s = turn.startTime, let e = turn.endTime, e > s {
                turn.durationMs = Int((e - s) * 1000)
            }
            let isEmptyPreamble = turn.opener == .preamble && turnRows.isEmpty
            if !isEmptyPreamble {
                var headerFilters: Set<TranscriptFilter> = []
                switch turn.opener {
                case .prompt, .command: headerFilters = [.prompts]
                case .notification:
                    headerFilters = [.system]
                    if let p = turn.promptIndex, case .userMessage(let m) = events[p],
                       let id = m.notification?.toolUseID, let ti = toolIndex[id],
                       case .tool(let inv) = events[ti], case .agent = inv.toolClass {
                        headerFilters = [.subagents]
                    }
                case .peer: headerFilters = [.subagents]
                case .preamble: headerFilters = []
                }
                rows.append(TranscriptRow(id: "h\(turn.index)", turn: turn.index, kind: .turnHeader, filters: headerFilters))
                rows.append(contentsOf: turnRows)
                if turn.hasActivity || turn.durationMs != nil {
                    rows.append(TranscriptRow(id: "f\(turn.index)", turn: turn.index, kind: .turnFooter, filters: []))
                }
                turns.append(turn)
                stats.turns += 1
                if turn.opener == .prompt { stats.prompts += 1 }
            }
            turnRows = []
            turnEndMs = nil
        }

        for (i, e) in events.enumerated() {
            if case .userMessage(let m) = e, m.startsTurn {
                closeTurn(before: i)
                turnFirstEvent = i
                let opener: TranscriptTurn.Opener
                switch m.kind {
                case .command: opener = .command
                case .taskNotification: opener = .notification
                case .peer: opener = .peer
                default: opener = .prompt
                }
                turn = TranscriptTurn(index: turns.count, opener: opener, promptIndex: i, label: Self.label(m))
                turn.startTime = m.time
                turn.endTime = m.time
                continue
            }
            if let t = Self.time(of: e) {
                if turn.startTime == nil { turn.startTime = t }
                turn.endTime = max(turn.endTime ?? t, t)
            }
            switch e {
            case .turnUsage(let u):
                turn.apiCalls += 1
                turn.inputTokens += u.inputTokens; turn.outputTokens += u.outputTokens
                turn.cacheReadTokens += u.cacheReadTokens; turn.cacheWriteTokens += u.cacheWriteTokens
                turn.contextAtEnd = u.contextTokens
                if !turn.models.contains(u.model) { turn.models.append(u.model) }
                if !sessionModels.contains(u.model) { sessionModels.append(u.model) }
                if let eff = u.effort { turn.effort = eff }
                stats.apiCalls += 1
                stats.inputTokens += u.inputTokens; stats.outputTokens += u.outputTokens
                stats.cacheReadTokens += u.cacheReadTokens; stats.cacheWriteTokens += u.cacheWriteTokens
                continue   // no row: totals live in the footer

            case .thinking(let th):
                turn.thinkingBlocks += 1
                guard !th.isRedacted else { continue }   // signed thinking: counted, nothing to show
                flushTools(); flushContext()
                thinkingRun.append(i)

            case .tool(let inv):
                turn.toolCalls += 1; stats.toolCalls += 1
                if planPath(of: inv) != nil || inv.name == "ExitPlanMode" { turn.plans += 1 }
                if inv.name == "AskUserQuestion" { turn.questions += 1 }
                if case .skill = inv.toolClass { turn.skills += 1 }
                if Self.taskTools.contains(inv.name) { turn.tasks += 1 }
                if inv.failed { turn.failedTools += 1; turn.errors += 1; stats.failedTools += 1; stats.errors += 1 }
                if inv.isFileChange {
                    turn.edits += 1
                    if let p = (inv.input["file_path"] as? String) ?? (inv.input["notebook_path"] as? String) {
                        changedFiles.insert(p)
                    }
                }
                if case .agent = inv.toolClass { turn.subagents += 1; stats.subagents += 1 }
                flushThinking(); flushContext()
                if Self.keyTools.contains(inv.name) {
                    flushTools()
                    turnRows.append(toolRow(i, turn: turn.index))
                } else {
                    pending.append(i)
                }

            case .context(let item):
                if item.type == "read_truncation_notice", attachedContext.contains(i) { continue }
                flushTools(); flushThinking()
                contextRun.append(i)

            case .hook(let h):
                if attachedHooks.contains(i) { continue }
                flushAll()
                if h.isError { turn.errors += 1; stats.errors += 1 }
                var f: Set<TranscriptFilter> = [.hooks]
                if h.isError { f.insert(.errors) }
                turnRows.append(TranscriptRow(id: "e\(i)", turn: turn.index, kind: .hook(i), filters: f))

            case .notice(let n):
                if n.kind == .turnEnd { turnEndMs = n.durationMs ?? turnEndMs; continue }
                flushAll()
                if n.kind == .compaction { stats.compactions += 1 }
                var f: Set<TranscriptFilter> = [.system]
                if n.isError { f.insert(.errors); turn.errors += 1; stats.errors += 1 }
                if n.kind == .modeChange, n.title.hasSuffix(": plan") || n.detail == "was plan" { f.insert(.plans) }
                turnRows.append(TranscriptRow(id: "e\(i)", turn: turn.index, kind: .notice(i), filters: f))

            case .systemPrompt:
                flushAll()
                turnRows.append(TranscriptRow(id: "e\(i)", turn: turn.index, kind: .systemPrompt(i), filters: [.context]))

            case .assistantText:
                flushAll()
                turnRows.append(TranscriptRow(id: "e\(i)", turn: turn.index, kind: .assistant(i), filters: [.responses]))

            case .userMessage(let m):
                flushAll()
                turnRows.append(TranscriptRow(id: "e\(i)", turn: turn.index, kind: .message(i), filters: messageFilters(m)))

            case .attachment:
                flushAll()
                turnRows.append(TranscriptRow(id: "e\(i)", turn: turn.index, kind: .attachment(i), filters: [.context]))
            }
        }
        closeTurn(before: events.count)

        let offset = turns.first?.opener == .preamble ? 0 : 1
        for i in turns.indices { turns[i].number = turns[i].index + offset }
        markRewinds()
        stats.filesChanged = changedFiles.count
        stats.models = sessionModels
        counts = Dictionary(uniqueKeysWithValues: TranscriptFilter.allCases.map { f in
            (f, visibleRows(filters: [f]).filter { $0.kind != .turnHeader || $0.filters.contains(f) }.count)
        })
    }

    /// Prompts that share a parent record are a rewind: every turn from an earlier sibling up to
    /// the next one is a branch the conversation left behind.
    private mutating func markRewinds() {
        var siblings: [String: [Int]] = [:]   // parent uuid → turn indices, in order
        for t in turns where t.opener == .prompt || t.opener == .command {
            guard let p = t.promptIndex, case .userMessage(let m) = events[p], let parent = m.parentUUID else { continue }
            siblings[parent, default: []].append(t.index)
        }
        // In turn order, so overlapping rewinds (one inside an abandoned branch) resolve the same
        // way every time: the nearest resend claims a turn first.
        for group in siblings.values.filter({ $0.count > 1 }).sorted(by: { $0[0] > $1[0] }) {
            for (a, b) in zip(group, group.dropFirst()) {
                for t in a..<b where turns[t].replacedBy == nil {
                    turns[t].rewound = true
                    turns[t].replacedBy = b
                }
            }
        }
    }

    private func toolRow(_ i: Int, turn: Int) -> TranscriptRow {
        TranscriptRow(id: "e\(i)", turn: turn, kind: .tool(i), filters: toolFilters(i))
    }

    private func toolFilters(_ i: Int) -> Set<TranscriptFilter> {
        guard case .tool(let inv) = events[i] else { return [.tools] }
        var f: Set<TranscriptFilter> = [.tools]
        if inv.isFileChange { f.insert(.edits) }
        if planPath(of: inv) != nil || inv.name == "EnterPlanMode" || inv.name == "ExitPlanMode" { f.insert(.plans) }
        if Self.taskTools.contains(inv.name) { f.insert(.tasks) }
        if inv.name == "AskUserQuestion" { f.insert(.questions) }
        if case .agent = inv.toolClass { f.insert(.subagents) }
        if case .skill = inv.toolClass { f.insert(.skills) }
        if inv.failed { f.insert(.errors) }
        let hooks = hooksByTool[inv.id] ?? []
        if !hooks.isEmpty { f.insert(.hooks) }
        if hooks.contains(where: { if case .hook(let h) = events[$0] { return h.isError } else { return false } }) {
            f.insert(.errors)
        }
        return f
    }

    private func messageFilters(_ m: UserMessage) -> Set<TranscriptFilter> {
        switch m.kind {
        case .prompt, .command, .commandOutput: return [.prompts]
        case .meta: return [.context]
        case .compactSummary: return [.system, .context]
        case .taskNotification:
            if let id = m.notification?.toolUseID, let ti = toolIndex[id], case .tool(let inv) = events[ti],
               case .agent = inv.toolClass { return [.subagents] }
            return [.system]
        case .peer: return [.subagents]
        }
    }

    // Tool ids → event index, and the hook / context events shown on a call rather than as rows.
    private var toolIndex: [String: Int] = [:]
    private var attachedHooks = Set<Int>()
    private var attachedContext = Set<Int>()

    private mutating func collectAttachments() {
        for (i, e) in events.enumerated() {
            guard case .tool(let inv) = e else { continue }
            toolIndex[inv.id] = i
            if case .agent = inv.toolClass, let agentID = inv.detail?["agentId"] as? String {
                agentCallByAgentID[agentID] = inv.id
            }
        }
        for (i, e) in events.enumerated() {
            switch e {
            case .hook(let h):
                // Tool hooks (PreToolUse/PostToolUse…) carry their call's id.
                if toolIndex[h.id] != nil {
                    hooksByTool[h.id, default: []].append(i)
                    attachedHooks.insert(i)
                }
            case .context(let c) where c.type == "read_truncation_notice":
                if let id = Self.toolUseID(ofContext: c, event: i, events: events), toolIndex[id] != nil {
                    contextByTool[id, default: []].append(i)
                    attachedContext.insert(i)
                }
            default: break
            }
        }
    }

    /// A read-truncation notice follows the Read it's about; the parser doesn't keep the
    /// attachment's toolUseID, so pair it with the nearest preceding Read.
    private static func toolUseID(ofContext c: ContextItem, event i: Int, events: [SessionEvent]) -> String? {
        var j = i - 1
        while j >= 0 {
            if case .tool(let inv) = events[j] { return inv.name == "Read" ? inv.id : nil }
            j -= 1
        }
        return nil
    }

    private mutating func collectTasks() {
        for (i, e) in events.enumerated() {
            guard case .tool(let inv) = e else { continue }
            switch inv.name {
            case "TaskList", "TodoWrite":
                lastTaskListEvent = i
            case "TaskCreate":
                if let id = Self.createdTaskID(inv), let subject = inv.input["subject"] as? String {
                    taskSubjects[id] = subject
                    if taskStatus[id] == nil { taskStatus[id] = "pending" }
                    if taskCreateEvent[id] == nil { taskCreateEvent[id] = i }
                }
            case "TaskUpdate":
                if let id = inv.input["taskId"] as? String, let st = Self.updateStatus(inv) {
                    taskStatus[id] = st
                }
            default: break
            }
        }
        // Spans: open on in_progress; close on the next in_progress of another task (just before
        // it) or on this task's completed/deleted (that update included); still open at the end.
        var openID: String?, openStart = 0
        func label(_ id: String) -> String {
            guard let s = taskSubjects[id] else { return "Task \(id)" }
            return s.hasPrefix("Task ") ? s : "Task \(id): \(s)"
        }
        func close(at end: Int) {
            guard let id = openID else { return }
            taskSpans.append(TranscriptTaskSpan(taskID: id, label: label(id), start: openStart, end: max(openStart, end)))
            openID = nil
        }
        for (i, e) in events.enumerated() {
            guard case .tool(let inv) = e, inv.name == "TaskUpdate",
                  let id = inv.input["taskId"] as? String, let st = Self.updateStatus(inv) else { continue }
            switch st {
            case "in_progress":
                if openID == id { continue }
                if openID != nil { close(at: i - 1) }
                openID = id; openStart = i
            case "completed", "deleted":
                if openID == id { close(at: i) }
            default: break
            }
        }
        if openID != nil { close(at: events.count - 1) }
    }

    /// The id a TaskCreate was given: its structured result, else the `#N` in its text.
    public static func createdTaskID(_ inv: ToolInvocation) -> String? {
        guard inv.name == "TaskCreate" else { return nil }
        return ((inv.detail?["task"] as? [String: Any])?["id"] as? String)
            ?? inv.resultText.flatMap(parseCreatedTaskId)
    }

    /// The first span of work on a task, if it was ever started.
    public func firstSpan(of taskID: String) -> TranscriptTaskSpan? {
        taskSpans.first { $0.taskID == taskID }
    }

    /// The status a TaskUpdate set: its input, else the structured change it reported.
    public static func updateStatus(_ inv: ToolInvocation) -> String? {
        (inv.input["status"] as? String)
            ?? ((inv.detail?["statusChange"] as? [String: Any])?["to"] as? String)
    }

    /// Plan-mode context: entering, leaving or re-entering it, or the plan file it carries.
    public static func isPlanContext(_ c: ContextItem) -> Bool {
        ["plan_mode", "plan_mode_exit", "plan_mode_reentry", "plan_file_reference"].contains(c.type)
    }

    /// What a row is on the timeline rail, if it is anything: where a turn starts, a file edit,
    /// a plan step, a question, a subagent, a skill, a task-list change, a compaction, a failure.
    /// Reads, searches, replies and injected context are the bulk of a session and get no mark.
    public func landmark(of row: TranscriptRow) -> TranscriptLandmark? {
        switch row.kind {
        case .turnHeader:
            guard turns.indices.contains(row.turn) else { return nil }
            switch turns[row.turn].opener {
            case .prompt: return .prompt
            case .command: return .command
            case .notification, .peer: return .report
            case .preamble: return nil
            }
        case .message(let i):
            guard case .userMessage(let m) = events[i] else { return nil }
            switch m.kind {
            case .prompt: return .prompt          // sent mid-turn (queued)
            case .command: return .command
            case .peer, .taskNotification: return .report
            default: return nil
            }
        case .tool(let i):
            guard case .tool(let inv) = events[i] else { return nil }
            if inv.failed { return .error }
            if planPath(of: inv) != nil || inv.name == "ExitPlanMode" || inv.name == "EnterPlanMode" { return .plan }
            if inv.name == "AskUserQuestion" { return .question }
            if inv.isFileChange { return .edit }
            switch inv.toolClass {
            case .agent: return .subagent
            case .skill: return .skill
            default: break
            }
            return ["TaskCreate", "TaskUpdate", "TodoWrite"].contains(inv.name) ? .task : nil
        case .toolRun(let members):
            return members.contains { if case .tool(let inv) = events[$0] { return inv.failed } else { return false } }
                ? .error : nil
        case .notice(let i):
            guard case .notice(let n) = events[i] else { return nil }
            if n.isError { return .error }
            if n.kind == .compaction { return .compaction }
            if n.kind == .modeChange, n.title.hasSuffix(": plan") || n.detail == "was plan" { return .plan }
            return nil
        case .hook(let i):
            guard case .hook(let h) = events[i] else { return nil }
            return h.isError ? .error : nil
        case .assistant, .thinking, .context, .systemPrompt, .attachment, .turnFooter:
            return nil
        }
    }

    /// The API calls a turn made, in order.
    public func apiCalls(in turn: TranscriptTurn) -> [TurnUsage] {
        guard let r = turn.eventRange else { return [] }
        return events[r].compactMap { if case .turnUsage(let u) = $0 { return u } else { return nil } }
    }

    // MARK: - Per-event facts

    public static func time(of e: SessionEvent) -> TimeInterval? {
        switch e {
        case .userMessage(let m): return m.time
        case .assistantText(let a): return a.time
        case .thinking(let t): return t.time
        case .tool(let inv): return inv.finishedAt ?? inv.startedAt
        case .hook(let h): return h.time
        case .context(let c): return c.time
        case .systemPrompt(let s): return s.time
        case .notice(let n): return n.time
        case .attachment(let a): return a.time
        case .turnUsage(let u): return u.time
        }
    }

    /// One line naming a turn by its opener.
    public static func label(_ m: UserMessage) -> String {
        switch m.kind {
        case .command:
            return [m.commandName, m.commandArgs].compactMap { $0 }.joined(separator: " ")
        case .taskNotification:
            return m.notification?.summary ?? "Background task finished"
        case .peer:
            return "Message from \(m.sender ?? "another agent")"
        default:
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return m.blocks.isEmpty ? "" : "Image" }
            let first = t.components(separatedBy: "\n").first ?? t
            return first.count > 140 ? String(first.prefix(140)) + "…" : first
        }
    }

    /// Everything a search should see in an event, lowercased. Long bodies are capped — a
    /// 200 KB Read result would otherwise dominate both memory and every keystroke.
    /// Per-event search text, computed when a search first needs it and kept. A reference type,
    /// so the (immutable) model's copies share one cache; locked, since a model is built off the
    /// main thread and searched on it.
    private final class SearchBlobs: @unchecked Sendable {
        private var blobs: [Int: String] = [:]
        private let lock = NSLock()

        func blob(_ i: Int, in events: [SessionEvent]) -> String {
            lock.lock(); defer { lock.unlock() }
            if let b = blobs[i] { return b }
            let b = events.indices.contains(i) ? TranscriptModel.searchText(events[i]) : ""
            blobs[i] = b
            return b
        }
    }

    static func searchText(_ e: SessionEvent) -> String {
        let cap = 20_000
        func c(_ s: String?) -> String? { s.map { $0.count > cap ? String($0.prefix(cap)) : $0 } }
        let parts: [String?]
        switch e {
        case .userMessage(let m):
            parts = [m.text, m.commandName, m.commandArgs, m.commandOutput, c(m.expansion),
                     m.notification?.summary, c(m.notification?.result)]
        case .assistantText(let a): parts = [a.text]
        case .thinking(let t): parts = [t.text]
        case .tool(let inv):
            parts = [inv.name, inv.displayName, inv.argSummary, c(inputText(inv.input)), c(inv.resultText),
                     c(inv.injectedContent), inv.completion?.summary, c(inv.completion?.result)]
        case .hook(let h): parts = [h.hookName, h.hookEvent, h.command, c(h.stdout), c(h.stderr), c(h.content)]
        case .context(let item):
            parts = [item.title, item.summary] + item.sections.flatMap { [$0.title, $0.subtitle, c($0.body)] }
        case .systemPrompt(let s): parts = ["system prompt"] + s.parts.map(c) + s.tools.map(\.name)
        case .notice(let n): parts = [n.title, n.detail]
        case .attachment(let a): parts = [a.type, c(inputText(a.fields))]
        case .turnUsage: parts = []
        }
        return parts.compactMap { $0 }.joined(separator: "\n").lowercased()
    }

    /// A tool input as plain `key: value` lines — searchable, and how the view lists parameters.
    public static func inputText(_ input: [String: Any]) -> String {
        input.keys.sorted().map { k in "\(k): \(plain(input[k] as Any))" }.joined(separator: "\n")
    }

    static func plain(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default:
            if JSONSerialization.isValidJSONObject(v),
               let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .prettyPrinted]),
               let s = String(data: d, encoding: .utf8) { return s }
            return String(describing: v)
        }
    }
}

// MARK: - Export

extension TranscriptModel {
    /// The conversation as Markdown — prompts, replies, one line per tool call and the system
    /// events that change the story (compactions, errors, interrupts, rewinds). For pasting into
    /// an issue, a review or a chat.
    public func markdown() -> String {
        var blocks: [String] = []
        var toolLines: [String] = []
        func flushTools() {
            if !toolLines.isEmpty { blocks.append(toolLines.joined(separator: "\n")); toolLines = [] }
        }
        let clock: (TimeInterval?) -> String = { t in
            guard let t else { return "" }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            return " · " + f.string(from: Date(timeIntervalSince1970: t))
        }
        if let title = metadata.aiTitle { blocks.append("# \(title)") }
        var lastSpeakerWasClaude = false
        for turn in turns {
            guard let range = turn.eventRange else { continue }
            if turn.rewound { flushTools(); blocks.append("> ↩︎ Rewound — the turn below was abandoned; the conversation continued from turn \(turn.replacedBy.map { turns[$0].number } ?? 0).") }
            for i in range {
                switch events[i] {
                case .userMessage(let m):
                    flushTools(); lastSpeakerWasClaude = false
                    switch m.kind {
                    case .prompt: blocks.append("## You\(clock(m.time))\n\n\(m.text)")
                    case .command:
                        blocks.append("`\([m.commandName, m.commandArgs].compactMap { $0 }.joined(separator: " "))`"
                                      + (m.commandOutput.map { " → \($0)" } ?? ""))
                    case .taskNotification: blocks.append("> 🔔 \(m.notification?.summary ?? "Background task finished")")
                    case .peer: blocks.append("> Report from a subagent:\n>\n" + m.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n"))
                    case .compactSummary: blocks.append("> Conversation continued from a compaction summary.")
                    case .commandOutput, .meta: continue
                    }
                case .assistantText(let a):
                    flushTools()
                    blocks.append((lastSpeakerWasClaude ? "" : "## Claude\(clock(a.time))\n\n") + a.text)
                    lastSpeakerWasClaude = true
                case .tool(let inv):
                    if !lastSpeakerWasClaude, toolLines.isEmpty {
                        blocks.append("## Claude\(clock(inv.startedAt))"); lastSpeakerWasClaude = true
                    }
                    var line = "- `\(inv.name)`"
                    let detail = Self.exportDetail(inv)
                    if !detail.isEmpty { line += " \(detail)" }
                    if inv.failed { line += " — **failed**" }
                    toolLines.append(line)
                case .notice(let n):
                    switch n.kind {
                    case .compaction, .apiError, .interrupted:
                        flushTools()
                        blocks.append("> \(n.kind == .apiError ? "⚠︎ " : "")\(n.title)")
                    default: continue
                    }
                default: continue
                }
            }
        }
        flushTools()
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func exportDetail(_ inv: ToolInvocation) -> String {
        func s(_ k: String) -> String? { (inv.input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let raw: String
        switch inv.name {
        case "Bash": raw = s("description") ?? s("command") ?? ""
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            raw = ((s("file_path") ?? s("notebook_path") ?? "") as NSString).lastPathComponent
        case "AskUserQuestion":
            // The exchange itself: each question and the answer it got.
            let answers = (inv.detail?["answers"] as? [String: String]) ?? inv.resultText.map(parseAskAnswers) ?? [:]
            return parseAskQuestions(inv.input).map { q in
                "“\(q.question)” → " + (answers[q.question].map { "**\($0)**" } ?? "(no answer)")
            }.joined(separator: "; ")
        default: raw = inv.argSummary
        }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}
