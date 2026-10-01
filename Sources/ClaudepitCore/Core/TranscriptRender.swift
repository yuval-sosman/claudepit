import Foundation

public enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// A list, nested items included: one entry per item, each with its depth and marker.
    case list([MarkdownListItem])
    case code(language: String?, body: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    /// `---`, `***` or `___` on a line of its own.
    case rule
}

public struct MarkdownListItem: Equatable {
    public enum Marker: Equatable {
        case bullet
        /// The number as written, so a list interrupted by a sub-list keeps counting.
        case number(Int)
        /// `- [ ]` / `- [x]`.
        case task(checked: Bool)
    }
    public var level: Int
    public var marker: Marker
    public var text: String
    public init(level: Int = 0, marker: Marker, text: String) {
        self.level = level; self.marker = marker; self.text = text
    }
    public static func bullet(_ text: String, level: Int = 0) -> MarkdownListItem { .init(level: level, marker: .bullet, text: text) }
    public static func number(_ n: Int, _ text: String, level: Int = 0) -> MarkdownListItem { .init(level: level, marker: .number(n), text: text) }
}

/// A list-item line: its indentation depth, marker and text. nil for any other line.
private func listItem(_ line: String) -> MarkdownListItem? {
    let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    let t = line.trimmingCharacters(in: .whitespaces)
    let level = min(indent / 2, 6)
    if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
        var text = String(t.dropFirst(2))
        if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            let checked = !text.hasPrefix("[ ]")
            text = String(text.dropFirst(4))
            return MarkdownListItem(level: level, marker: .task(checked: checked), text: text)
        }
        return MarkdownListItem(level: level, marker: .bullet, text: text)
    }
    if let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), dot > t.startIndex,
       t[t.startIndex..<dot].allSatisfy(\.isNumber), t[t.startIndex..<dot].count <= 4,
       t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " ",
       let n = Int(t[t.startIndex..<dot]) {
        return MarkdownListItem(level: level, marker: .number(n), text: String(t[t.index(dot, offsetBy: 2)...]))
    }
    return nil
}

private func isRule(_ trimmed: String) -> Bool {
    let compact = trimmed.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
    return compact.allSatisfy { $0 == c }
}

/// Line-based block splitter. Not full CommonMark — covers what Claude writes: nested and
/// numbered lists, task lists, fences, tables, quotes, rules.
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
            // Strip the fence's own indentation from the body (a fence inside a list item).
            let fenceIndent = line.prefix { $0 == " " }.count
            var body: [String] = []
            i += 1
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var l = lines[i]
                let lead = l.prefix { $0 == " " }.count
                l.removeFirst(min(lead, fenceIndent))
                body.append(l); i += 1
            }
            if i < lines.count { i += 1 } // consume closing fence
            blocks.append(.code(language: lang.isEmpty ? nil : lang, body: body.joined(separator: "\n")))
            continue
        }

        // rule (before lists: `- - -` and `***` are rules, not items)
        if isRule(trimmed) { blocks.append(.rule); i += 1; continue }

        // heading
        if isHeading(trimmed) {
            let hashes = trimmed.prefix { $0 == "#" }.count
            let t = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
            blocks.append(.heading(level: hashes, text: t)); i += 1; continue
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

        // list: items at any depth; indented non-item lines continue the item above; a change
        // of marker kind at the top level starts a new list.
        if let first = listItem(line) {
            var items = [first]
            let baseIndent = first.level
            let ordered: Bool = { if case .number = first.marker { return true } else { return false } }()
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    // A blank line continues the list only if the next text belongs to it.
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    guard j < lines.count, let next = listItem(lines[j]),
                          next.level > baseIndent || isOrdered(next) == ordered else { break }
                    i = j; continue
                }
                if var item = listItem(l) {
                    item.level = max(0, item.level - baseIndent)
                    if item.level == 0 && isOrdered(item) != ordered { break }
                    items.append(item); i += 1; continue
                }
                // Indented continuation of the previous item (not a fence, rule or table).
                let indent = l.prefix { $0 == " " || $0 == "\t" }.count
                guard indent >= 2, !t.hasPrefix("```"), !t.hasPrefix("|"), !isRule(t) else { break }
                items[items.count - 1].text += "\n" + t
                i += 1
            }
            blocks.append(.list(items)); continue
        }

        // paragraph: gather consecutive plain lines
        var para: [String] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            let isTableStart = t.contains("|") && i + 1 < lines.count && isTableSep(lines[i + 1])
            // The first line is this paragraph's no matter what — every pass must consume one.
            if !para.isEmpty, t.isEmpty || isHeading(t) || t.hasPrefix("```") || t.hasPrefix(">")
                || listItem(lines[i]) != nil || isTableStart || isRule(t) { break }
            if para.isEmpty && t.isEmpty { break }
            para.append(lines[i]); i += 1
        }
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
    }
    return blocks
}

/// `# Title` … `###### Title`: one to six hashes, then a space or nothing.
private func isHeading(_ trimmed: String) -> Bool {
    let hashes = trimmed.prefix { $0 == "#" }.count
    guard hashes >= 1, hashes <= 6 else { return false }
    let rest = trimmed.dropFirst(hashes)
    return rest.isEmpty || rest.first == " "
}

private func isOrdered(_ item: MarkdownListItem) -> Bool {
    if case .number = item.marker { return true } else { return false }
}

public struct DiffLine: Equatable {
    public enum Kind: Equatable { case add, remove, context, file, note }
    public let kind: Kind
    public let text: String
    /// Line numbers in the old / new file, when the source had them (a structured patch).
    public var oldLine: Int?
    public var newLine: Int?
    public init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
        self.kind = kind; self.text = text; self.oldLine = oldLine; self.newLine = newLine
    }
}

/// Lines of an edit's `structuredPatch` — the CLI's real hunks, with context lines and line
/// numbers, which `diffLines(toolName:input:)` (old string vs new string) can't give.
public func diffLines(patch hunks: [[String: Any]], path: String?) -> [DiffLine] {
    var out: [DiffLine] = []
    if let path { out.append(DiffLine(kind: .file, text: path)) }
    for (h, hunk) in hunks.enumerated() {
        var old = hunk["oldStart"] as? Int ?? 1
        var new = hunk["newStart"] as? Int ?? 1
        if h > 0 { out.append(DiffLine(kind: .note, text: "⋯")) }
        for raw in hunk["lines"] as? [String] ?? [] {
            let body = String(raw.dropFirst())
            switch raw.first {
            case "+": out.append(DiffLine(kind: .add, text: body, newLine: new)); new += 1
            case "-": out.append(DiffLine(kind: .remove, text: body, oldLine: old)); old += 1
            case "\\": continue   // "\ No newline at end of file"
            default:
                out.append(DiffLine(kind: .context, text: body, oldLine: old, newLine: new))
                old += 1; new += 1
            }
        }
    }
    return out
}

/// Added and removed line counts — the `+12 −3` on an edit's row.
public func diffStat(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
    lines.reduce(into: (0, 0)) { acc, l in
        if l.kind == .add { acc.0 += 1 } else if l.kind == .remove { acc.1 += 1 }
    }
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

/// One line of a TaskList result.
public struct TaskListLine: Equatable, Sendable {
    public let id: String
    public let status: String
    public let subject: String
    public init(id: String, status: String, subject: String) {
        self.id = id; self.status = status; self.subject = subject
    }
}

/// TaskList's text, one task a line — `#1 [completed] Fix bugs` — read leniently: the id from
/// `#N`, an optional `[status]` (`in progress` normalised to `in_progress`), the rest the subject.
/// Lines without a `#N` (a heading, a blank) are skipped.
public func parseTaskListLines(_ text: String) -> [TaskListLine] {
    var out: [TaskListLine] = []
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let hash = line.firstIndex(of: "#") else { continue }
        let after = line[line.index(after: hash)...]
        let id = String(after.prefix { $0.isNumber })
        guard !id.isEmpty else { continue }
        var rest = String(after.drop { $0.isNumber }).trimmingCharacters(in: CharacterSet(charactersIn: " .:-"))
        var status = "pending"
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            status = String(rest[rest.index(after: rest.startIndex)..<close]).replacingOccurrences(of: " ", with: "_")
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        out.append(TaskListLine(id: id, status: status, subject: rest))
    }
    return out
}

/// Extract the numeric task id from a TaskCreate/TaskUpdate result string ("... #7 ...").
public func parseCreatedTaskId(_ resultText: String) -> String? {
    guard let hash = resultText.firstIndex(of: "#") else { return nil }
    let after = resultText[resultText.index(after: hash)...]
    let digits = after.prefix { $0.isNumber }
    return digits.isEmpty ? nil : String(digits)
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

// MARK: - Tool output helpers

/// Result lines under `root` rewritten relative to it — a search's matches, with the root said
/// once. Returns the root actually stripped, or nil when most lines aren't under it.
public func relativeLines(_ text: String, to root: String?) -> (text: String, root: String?) {
    guard let root, !root.isEmpty else { return (text, nil) }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    let lines = text.components(separatedBy: "\n")
    let under = lines.filter { $0.hasPrefix(prefix) }.count
    guard under > 0, under * 2 >= lines.filter({ !$0.isEmpty }).count else { return (text, nil) }
    return (lines.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }.joined(separator: "\n"), root)
}

/// A failed shell call's result, `Exit code N` then its output → (N, output). (nil, nil) when
/// the text doesn't start that way.
public func splitExitCode(_ text: String?) -> (code: Int?, output: String?) {
    guard let text, text.hasPrefix("Exit code ") else { return (nil, nil) }
    let first = text.prefix { $0 != "\n" }
    let code = Int(first.dropFirst("Exit code ".count).trimmingCharacters(in: .whitespaces))
    let rest = text.dropFirst(first.count).drop { $0 == "\n" }
    return (code, String(rest))
}

