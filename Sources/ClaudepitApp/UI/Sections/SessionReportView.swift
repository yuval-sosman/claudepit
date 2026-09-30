import SwiftUI
import ClaudepitCore

/// Everything a session report needs, taken from the session row when the sheet opens — so
/// the report reads files only, never the Sessions page's changing state.
struct SessionReportRequest: Hashable, Identifiable {
    var id: String { sessionID }
    struct Subagent: Hashable {
        let id: String
        let type: String
        let description: String
        let path: String
    }
    let sessionID: String
    let title: String
    let mainPath: String
    let inWorktree: Bool
    let subagents: [Subagent]

    init(session: SessionSummary) {
        sessionID = session.id
        title = session.title
        mainPath = session.fileURL.path
        inWorktree = session.projectSlug.contains("--claude-worktrees-")
        subagents = session.subagents.map {
            Subagent(id: $0.id, type: $0.agentType, description: $0.description, path: $0.fileURL.path)
        }
    }

    /// Re-reads the subagent list at load time: a running session keeps spawning them.
    var subagentSummaries: [SubagentSummary] {
        subagents.map {
            SubagentSummary(id: $0.id, toolUseId: "", agentType: $0.type, description: $0.description,
                            spawnDepth: 1, fileURL: URL(filePath: $0.path))
        }
    }
}

/// One session's usage report, as a sheet over the app like Source Control: the session's cost,
/// how its context grew, every cache miss with its cause and what it cost over a hit, and the
/// subagents and tools it ran. Report numbers only — the same counting as Home's Usage card, per
/// session.
struct SessionReportView: View {
    let request: SessionReportRequest

    @Environment(\.dismiss) private var dismiss
    @State private var report: SessionReport?
    @State private var loading = false
    @State private var failed = false
    @State private var breakdown: UsageBreakdown = .tokens
    @State private var showAllMisses = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.2)
            ScrollView { content }
        }
        .background(.ultraThinMaterial)
        .task { await load() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            subtitle
            if let r = report {
                if r.summary.apiCalls == 0 {
                    Text("This session made no API calls.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    overview(r)
                    costSection(r)
                    contextSection(r)
                    cacheSection(r)
                    if !r.subagents.isEmpty { subagentSection(r) }
                    if !r.tools.isEmpty { toolSection(r) }
                    if !r.summary.unpriced.isEmpty { pricingNote(r) }
                }
            } else if failed {
                Text("Couldn't read this session's transcript.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the transcript…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: 1080, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        loading = true
        let request = self.request
        let loaded = await Task.detached(priority: .userInitiated) {
            // Pick up subagents spawned since the window opened.
            let main = URL(filePath: request.mainPath)
            let subDir = main.deletingPathExtension().appending(path: "subagents")
            let known = Dictionary(request.subagentSummaries.map { ($0.fileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
            let files = ((try? FileManager.default.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            let subagents = files.map { file in
                known[file.path] ?? SubagentSummary(
                    id: String(file.deletingPathExtension().lastPathComponent.dropFirst("agent-".count)),
                    toolUseId: "", agentType: "subagent", description: "", spawnDepth: 1, fileURL: file)
            }
            return SessionReport.load(sessionID: request.sessionID, mainFile: main,
                                      subagents: subagents.isEmpty ? request.subagentSummaries : subagents,
                                      inWorktree: request.inWorktree)
        }.value
        report = loaded
        failed = loaded == nil
        loading = false
    }

    // MARK: - Title bar

    /// The Source Control sheet's bar: what this is · which session, then refresh and close.
    private var titleBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 15)).foregroundStyle(Color.accentColor)
            Text("Session Report").font(.headline)
            Text("·").foregroundStyle(.secondary)
            Text(request.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { Task { await load() } } label: {
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary) }
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .help("Re-read the transcript (a running session keeps growing)")
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// When the session ran and its id — the title is already in the bar.
    private var subtitle: some View {
        HStack(spacing: 6) {
            if let r = report, let start = r.start, let end = r.end {
                Text(span(start, end))
                Text("·")
                Text(Elapsed.short(end.timeIntervalSince(start)) + " wall clock")
                Text("·")
            }
            Text(request.sessionID)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func span(_ start: Date, _ end: Date) -> String {
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        let from = start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let to = sameDay ? end.formatted(.dateTime.hour().minute())
                         : end.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(from) – \(to)"
    }

    // MARK: - Overview

    private func overview(_ r: SessionReport) -> some View {
        let s = r.summary
        return StatTileGrid {
            StatTile(label: "Cost", value: Money.hero(s.cost), sub: "at API list prices",
                     help: "Tokens × Anthropic API list prices, cache writes and fast mode included — a yardstick, not a bill")
            StatTile(label: "API calls", value: s.apiCalls.formatted(),
                     sub: r.subagentCalls > 0 ? "\(r.mainCalls) main · \(r.subagentCalls) sub" : "main thread",
                     help: "One per message id + request id; subagent calls included")
            StatTile(label: "Prompts", value: s.prompts.formatted(), sub: "typed by you",
                     help: "Prompts you typed or queued; slash commands and task notifications excluded")
            StatTile(label: "Active time", value: Elapsed.hours(s.activeSeconds), sub: "idle excluded",
                     help: "Time between the session's events, with any gap over five minutes left out")
            StatTile(label: "Cache hit rate", value: Percent.text(s.cacheHitRate),
                     sub: r.mainCacheLifetime.map { $0 >= 3600 ? "1-hour cache" : "5-minute cache" } ?? "of input from cache",
                     help: "Cache reads ÷ every input token. The cache lifetime is the one the main thread wrote.")
            StatTile(label: "Peak context", value: r.peakContext.map(CompactCount.tokens) ?? "—",
                     sub: r.baselineContext.map { "from \(CompactCount.tokens($0))" } ?? "main thread",
                     help: "The main thread's largest request, and its first — the start-up baseline")
        }
    }

    // MARK: - Cost

    private func costSection(_ r: SessionReport) -> some View {
        let s = r.summary
        let options: [UsageBreakdown] = r.subagentCalls > 0 ? [.tokens, .model, .thread] : [.tokens, .model]
        let parts: [UsageSegment]
        switch breakdown {
        case .tokens: parts = UsagePalette.tokenSegments(s.byTokenType)
        case .model:  parts = UsagePalette.modelSegments(s.byModel)
        case .thread: parts = UsagePalette.threadSegments(subagentShare: s.subagentShare, total: s.cost)
        }
        return CostBreakdownView(options: options, selection: $breakdown, total: s.cost, segments: parts)
    }

    // MARK: - Context

    private func contextSection(_ r: SessionReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                UsageSectionTitle(title: "Context per main-thread call")
                Spacer()
                if r.compactions > 0 {
                    Text("\(r.compactions) compaction\(r.compactions == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if r.context.count > 1 {
                ContextChart(points: r.context)
            } else {
                Text("One main-thread call — nothing to chart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cache

    private func cacheSection(_ r: SessionReport) -> some View {
        let s = r.summary
        return VStack(alignment: .leading, spacing: 12) {
            UsageSectionTitle(title: "Cache")
            StatTileGrid {
                StatTile(label: "Misses", value: r.misses.count.formatted(),
                         sub: "over \(SessionReport.missThreshold.formatted()) tokens",
                         help: "Calls that wrote their thread's earlier history to the cache again")
                StatTile(label: "Tokens re-written", value: CompactCount.tokens(r.missTokens),
                         sub: "\(Percent.text(r.cacheWriteTokens > 0 ? Double(r.missTokens) / Double(r.cacheWriteTokens) : nil)) of writes",
                         help: "Previous context − this call's cache read − its input, capped at what it wrote")
                StatTile(label: "Extra cost", value: Money.compact(r.missCost),
                         sub: "\(Percent.text(s.cost > 0 ? r.missCost / s.cost : nil)) of session",
                         help: "Re-written tokens × (write price − read price): what the misses paid over cache hits")
                StatTile(label: "Re-read ratio", value: r.rereadPerOutput.map { "\(Int($0.rounded()))×" } ?? "—",
                         sub: "per output token",
                         help: "How many context tokens were re-sent for every token Claude wrote")
                StatTile(label: "Main thread hits", value: Percent.text(r.mainHitRate), sub: "hit rate")
                if r.subagentCalls > 0 {
                    StatTile(label: "Subagent hits", value: Percent.text(r.subagentHitRate), sub: "hit rate")
                }
            }
            if r.misses.isEmpty {
                Text("No cache misses — every call reused the cached context.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                causesTable(r)
                missesTable(r)
            }
        }
    }

    private func causesTable(_ r: SessionReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Cause"); Text("Misses").gridColumnAlignment(.trailing)
                Text("Re-written").gridColumnAlignment(.trailing); Text("Extra cost").gridColumnAlignment(.trailing)
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(r.causes) { c in
                GridRow {
                    HStack(spacing: 4) {
                        Text(c.cause)
                        Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .help(SessionReport.causeHelp[c.cause] ?? "")
                    Text(c.misses.formatted())
                    Text(CompactCount.tokens(c.tokens))
                    Text(Money.compact(c.extraCost))
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func missesTable(_ r: SessionReport) -> some View {
        let shown = showAllMisses ? r.misses : Array(r.misses.prefix(8))
        return VStack(alignment: .leading, spacing: 6) {
            Text(r.misses.count > 8 && !showAllMisses ? "Largest misses" : "Every miss")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("When"); Text("Thread"); Text("Idle before").gridColumnAlignment(.trailing)
                    Text("Re-written").gridColumnAlignment(.trailing); Text("Cause")
                    Text("Extra cost").gridColumnAlignment(.trailing)
                }
                .font(.caption2).foregroundStyle(.tertiary)
                ForEach(shown) { m in
                    GridRow {
                        Text(m.time.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        Text(m.thread).lineLimit(1)
                        Text(Elapsed.short(m.idleBefore))
                            .foregroundStyle(m.idleBefore > m.cacheLifetime ? Color.orange : .primary)
                            .help("Cache lifetime \(Elapsed.short(m.cacheLifetime))")
                        Text(CompactCount.tokens(m.rewritten))
                        Text(m.cause).lineLimit(1).help(SessionReport.causeHelp[m.cause] ?? "")
                        Text(Money.compact(m.extraCost))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            if r.misses.count > 8 {
                Button(showAllMisses ? "Show fewer" : "Show all \(r.misses.count)") { showAllMisses.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Subagents

    private func subagentSection(_ r: SessionReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSectionTitle(title: "Subagents (\(r.subagents.count))")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Subagent"); Text("Model"); Text("Calls").gridColumnAlignment(.trailing)
                    Text("Hit rate").gridColumnAlignment(.trailing); Text("Peak").gridColumnAlignment(.trailing)
                    Text("Misses").gridColumnAlignment(.trailing); Text("Cost").gridColumnAlignment(.trailing)
                }
                .font(.caption2).foregroundStyle(.tertiary)
                ForEach(r.subagents) { a in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.type).lineLimit(1)
                            if !a.description.isEmpty {
                                Text(a.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text(a.models.map(ModelNames.display).joined(separator: ", ")).lineLimit(1)
                        Text(a.calls.formatted())
                        Text(Percent.text(a.hitRate))
                        Text(CompactCount.tokens(a.peakContext))
                        Text(a.misses.formatted())
                        Text(Money.compact(a.cost)).fontWeight(.semibold)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    // MARK: - Tools

    private func toolSection(_ r: SessionReport) -> some View {
        let top = Array(r.tools.prefix(12))
        let most = max(1, top.map(\.calls).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            UsageSectionTitle(title: "Tools (\(r.tools.reduce(0) { $0 + $1.calls }.formatted()) calls)")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(top) { t in
                    GridRow {
                        Text(t.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.28))
                                .frame(width: max(2, geo.size.width * CGFloat(t.calls) / CGFloat(most)))
                        }
                        .frame(height: 8)
                        Text(t.calls.formatted()).font(.caption.monospacedDigit()).gridColumnAlignment(.trailing)
                        Text(t.errors > 0 ? "\(t.errors) failed" : "")
                            .font(.caption2).foregroundStyle(.orange)
                        Text(Elapsed.short(t.totalSeconds) + " total")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            if r.tools.count > top.count {
                Text("+ \(r.tools.count - top.count) more tools")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func pricingNote(_ r: SessionReport) -> some View {
        Text(r.summary.unpriced.map { m in
            m.pricedAs.map { "\(ModelNames.display(m.model)) priced as \(ModelNames.display($0))" }
                ?? "\(ModelNames.display(m.model)) not priced"
        }.joined(separator: " · "))
        .font(.caption2).foregroundStyle(.tertiary)
    }
}

/// Context size of every main-thread call, in order: a line over a light wash, cache misses as
/// orange dots, compactions as thin rules. Hovering a call names it in the readout above.
private struct ContextChart: View {
    let points: [SessionReport.ContextPoint]
    @State private var hovered: Int?

    private static let height: CGFloat = 150
    private static let missColor = Color.orange

    var body: some View {
        let peak = max(1, points.map(\.context).max() ?? 1)
        let top = Double(peak) * 1.08
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(readout).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Self.missColor).frame(width: 7, height: 7)
                    Text("cache miss")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let x = { (i: Int) in points.count > 1 ? w * CGFloat(i) / CGFloat(points.count - 1) : w / 2 }
                let y = { (v: Int) in h - h * CGFloat(Double(v) / top) }
                ZStack(alignment: .topLeading) {
                    // Recessive frame: a hairline at the top of the scale and the baseline.
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).offset(y: h - 1)
                    ForEach(Array(points.enumerated()).filter { $0.element.afterCompaction }, id: \.offset) { i, _ in
                        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: h).offset(x: x(i))
                    }
                    Path { p in
                        p.move(to: CGPoint(x: x(0), y: h))
                        for (i, pt) in points.enumerated() { p.addLine(to: CGPoint(x: x(i), y: y(pt.context))) }
                        p.addLine(to: CGPoint(x: x(points.count - 1), y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.accentColor.opacity(0.10))
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let point = CGPoint(x: x(i), y: y(pt.context))
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    ForEach(Array(points.enumerated()).filter { $0.element.isMiss }, id: \.offset) { i, pt in
                        Circle()
                            .fill(Self.missColor)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2).padding(-2))
                            .position(x: x(i), y: y(pt.context))
                    }
                    if let i = hovered, points.indices.contains(i) {
                        Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: h).offset(x: x(i))
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            .position(x: x(i), y: y(points[i].context))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let step = points.count > 1 ? w / CGFloat(points.count - 1) : w
                        hovered = min(points.count - 1, max(0, Int((location.x / step).rounded())))
                    case .ended:
                        hovered = nil
                    }
                }
            }
            .frame(height: Self.height)
            HStack {
                Text("call 1")
                Spacer()
                Text("peak \(CompactCount.tokens(peak))")
                Spacer()
                Text("call \(points.count)")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var readout: String {
        if let i = hovered, points.indices.contains(i) {
            let p = points[i]
            var text = "Call \(p.id) · \(p.time.formatted(.dateTime.hour().minute())) · \(CompactCount.tokens(p.context)) tokens"
            if p.isMiss { text += " · re-wrote \(CompactCount.tokens(p.rewritten))" }
            if p.afterCompaction { text += " · after a compaction" }
            return text
        }
        guard let first = points.first, let last = points.last else { return "" }
        let peak = points.map(\.context).max() ?? 0
        return "\(points.count) calls · starts at \(CompactCount.tokens(first.context)) · "
            + "peaks at \(CompactCount.tokens(peak)) · ends at \(CompactCount.tokens(last.context))"
    }
}
