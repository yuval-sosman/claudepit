import SwiftUI
import ClaudepitCore

// Pieces every usage surface shares — Home's Usage card and the session report — so a number,
// a colour or a breakdown reads the same wherever it appears.

/// One coloured slice of a cost breakdown.
struct UsageSegment: Identifiable {
    let id: String
    let label: String
    let cost: Double
    let color: Color
}

enum UsageBreakdown: String, CaseIterable {
    case model = "Model"
    case tokens = "Token type"
    case thread = "Thread"
}

enum UsagePalette {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// Checked as a categorical palette on the card surface in this order (adjacent pairs,
    /// normal and colour-blind vision) — `ProjectUsageSummary.byTokenType` keeps the order fixed
    /// so the check holds.
    static let tokenColors: [String: Color] = [
        "cacheRead": rgb(0x39, 0x87, 0xE5),    // blue
        "cacheWrite": rgb(0xD9, 0x59, 0x26),   // orange
        "output": rgb(0x19, 0x9E, 0x70),       // aqua
        "input": rgb(0xC9, 0x85, 0x00),        // yellow
    ]
    /// Main thread vs subagents: the first two slots of the same checked palette.
    static let mainThread = rgb(0x39, 0x87, 0xE5)
    static let subagents = rgb(0xD9, 0x59, 0x26)

    static func tokenSegments(_ slices: [CostSlice]) -> [UsageSegment] {
        slices.map { UsageSegment(id: $0.id, label: $0.label, cost: $0.cost, color: tokenColors[$0.id] ?? .gray) }
    }

    /// Stacked by family tier, not by cost, so neighbours are always the pairs the model palette
    /// was checked for; a second version of a family takes a lighter step. Past five, the tail
    /// folds into "Other".
    static func modelSegments(_ slices: [CostSlice]) -> [UsageSegment] {
        let rank = { (id: String) in
            ModelBadge.familyOrder.firstIndex(of: ModelBadge.family(id)) ?? ModelBadge.familyOrder.count
        }
        let ordered = slices.sorted { a, b in
            rank(a.id) != rank(b.id) ? rank(a.id) < rank(b.id)
                : a.cost != b.cost ? a.cost > b.cost : a.id < b.id
        }
        var seen: [String: Int] = [:]
        var out: [UsageSegment] = []
        for slice in ordered.prefix(5) {
            let family = ModelBadge.family(slice.id)
            let step = seen[family, default: 0]
            seen[family] = step + 1
            out.append(UsageSegment(id: slice.id, label: slice.label, cost: slice.cost,
                                    color: ModelBadge.color(for: slice.id).opacity(step == 0 ? 1 : 0.55)))
        }
        let rest = ordered.dropFirst(5).reduce(0) { $0 + $1.cost }
        if rest > 0 { out.append(UsageSegment(id: "other", label: "Other", cost: rest, color: .gray)) }
        return out
    }

    static func threadSegments(subagentShare: Double?, total: Double) -> [UsageSegment] {
        let sub = (subagentShare ?? 0) * total
        return [UsageSegment(id: "main", label: "Main thread", cost: total - sub, color: mainThread),
                UsageSegment(id: "sub", label: "Subagents", cost: sub, color: subagents)]
            .filter { $0.cost > 0 }
    }
}

/// "Cost by model · token type [· thread]": one stacked bar with its legend. The legend is the
/// identity channel (text in text colours, a dot beside it), the bar the proportion.
struct CostBreakdownView: View {
    let options: [UsageBreakdown]
    @Binding var selection: UsageBreakdown
    let total: Double
    let segments: [UsageSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Cost by")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(options, id: \.self) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                    } label: {
                        Text(option.rawValue.lowercased())
                            .font(.caption.weight(selection == option ? .semibold : .regular))
                            .foregroundStyle(selection == option ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            let whole = max(total, 0.000_001)
            StackedBar(parts: segments.map { ($0.cost / whole, $0.color, "\($0.label) · \(Money.compact($0.cost))") })
                .frame(height: 10)
            FlowLayout(spacing: 12) {
                ForEach(segments) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        Text(part.label).font(.caption)
                        Text("\(Money.compact(part.cost)) · \(Percent.text(part.cost / whole))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A part-to-whole bar: segments left to right, a 2pt gap between them, rounded outer ends.
struct StackedBar: View {
    /// (fraction of the whole, colour, tooltip)
    let parts: [(Double, Color, String)]
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let usable = max(0, geo.size.width - gap * CGFloat(max(0, parts.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.1)
                        .frame(width: max(2, usable * part.0))
                        .help(part.2)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

/// A labelled figure: what it is, the number, and what the number is of.
struct StatTile: View {
    let label: String
    let value: String
    let sub: String
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .help(help)
    }
}

/// Tiles in balanced rows, as many across as the width allows: six in one row on a wide sheet,
/// 3 + 3 in a card, 2 + 2 + 2 where it's narrow — never 5 + 1. An adaptive `LazyVGrid` can't do
/// this: it lays out every column that fits, so six tiles on a wide sheet were squeezed into
/// the first six of nine columns with the rest left empty.
struct StatTileGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        BalancedGridLayout { content }
    }
}

struct BalancedGridLayout: Layout {
    var minWidth: CGFloat = 104
    var spacing: CGFloat = 8

    private func rows(_ subviews: Subviews, width: CGFloat) -> (columns: Int, cell: CGFloat, heights: [CGFloat]) {
        let c = HomeLayout.balancedColumns(width: width, count: subviews.count,
                                           minWidth: minWidth, spacing: spacing)
        let cell = max(0, (width - spacing * CGFloat(c - 1)) / CGFloat(c))
        let heights = stride(from: 0, to: subviews.count, by: c).map { start in
            subviews[start..<min(start + c, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }
                .max() ?? 0
        }
        return (c, cell, heights)
    }

    /// Unspecified or unlimited proposals (SwiftUI asks for ideal sizes with nil and `.infinity`)
    /// get the ideal width: every tile in one row at its minimum.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = minWidth * CGFloat(max(1, subviews.count)) + spacing * CGFloat(max(0, subviews.count - 1))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        let r = rows(subviews, width: width)
        let height = r.heights.reduce(0, +) + spacing * CGFloat(max(0, r.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in r.heights.enumerated() {
            for column in 0..<r.columns {
                let index = row * r.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (r.cell + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: r.cell, height: height))
            }
            y += height + spacing
        }
    }
}

/// A caption-weight section title inside a card or report.
struct UsageSectionTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Formatting

/// Always `$` and US grouping: these are USD list prices, and a locale's currency style
/// ("US$579.38") reads as a foreign charge rather than a yardstick.
enum Money {
    private static let us = Locale(identifier: "en_US")

    /// `$579.38`, or `$1,234` once cents stop mattering.
    static func hero(_ usd: Double) -> String {
        "$" + usd.formatted(.number.locale(us).precision(.fractionLength(usd >= 1000 ? 0 : 2)))
    }

    /// `$0.42`, `$12.40`, `$369`, `$1,234`; `<$0.01` rather than a misleading `$0.00`.
    static func compact(_ usd: Double) -> String {
        if usd > 0 && usd < 0.005 { return "<$0.01" }
        return "$" + usd.formatted(.number.locale(us).precision(.fractionLength(usd >= 100 ? 0 : 2)))
    }
}

enum Percent {
    static func text(_ share: Double?) -> String {
        guard let share else { return "—" }
        let pct = share * 100
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }
}

enum Elapsed {
    /// `22.9 h`, or `42 min` under an hour.
    static func hours(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(Int((seconds / 60).rounded())) min"
                       : String(format: "%.1f h", seconds / 3600)
    }

    /// `<1s`, `45s`, `12m`, `2h 5m`, `3d 4h` — for gaps and durations in tables.
    static func short(_ seconds: TimeInterval) -> String {
        if seconds < 0.5 { return "<1s" }
        let s = Int(seconds.rounded())
        switch s {
        case ..<60:      return "\(s)s"
        case ..<3600:    return "\(s / 60)m"
        case ..<86_400:  return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
        default:         return "\(s / 86_400)d \(s % 86_400 / 3600)h"
        }
    }
}

extension UsageScope {
    var label: String {
        switch self {
        case .project: return "This project"
        case .all:     return "All projects"
        }
    }
}

/// Where a session ran, for a row that may come from another project: `claudepit`, or
/// `claudepit ▸ task-5de7827b…` for a worktree.
enum SessionPlace {
    static func label(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if let range = cwd.range(of: "/.claude/worktrees/") {
            let repo = URL(filePath: String(cwd[..<range.lowerBound])).lastPathComponent
            let tree = String(cwd[range.upperBound...]).split(separator: "/").first.map(String.init) ?? ""
            return "\(repo) ▸ \(tree)"
        }
        return URL(filePath: cwd).lastPathComponent
    }
}
