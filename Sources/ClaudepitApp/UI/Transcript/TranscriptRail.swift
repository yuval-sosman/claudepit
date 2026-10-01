import SwiftUI
import ClaudepitCore

/// The transcript's timeline: a minimap of the rows on screen. Every row that matters gets a mark
/// at its place in the list (`TranscriptModel.landmark(of:)`): wide where a turn starts, small
/// for a file edit, a plan step, a question, a subagent, a skill, a task-list change, a
/// compaction or a failure — so a session that is one long turn still reads as a timeline.
/// Marks are spaced by row, not by pixel (rows vary too much in height for a pixel map to mean
/// anything). The white bar is where the view is. Hover for what a mark is; click to go there.
struct TranscriptRail: View {
    let model: TranscriptModel
    let rows: [TranscriptRow]
    @ObservedObject var tracker: TranscriptScrollTracker
    let onRow: (String) -> Void
    let onTop: () -> Void
    let onBottom: () -> Void

    static let width: CGFloat = 18

    struct Mark { let row: Int; let kind: TranscriptLandmark }

    @State private var marks: [Mark] = []
    @State private var rowIndex: [String: Int] = [:]
    @State private var hover: Hover?
    @State private var showKey = false
    /// The snapshot tool's `--hover-row`: a row to show hovered.
    private let initialHover: String?

    /// A mark under the pointer, or (between marks) just the row there.
    private enum Hover: Equatable { case mark(Int), row(Int) }

    init(model: TranscriptModel, rows: [TranscriptRow], tracker: TranscriptScrollTracker,
         hoverRow: String? = nil, onRow: @escaping (String) -> Void,
         onTop: @escaping () -> Void, onBottom: @escaping () -> Void) {
        self.model = model; self.rows = rows; self.tracker = tracker
        self.onRow = onRow; self.onTop = onTop; self.onBottom = onBottom
        self.initialHover = hoverRow
    }

    var body: some View {
        VStack(spacing: 6) {
            Button { showKey.toggle() } label: {
                Image(systemName: Icon.info)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(showKey ? Color.accentColor : .secondary)
                    .frame(width: Self.width, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("What the timeline's marks mean")
            .popover(isPresented: $showKey, arrowEdge: .leading) { RailKey() }
            railButton("arrow.up.to.line", help: "Go to the start", action: onTop)
            GeometryReader { geo in
                track(height: geo.size.height)
            }
            railButton("arrow.down.to.line", help: "Go to the end", action: onBottom)
        }
        .frame(width: Self.width)
        .padding(.vertical, 2)
        .onAppear(perform: index)
        .onChange(of: rows) { _, _ in index() }
    }

    private func index() {
        var map: [String: Int] = [:]
        var found: [Mark] = []
        for (i, r) in rows.enumerated() {
            map[r.id] = i
            if let kind = model.landmark(of: r) { found.append(Mark(row: i, kind: kind)) }
        }
        rowIndex = map
        // Lower kinds first, so where marks overlap the more telling one is drawn on top.
        marks = found.sorted { $0.kind == $1.kind ? $0.row < $1.row : $0.kind < $1.kind }
        if hover == nil, let id = initialHover, let i = map[id] {
            hover = marks.firstIndex { $0.row == i }.map(Hover.mark) ?? .row(i)
        }
    }

    private func y(row: Int, height h: CGFloat) -> CGFloat {
        guard rows.count > 1 else { return 4 }
        return 4 + (h - 8) * CGFloat(row) / CGFloat(rows.count - 1)
    }

    private func nearestRow(_ y: CGFloat, height h: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        guard rows.count > 1 else { return 0 }
        let frac = min(1, max(0, (y - 4) / max(1, h - 8)))
        return Int((frac * CGFloat(rows.count - 1)).rounded())
    }

    /// The mark under the pointer — the most telling one within a few points — else the row there.
    private func hit(_ y: CGFloat, height h: CGFloat) -> Hover? {
        var best: (index: Int, distance: CGFloat, kind: TranscriptLandmark)?
        for (i, m) in marks.enumerated() {
            let d = abs(self.y(row: m.row, height: h) - y)
            guard d <= 5 else { continue }
            if best == nil || m.kind > best!.kind || (m.kind == best!.kind && d < best!.distance) {
                best = (i, d, m.kind)
            }
        }
        if let best { return .mark(best.index) }
        return nearestRow(y, height: h).map(Hover.row)
    }

    private var currentRow: Int? { tracker.topRowID.flatMap { rowIndex[$0] } }

    private func track(height h: CGFloat) -> some View {
        let current = currentRow
        return ZStack(alignment: .top) {
            Capsule().fill(Color.white.opacity(0.07)).frame(width: 2)
                .frame(maxWidth: .infinity)
            Canvas { ctx, size in
                for m in marks {
                    let (w, t) = Self.size(of: m.kind)
                    let rect = CGRect(x: (size.width - w) / 2, y: y(row: m.row, height: size.height) - t / 2, width: w, height: t)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: t / 2), with: .color(m.kind.color))
                }
                if let current {
                    let rect = CGRect(x: (size.width - 16) / 2, y: y(row: current, height: size.height) - 2, width: 16, height: 4)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.white.opacity(0.92)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            // The card floats left of the rail, beside the hovered place.
            if let hover, let card = card(for: hover) {
                card
                    .fixedSize()
                    // Room for the tallest card (two-line prompt, wrapped facts) above the end.
                    .offset(x: -26, y: max(0, min(h - 96, y(row: row(of: hover), height: h) - 24)))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = hit(p.y, height: h)
            case .ended: hover = nil
            }
        }
        .onTapGesture { p in
            if let target = hit(p.y, height: h) { onRow(rows[row(of: target)].id) }
        }
    }

    private func row(of hover: Hover) -> Int {
        switch hover {
        case .mark(let i): return marks[i].row
        case .row(let r): return r
        }
    }

    @ViewBuilder private func card(for hover: Hover) -> (some View)? {
        let r = row(of: hover)
        if rows.indices.contains(r), model.turns.indices.contains(rows[r].turn) {
            let turn = model.turns[rows[r].turn]
            if case .mark(let i) = hover, marks.indices.contains(i), !marks[i].kind.startsTurn {
                RailEventLabel(kind: marks[i].kind, text: Self.describe(rows[r], model: model),
                               time: rows[r].eventIndices.first.flatMap { TranscriptModel.time(of: model.events[$0]) },
                               turn: turn.number)
            } else {
                RailLabel(turn: turn, number: turn.number)
            }
        }
    }

    /// Width and thickness of a mark: turn starts wide, events short.
    static func size(of kind: TranscriptLandmark) -> (CGFloat, CGFloat) {
        switch kind {
        case .prompt: return (12, 2.5)
        case .command, .report: return (9, 2)
        default: return (6, 3)
        }
    }

    /// One line for an event mark's card: what the row is, as its own title reads.
    static func describe(_ row: TranscriptRow, model: TranscriptModel) -> String {
        switch row.kind {
        case .tool(let i):
            guard case .tool(let inv) = model.events[i] else { return "" }
            let detail = ToolSummary.detail(inv, model: model).text
            return [ToolSummary.name(inv), detail].filter { !$0.isEmpty }.joined(separator: "  ")
        case .toolRun(let members):
            let failed = members.filter { if case .tool(let inv) = model.events[$0] { return inv.failed } else { return false } }.count
            return "\(TranscriptFormat.plural(members.count, "tool call")), \(failed) failed"
        case .notice(let i):
            guard case .notice(let n) = model.events[i] else { return "" }
            return [n.title, n.detail].compactMap { $0 }.joined(separator: " · ")
        case .hook(let i):
            guard case .hook(let h) = model.events[i] else { return "" }
            return "\(h.hookName) failed"
        case .message(let i):
            guard case .userMessage(let m) = model.events[i] else { return "" }
            return TranscriptModel.label(m)
        default:
            return ""
        }
    }

    private func railButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.width, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension TranscriptLandmark {
    var color: Color {
        switch self {
        case .prompt: return TranscriptStyle.prompt
        case .command: return Color(white: 0.6)
        case .report: return TranscriptStyle.agent.opacity(0.6)
        case .task: return TranscriptStyle.task
        case .skill: return TranscriptStyle.skill
        case .subagent: return TranscriptStyle.agent
        case .question: return TranscriptStyle.question
        case .edit: return TranscriptStyle.edit
        case .plan: return TranscriptStyle.plan
        case .compaction: return TranscriptStyle.context
        case .error: return TranscriptStyle.error
        }
    }

    var label: String {
        switch self {
        case .prompt: return "Your prompt"
        case .command: return "A slash command"
        case .report: return "A background task or subagent reported back"
        case .task: return "The task list changed"
        case .skill: return "A skill was loaded"
        case .subagent: return "A subagent was launched"
        case .question: return "Claude asked you a question"
        case .edit: return "A file edit"
        case .plan: return "A plan written, presented or entered"
        case .compaction: return "The context was compacted"
        case .error: return "Something failed — a call, a hook or the API"
        }
    }
}

/// The hover card for a turn: which turn, when, how it started and what it did.
private struct RailLabel: View {
    let turn: TranscriptTurn
    let number: Int

    var body: some View {
        WrapToWidth(maxWidth: 300) { VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Turn \(number)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if let t = TranscriptFormat.clock(turn.startTime) {
                    Text(t).font(TranscriptStyle.meta).foregroundStyle(.tertiary)
                }
                if let ms = turn.durationMs {
                    Text(TranscriptFormat.duration(ms: ms)).font(TranscriptStyle.meta).foregroundStyle(.tertiary)
                }
            }
            Text(turn.label)
                .font(.system(size: 12))
                .lineLimit(2)
            let facts = [
                turn.toolCalls > 0 ? TranscriptFormat.plural(turn.toolCalls, "tool call") : nil,
                turn.edits > 0 ? TranscriptFormat.plural(turn.edits, "edit") : nil,
                turn.plans > 0 ? TranscriptFormat.plural(turn.plans, "plan step") : nil,
                turn.questions > 0 ? TranscriptFormat.plural(turn.questions, "question") : nil,
                turn.subagents > 0 ? TranscriptFormat.plural(turn.subagents, "subagent") : nil,
                turn.skills > 0 ? TranscriptFormat.plural(turn.skills, "skill") : nil,
                turn.tasks > 0 ? TranscriptFormat.plural(turn.tasks, "task update") : nil,
                turn.errors > 0 ? TranscriptFormat.plural(turn.errors, "error") : nil,
            ].compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(turn.errors > 0 ? TranscriptStyle.error : .secondary)
            }
        } }
        .railCard()
    }
}

/// The hover card for an event mark: what happened, when, and in which turn.
private struct RailEventLabel: View {
    let kind: TranscriptLandmark
    let text: String
    let time: TimeInterval?
    let turn: Int

    var body: some View {
        WrapToWidth(maxWidth: 300) { VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(kind.color).frame(width: 10, height: 3)
                Text("Turn \(turn)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if let t = TranscriptFormat.clock(time) {
                    Text(t).font(TranscriptStyle.meta).foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(kind == .error ? TranscriptStyle.error : Color.primary)
                .lineLimit(2)
        } }
        .railCard()
    }
}

/// Shrink-wraps its content up to `maxWidth`, wrapping text at that width. The cards used
/// `.fixedSize()` with a `.frame(maxWidth: 280)` on the prompt: SwiftUI then sizes the text's
/// height as one unwrapped line but draws it wrapped, so a two-line prompt pushed the facts line
/// out below the card's border. This asks for the height at the width actually used.
private struct WrapToWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, maxWidth)
        let fitted = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension View {
    func railCard() -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

/// The rail's key.
struct RailKey: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Timeline").font(.system(size: 12, weight: .semibold))
            Text("Each mark sits at its place in the transcript. Wide marks start a turn:")
                .font(TranscriptStyle.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(TranscriptLandmark.allCases.filter(\.startsTurn).reversed(), id: \.self) { keyRow($0) }
            Text("Short marks are what happened in it:")
                .font(TranscriptStyle.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(TranscriptLandmark.allCases.filter { !$0.startsTurn }.reversed(), id: \.self) { keyRow($0) }
            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.92)).frame(width: 16, height: 4)
                Text("Where you are").font(.system(size: 11.5))
            }
            Text("Reads, searches and replies get no mark. Hover a mark for what it is; click to go there.")
                .font(TranscriptStyle.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
    }

    private func keyRow(_ k: TranscriptLandmark) -> some View {
        let (w, t) = TranscriptRail.size(of: k)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: t / 2).fill(k.color).frame(width: w, height: t)
                .frame(width: 16)
            Text(k.label).font(.system(size: 11.5))
        }
    }
}
