import SwiftUI
import ClaudepitCore
import AppKit

/// Routes a display row to its view.
struct TranscriptRowView: View {
    let row: TranscriptRow
    let model: TranscriptModel
    let actions: TranscriptActions
    @ObservedObject var expansion: TranscriptExpansion
    var isFirstResponse = false
    var isFiltered = false
    var highlight = ""
    var jumpToTool: (String) -> Void = { _ in }
    var jumpToEvent: (Int) -> Void = { _ in }

    /// A row only renders against the model it was computed for; one that points past this
    /// model's end (a rewritten file, mid-update) draws nothing rather than trapping.
    private var fitsModel: Bool {
        model.turns.indices.contains(row.turn) && row.eventIndices.allSatisfy { model.events.indices.contains($0) }
    }

    var body: some View {
        if fitsModel {
            content
                .environment(\.textHighlight, highlight)
                .overlay(alignment: .leading) { spanBar }
                // A branch the person rewound away from: still shown, since it happened, but faded.
                .opacity(model.turns[row.turn].rewound && row.kind != .turnHeader ? 0.5 : 1)
        }
    }

    /// A bar down the leading edge of every row inside a task's span, in the span's colour —
    /// so what Claude did for each task-list item reads as one stretch.
    @ViewBuilder private var spanBar: some View {
        if row.kind != .turnHeader, row.kind != .turnFooter, let first = row.eventIndices.first,
           let span = model.taskSpan(containing: first) {
            RoundedRectangle(cornerRadius: 1.25)
                .fill(TranscriptStyle.spanColor(model.taskSpanIndex(span)).opacity(0.55))
                .frame(width: 2.5)
                .padding(.vertical, -1)   // across the list's row spacing, so a span reads as one bar
                .help(span.label)
        }
    }

    @ViewBuilder private var content: some View {
        switch row.kind {
        case .turnHeader:
            TurnHeaderView(turn: model.turns[row.turn], model: model, rowID: row.id,
                           expansion: expansion, isFiltered: isFiltered, jumpToTool: jumpToTool)
        case .turnFooter:
            TurnFooterView(turn: model.turns[row.turn], model: model, id: row.id, expansion: expansion)
        case .assistant(let i):
            if case .assistantText(let a) = model.events[i] {
                AssistantRow(text: a, showLabel: isFirstResponse)
            }
        case .thinking(let indices):
            ThinkingRow(blocks: indices.compactMap { if case .thinking(let t) = model.events[$0] { return t } else { return nil } },
                        id: row.id, expansion: expansion)
        case .message(let i):
            if case .userMessage(let m) = model.events[i] {
                MessageRow(message: m, id: row.id, model: model, expansion: expansion, jumpToTool: jumpToTool)
            }
        case .tool(let i):
            if case .tool(let inv) = model.events[i] {
                ToolRowView(inv: inv, id: row.id, index: i, model: model, actions: actions, expansion: expansion,
                            nested: !isFiltered && model.runID(containing: i) != nil, jumpToEvent: jumpToEvent)
            }
        case .toolRun(let members):
            ToolRunRow(members: members, id: row.id, model: model, expansion: expansion)
        case .context(let indices):
            ContextRow(items: indices.compactMap { if case .context(let c) = model.events[$0] { return c } else { return nil } },
                       id: row.id, actions: actions, expansion: expansion)
        case .systemPrompt(let i):
            if case .systemPrompt(let s) = model.events[i] {
                SystemPromptRow(snapshot: s, id: row.id, expansion: expansion)
            }
        case .hook(let i):
            if case .hook(let h) = model.events[i] {
                HookRow(hook: h, id: row.id, expansion: expansion)
            }
        case .notice(let i):
            if case .notice(let n) = model.events[i] {
                NoticeRow(notice: n, id: row.id, expansion: expansion)
            }
        case .attachment(let i):
            if case .attachment(let a) = model.events[i] {
                RawAttachmentRow(attachment: a, id: row.id, expansion: expansion)
            }
        }
    }
}

// MARK: - Shared row layout

/// One line that opens into a body: glyph, title, trailing facts, chevron. The whole line is the
/// hit target; the body sits under the title so text lines up down the page.
struct DisclosureRow<Title: View, Trailing: View, Accessory: View, Content: View>: View {
    let icon: String
    let tint: Color
    let isExpanded: Bool
    var isEnabled = true
    /// False for a row whose "body" is other rows (a tool run): the chevron turns, nothing draws.
    var showsBody = true
    /// A panel an accessory opened (a plan's Q&A), drawn right under the title line whether the
    /// row is open or not — next to the control that opened it, never below a long body.
    var inset: AnyView? = nil
    let onToggle: () -> Void
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing
    /// Controls that act on their own — open the plan, jump to a task. They sit outside the
    /// toggle, so clicking one never opens or folds the row.
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tint)
                            .frame(width: 16)
                        title()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        trailing()
                    }
                    // The row's padding is part of the hit target, as it was when the whole
                    // line was one button.
                    .padding(.leading, 6).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                accessory()
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(isEnabled ? (hover || isExpanded ? 1 : 0.45) : 0)
                        .frame(width: 10, height: 16)
                        .padding(.trailing, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
            .background(hover && isEnabled ? TranscriptStyle.rowHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            if let inset { inset }
            if isExpanded && showsBody {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30).padding(.trailing, 6).padding(.top, 2).padding(.bottom, 8)
            }
        }
    }
}

extension DisclosureRow where Accessory == EmptyView {
    init(icon: String, tint: Color, isExpanded: Bool, isEnabled: Bool = true, showsBody: Bool = true,
         onToggle: @escaping () -> Void,
         @ViewBuilder title: @escaping () -> Title,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(icon: icon, tint: tint, isExpanded: isExpanded, isEnabled: isEnabled, showsBody: showsBody,
                  onToggle: onToggle, title: title, trailing: trailing, accessory: { EmptyView() }, content: content)
    }
}

/// A title and a dimmer detail on one line, the detail giving way first.
struct RowTitle: View {
    let title: String
    var detail: String? = nil
    var mono = false
    var titleColor: Color = .primary

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(TranscriptStyle.rowTitle)
                .foregroundStyle(titleColor)
                .layoutPriority(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(mono ? TranscriptStyle.mono : TranscriptStyle.rowDetail)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Small uppercase label over a block inside an expanded row.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(TranscriptStyle.sectionLabel)
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            if let trailing {
                Text(trailing).font(TranscriptStyle.meta).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A trailing fact: duration, count, status.
struct MetaText: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(TranscriptStyle.meta).foregroundStyle(color.opacity(0.85)).lineLimit(1).fixedSize()
    }
}

/// A capsule tag (`background`, `as user`, `failed`) — smaller and quieter than `Pill`.
struct TagPill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// Text that folds after a number of characters, for prompts and reports that run long.
struct FoldingMarkdown: View {
    let text: String
    let id: String
    @ObservedObject var expansion: TranscriptExpansion
    var limit = 1_400
    var mono = false

    var body: some View {
        let long = text.count > limit + 200
        let open = !long || expansion.isExpanded(id + "/more")
        VStack(alignment: .leading, spacing: 6) {
            let shown = open ? text : Self.cut(text, limit)
            if mono {
                Text(shown).font(TranscriptStyle.mono).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownText(shown, scale: .compact)
            }
            if long {
                Button { expansion.toggle(id + "/more") } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        Text(open ? "Show less" : "Show all (\(TranscriptFormat.plural(text.count, "character")))")
                    }
                    .font(TranscriptStyle.caption)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cut at a paragraph or line break near the limit, never inside a code fence's line.
    static func cut(_ s: String, _ limit: Int) -> String {
        let head = String(s.prefix(limit))
        if let r = head.range(of: "\n\n", options: .backwards), head.distance(from: head.startIndex, to: r.lowerBound) > limit / 2 {
            return String(head[..<r.lowerBound]) + "\n\n…"
        }
        if let r = head.range(of: "\n", options: .backwards), head.distance(from: head.startIndex, to: r.lowerBound) > limit / 2 {
            return String(head[..<r.lowerBound]) + "\n…"
        }
        return head + "…"
    }
}

// MARK: - Turn header

struct TurnHeaderView: View {
    let turn: TranscriptTurn
    let model: TranscriptModel
    let rowID: String
    @ObservedObject var expansion: TranscriptExpansion
    var isFiltered = false
    var jumpToTool: (String) -> Void = { _ in }

    private var message: UserMessage? {
        guard let i = turn.promptIndex, case .userMessage(let m) = model.events[i] else { return nil }
        return m
    }

    /// Time since the previous turn ended, when it's long enough to be worth saying.
    private var gap: (seconds: TimeInterval, newDay: Bool)? {
        guard turn.index > 0, let start = turn.startTime,
              let end = model.turns[turn.index - 1].endTime, start - end > 600 else { return nil }
        let cal = Calendar.current
        let newDay = !cal.isDate(Date(timeIntervalSince1970: start), inSameDayAs: Date(timeIntervalSince1970: end))
        return (start - end, newDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let gap, !isFiltered { gapLine(gap) }
            if turn.rewound { rewoundNote }
            header.opacity(turn.rewound ? 0.6 : 1)
        }
        .padding(.top, turn.index == 0 ? 0 : (isFiltered ? 8 : 14))
        .padding(.bottom, 4)
    }

    /// Says why this turn is faded and where the conversation went instead.
    private var rewoundNote: some View {
        let target = turn.replacedBy.map { model.turns[$0].number }
        return HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 9.5, weight: .semibold))
            Text("Rewound").font(.system(size: 11, weight: .semibold))
            Text(target.map { "— you went back and sent turn #\($0) instead; Claude never saw what follows here" }
                 ?? "— you went back and resent from an earlier point")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(TranscriptStyle.warning)
        .padding(.horizontal, 6)
        .help("This turn is on a branch the conversation left: its prompt was edited or resent from the same point")
    }

    private func gapLine(_ gap: (seconds: TimeInterval, newDay: Bool)) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(TranscriptStyle.hairline).frame(width: 18, height: 1)
            HStack(spacing: 4) {
                Image(systemName: "hourglass").font(.system(size: 9))
                Text(Elapsed.short(gap.seconds) + " later")
                if gap.newDay, let day = turn.startTime.map({ Date(timeIntervalSince1970: $0) }) {
                    Text("· " + day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                }
            }
            .font(TranscriptStyle.meta)
            .foregroundStyle(.tertiary)
            .fixedSize()
            Rectangle().fill(TranscriptStyle.hairline).frame(height: 1)
        }
        .padding(.horizontal, 6)
        .help("Nothing happened in the session for this long before this turn")
    }

    @ViewBuilder private var header: some View {
        Group {
            switch turn.opener {
            case .preamble: preamble
            case .prompt:
                if let m = message {
                    PromptBubble(message: m, turn: turn, id: rowID, expansion: expansion,
                                 fromParent: model.metadata.isSidechain)
                }
            case .command: if let m = message { CommandRow(message: m, id: rowID, expansion: expansion) }
            case .notification: if let m = message { NotificationLine(message: m, id: rowID, model: model, expansion: expansion, jumpToTool: jumpToTool) }
            case .peer: if let m = message { PeerMessage(message: m, id: rowID, model: model, expansion: expansion, jumpToTool: jumpToTool) }
            }
        }
    }

    private var preamble: some View {
        HStack(spacing: 6) {
            Image(systemName: "flag").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text("Session start").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if let t = TranscriptFormat.dayClock(turn.startTime) {
                Text(t).font(TranscriptStyle.meta).foregroundStyle(.tertiary)
            }
            Rectangle().fill(TranscriptStyle.hairline).frame(height: 1)
        }
        .padding(.horizontal, 6).padding(.top, 2)
    }
}

/// What the person typed: the one element on the page with a filled background.
struct PromptBubble: View {
    let message: UserMessage
    let turn: TranscriptTurn?
    let id: String
    @ObservedObject var expansion: TranscriptExpansion
    var queued = false
    /// In a subagent's transcript the prompt is the task its parent session handed it.
    var fromParent = false
    @State private var hover = false

    private var tint: Color { fromParent ? TranscriptStyle.agent : TranscriptStyle.prompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: fromParent ? "person.2.fill" : "person.fill").font(.system(size: 9))
                Text(fromParent ? "Task from the main session" : "You").font(.system(size: 11, weight: .semibold))
                if queued {
                    Text("· sent while Claude was working").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let t = TranscriptFormat.clock(message.time) {
                    Text(t).font(TranscriptStyle.meta).foregroundStyle(Color.secondary)
                        .help(TranscriptFormat.dayClock(message.time) ?? "")
                }
                if let turn {
                    Text("#\(turn.number)").font(TranscriptStyle.meta).foregroundStyle(Color.secondary.opacity(0.7))
                        .help("Turn \(turn.number)")
                }
                CopyButton(text: message.text, size: 11).opacity(hover ? 1 : 0.35)
            }
            .foregroundStyle(tint)
            if !message.text.isEmpty {
                FoldingMarkdown(text: message.text, id: id, expansion: expansion)
                    .font(TranscriptStyle.bodyFont)
                    .textSelection(.enabled)
            }
            let media = message.blocks.filter { if case .text = $0 { return false } else { return true } }
            if !media.isEmpty { MediaStrip(blocks: media) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(queued ? 0.06 : 0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.22)))
        .onHover { hover = $0 }
    }
}

/// A slash command (or `!` shell command) the person ran, with what it printed and — folded —
/// the prompt it expanded into.
struct CommandRow: View {
    let message: UserMessage
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        let isShell = message.commandName == "!"
        let hasBody = message.expansion != nil || (message.commandOutput?.contains("\n") ?? false)
        DisclosureRow(icon: isShell ? "dollarsign.circle" : "terminal", tint: TranscriptStyle.prompt,
                      isExpanded: expansion.isExpanded(id), isEnabled: hasBody,
                      onToggle: { expansion.toggle(id) }) {
            HStack(spacing: 7) {
                Text(isShell ? "$ \(message.commandArgs ?? "")" : (message.commandName ?? "command"))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TranscriptStyle.prompt)
                    .layoutPriority(1)
                let out = message.commandOutput?.components(separatedBy: "\n").first ?? ""
                if !isShell, let args = message.commandArgs, !out.contains(args.prefix(40)) {
                    Text(args).font(TranscriptStyle.rowDetail).foregroundStyle(.primary.opacity(0.85))
                }
                if !out.isEmpty {
                    Text(InlineMarkdown.attributed("→ " + out)).font(TranscriptStyle.rowDetail).foregroundStyle(.secondary)
                }
            }
        } trailing: {
            if let t = TranscriptFormat.clock(message.time) { MetaText(t, color: .secondary) }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let out = message.commandOutput, out.contains("\n") {
                    SectionLabel(text: "Output")
                    CodeBlockView(code: out, showHeader: false)
                }
                if let exp = message.expansion {
                    SectionLabel(text: "Sent to Claude")
                    FoldingMarkdown(text: exp, id: id + "/exp", expansion: expansion)
                }
            }
        }
    }
}

/// A background task reporting back — the turn it opens is Claude reacting to it.
struct NotificationLine: View {
    let message: UserMessage
    let id: String
    let model: TranscriptModel
    @ObservedObject var expansion: TranscriptExpansion
    var jumpToTool: (String) -> Void = { _ in }

    var body: some View {
        let n = message.notification
        let failed = ["failed", "error", "killed"].contains(n?.status.lowercased() ?? "")
        DisclosureRow(icon: "bell.badge", tint: failed ? TranscriptStyle.error : TranscriptStyle.agent,
                      isExpanded: expansion.isExpanded(id), isEnabled: n?.result != nil,
                      onToggle: { expansion.toggle(id) }) {
            RowTitle(title: n?.summary ?? "Background task finished")
        } trailing: {
            HStack(spacing: 6) {
                if let s = n?.status, !s.isEmpty { TagPill(text: s, color: failed ? TranscriptStyle.error : TranscriptStyle.added) }
                if let tool = n?.toolUseID, model.events.contains(where: { if case .tool(let t) = $0 { return t.id == tool } else { return false } }) {
                    Button { jumpToTool(tool) } label: {
                        Label("Go to call", systemImage: "arrow.up.forward").labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5)).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Scroll to the call that started this task")
                }
                if let t = TranscriptFormat.clock(message.time) { MetaText(t) }
            }
        } content: {
            if let r = n?.result {
                FoldingMarkdown(text: r, id: id + "/r", expansion: expansion)
            }
        }
    }
}

/// Another agent's message — usually a subagent handing back its report. Named by the Agent
/// call that launched it when the transcript has one, with a link back to that call.
struct PeerMessage: View {
    let message: UserMessage
    let id: String
    let model: TranscriptModel
    @ObservedObject var expansion: TranscriptExpansion
    var jumpToTool: (String) -> Void = { _ in }

    private var launch: ToolInvocation? {
        guard let sender = message.sender, let callID = model.agentCallByAgentID[sender] else { return nil }
        for e in model.events { if case .tool(let t) = e, t.id == callID { return t } }
        return nil
    }

    var body: some View {
        let call = launch
        let who = (call?.input["description"] as? String).map { "“\($0)”" } ?? message.sender.map { "agent \($0.prefix(8))" } ?? "an agent"
        DisclosureRow(icon: "arrowshape.turn.up.left", tint: TranscriptStyle.agent,
                      isExpanded: expansion.isExpanded(id), onToggle: { expansion.toggle(id) }) {
            RowTitle(title: "Report from \(who)", detail: TranscriptModel.label(UserMessage(blocks: message.blocks)))
        } trailing: {
            HStack(spacing: 6) {
                if message.isQueued { TagPill(text: "mid-turn") }
                if let call {
                    Button { jumpToTool(call.id) } label: {
                        Label("Go to call", systemImage: "arrow.up.forward").labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5)).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Scroll to the Agent call that started this subagent")
                }
                if let t = TranscriptFormat.clock(message.time) { MetaText(t) }
            }
        } content: {
            FoldingMarkdown(text: message.text, id: id + "/b", expansion: expansion)
        }
        .help("A subagent's final report, delivered to Claude as model output — not a message from you")
    }
}

// MARK: - Claude

struct AssistantRow: View {
    let text: AssistantText
    var showLabel = false
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TranscriptStyle.claude)
                .frame(width: 16)
                .padding(.top, showLabel ? 2 : 3)
            VStack(alignment: .leading, spacing: 4) {
                if showLabel {
                    HStack(spacing: 6) {
                        Text("Claude").font(.system(size: 11, weight: .semibold)).foregroundStyle(TranscriptStyle.claude)
                        if let m = text.model { Text(TranscriptFormat.model(m)).font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }
                }
                MarkdownText(text.text, scale: .compact)
                    .font(TranscriptStyle.bodyFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if let t = TranscriptFormat.clock(text.time) {
                    Text(t).font(TranscriptStyle.meta).foregroundStyle(.tertiary)
                }
                CopyButton(text: text.text, size: 11)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(white: 0.13).opacity(0.92), in: Capsule())
            .opacity(hover ? 1 : 0)
        }
        .onHover { hover = $0 }
    }
}

struct ThinkingRow: View {
    let blocks: [ThinkingBlock]
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        let text = blocks.map(\.text).joined(separator: "\n\n")
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first ?? ""
        DisclosureRow(icon: "brain", tint: TranscriptStyle.thinking,
                      isExpanded: expansion.isExpanded(id), onToggle: { expansion.toggle(id) }) {
            HStack(spacing: 7) {
                Text("Thinking").font(TranscriptStyle.rowTitle).foregroundStyle(TranscriptStyle.thinking)
                Text(preview).font(TranscriptStyle.rowDetail).italic().foregroundStyle(.secondary)
            }
        } trailing: {
            MetaText(TranscriptFormat.plural(text.split(whereSeparator: \.isWhitespace).count, "word"))
        } content: {
            MarkdownText(text, scale: .compact)
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(TranscriptStyle.thinking.opacity(0.35)).frame(width: 2)
                }
        }
    }
}

// MARK: - Messages that open no turn

struct MessageRow: View {
    let message: UserMessage
    let id: String
    let model: TranscriptModel
    @ObservedObject var expansion: TranscriptExpansion
    var jumpToTool: (String) -> Void = { _ in }

    var body: some View {
        switch message.kind {
        case .prompt:
            PromptBubble(message: message, turn: nil, id: id, expansion: expansion, queued: message.isQueued)
                .padding(.vertical, 4)
        case .command:
            CommandRow(message: message, id: id, expansion: expansion)
        case .taskNotification:
            NotificationLine(message: message, id: id, model: model, expansion: expansion, jumpToTool: jumpToTool)
        case .peer:
            PeerMessage(message: message, id: id, model: model, expansion: expansion, jumpToTool: jumpToTool)
        case .commandOutput:
            DisclosureRow(icon: "terminal", tint: TranscriptStyle.system,
                          isExpanded: expansion.isExpanded(id), isEnabled: message.text.contains("\n"),
                          onToggle: { expansion.toggle(id) }) {
                RowTitle(title: "Command output", detail: firstLine, mono: true)
            } trailing: {
                if let t = TranscriptFormat.clock(message.time) { MetaText(t) }
            } content: {
                CodeBlockView(code: message.text, showHeader: false)
            }
        case .meta:
            let body = InjectedText.body(message.text)
            DisclosureRow(icon: "text.bubble", tint: TranscriptStyle.context,
                          isExpanded: expansion.isExpanded(id), onToggle: { expansion.toggle(id) }) {
                RowTitle(title: InjectedText.title(message), detail: body.components(separatedBy: "\n").first ?? "")
            } trailing: {
                TagPill(text: "not typed", color: TranscriptStyle.context)
            } content: {
                FoldingMarkdown(text: body, id: id, expansion: expansion)
            }
            .help("Text the model received as a user message that nobody typed")
        case .compactSummary:
            DisclosureRow(icon: "rectangle.compress.vertical", tint: TranscriptStyle.context,
                          isExpanded: expansion.isExpanded(id), onToggle: { expansion.toggle(id) }) {
                RowTitle(title: "Compaction summary", detail: "what the conversation continues from")
            } trailing: {
                MetaText(TranscriptFormat.plural(message.text.count, "character"))
            } content: {
                FoldingMarkdown(text: message.text, id: id, expansion: expansion, limit: 3_000)
            }
        }
    }

    private var firstLine: String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
    }
}

/// Naming for injected user-role text: who put it there, without the CLI's envelope tags.
enum InjectedText {
    static func title(_ m: UserMessage) -> String {
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.originKind == "coordinator" { return "Coordinator message" }
        if t.hasPrefix("<system-reminder>") { return "System reminder" }
        if t.hasPrefix("[") , let close = t.firstIndex(of: "]"), t.distance(from: t.startIndex, to: close) < 40 {
            return "System note"
        }
        return "Injected message"
    }

    static func body(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<system-reminder>") else { return t }
        return t.replacingOccurrences(of: "<system-reminder>", with: "")
            .replacingOccurrences(of: "</system-reminder>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Context

enum ContextStyle {
    static func icon(_ type: String) -> String {
        switch type {
        case "instructions", "nested_memory": return "doc.text"
        case "environment": return "desktopcomputer"
        case "session_context": return "person.text.rectangle"
        case "date", "date_change": return "calendar"
        case "model": return "cpu"
        case "skill_listing", "dynamic_skill", "invoked_skills": return "wand.and.stars"
        case "agent_listing_delta": return "person.2"
        case "mcp_instructions_delta": return "server.rack"
        case "deferred_tools_delta": return "shippingbox"
        case "auto_mode", "auto_mode_exit": return "bolt.badge.automatic"
        case "plan_mode", "plan_mode_exit", "plan_mode_reentry", "plan_file_reference": return "list.bullet.clipboard"
        case "remote_session_change": return "signature"
        case "silent_turn_reminder", "task_reminder": return "bell"
        case "read_truncation_notice": return "scissors"
        case "file", "compact_file_reference": return "doc"
        case "edited_text_file": return "pencil.and.outline"
        case "diagnostics": return "exclamationmark.triangle"
        case "goal_status": return "flag.checkered"
        case "command_permissions": return "lock.open"
        default: return "paperclip"
        }
    }
}

/// Consecutive injected context, folded to one line that names every item.
struct ContextRow: View {
    let items: [ContextItem]
    let id: String
    var actions = TranscriptActions()
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        // Plan mode names its plan file: the row links to it, collapsed or not.
        let planPath = items.first { TranscriptModel.isPlanContext($0) && $0.path != nil }?.path
        DisclosureRow(icon: planPath != nil ? "list.bullet.clipboard" : "paperclip",
                      tint: planPath != nil ? TranscriptStyle.plan : TranscriptStyle.context,
                      isExpanded: expansion.isExpanded(id),
                      inset: planPath.map { AnyView(PlanQASlot(path: $0, id: id, actions: actions, expansion: expansion)) },
                      onToggle: { expansion.toggle(id) }) {
            HStack(spacing: 7) {
                Text(items.count == 1 ? items[0].title : "Context")
                    .font(TranscriptStyle.rowTitle).foregroundStyle(TranscriptStyle.context)
                    .layoutPriority(1)
                Text(summary).font(TranscriptStyle.rowDetail).foregroundStyle(.secondary)
            }
        } trailing: {
            if items.count > 1 { MetaText(TranscriptFormat.plural(items.count, "item")) }
        } accessory: {
            if let planPath { PlanLinks(path: planPath, id: id, actions: actions, expansion: expansion) }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    ContextItemView(item: item, id: "\(id)/\(i)", expansion: expansion, startOpen: items.count == 1)
                }
            }
            .padding(.leading, -24)   // sub-rows carry their own glyph column
        }
        .help("Context Claude Code added to the model's input — nobody typed it")
    }

    private var summary: String {
        if items.count == 1 { return items[0].summary }
        // Plan mode first: in a cluster it's the item a reader is looking for.
        let ordered = items.filter(TranscriptModel.isPlanContext) + items.filter { !TranscriptModel.isPlanContext($0) }
        return ordered.map { i in
            if i.summary.isEmpty { return i.title }
            return i.summary.hasPrefix("→") ? "\(i.title) \(i.summary)" : "\(i.title): \(i.summary)"
        }.joined(separator: " · ")
    }
}

struct ContextItemView: View {
    let item: ContextItem
    let id: String
    @ObservedObject var expansion: TranscriptExpansion
    var startOpen = false

    var body: some View {
        let hasBody = !item.sections.isEmpty || item.rendered != nil
        DisclosureRow(icon: ContextStyle.icon(item.type), tint: TranscriptStyle.context.opacity(0.85),
                      isExpanded: expansion.isExpanded(id, default: startOpen) && hasBody, isEnabled: hasBody,
                      onToggle: { expansion.toggle(id) }) {
            RowTitle(title: item.title, detail: item.summary)
        } trailing: {
            if let role = item.role { TagPill(text: "as \(role)", color: TranscriptStyle.context) }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(item.sections.enumerated()), id: \.offset) { i, section in
                    ContextSectionView(section: section, id: "\(id)/s\(i)", expansion: expansion)
                }
                if let rendered = item.rendered {
                    let key = "\(id)/raw"
                    let open = expansion.isExpanded(key, default: item.sections.isEmpty)
                    Button { expansion.toggle(key) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold))
                            Text("Exact text the model received").font(TranscriptStyle.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if open { CodeBlockView(code: rendered, title: item.role.map { "\($0) message" }, foldAfter: 40, wrap: true) }
                }
            }
        }
    }
}

struct ContextSectionView: View {
    let section: ContextItem.Section
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(section.title).font(.system(size: 11.5, weight: .semibold))
                if let sub = section.subtitle { Text(sub).font(TranscriptStyle.caption).foregroundStyle(.tertiary) }
                Spacer(minLength: 6)
                if let path = section.path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                        Image(systemName: Icon.openFile).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Open \(TranscriptFormat.path(path))")
                }
            }
            if looksLikeMarkdown(section.body) {
                FoldingMarkdown(text: section.body, id: id, expansion: expansion, limit: 1_600)
                    .padding(10)
                    .background(TranscriptStyle.bodyBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                CodeBlockView(code: section.body, showHeader: false, foldAfter: 16, wrap: !looksLikeCode(section.body))
            }
        }
    }

    private func looksLikeMarkdown(_ s: String) -> Bool {
        s.hasPrefix("#") || s.contains("\n#") || s.contains("\n- ") || s.contains("**")
    }

    /// Numbered source (`1\t…`), JSON, or lines laid out in columns — keep their shape.
    private func looksLikeCode(_ s: String) -> Bool {
        s.hasPrefix("{") || s.hasPrefix("[") || NumberedLines.parse(s) != nil || s.contains("\t")
    }
}

struct SystemPromptRow: View {
    let snapshot: SystemPromptSnapshot
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        DisclosureRow(icon: "text.book.closed", tint: TranscriptStyle.context,
                      isExpanded: expansion.isExpanded(id), onToggle: { expansion.toggle(id) }) {
            RowTitle(title: "System prompt",
                     detail: [TranscriptFormat.plural(snapshot.parts.count, "section"),
                              snapshot.tools.isEmpty ? nil : TranscriptFormat.plural(snapshot.tools.count, "tool"),
                              "\(TranscriptFormat.tokens(snapshot.characterCount)) characters"]
                        .compactMap { $0 }.joined(separator: " · "),
                     titleColor: TranscriptStyle.context)
        } trailing: {
            if let t = TranscriptFormat.clock(snapshot.time) { MetaText(t) }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                if let prefix = snapshot.cliPrefix {
                    Text(prefix).font(TranscriptStyle.caption).italic().foregroundStyle(.secondary)
                        .padding(.leading, 30).padding(.bottom, 4)
                        .help("The identity line the CLI puts before the system prompt")
                }
                ForEach(Array(snapshot.parts.enumerated()), id: \.offset) { i, part in
                    promptSection(part, key: "\(id)/p\(i)")
                }
                if !snapshot.tools.isEmpty {
                    SectionLabel(text: "Tools", trailing: "\(snapshot.tools.count)").padding(.top, 8).padding(.leading, 30)
                    ForEach(Array(snapshot.tools.enumerated()), id: \.offset) { i, tool in
                        toolEntry(tool, key: "\(id)/t\(i)")
                    }
                }
            }
            .padding(.leading, -24)
        }
        .help("The system prompt and tool list Claude Code sent with this session's requests")
    }

    private func promptSection(_ part: String, key: String) -> some View {
        let first = part.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
        let title = first.hasPrefix("#") ? String(first.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) : first
        return DisclosureRow(icon: "text.alignleft", tint: .secondary, isExpanded: expansion.isExpanded(key),
                             onToggle: { expansion.toggle(key) }) {
            RowTitle(title: title.isEmpty ? "Section" : title)
        } trailing: {
            MetaText(TranscriptFormat.plural(part.count, "char"))
        } content: {
            FoldingMarkdown(text: part, id: key, expansion: expansion, limit: 2_400)
                .padding(10)
                .background(TranscriptStyle.bodyBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func toolEntry(_ tool: SystemPromptSnapshot.Tool, key: String) -> some View {
        DisclosureRow(icon: "wrench.and.screwdriver", tint: .secondary, isExpanded: expansion.isExpanded(key),
                      onToggle: { expansion.toggle(key) }) {
            RowTitle(title: tool.name, detail: tool.description.components(separatedBy: "\n").first)
        } trailing: {
            EmptyView()
        } content: {
            FoldingMarkdown(text: tool.description, id: key, expansion: expansion, limit: 2_400)
                .padding(10)
                .background(TranscriptStyle.bodyBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Hooks

struct HookRow: View {
    let hook: HookExecution
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        DisclosureRow(icon: "link", tint: hook.isError ? TranscriptStyle.error : TranscriptStyle.hook,
                      isExpanded: expansion.isExpanded(id), onToggle: { expansion.toggle(id) }) {
            HStack(spacing: 7) {
                Text(hook.hookEvent.isEmpty ? hook.hookName : hook.hookEvent)
                    .font(TranscriptStyle.rowTitle)
                    .foregroundStyle(hook.isError ? TranscriptStyle.error : TranscriptStyle.hook)
                    .layoutPriority(1)
                if let matcher = HookDetail.matcher(hook) {
                    Text(matcher).font(TranscriptStyle.mono).foregroundStyle(.secondary)
                }
                Text(HookDetail.summary(hook)).font(TranscriptStyle.rowDetail).foregroundStyle(.secondary)
            }
        } trailing: {
            HStack(spacing: 6) {
                if hook.preventedContinuation { TagPill(text: "kept Claude going", color: TranscriptStyle.hook) }
                if let ms = hook.durationMs { MetaText(TranscriptFormat.duration(ms: ms)) }
            }
        } content: {
            HookDetail(hook: hook)
        }
        .help("A hook: a script Claude Code ran on \(hook.hookEvent.isEmpty ? "an event" : hook.hookEvent)")
    }
}

/// A hook run's full record: the command, what it printed, and what it fed back to Claude.
struct HookDetail: View {
    let hook: HookExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cmd = hook.command {
                CodeBlockView(code: cmd, language: "bash", title: "command", foldAfter: 6)
            }
            if let content = hook.content {
                SectionLabel(text: "Added to Claude's context")
                CodeBlockView(code: content, showHeader: false, foldAfter: 20, wrap: true)
            }
            if let out = hook.stdout, out != hook.content {
                SectionLabel(text: "stdout")
                CodeBlockView(code: HookDetail.pretty(out), language: out.hasPrefix("{") ? "json" : nil, showHeader: false, foldAfter: 20)
            }
            if let err = hook.stderr {
                SectionLabel(text: "stderr")
                CodeBlockView(code: err, showHeader: false, foldAfter: 20, tint: TranscriptStyle.error, wrap: true)
            }
            HStack(spacing: 10) {
                Text(hook.hookName)
                if let code = hook.exitCode { Text("exit \(code)") }
                if let t = TranscriptFormat.clock(hook.time) { Text("ran \(t)") }
            }
            .font(TranscriptStyle.monoSmall)
            .foregroundStyle(.tertiary)
        }
    }

    static func matcher(_ h: HookExecution) -> String? {
        let parts = h.hookName.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    static func summary(_ h: HookExecution) -> String {
        var parts: [String] = []
        if let s = h.scriptName { parts.append(s) }
        switch h.outcome {
        case .additionalContext: parts.append("added context")
        case .systemMessage: parts.append("showed a message")
        case .cancelled: parts.append("cancelled")
        case .nonBlockingError: parts.append("failed" + (h.exitCode.map { " (exit \($0))" } ?? ""))
        case .blockingError: parts.append("blocked" + (h.exitCode.map { " (exit \($0))" } ?? ""))
        case .success, .other:
            if h.content != nil { parts.append("added context") }
        }
        if parts.isEmpty, let c = h.content { parts.append(c.components(separatedBy: "\n").first ?? "") }
        return parts.joined(separator: " · ")
    }

    static func pretty(_ s: String) -> String {
        guard s.hasPrefix("{") || s.hasPrefix("["), let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: out, encoding: .utf8) else { return s }
        return str
    }
}

// MARK: - Notices

struct NoticeRow: View {
    let notice: TranscriptNotice
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        switch notice.kind {
        case .compaction: compaction
        case .apiError: banner(icon: "exclamationmark.octagon.fill", color: TranscriptStyle.error)
        case .interrupted: banner(icon: "hand.raised.fill", color: TranscriptStyle.warning)
        case .awaySummary: recap
        default: line
        }
    }

    private var compaction: some View {
        HStack(spacing: 8) {
            Rectangle().fill(TranscriptStyle.context.opacity(0.35)).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: "rectangle.compress.vertical").font(.system(size: 10))
                Text("Conversation compacted").font(.system(size: 11, weight: .semibold))
                if let pre = notice.preTokens, let post = notice.postTokens {
                    Text("\(TranscriptFormat.tokens(pre)) → \(TranscriptFormat.tokens(post)) tokens").font(TranscriptStyle.meta)
                }
                if let trigger = notice.detail { Text(trigger).font(TranscriptStyle.caption).foregroundStyle(.secondary) }
                if let ms = notice.durationMs { Text(TranscriptFormat.duration(ms: ms)).font(TranscriptStyle.meta).foregroundStyle(.secondary) }
            }
            .foregroundStyle(TranscriptStyle.context)
            .fixedSize()
            Rectangle().fill(TranscriptStyle.context.opacity(0.35)).frame(height: 1)
        }
        .padding(.vertical, 10)
        .help("Claude Code summarised the conversation to free context; what follows continues from the summary")
    }

    private func banner(icon: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                    .textSelection(.enabled)
                if let d = notice.detail { Text(d).font(TranscriptStyle.monoSmall).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let t = TranscriptFormat.clock(notice.time) { MetaText(t) }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.25)))
        .padding(.vertical, 2)
    }

    private var recap: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.quote").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recap while you were away").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(notice.detail ?? "").font(.system(size: 12)).italic().foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let t = TranscriptFormat.clock(notice.time) { MetaText(t) }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private var line: some View {
        let warn = notice.level == "warning"
        let icon: String = {
            switch notice.kind {
            case .modeChange: return "switch.2"
            case .scheduledWakeup: return "alarm"
            case .localCommand: return "terminal"
            case .informational: return warn ? "exclamationmark.triangle" : "info.circle"
            default: return "gearshape"
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11))
                .foregroundStyle(warn ? TranscriptStyle.warning : Color.secondary).frame(width: 16)
            Text(notice.title).font(.system(size: 12))
                .foregroundStyle(warn ? TranscriptStyle.warning : Color.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let d = notice.detail {
                Text(d).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let t = TranscriptFormat.clock(notice.time) { MetaText(t) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }
}

/// An attachment type this view has no rendering for: its fields, verbatim.
struct RawAttachmentRow: View {
    let attachment: Attachment
    let id: String
    @ObservedObject var expansion: TranscriptExpansion

    var body: some View {
        DisclosureRow(icon: "questionmark.square.dashed", tint: .secondary,
                      isExpanded: expansion.isExpanded(id), onToggle: { expansion.toggle(id) }) {
            RowTitle(title: attachment.type, mono: true)
        } trailing: {
            if let t = TranscriptFormat.clock(attachment.time) { MetaText(t) }
        } content: {
            CodeBlockView(code: TranscriptModel.inputText(attachment.fields), language: "yaml", showHeader: false)
        }
    }
}

// MARK: - Turn footer

struct TurnFooterView: View {
    let turn: TranscriptTurn
    let model: TranscriptModel
    let id: String
    @ObservedObject var expansion: TranscriptExpansion
    @State private var hover = false

    var body: some View {
        let open = expansion.isExpanded(id)
        VStack(alignment: .trailing, spacing: 6) {
            Button { if turn.apiCalls > 0 { expansion.toggle(id) } } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(TranscriptStyle.hairline).frame(height: 1)
                    HStack(spacing: 10) {
                        if let ms = turn.durationMs {
                            fact("timer", TranscriptFormat.duration(ms: ms), help: "How long the turn took")
                        }
                        if turn.apiCalls > 0 {
                            fact("arrow.left.arrow.right", TranscriptFormat.plural(turn.apiCalls, "call"),
                                 help: "API requests to the model this turn — click for each one")
                        }
                        if turn.thinkingBlocks > 0 {
                            fact("brain", "\(turn.thinkingBlocks)", help: "Times Claude thought before acting")
                        }
                        if turn.outputTokens > 0 {
                            fact("arrow.down", "\(TranscriptFormat.tokens(turn.outputTokens)) out", help: "Tokens Claude wrote")
                        }
                        if turn.contextAtEnd > 0 {
                            fact("square.stack.3d.up", "\(TranscriptFormat.tokens(turn.contextAtEnd)) ctx",
                                 help: "Context the turn's last request carried")
                        }
                        if let hit = cacheHit {
                            fact("bolt.horizontal", "\(hit)% cached", help: "Share of the turn's input served from the prompt cache")
                        }
                        if !turn.models.isEmpty {
                            Text(turn.models.map(TranscriptFormat.model).joined(separator: " → ") + (turn.effort.map { " · \($0)" } ?? ""))
                                .foregroundStyle(ModelBadge.color(for: turn.models.last ?? ""))
                        }
                        if turn.apiCalls > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .opacity(hover || open ? 1 : 0.4)
                        }
                    }
                    .font(TranscriptStyle.meta)
                    .foregroundStyle(hover ? .secondary : .tertiary)
                    .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(tooltip)
            if open { CallTable(calls: model.apiCalls(in: turn)) }
        }
        .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
    }

    private var cacheHit: Int? {
        let total = turn.inputTokens + turn.cacheReadTokens + turn.cacheWriteTokens
        guard total > 0 else { return nil }
        return Int((Double(turn.cacheReadTokens) / Double(total) * 100).rounded())
    }

    private var tooltip: String {
        [
            "Input \(turn.inputTokens.formatted()) · cache read \(turn.cacheReadTokens.formatted()) · cache write \(turn.cacheWriteTokens.formatted())",
            "Output \(turn.outputTokens.formatted()) across \(TranscriptFormat.plural(turn.apiCalls, "request"))",
            "\(TranscriptFormat.plural(turn.toolCalls, "tool call"))\(turn.failedTools > 0 ? " (\(turn.failedTools) failed)" : "")",
        ].joined(separator: "\n")
    }

    private func fact(_ icon: String, _ text: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .semibold))
            Text(text)
        }
        .help(help)
    }
}

/// Every API request of a turn, one row each: when, on what, and what it read and wrote.
struct CallTable: View {
    let calls: [TurnUsage]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                ForEach(["#", "time", "model", "input", "cache read", "cache write", "output", "context"], id: \.self) {
                    Text($0.uppercased()).font(TranscriptStyle.sectionLabel).kerning(0.3).foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(calls.enumerated()), id: \.offset) { i, c in
                GridRow {
                    Text("\(i + 1)").foregroundStyle(.tertiary)
                    Text(TranscriptFormat.clock(c.time) ?? "—").foregroundStyle(.secondary)
                    // Named where it changes; a blank means "same as above".
                    let same = i > 0 && calls[i - 1].model == c.model && calls[i - 1].effort == c.effort
                    Text(same ? "" : TranscriptFormat.model(c.model) + (c.effort.map { " · \($0)" } ?? ""))
                        .foregroundStyle(ModelBadge.color(for: c.model))
                        .gridColumnAlignment(.leading)
                    Text(c.inputTokens.formatted())
                    Text(c.cacheReadTokens.formatted())
                    Text(c.cacheWriteTokens.formatted()).foregroundStyle(c.cacheWriteTokens > 10_000 ? TranscriptStyle.warning : .primary)
                    Text(c.outputTokens.formatted())
                    Text(TranscriptFormat.tokens(c.contextTokens)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(TranscriptStyle.bodyBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TranscriptStyle.hairline))
        .help("A large cache write means the request re-sent history the cache no longer had")
    }
}

// MARK: - Media

/// Thumbnails for pasted images and attached documents; click to open.
struct MediaStrip: View {
    let blocks: [UserContentBlock]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text: EmptyView()
                case .image(let data, let mediaType):
                    ImageThumb(image: NSImage(data: data)) { openTemp(data, ext: extForMediaType(mediaType)) }
                case .imageFile(let url):
                    ImageThumb(image: NSImage(contentsOf: url)) { NSWorkspace.shared.open(url) }
                case .document(let data, let mediaType, let name):
                    Button { openTemp(data, ext: extForMediaType(mediaType)) } label: {
                        Label(name ?? mediaType, systemImage: mediaType == "application/pdf" ? "doc.richtext" : "doc")
                            .font(.caption).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ImageThumb: View {
    let image: NSImage?
    var size: CGFloat = 84
    let onOpen: () -> Void

    var body: some View {
        if let image {
            // Whole image, aspect kept: a cropped square hid what a wide screenshot showed.
            Button(action: onOpen) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: size * 2.4, maxHeight: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Open image")
        }
    }
}

func openTemp(_ data: Data, ext: String) {
    // Hash the full data so different images never share a temp path.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("claudepit-\(String(hash, radix: 16)).\(ext)")
    if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
    NSWorkspace.shared.open(url)
}

func extForMediaType(_ mediaType: String) -> String {
    switch mediaType {
    case "image/png": return "png"
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "application/pdf": return "pdf"
    default: return mediaType.components(separatedBy: "/").last ?? "bin"
    }
}
