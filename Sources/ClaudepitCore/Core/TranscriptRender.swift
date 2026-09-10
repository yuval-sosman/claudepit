import Foundation

public enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bulletList([String])
    case orderedList([String])
    case code(language: String?, body: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
}

/// Line-based block splitter. Not full CommonMark — covers the common cases.
public func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    let lines = text.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var i = 0

    func isTableSep(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }
    func cells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // blank
        if trimmed.isEmpty { i += 1; continue }

        // fenced code
        if trimmed.hasPrefix("```") {
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var body: [String] = []
            i += 1
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                body.append(lines[i]); i += 1
            }
            if i < lines.count { i += 1 } // consume closing fence
            blocks.append(.code(language: lang.isEmpty ? nil : lang, body: body.joined(separator: "\n")))
            continue
        }

        // heading
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes <= 6 {
                let t = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: hashes, text: t)); i += 1; continue
            }
        }

        // blockquote
        if trimmed.hasPrefix(">") {
            var qs: [String] = []
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                qs.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            blocks.append(.quote(qs.joined(separator: "\n"))); continue
        }

        // table: current line has |, next line is a separator row
        if trimmed.contains("|"), i + 1 < lines.count, isTableSep(lines[i + 1]) {
            let header = cells(line)
            i += 2
            var rows: [[String]] = []
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).contains("|") {
                rows.append(cells(lines[i])); i += 1
            }
            blocks.append(.table(header: header, rows: rows)); continue
        }

        // unordered list
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            var items: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") else { break }
                items.append(String(t.dropFirst(2))); i += 1
            }
            blocks.append(.bulletList(items)); continue
        }

        // ordered list: "N. "
        if let dot = trimmed.firstIndex(of: "."),
           trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber),
           trimmed.index(after: dot) < trimmed.endIndex, trimmed[trimmed.index(after: dot)] == " " {
            var items: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard let d = t.firstIndex(of: "."),
                      t[t.startIndex..<d].allSatisfy(\.isNumber), !t[t.startIndex..<d].isEmpty,
                      t.index(after: d) < t.endIndex, t[t.index(after: d)] == " " else { break }
                items.append(String(t[t.index(t.index(after: d), offsetBy: 1)...])); i += 1
            }
            blocks.append(.orderedList(items)); continue
        }

        // paragraph: gather consecutive plain lines
        var para: [String] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            // stop at the start of any other block
            let isOrdered: Bool = {
                guard let d = t.firstIndex(of: "."), t.startIndex < d,
                      t[t.startIndex..<d].allSatisfy(\.isNumber),
                      t.index(after: d) < t.endIndex, t[t.index(after: d)] == " " else { return false }
                return true
            }()
            let isTableStart = t.contains("|") && i + 1 < lines.count && isTableSep(lines[i + 1])
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix(">")
                || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
                || isOrdered || isTableStart { break }
            para.append(lines[i]); i += 1
        }
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
    }
    return blocks
}

public struct DiffLine: Equatable {
    public enum Kind: Equatable { case add, remove, context, file, note }
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

public func diffLines(toolName: String, input: [String: Any]) -> [DiffLine] {
    func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
    let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
    var out: [DiffLine] = []
    if let path { out.append(DiffLine(kind: .file, text: path)) }

    func addEdit(old: String, new: String) {
        for l in lines(old) { out.append(DiffLine(kind: .remove, text: l)) }
        for l in lines(new) { out.append(DiffLine(kind: .add, text: l)) }
    }

    switch toolName {
    case "Edit":
        guard let o = input["old_string"] as? String, let n = input["new_string"] as? String else { return [] }
        addEdit(old: o, new: n)
    case "MultiEdit":
        guard let edits = input["edits"] as? [[String: Any]] else { return [] }
        for (idx, e) in edits.enumerated() {
            if idx > 0 { out.append(DiffLine(kind: .note, text: "—")) }
            addEdit(old: e["old_string"] as? String ?? "", new: e["new_string"] as? String ?? "")
        }
    case "Write":
        guard let c = input["content"] as? String else { return [] }
        for l in lines(c) { out.append(DiffLine(kind: .add, text: l)) }
    case "NotebookEdit":
        guard let c = input["new_source"] as? String else { return [] }
        for l in lines(c) { out.append(DiffLine(kind: .add, text: l)) }
    default:
        return []
    }
    return out
}

/// Convert raw unified `git diff` output into DiffLine rows for `DiffView`.
/// Drops file/index headers, maps @@ hunk headers to a `.note` separator, and
/// maps +/-/space lines to `.add`/`.remove`/`.context`.
public func diffLinesFromUnified(_ raw: String, path: String) -> [DiffLine] {
    var out: [DiffLine] = [DiffLine(kind: .file, text: path)]
    for line in raw.components(separatedBy: "\n") {
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ") || line.hasPrefix("similarity ")
            || line.hasPrefix("\\ No newline") {
            continue
        }
        if line.hasPrefix("@@") { out.append(DiffLine(kind: .note, text: "—")); continue }
        if line.hasPrefix("+") { out.append(DiffLine(kind: .add, text: String(line.dropFirst()))) }
        else if line.hasPrefix("-") { out.append(DiffLine(kind: .remove, text: String(line.dropFirst()))) }
        else if line.hasPrefix(" ") { out.append(DiffLine(kind: .context, text: String(line.dropFirst()))) }
        else if line.isEmpty { continue }
        else { out.append(DiffLine(kind: .context, text: line)) }
    }
    return out
}

public enum ResultKind: Equatable { case json, markdown, plain }

public func classifyResult(_ text: String) -> ResultKind {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("{") || t.hasPrefix("[") {
        if (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil { return .json }
    }
    let mdSignals = ["```", "\n# ", "\n## ", "\n- ", "\n* ", "\n| "]
    let probe = "\n" + t
    if t.hasPrefix("# ") || t.hasPrefix("- ") || t.hasPrefix("* ") || mdSignals.contains(where: { probe.contains($0) }) {
        return .markdown
    }
    return .plain
}

public struct HighlightTarget: Equatable {
    public let sectionRaw: String
    public let itemID: String
    public init(sectionRaw: String, itemID: String) { self.sectionRaw = sectionRaw; self.itemID = itemID }
}

public func deepLinkTarget(for toolClass: ToolClass,
                           skillIDs: Set<String>, agentIDs: Set<String>,
                           mcpServerIDs: Set<String>, commandIDs: Set<String>,
                           hookIDs: Set<String>) -> HighlightTarget? {
    switch toolClass {
    case .skill(let name):
        return skillIDs.contains(name) ? HighlightTarget(sectionRaw: "skills", itemID: name) : nil
    case .agent(let type):
        return agentIDs.contains(type) ? HighlightTarget(sectionRaw: "agents", itemID: type) : nil
    case .mcp(let server, _):
        return mcpServerIDs.contains(server) ? HighlightTarget(sectionRaw: "mcp", itemID: server) : nil
    case .builtin:
        return nil
    }
}

public struct TaskSpan: Equatable {
    public let taskId: String
    public let label: String
    public let startIndex: Int
    public let endIndex: Int      // inclusive
    public init(taskId: String, label: String, startIndex: Int, endIndex: Int) {
        self.taskId = taskId; self.label = label
        self.startIndex = startIndex; self.endIndex = endIndex
    }
}

/// Extract the numeric task id from a TaskCreate/TaskUpdate result string ("... #7 ...").
public func parseCreatedTaskId(_ resultText: String) -> String? {
    guard let hash = resultText.firstIndex(of: "#") else { return nil }
    let after = resultText[resultText.index(after: hash)...]
    let digits = after.prefix { $0.isNumber }
    return digits.isEmpty ? nil : String(digits)
}

/// Map task id → subject, from each TaskCreate's input.subject and its result id.
public func taskSubjects(_ events: [SessionEvent]) -> [String: String] {
    var out: [String: String] = [:]
    for e in events {
        guard case .tool(let inv) = e, inv.name == "TaskCreate" else { continue }
        guard let subject = inv.input["subject"] as? String,
              let result = inv.resultText, let id = parseCreatedTaskId(result) else { continue }
        out[id] = subject
    }
    return out
}

/// Derive flat task spans. Open on TaskUpdate(in_progress); close on the next
/// in_progress (different task) or this task's completed/deleted. Events outside
/// spans are ungrouped. Label = "Task <id>: <subject>" or "Task <id>" if unknown.
public func taskSpans(_ events: [SessionEvent]) -> [TaskSpan] {
    let subjects = taskSubjects(events)
    func label(_ id: String) -> String {
        if let s = subjects[id] { return s.hasPrefix("Task ") ? s : "Task \(id): \(s)" }
        return "Task \(id)"
    }
    var spans: [TaskSpan] = []
    var openID: String?
    var openStart = 0

    func closeOpen(at endIndex: Int) {
        guard let id = openID else { return }
        spans.append(TaskSpan(taskId: id, label: label(id), startIndex: openStart, endIndex: endIndex))
        openID = nil
    }

    for (i, e) in events.enumerated() {
        guard case .tool(let inv) = e, inv.name == "TaskUpdate",
              let taskId = inv.input["taskId"] as? String,
              let status = inv.input["status"] as? String else { continue }
        switch status {
        case "in_progress":
            if let cur = openID {
                if cur == taskId { break }          // same task, already open
                closeOpen(at: i - 1)                // switching tasks: close previous just before this
            }
            openID = taskId; openStart = i
        case "completed", "deleted":
            if openID == taskId { closeOpen(at: i) } // this update is the span's last event
        default:
            break
        }
    }
    if openID != nil { closeOpen(at: events.count - 1) }
    return spans
}

public struct AskOption: Equatable {
    public let label: String
    public let description: String
    public init(label: String, description: String) { self.label = label; self.description = description }
}

public struct AskQuestion: Equatable {
    public let header: String
    public let question: String
    public let multiSelect: Bool
    public let options: [AskOption]
    public init(header: String, question: String, multiSelect: Bool, options: [AskOption]) {
        self.header = header; self.question = question
        self.multiSelect = multiSelect; self.options = options
    }
}

public func parseAskQuestions(_ input: [String: Any]) -> [AskQuestion] {
    guard let qs = input["questions"] as? [[String: Any]] else { return [] }
    return qs.map { q in
        let opts = (q["options"] as? [[String: Any]] ?? []).map {
            AskOption(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
        }
        return AskQuestion(header: q["header"] as? String ?? "",
                           question: q["question"] as? String ?? "",
                           multiSelect: q["multiSelect"] as? Bool ?? false,
                           options: opts)
    }
}

/// Parse `"<question>"="<label>"` pairs out of the AskUserQuestion result text.
public func parseAskAnswers(_ resultText: String) -> [String: String] {
    var out: [String: String] = [:]
    let chars = Array(resultText)
    var i = 0
    // find sequences: "..."="..."
    while i < chars.count {
        guard chars[i] == "\"" else { i += 1; continue }
        // read quoted question
        var j = i + 1; var q = ""
        while j < chars.count, chars[j] != "\"" { q.append(chars[j]); j += 1 }
        guard j < chars.count else { break }
        // expect ="
        guard j + 2 < chars.count, chars[j + 1] == "=", chars[j + 2] == "\"" else { i = j + 1; continue }
        var k = j + 3; var a = ""
        while k < chars.count, chars[k] != "\"" { a.append(chars[k]); k += 1 }
        guard k < chars.count else { break }
        if !q.isEmpty { out[q] = a }
        i = k + 1
    }
    return out
}

public struct TimelineMarker: Equatable {
    public enum Kind: Equatable, CaseIterable { case user, task, subagent, skill, question, hook, tools, plan }
    public let index: Int
    public let kind: Kind
    public let label: String
    public init(index: Int, kind: Kind, label: String) {
        self.index = index; self.kind = kind; self.label = label
    }
}

/// Notable events for the timeline rail: user messages, TaskCreate, subagents,
/// skills, AskUserQuestion. High-frequency tools (Bash/Read/Edit/…) are excluded.
public func timelineMarkers(_ events: [SessionEvent]) -> [TimelineMarker] {
    func trim(_ s: String, _ n: Int = 60) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) : t
    }
    var out: [TimelineMarker] = []
    for (i, e) in events.enumerated() {
        switch e {
        case .userMessage(let blocks):
            if case .text(let t) = blocks.first, blocks.count == 1, commandChipLabel(t) != nil { break }
            let label = blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.first ?? ""
            out.append(TimelineMarker(index: i, kind: .user, label: trim(label)))
        case .tool(let inv):
            if inv.name == "TaskCreate" {
                let subj = (inv.input["subject"] as? String) ?? inv.argSummary
                out.append(TimelineMarker(index: i, kind: .task, label: trim(subj)))
            } else if inv.name == "AskUserQuestion" {
                let qs = parseAskQuestions(inv.input)
                out.append(TimelineMarker(index: i, kind: .question, label: trim(qs.first?.question ?? "Question")))
            } else {
                switch inv.toolClass {
                case .agent:
                    out.append(TimelineMarker(index: i, kind: .subagent, label: inv.displayName))
                case .skill:
                    out.append(TimelineMarker(index: i, kind: .skill, label: inv.displayName))
                default:
                    if inv.name == "Write",
                       let path = inv.input["file_path"] as? String,
                       path.hasPrefix(Paths.plansRoot.path + "/"),
                       path.hasSuffix(".md") {
                        let planName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                        out.append(TimelineMarker(index: i, kind: .plan, label: planName))
                    }
                }
            }
        case .hook(let h):
            out.append(TimelineMarker(index: i, kind: .hook, label: trim(h.hookName)))
        case .assistantText, .systemNote, .attachment, .turnUsage:
            break
        }
    }
    return out
}

/// If a user message is Claude Code command metadata (a slash-command invocation
/// or local-command wrapper), return a friendly one-line label; else nil.
public func commandChipLabel(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // slash command: <command-name>/clear</command-name> ...
    if let name = between(t, "<command-name>", "</command-name>") {
        let args = between(t, "<command-args>", "</command-args>")?.trimmingCharacters(in: .whitespaces) ?? ""
        return args.isEmpty ? "ran \(name)" : "ran \(name) \(args)"
    }
    // local command caveat / stdout wrappers → treat as a system-ish note
    if t.hasPrefix("<local-command-caveat>") || t.hasPrefix("<local-command-stdout>") {
        return "local command output"
    }
    return nil
}

private func between(_ s: String, _ open: String, _ close: String) -> String? {
    guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
    return String(s[a.upperBound..<b.lowerBound])
}

// MARK: - Session aggregate stats

public struct ModelStat {
    public let model: String
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, messages = 0
    public init(model: String) { self.model = model }
    var total: Int { input + output + cacheRead + cacheWrite }
}

public struct SessionStats {
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    public var userMessages = 0, assistantMessages = 0, toolCalls = 0
    public var topTools: [(label: String, count: Int)] = []
    public var perModel: [ModelStat] = []
    public var total: Int { input + output + cacheRead + cacheWrite }
    public init() {}
}

public func sessionStats(_ events: [SessionEvent]) -> SessionStats {
    var s = SessionStats()
    var models: [String: ModelStat] = [:]
    var tools: [ToolInvocation] = []
    for e in events {
        switch e {
        case .userMessage(let blocks):
            let t = blocks.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined(separator: "\n")
            if t.hasPrefix("<command-") || t.hasPrefix("<local-command-") { continue }
            s.userMessages += 1
        case .turnUsage(let u):
            s.assistantMessages += 1
            s.input += u.inputTokens; s.output += u.outputTokens
            s.cacheRead += u.cacheReadTokens; s.cacheWrite += u.cacheWriteTokens
            var m = models[u.model] ?? ModelStat(model: u.model)
            m.input += u.inputTokens; m.output += u.outputTokens
            m.cacheRead += u.cacheReadTokens; m.cacheWrite += u.cacheWriteTokens
            m.messages += 1
            models[u.model] = m
        case .tool(let inv):
            tools.append(inv)
        default:
            break
        }
    }
    s.toolCalls = tools.count
    s.topTools = ToolInvocation.counts(tools)
    s.perModel = models.values.sorted { $0.total > $1.total }
    return s
}

/// Collapse per-message usage into one summary per *response*: sum all consecutive
/// `.turnUsage` events since the last user message, keyed by the index of the LAST
/// turnUsage in that run. Render only those indices to show one line per response.
/// The summed model is the last message's model (the one that finished the response).
public func responseUsageSummaries(_ events: [SessionEvent]) -> [Int: TurnUsage] {
    var out: [Int: TurnUsage] = [:]
    var runOut = 0, runIn = 0, runCacheR = 0, runCacheW = 0
    var lastIdx = -1, lastModel = ""
    func flush() {
        guard lastIdx >= 0 else { return }
        out[lastIdx] = TurnUsage(inputTokens: runIn, outputTokens: runOut,
                                 cacheReadTokens: runCacheR, cacheWriteTokens: runCacheW,
                                 model: lastModel)
        runIn = 0; runOut = 0; runCacheR = 0; runCacheW = 0; lastIdx = -1
    }
    for (i, e) in events.enumerated() {
        switch e {
        case .turnUsage(let u):
            runIn += u.inputTokens; runOut += u.outputTokens
            runCacheR += u.cacheReadTokens; runCacheW += u.cacheWriteTokens
            lastIdx = i; lastModel = u.model
        case .userMessage:
            flush()   // a new user message ends the previous response
        default:
            break
        }
    }
    flush()
    return out
}
