import SwiftUI
import ClaudepitCore
import AppKit

/// One tool call: a line naming what it did and to what, with its outcome and time; opening it
/// shows the call's full record, laid out for that tool. A call about a plan carries Ask / Plans
/// links; a task's creation shows the task's status; the update that starts work on a task heads
/// that task's span.
struct ToolRowView: View {
    let inv: ToolInvocation
    let id: String
    /// The call's event index — what task spans are keyed on.
    let index: Int
    let model: TranscriptModel
    let actions: TranscriptActions
    @ObservedObject var expansion: TranscriptExpansion
    /// Inside an opened run: drawn a step in, no top spacing.
    var nested = false
    var jumpToEvent: (Int) -> Void = { _ in }

    var body: some View {
        let planPath = model.planPath(of: inv)
        let startsSpan = inv.name == "TaskUpdate" ? model.taskSpans.first { $0.start == index } : nil
        let style = rowStyle(isPlan: planPath != nil, span: startsSpan)
        DisclosureRow(icon: style.icon, tint: inv.failed ? TranscriptStyle.error : style.color,
                      // The page's "Edits" mode: a file change opens on its diff, the rest folds.
                      isExpanded: expansion.isExpanded(id, default: inv.isFileChange),
                      inset: planPath.map { AnyView(PlanQASlot(path: $0, id: id, actions: actions, expansion: expansion)) },
                      onToggle: { expansion.toggle(id) }) {
            if let span = startsSpan {
                TaskSpanTitle(span: span, color: style.color)
            } else {
                ToolTitle(inv: inv, model: model, link: actions.sectionLink(inv))
            }
        } trailing: {
            if let span = startsSpan {
                TaskSpanTrailing(span: span, model: model)
            } else {
                ToolTrailing(inv: inv, hooks: hooks)
            }
        } accessory: {
            accessory(planPath: planPath, startsSpan: startsSpan)
        } content: {
            ToolBody(inv: inv, id: id, model: model, actions: actions, expansion: expansion, hooks: hooks,
                     jumpToEvent: jumpToEvent)
        }
        .padding(.leading, nested ? 14 : 0)
        .overlay(alignment: .leading) {
            if nested { Rectangle().fill(TranscriptStyle.hairline).frame(width: 1).padding(.leading, 4) }
        }
    }

    @ViewBuilder private func accessory(planPath: String?, startsSpan: TranscriptTaskSpan?) -> some View {
        if let planPath {
            PlanLinks(path: planPath, id: id, actions: actions, expansion: expansion)
        } else if let span = startsSpan {
            if let list = model.lastTaskListEvent, list != index {
                RowLinkButton(title: "Task list", icon: "list.bullet.rectangle", tint: TranscriptStyle.task,
                              help: "Go to the session's latest task list") { jumpToEvent(list) }
            } else if let created = model.taskCreateEvent[span.taskID] {
                RowLinkButton(title: "Created", icon: "arrow.up", tint: TranscriptStyle.task,
                              help: "Go to where task #\(span.taskID) was created") { jumpToEvent(created) }
            }
        } else if let taskID = TranscriptModel.createdTaskID(inv), let span = model.firstSpan(of: taskID) {
            RowLinkButton(title: "#\(taskID)", icon: "arrow.right", tint: TranscriptStyle.task,
                          help: "Go to where Claude started task #\(taskID)") { jumpToEvent(span.start) }
        }
    }

    /// The tool's own glyph, except where the call means more: a plan write wears the plan's,
    /// a created task shows where that task ended up, and a task's start flags its span.
    private func rowStyle(isPlan: Bool, span: TranscriptTaskSpan?) -> (icon: String, color: Color) {
        if let span { return ("flag.fill", TranscriptStyle.spanColor(model.taskSpanIndex(span))) }
        if isPlan, inv.name != "ExitPlanMode" { return ("list.bullet.clipboard", TranscriptStyle.plan) }
        if let taskID = TranscriptModel.createdTaskID(inv) {
            switch model.taskStatus[taskID] {
            case "completed": return ("checkmark.circle.fill", TranscriptStyle.added)
            case "in_progress": return ("circle.dotted.circle", TranscriptStyle.task)
            case "deleted": return ("xmark.circle", Color.secondary)
            default: return ("circle", TranscriptStyle.task)
            }
        }
        if inv.name == "TaskUpdate", let st = TranscriptModel.updateStatus(inv) {
            switch st {
            case "completed": return ("checkmark.circle.fill", TranscriptStyle.added)
            case "deleted": return ("xmark.circle", Color.secondary)
            default: break
            }
        }
        return TranscriptStyle.toolStyle(inv)
    }

    private var hooks: [HookExecution] {
        (model.hooksByTool[inv.id] ?? []).compactMap { if case .hook(let h) = model.events[$0] { return h } else { return nil } }
    }
}

/// The title of the update that starts work on a task: the task, in its span's colour.
struct TaskSpanTitle: View {
    let span: TranscriptTaskSpan
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Text("Started").font(TranscriptStyle.rowDetail).foregroundStyle(.secondary)
            Text(span.label).font(TranscriptStyle.rowTitle).foregroundStyle(color)
        }
    }
}

/// How long the task's span ran, or that it is still running.
struct TaskSpanTrailing: View {
    let span: TranscriptTaskSpan
    let model: TranscriptModel

    var body: some View {
        let open = model.taskStatus[span.taskID] == "in_progress" && span.end == model.events.count - 1
        HStack(spacing: 6) {
            if open {
                TagPill(text: "in progress", color: TranscriptStyle.task)
            } else if let s = TranscriptModel.time(of: model.events[span.start]),
                      let e = TranscriptModel.time(of: model.events[span.end]), e > s {
                MetaText("took " + TranscriptFormat.duration(seconds: e - s))
            }
        }
        .help(TranscriptFormat.plural(span.end - span.start + 1, "event") + " in this task's span")
    }
}

/// A folded run of routine calls: how many, of what, how long, and whether any failed.
struct ToolRunRow: View {
    let members: [Int]
    let id: String
    let model: TranscriptModel
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        let calls = members.compactMap { i -> ToolInvocation? in
            if case .tool(let t) = model.events[i] { return t } else { return nil }
        }
        let failed = calls.filter(\.failed).count
        let open = expansion.isExpanded(id)
        DisclosureRow(icon: "square.stack.3d.down.right", tint: failed > 0 ? TranscriptStyle.error : Color(white: 0.6),
                      isExpanded: open, showsBody: false, onToggle: { expansion.toggle(id) }) {
            HStack(spacing: 7) {
                Text(TranscriptFormat.plural(calls.count, "tool call"))
                    .font(TranscriptStyle.rowTitle).layoutPriority(1)
                Text(Self.breakdown(calls)).font(TranscriptStyle.rowDetail).foregroundStyle(.secondary)
            }
        } trailing: {
            HStack(spacing: 6) {
                if failed > 0 { TagPill(text: "\(failed) failed", color: TranscriptStyle.error) }
                if let span = Self.span(calls) { MetaText(TranscriptFormat.duration(seconds: span)) }
            }
        } content: { EmptyView() }
        .help(calls.map { "\($0.name)  \($0.argSummary)" }.prefix(40).joined(separator: "\n"))
    }

    /// `Read ×4 · Grep ×2 · Bash`.
    static func breakdown(_ calls: [ToolInvocation]) -> String {
        var order: [String] = [], counts: [String: Int] = [:]
        for c in calls {
            let name: String
            if case .mcp(let server, _) = c.toolClass { name = server } else { name = c.name }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: " · ")
    }

    /// First call to last result.
    static func span(_ calls: [ToolInvocation]) -> TimeInterval? {
        guard let start = calls.compactMap(\.startedAt).min(),
              let end = calls.compactMap({ $0.finishedAt ?? $0.startedAt }).max(), end > start else { return nil }
        return end - start
    }
}

// MARK: - Title and trailing facts

struct ToolTitle: View {
    let inv: ToolInvocation
    let model: TranscriptModel
    var link: (() -> Void)? = nil

    var body: some View {
        let d = ToolSummary.detail(inv, model: model)
        let done = TranscriptModel.createdTaskID(inv).map { model.taskStatus[$0] == "completed" } ?? false
        HStack(spacing: 7) {
            if let link {
                Button(action: link) {
                    Text(ToolSummary.name(inv)).font(TranscriptStyle.rowTitle)
                        .foregroundStyle(Color.accentColor).underline()
                }
                .buttonStyle(.plain)
                .help("Show in its section")
                .layoutPriority(2)
            } else {
                Text(ToolSummary.name(inv)).font(TranscriptStyle.rowTitle).layoutPriority(2)
            }
            if !d.text.isEmpty {
                // Prose details can carry `code` spans; commands and paths are shown verbatim.
                Text(d.mono ? AttributedString(d.text) : InlineMarkdown.attributed(d.text))
                    .font(d.mono ? TranscriptStyle.mono : TranscriptStyle.rowDetail)
                    .foregroundStyle(d.emphasis && !done ? Color.primary.opacity(0.9) : Color.secondary)
                    .strikethrough(done, color: .secondary)
                    .truncationMode(d.mono ? .middle : .tail)
            }
        }
    }
}

struct ToolTrailing: View {
    let inv: ToolInvocation
    let hooks: [HookExecution]

    var body: some View {
        HStack(spacing: 6) {
            if let stat = ToolSummary.diffStat(inv), stat.added + stat.removed > 0 {
                HStack(spacing: 3) {
                    if stat.added > 0 { Text("+\(stat.added)").foregroundStyle(TranscriptStyle.added) }
                    if stat.removed > 0 { Text("−\(stat.removed)").foregroundStyle(TranscriptStyle.removed) }
                }
                .font(TranscriptStyle.meta)
            }
            if let count = ToolSummary.resultCount(inv) { MetaText(count) }
            if !inv.resultImages.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "photo").font(.system(size: 9))
                    if inv.resultImages.count > 1 { Text("\(inv.resultImages.count)") }
                }
                .font(TranscriptStyle.meta).foregroundStyle(.secondary)
            }
            if !hooks.isEmpty {
                let bad = hooks.contains(where: \.isError)
                HStack(spacing: 2) {
                    Image(systemName: "link").font(.system(size: 9, weight: .semibold))
                    Text("\(hooks.count)")
                }
                .font(TranscriptStyle.meta)
                .foregroundStyle(bad ? TranscriptStyle.error : TranscriptStyle.hook)
                .help(hooks.map { "\($0.hookName): \(HookDetail.summary($0))" }.joined(separator: "\n"))
            }
            status
            if let d = inv.duration { MetaText(TranscriptFormat.duration(seconds: d)) }
        }
    }

    @ViewBuilder private var status: some View {
        if let c = inv.completion {
            let bad = inv.failed
            TagPill(text: c.status.isEmpty ? "done" : c.status, color: bad ? TranscriptStyle.error : TranscriptStyle.added)
        } else if ToolSummary.isBackground(inv) {
            TagPill(text: "background", color: TranscriptStyle.agent)
        } else if inv.isError == true {
            TagPill(text: ToolSummary.isRejection(inv) ? "rejected" : "failed", color: TranscriptStyle.error)
        } else if inv.resultText == nil {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("running").font(TranscriptStyle.caption).foregroundStyle(.secondary)
            }
            .help("No result recorded yet — still running, or the session ended mid-call")
        }
    }
}

/// How each tool reads in one line.
enum ToolSummary {
    struct Detail { var text: String; var mono = false; var emphasis = false }

    static func name(_ inv: ToolInvocation) -> String {
        switch inv.toolClass {
        case .mcp(let server, let tool): return "\(server) · \(tool)"
        case .agent: return "Agent"
        case .skill: return "Skill"
        case .builtin: return inv.name
        }
    }

    static func str(_ inv: ToolInvocation, _ k: String) -> String? {
        guard let v = inv.input[k] as? String, !v.isEmpty else { return nil }
        return v
    }

    static func detail(_ inv: ToolInvocation, model: TranscriptModel) -> Detail {
        switch inv.toolClass {
        case .agent(let type):
            return Detail(text: [str(inv, "description"), type == "?" ? nil : type].compactMap { $0 }.joined(separator: " · "), emphasis: true)
        case .skill(let n):
            return Detail(text: [n, str(inv, "args")].compactMap { $0 }.joined(separator: "  "), mono: true, emphasis: true)
        case .mcp:
            return Detail(text: oneLine(inv.argSummary), mono: true)
        case .builtin: break
        }
        switch inv.name {
        case "Bash":
            if let d = str(inv, "description") { return Detail(text: d) }
            return Detail(text: commandLine(str(inv, "command") ?? ""), mono: true)
        case "Read", "NotebookRead":
            let path = str(inv, "file_path") ?? str(inv, "notebook_path") ?? ""
            var text = TranscriptFormat.fileName(path)
            if let range = readRange(inv) { text += "  " + range }
            return Detail(text: text, emphasis: true)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = str(inv, "file_path") ?? str(inv, "notebook_path") ?? ""
            let dir = (TranscriptFormat.path(path) as NSString).deletingLastPathComponent
            return Detail(text: TranscriptFormat.fileName(path) + (dir.isEmpty ? "" : "  \(dir)"), emphasis: true)
        case "Grep":
            var t = "“\(str(inv, "pattern") ?? "")”"
            if let p = str(inv, "path") { t += " in \(TranscriptFormat.path(p))" }
            if let g = str(inv, "glob") { t += " (\(g))" }
            return Detail(text: t, mono: true)
        case "Glob":
            return Detail(text: str(inv, "pattern") ?? "", mono: true)
        case "WebFetch":
            return Detail(text: str(inv, "url").map(shortURL) ?? "", mono: true)
        case "WebSearch":
            return Detail(text: str(inv, "query") ?? "")
        case "ToolSearch":
            return Detail(text: str(inv, "query") ?? "", mono: true)
        case "TaskCreate":
            let id = TranscriptModel.createdTaskID(inv).map { "#\($0)  " } ?? ""
            return Detail(text: id + (str(inv, "subject") ?? ""), emphasis: true)
        case "TaskUpdate":
            let id = str(inv, "taskId") ?? "?"
            let status = str(inv, "status")
                ?? ((inv.detail?["statusChange"] as? [String: Any])?["to"] as? String)
            let subject = model.taskSubjects[id].map { "  \($0)" } ?? ""
            return Detail(text: "#\(id)" + (status.map { " → \($0.replacingOccurrences(of: "_", with: " "))" } ?? "") + subject)
        case "TaskList":
            return Detail(text: "")
        case "TodoWrite":
            let todos = inv.input["todos"] as? [[String: Any]] ?? []
            let done = todos.filter { $0["status"] as? String == "completed" }.count
            let active = todos.first { $0["status"] as? String == "in_progress" }?["activeForm"] as? String
            return Detail(text: "\(done)/\(todos.count) done" + (active.map { " · \($0)" } ?? ""))
        case "AskUserQuestion":
            return Detail(text: parseAskQuestions(inv.input).first?.question ?? "", emphasis: true)
        case "ExitPlanMode":
            let plan = str(inv, "plan") ?? (inv.detail?["plan"] as? String) ?? ""
            let heading = plan.components(separatedBy: "\n").first { $0.hasPrefix("#") }
                .map { String($0.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            return Detail(text: heading ?? "plan ready for approval", emphasis: true)
        case "SendMessage":
            return Detail(text: [str(inv, "to"), str(inv, "message").map(oneLine)].compactMap { $0 }.joined(separator: ": "))
        default:
            return Detail(text: oneLine(inv.argSummary), mono: inv.argSummary.contains("/"))
        }
    }

    /// The line of a shell script that says what it does: `cd` prefixes skipped, the rest marked.
    static func commandLine(_ s: String) -> String {
        let steps = s.components(separatedBy: "\n")
            .flatMap { $0.components(separatedBy: " && ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let meaningful = steps.drop { $0.hasPrefix("cd ") || $0 == "cd" }
        guard let first = meaningful.first ?? steps.first else { return oneLine(s) }
        return meaningful.count > 1 ? first + "  …" : first
    }

    static func oneLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? s
    }

    static func shortURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return s }
        return host + u.path
    }

    /// `L120–180` or `lines 1–520 of 1,017`, from the input or the structured result.
    static func readRange(_ inv: ToolInvocation) -> String? {
        let file = inv.detail?["file"] as? [String: Any]
        if let start = file?["startLine"] as? Int, let n = file?["numLines"] as? Int, let total = file?["totalLines"] as? Int {
            if start == 1 && n >= total { return "\(total.formatted()) lines" }
            return "L\(start)–\(start + max(n, 1) - 1) of \(total.formatted())"
        }
        if let offset = inv.input["offset"] as? Int {
            let limit = inv.input["limit"] as? Int
            return limit.map { "L\(offset)–\(offset + $0 - 1)" } ?? "from L\(offset)"
        }
        return nil
    }

    static func patchLines(_ inv: ToolInvocation) -> [DiffLine]? {
        guard let hunks = inv.detail?["structuredPatch"] as? [[String: Any]], !hunks.isEmpty else { return nil }
        return diffLines(patch: hunks, path: str(inv, "file_path") ?? str(inv, "notebook_path"))
    }

    static func diffStat(_ inv: ToolInvocation) -> (added: Int, removed: Int)? {
        guard inv.isFileChange else { return nil }
        if let lines = patchLines(inv) { return ClaudepitCore.diffStat(lines) }
        if inv.name == "Write", let c = str(inv, "content") { return (c.components(separatedBy: "\n").count, 0) }
        return ClaudepitCore.diffStat(diffLines(toolName: inv.name, input: inv.input))
    }

    /// `14 files`, `36 matches` — for searches.
    static func resultCount(_ inv: ToolInvocation) -> String? {
        guard let d = inv.detail else { return nil }
        switch inv.name {
        case "Glob":
            if let n = d["numFiles"] as? Int { return TranscriptFormat.plural(n, "file") }
        case "Grep":
            if let mode = d["mode"] as? String, mode == "content", let n = d["numLines"] as? Int { return TranscriptFormat.plural(n, "line") }
            if let n = d["numFiles"] as? Int { return TranscriptFormat.plural(n, "file") }
        case "WebFetch":
            if let code = d["code"] as? Int { return "\(code)" }
        case "ToolSearch":
            if let m = d["matches"] as? [String] { return "loaded \(m.count)" }
        default: break
        }
        return nil
    }

    static func isBackground(_ inv: ToolInvocation) -> Bool {
        if inv.input["run_in_background"] as? Bool == true { return true }
        if inv.detail?["isAsync"] as? Bool == true || inv.detail?["backgroundTaskId"] != nil { return true }
        return false
    }

    static func isRejection(_ inv: ToolInvocation) -> Bool {
        guard let r = inv.resultText else { return false }
        return r.contains("user doesn't want to proceed") || r.contains("tool use was rejected")
            || r.contains("user denied") || r.contains("Permission to use")
    }
}
