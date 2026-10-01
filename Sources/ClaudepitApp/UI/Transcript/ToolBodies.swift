import SwiftUI
import ClaudepitCore
import AppKit

/// A tool call's expanded record, laid out for the tool: a terminal for Bash, numbered source for
/// Read, a real diff for edits, the prompt and report for a subagent, the loaded instructions for
/// a skill — and for anything else its parameters and result. Hooks that ran on the call, images
/// it returned and text injected on its behalf follow.
struct ToolBody: View {
    let inv: ToolInvocation
    let id: String
    let model: TranscriptModel
    let actions: TranscriptActions
    @ObservedObject var expansion: TranscriptExpansion
    let hooks: [HookExecution]
    var jumpToEvent: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            main
            if !inv.resultImages.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(inv.resultImages.enumerated()), id: \.offset) { _, img in
                        ImageThumb(image: NSImage(data: img.data), size: 160) { openTemp(img.data, ext: extForMediaType(img.mediaType)) }
                    }
                }
            }
            if let injected = inv.injectedContent, !isSkill {
                SectionLabel(text: "Injected with this call")
                FoldingMarkdown(text: injected, id: id + "/inj", expansion: expansion)
            }
            if !hooks.isEmpty {
                SectionLabel(text: hooks.count == 1 ? "Hook on this call" : "Hooks on this call", trailing: hooks.count > 1 ? "\(hooks.count)" : nil)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hooks.enumerated()), id: \.offset) { i, h in
                        HookRow(hook: h, id: "\(id)/h\(i)", expansion: expansion)
                    }
                }
                .padding(.leading, -24)
            }
            footer
        }
    }

    private var isSkill: Bool { if case .skill = inv.toolClass { return true } else { return false } }

    @ViewBuilder private var main: some View {
        switch inv.toolClass {
        case .agent: AgentBody(inv: inv, id: id, actions: actions, expansion: expansion)
        case .skill: SkillBody(inv: inv, id: id, expansion: expansion)
        case .mcp: GenericBody(inv: inv, id: id, expansion: expansion)
        case .builtin:
            switch inv.name {
            case "Bash": BashBody(inv: inv)
            case "Read", "NotebookRead": ReadBody(inv: inv)
            case "Edit", "MultiEdit", "Write", "NotebookEdit": EditBody(inv: inv)
            case "AskUserQuestion": AskBody(inv: inv)
            case "ExitPlanMode": PlanBody(inv: inv, id: id, expansion: expansion)
            case "WebSearch": WebSearchBody(inv: inv, id: id, expansion: expansion)
            case "WebFetch": WebFetchBody(inv: inv, id: id, expansion: expansion)
            case "ToolSearch": ToolSearchBody(inv: inv)
            case "Grep", "Glob": SearchBody(inv: inv, cwd: model.metadata.cwd)
            case "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TodoWrite":
                TaskBody(inv: inv, model: model, jumpToEvent: jumpToEvent)
            default: GenericBody(inv: inv, id: id, expansion: expansion)
            }
        }
    }

    /// When it ran, the call id, and the raw input / result to copy — the facts that let a
    /// reader line the call up with anything else or replay it.
    private var footer: some View {
        HStack(spacing: 10) {
            if let t = TranscriptFormat.clock(inv.startedAt) { Text("called \(t)") }
            if let d = inv.duration { Text("took \(TranscriptFormat.duration(seconds: d))") }
            Text(inv.id).textSelection(.enabled)
            Spacer(minLength: 8)
            FooterCopy(label: "input", text: HookDetail.pretty(Self.json(inv.input)))
            if let r = inv.resultText { FooterCopy(label: "result", text: r) }
        }
        .font(TranscriptStyle.monoSmall)
        .foregroundStyle(.quaternary)
    }

    static func json(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return TranscriptModel.inputText(obj) }
        return s
    }
}

/// A quiet "copy input" / "copy result" link in a call's footer.
private struct FooterCopy: View {
    let label: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "copied" : "copy \(label)", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(copied ? AnyShapeStyle(TranscriptStyle.added) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .help("Copy the call's \(label)")
    }
}

// MARK: - Shell

struct BashBody: View {
    let inv: ToolInvocation

    var body: some View {
        let d = inv.detail
        let command = inv.input["command"] as? String ?? ""
        // A failed command's result starts "Exit code N" — that's a fact for a tag, not output.
        let (exit, raw) = splitExitCode(inv.isError == true ? inv.resultText : nil)
        let stdout = (d?["stdout"] as? String) ?? (d == nil ? (raw ?? inv.resultText) : nil) ?? ""
        let stderr = (d?["stderr"] as? String) ?? ""
        VStack(alignment: .leading, spacing: 6) {
            TerminalView(command: command, stdout: stdout, stderr: stderr,
                         isError: inv.isError == true,
                         errorText: d == nil || !(stdout + stderr).isEmpty ? nil : ErrorText.clean(raw ?? inv.resultText ?? ""))
            let notes = bashNotes(d)
            if exit != nil || !notes.isEmpty {
                HStack(spacing: 8) {
                    if let exit { TagPill(text: "exit \(exit)", color: TranscriptStyle.error) }
                    ForEach(notes, id: \.self) { TagPill(text: $0) }
                }
            }
            if let c = inv.completion {
                SectionLabel(text: "Background result")
                Text(c.summary).font(TranscriptStyle.caption).foregroundStyle(.secondary)
                if let r = c.result { CodeBlockView(code: r, showHeader: false, foldAfter: 20) }
            }
        }
    }

    private func bashNotes(_ d: [String: Any]?) -> [String] {
        var out: [String] = []
        if let t = inv.input["timeout"] as? Int { out.append("timeout \(TranscriptFormat.duration(ms: t))") }
        if inv.input["run_in_background"] as? Bool == true { out.append("in background") }
        if let id = d?["backgroundTaskId"] as? String { out.append("task \(id)") }
        if d?["interrupted"] as? Bool == true { out.append("interrupted") }
        if let ms = d?["timedOutAfterMs"] as? Int { out.append("timed out after \(TranscriptFormat.duration(ms: ms))") }
        if let r = d?["returnCodeInterpretation"] as? String, !r.isEmpty { out.append(r) }
        if d?["dangerouslyDisableSandbox"] as? Bool == true { out.append("sandbox off") }
        if let p = d?["persistedOutputPath"] as? String { out.append("full output: \(TranscriptFormat.fileName(p))") }
        return out
    }
}

/// A terminal panel: the prompt line, then what the command printed, stderr in red.
struct TerminalView: View {
    let command: String
    let stdout: String
    let stderr: String
    var isError = false
    var errorText: String? = nil
    @State private var showAll = false
    @Environment(\.textHighlight) private var highlight

    private func marked(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        InlineMarkdown.mark(&attr, highlight)
        return attr
    }

    var body: some View {
        let out = stripANSI(stdout).trimmingCharacters(in: .newlines)
        let lines = out.components(separatedBy: "\n")
        let fold = !showAll && lines.count > 40
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Text("$").foregroundStyle(TranscriptStyle.shell).fontWeight(.bold)
                Text(CodeHighlight.attributed(command, language: "sh"))
                    .foregroundStyle(Color(white: 0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: command, help: "Copy command", size: 11)
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, out.isEmpty && stderr.isEmpty ? 9 : 6)
            if !out.isEmpty {
                ScrollView(.horizontal) {
                    Text(marked(fold ? lines.prefix(40).joined(separator: "\n") : out))
                        .foregroundStyle(Color(white: 0.72))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !stderr.isEmpty {
                Text(stripANSI(stderr).trimmingCharacters(in: .newlines))
                    .foregroundStyle(TranscriptStyle.error.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 9)
            }
            if let e = errorText, !e.isEmpty {
                Text(e)
                    .foregroundStyle(TranscriptStyle.error.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 9)
            }
            if lines.count > 40 {
                Button { showAll.toggle() } label: {
                    Text(showAll ? "Show less" : "Show all \(lines.count.formatted()) lines")
                        .font(TranscriptStyle.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(TranscriptStyle.codeHeader)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isError ? TranscriptStyle.error.opacity(0.4) : TranscriptStyle.hairline))
    }
}

// MARK: - Files

struct ReadBody: View {
    let inv: ToolInvocation

    var body: some View {
        let path = (inv.input["file_path"] as? String) ?? (inv.input["notebook_path"] as? String) ?? ""
        if inv.isError == true {
            ErrorText(text: inv.resultText ?? "Failed")
        } else if !inv.resultImages.isEmpty {
            EmptyView()   // the image shows below
        } else if let r = inv.resultText {
            let parsed = NumberedLines.parse(r)
            CodeBlockView(code: parsed?.code ?? r, language: CodeHighlight.language(forPath: path),
                          header: AnyView(PathLabel(path: path)),
                          lineNumbers: parsed?.numbers, foldAfter: 40)
        }
    }
}

/// `cat -n`-style output (`   12\tcode`, `12→code`) → the code and its line numbers.
enum NumberedLines {
    static func parse(_ text: String) -> (code: String, numbers: [Int])? {
        var numbers: [Int] = [], code: [String] = []
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else {
                // A trailing system note after the numbered body ends the file.
                if i > 0, line.isEmpty || line.hasPrefix("<") { break }
                return nil
            }
            var rest = trimmed.dropFirst(digits.count)
            if rest.first == "\t" { rest = rest.dropFirst() }
            else if rest.hasPrefix("→") { rest = rest.dropFirst() }
            else { return nil }
            numbers.append(n); code.append(String(rest))
        }
        return numbers.isEmpty ? nil : (code.joined(separator: "\n"), numbers)
    }
}

struct PathLabel: View {
    let path: String
    var body: some View {
        HStack(spacing: 6) {
            Text(TranscriptFormat.path(path))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            if FileManager.default.fileExists(atPath: path) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Image(systemName: Icon.openFile).font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the file")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: Icon.revealInFinder).font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            }
        }
    }
}

struct EditBody: View {
    let inv: ToolInvocation

    var body: some View {
        let path = (inv.input["file_path"] as? String) ?? (inv.input["notebook_path"] as? String) ?? ""
        let lang = CodeHighlight.language(forPath: path)
        let pills = inv.name == "Write" || inv.input["replace_all"] as? Bool == true
            || inv.detail?["userModified"] as? Bool == true
        VStack(alignment: .leading, spacing: 8) {
            if pills {
                HStack(spacing: 8) {
                    if inv.name == "Write" {
                        let created = (inv.detail?["type"] as? String) == "create"
                        TagPill(text: created ? "new file" : "overwritten", color: created ? TranscriptStyle.added : TranscriptStyle.edit)
                    }
                    if inv.input["replace_all"] as? Bool == true { TagPill(text: "replace all") }
                    if inv.detail?["userModified"] as? Bool == true { TagPill(text: "you edited the change", color: TranscriptStyle.warning) }
                }
            }
            if inv.isError == true {
                ErrorText(text: inv.resultText ?? "Failed")
            }
            if let patch = ToolSummary.patchLines(inv) {
                DiffView(lines: patch, isSwift: lang == "swift", isMarkdown: false,
                         language: lang == "swift" ? nil : lang, foldAfter: 120)
            } else if inv.name == "Write", let content = inv.input["content"] as? String {
                if path.hasSuffix(".md") {
                    DiffView(lines: diffLines(toolName: "Write", input: inv.input), isMarkdown: true, markdownScale: .compact)
                } else {
                    CodeBlockView(code: content, language: lang, header: AnyView(PathLabel(path: path)), firstLine: 1, foldAfter: 40)
                }
            } else {
                let lines = diffLines(toolName: inv.name, input: inv.input)
                if !lines.isEmpty {
                    DiffView(lines: lines, isSwift: lang == "swift", isMarkdown: false,
                             language: lang == "swift" ? nil : lang, foldAfter: 120)
                }
            }
        }
    }
}

// MARK: - Delegation

struct AgentBody: View {
    let inv: ToolInvocation
    let id: String
    let actions: TranscriptActions
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        let d = inv.detail
        let type: String = { if case .agent(let t) = inv.toolClass { return t } else { return "?" } }()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TagPill(text: type, color: TranscriptStyle.agent)
                if let m = (d?["resolvedModel"] as? String) ?? (inv.input["model"] as? String) {
                    TagPill(text: TranscriptFormat.model(m), color: ModelBadge.color(for: m))
                }
                if ToolSummary.isBackground(inv) { TagPill(text: "ran in background") }
                if let iso = inv.input["isolation"] as? String { TagPill(text: iso) }
                Spacer()
                if actions.hasSubagent(inv.id), let open = actions.openSubagent {
                    Button { open(inv.id) } label: {
                        Label("Open subagent transcript", systemImage: Icon.jump)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
            if let prompt = inv.input["prompt"] as? String {
                SectionLabel(text: "Prompt it was given")
                FoldingMarkdown(text: prompt, id: id + "/prompt", expansion: expansion, limit: 1_200)
                    .padding(10)
                    .background(TranscriptStyle.bodyBackground, in: RoundedRectangle(cornerRadius: 8))
            }
            let report = inv.completion?.result
                ?? (inv.detail?["status"] as? String == "async_launched" ? nil : inv.resultText)
            if let report {
                SectionLabel(text: "Report", trailing: inv.completion.map { $0.status })
                FoldingMarkdown(text: report, id: id + "/report", expansion: expansion, limit: 1_800)
            } else if inv.resultText != nil {
                Text(inv.completion == nil && ToolSummary.isBackground(inv)
                     ? "Launched in the background — its report arrives later as a notification."
                     : (inv.resultText ?? ""))
                    .font(TranscriptStyle.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SkillBody: View {
    let inv: ToolInvocation
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let args = inv.input["args"] as? String, !args.isEmpty {
                SectionLabel(text: "Arguments")
                Text(args).font(TranscriptStyle.mono).textSelection(.enabled)
            }
            if inv.isError == true { ErrorText(text: inv.resultText ?? "Failed") }
            if let body = inv.injectedContent {
                SectionLabel(text: "Instructions loaded into the conversation",
                             trailing: TranscriptFormat.plural(body.count, "character"))
                FoldingMarkdown(text: body, id: id + "/skill", expansion: expansion, limit: 1_600)
                    .padding(10)
                    .background(TranscriptStyle.bodyBackground, in: RoundedRectangle(cornerRadius: 8))
            } else if let r = inv.resultText {
                Text(r).font(TranscriptStyle.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Conversation tools

struct AskBody: View {
    let inv: ToolInvocation

    var body: some View {
        let questions = parseAskQuestions(inv.input)
        let answers = (inv.detail?["answers"] as? [String: String]) ?? inv.resultText.map(parseAskAnswers) ?? [:]
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                AskQuestionCard(q: q, answer: answers[q.question])
            }
            if questions.isEmpty { Text("No questions").font(.caption).italic().foregroundStyle(.secondary) }
            if inv.resultText == nil { Text("Waiting for an answer…").font(TranscriptStyle.caption).foregroundStyle(.secondary) }
            else if answers.isEmpty, let r = inv.resultText { Text(r).font(TranscriptStyle.caption).foregroundStyle(.secondary) }
        }
    }
}

/// One AskUserQuestion question: header, question, options — the chosen one marked, and a
/// typed-in answer shown when it matches no option.
struct AskQuestionCard: View {
    let q: AskQuestion
    let answer: String?

    var body: some View {
        let chosen = Set((answer ?? "").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !q.header.isEmpty {
                    Text(q.header.uppercased()).font(TranscriptStyle.sectionLabel).kerning(0.4)
                        .foregroundStyle(TranscriptStyle.question)
                }
                Text(q.multiSelect ? "choose any" : "choose one").font(TranscriptStyle.caption).foregroundStyle(.tertiary)
            }
            Text(InlineMarkdown.attributed(q.question)).font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                let isChosen = chosen.contains(opt.label)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isChosen ? (q.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill")
                                               : (q.multiSelect ? "square" : "circle"))
                        .foregroundStyle(isChosen ? TranscriptStyle.question : Color.secondary)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(InlineMarkdown.attributed(opt.label)).font(.system(size: 12, weight: isChosen ? .semibold : .regular))
                        if !opt.description.isEmpty {
                            Text(InlineMarkdown.attributed(opt.description)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(isChosen ? TranscriptStyle.question.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isChosen ? TranscriptStyle.question.opacity(0.5) : TranscriptStyle.hairline))
            }
            if let answer, !answer.isEmpty, !q.options.contains(where: { chosen.contains($0.label) }) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill").font(.system(size: 9)).foregroundStyle(TranscriptStyle.prompt)
                    Text(InlineMarkdown.attributed(answer)).font(.system(size: 12))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(TranscriptStyle.prompt.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }
}

struct PlanBody: View {
    let inv: ToolInvocation
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        let plan = (inv.input["plan"] as? String) ?? (inv.detail?["plan"] as? String) ?? ""
        let approved = inv.resultText?.lowercased().contains("approved") == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if inv.resultText == nil {
                    TagPill(text: "awaiting approval", color: TranscriptStyle.plan)
                } else if inv.isError == true {
                    TagPill(text: "not approved", color: TranscriptStyle.error)
                } else if approved {
                    TagPill(text: "approved", color: TranscriptStyle.added)
                }
                if let path = inv.detail?["filePath"] as? String { PathLabel(path: path) }
            }
            if !plan.isEmpty {
                FoldingMarkdown(text: plan, id: id + "/plan", expansion: expansion, limit: 2_400)
                    .padding(12)
                    .background(TranscriptStyle.plan.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TranscriptStyle.plan.opacity(0.25)))
            }
            if inv.isError == true, let r = inv.resultText {
                SectionLabel(text: "Your response")
                Text(r).font(.system(size: 12)).textSelection(.enabled)
            }
        }
    }
}

struct TaskBody: View {
    let inv: ToolInvocation
    let model: TranscriptModel
    var jumpToEvent: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch inv.name {
            case "TaskList":
                let tasks = parseTaskListLines(inv.resultText ?? "")
                if tasks.isEmpty {
                    Text(inv.resultText ?? "").font(TranscriptStyle.mono).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    ForEach(tasks, id: \.id) { t in taskLine(id: t.id, status: t.status, subject: t.subject) }
                }
            case "TodoWrite":
                let todos = inv.input["todos"] as? [[String: Any]] ?? []
                ForEach(Array(todos.enumerated()), id: \.offset) { _, t in
                    taskLine(id: nil, status: t["status"] as? String ?? "pending", subject: t["content"] as? String ?? "")
                }
            case "TaskCreate":
                if let d = inv.input["description"] as? String {
                    Text(InlineMarkdown.attributed(d)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let r = inv.resultText { Text(r).font(TranscriptStyle.caption).foregroundStyle(.tertiary) }
            default:
                ParameterList(input: inv.input)
                if let r = inv.resultText { Text(r).font(TranscriptStyle.caption).foregroundStyle(.tertiary) }
            }
        }
    }

    /// One task: a status glyph and the subject — a link to where the task was worked on (or
    /// created) when the transcript has that place.
    @ViewBuilder private func taskLine(id: String?, status: String, subject: String) -> some View {
        let target = id.flatMap { model.firstSpan(of: $0)?.start ?? model.taskCreateEvent[$0] }
        let line = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.icon(status)).font(.system(size: 10)).foregroundStyle(Self.color(status))
                .frame(width: 12)
            if let id { Text("#\(id)").font(TranscriptStyle.monoSmall).foregroundStyle(.tertiary) }
            Text(InlineMarkdown.attributed(subject)).font(.system(size: 12, weight: status == "in_progress" ? .semibold : .regular))
                .foregroundStyle(status == "completed" ? Color.secondary : Color.primary)
                .strikethrough(status == "completed", color: .secondary)
            if target != nil {
                Image(systemName: "arrow.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
        if let target {
            Button { jumpToEvent(target) } label: { line.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(model.firstSpan(of: id ?? "") != nil ? "Go to where Claude started this task" : "Go to where this task was created")
        } else {
            line
        }
    }

    static func icon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted.circle"
        case "deleted": return "xmark.circle"
        default: return "circle"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "completed": return TranscriptStyle.added
        case "in_progress": return TranscriptStyle.task
        default: return Color.secondary
        }
    }

}

// MARK: - Web and search

struct WebFetchBody: View {
    let inv: ToolInvocation
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        let d = inv.detail
        VStack(alignment: .leading, spacing: 8) {
            if let url = inv.input["url"] as? String, let u = URL(string: url) {
                Link(destination: u) {
                    Text(url).font(TranscriptStyle.mono).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                if let code = d?["code"] as? Int { TagPill(text: "\(code) \(d?["codeText"] as? String ?? "")", color: code < 400 ? TranscriptStyle.added : TranscriptStyle.error) }
                if let bytes = d?["bytes"] as? Int { TagPill(text: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
            }
            if let prompt = inv.input["prompt"] as? String {
                SectionLabel(text: "Asked of the page")
                Text(prompt).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if inv.isError == true { ErrorText(text: inv.resultText ?? "Failed") }
            else if let r = (d?["result"] as? String) ?? inv.resultText {
                SectionLabel(text: "Result")
                FoldingMarkdown(text: r, id: id + "/r", expansion: expansion)
            }
        }
    }
}

struct WebSearchBody: View {
    let inv: ToolInvocation
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        let links = Self.links(inv.detail)
        VStack(alignment: .leading, spacing: 8) {
            if !links.isEmpty {
                SectionLabel(text: "Results", trailing: "\(links.count)")
                ForEach(Array(links.prefix(12).enumerated()), id: \.offset) { _, l in
                    if let u = URL(string: l.url) {
                        Link(destination: u) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(ToolSummary.shortURL(l.url)).font(TranscriptStyle.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if inv.isError == true { ErrorText(text: inv.resultText ?? "Failed") }
            else if let r = inv.resultText {
                SectionLabel(text: "Summary")
                FoldingMarkdown(text: r, id: id + "/r", expansion: expansion)
            }
        }
    }

    static func links(_ d: [String: Any]?) -> [(title: String, url: String)] {
        guard let results = d?["results"] as? [Any] else { return [] }
        var out: [(String, String)] = []
        for r in results {
            guard let entry = r as? [String: Any], let content = entry["content"] as? [[String: Any]] else { continue }
            for c in content { if let url = c["url"] as? String { out.append((c["title"] as? String ?? url, url)) } }
        }
        return out
    }
}

/// Grep / Glob: what was searched for, where, and the matches — relative to the search root,
/// which is said once instead of on every line.
struct SearchBody: View {
    let inv: ToolInvocation
    let cwd: String?

    var body: some View {
        let root = (inv.input["path"] as? String) ?? cwd
        let options: [String] = [
            (inv.input["glob"] as? String).map { "glob \($0)" },
            (inv.input["type"] as? String).map { "type \($0)" },
            (inv.input["output_mode"] as? String).map { $0.replacingOccurrences(of: "_", with: " ") },
            inv.input["-i"] as? Bool == true ? "ignore case" : nil,
            inv.input["multiline"] as? Bool == true ? "multiline" : nil,
            (inv.input["head_limit"] as? Int).map { "first \($0)" },
        ].compactMap { $0 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(inv.input["pattern"] as? String ?? "")
                    .font(TranscriptStyle.mono)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(TranscriptStyle.read.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    .textSelection(.enabled)
                ForEach(options, id: \.self) { TagPill(text: $0) }
            }
            if inv.isError == true {
                ErrorText(text: inv.resultText ?? "Failed")
            } else if let r = inv.resultText {
                let (text, stripped) = relativeLines(r, to: root)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No matches").font(TranscriptStyle.caption).foregroundStyle(.secondary)
                } else {
                    CodeBlockView(code: text,
                                  header: AnyView(HStack(spacing: 5) {
                                      Image(systemName: "folder").font(.system(size: 10))
                                      Text(stripped.map(TranscriptFormat.path) ?? "results")
                                          .font(.system(size: 11, weight: .medium, design: .monospaced))
                                          .lineLimit(1).truncationMode(.head)
                                  }.foregroundStyle(.secondary)),
                                  foldAfter: 30)
                }
            }
        }
    }

}

struct ToolSearchBody: View {
    let inv: ToolInvocation

    var body: some View {
        let names = (inv.detail?["matches"] as? [String])
            ?? (inv.resultText ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: names.isEmpty ? "No tools matched" : "Tools loaded", trailing: names.isEmpty ? nil : "\(names.count)")
            FlowLayout(spacing: 4) {
                ForEach(names, id: \.self) { n in
                    Text(n).font(TranscriptStyle.monoSmall)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

// MARK: - Anything else

struct GenericBody: View {
    let inv: ToolInvocation
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !inv.input.isEmpty {
                SectionLabel(text: "Parameters")
                ParameterList(input: inv.input)
            }
            ResultView(inv: inv, id: id, expansion: expansion)
        }
    }
}

/// A tool's result, rendered by what it looks like: JSON pretty-printed, markdown rendered,
/// anything else as monospaced text.
struct ResultView: View {
    let inv: ToolInvocation
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        if let r = inv.resultText {
            SectionLabel(text: inv.isError == true ? "Error" : "Result")
            if inv.isError == true {
                ErrorText(text: r)
            } else if r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("(empty)").font(TranscriptStyle.caption).foregroundStyle(.tertiary)
            } else {
                switch classifyResult(String(r.prefix(20_000))) {
                case .json: CodeBlockView(code: HookDetail.pretty(r.trimmingCharacters(in: .whitespacesAndNewlines)), language: "json", showHeader: false, foldAfter: 30)
                case .markdown: FoldingMarkdown(text: r, id: id + "/res", expansion: expansion)
                case .plain: CodeBlockView(code: r, showHeader: false, foldAfter: 30, wrap: Self.isProse(r))
                }
            }
        } else if inv.completion == nil {
            Text("No result recorded").font(TranscriptStyle.caption).italic().foregroundStyle(.tertiary)
        }
        if let c = inv.completion {
            SectionLabel(text: "Completed", trailing: c.status)
            Text(c.summary).font(TranscriptStyle.caption).foregroundStyle(.secondary)
            if let r = c.result { FoldingMarkdown(text: r, id: id + "/done", expansion: expansion) }
        }
    }
}

extension ResultView {
    /// Sentences rather than output: no tabs, no column alignment, no indented lines — wrap it
    /// instead of scrolling it sideways.
    static func isProse(_ s: String) -> Bool {
        if s.contains("\t") || s.contains("   ") { return false }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        let indented = lines.filter { $0.first == " " }.count
        return indented * 4 < max(lines.count, 1)
    }
}

/// Parameters as `name  value` lines; long or multi-line values fold into a code block.
struct ParameterList: View {
    let input: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(input.keys.sorted(), id: \.self) { key in
                let value = TranscriptModel.inputText([key: input[key] as Any])
                    .dropFirst(key.count + 2)
                if value.contains("\n") || value.count > 160 {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key).font(TranscriptStyle.caption).foregroundStyle(.secondary)
                        CodeBlockView(code: String(value), language: value.hasPrefix("{") || value.hasPrefix("[") ? "json" : nil,
                                      showHeader: false, foldAfter: 12)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(key).font(TranscriptStyle.caption).foregroundStyle(.secondary)
                            .frame(minWidth: 70, alignment: .leading)
                        Text(String(value)).font(TranscriptStyle.mono).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct ErrorText: View {
    let text: String

    /// The CLI wraps validation failures in `<tool_use_error>` — the message is what's inside.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Text(Self.clean(text))
            .font(TranscriptStyle.mono)
            .foregroundStyle(TranscriptStyle.error)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(TranscriptStyle.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TranscriptStyle.error.opacity(0.25)))
    }
}
