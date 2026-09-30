import SwiftUI
import ClaudepitCore

/// Home's Usage card: what Claude Code work amounted to, counted from the transcripts
/// themselves — for the open project (its task worktrees included) or for every project — with
/// every call priced at API list prices. Report numbers only, no advice.
///
/// One question per row, most important first: what it cost and when (hero + daily bars), how
/// the work went (six tiles), where the cost sits (one stacked bar, by model or token type),
/// and which sessions drove it. Everything is computed by `ProjectUsageSummary` off the main
/// actor; the view only formats. It is the one place Home answers "how much, on which models":
/// the Claude Code card is limits only and the Activity card is habits only.
struct HomeUsageCard: View {
    @ObservedObject var app: AppState

    /// Remembered across launches: which window you look at is a standing preference.
    @AppStorage("homeUsagePeriod") private var period: UsagePeriod = .month
    @State private var breakdown: UsageBreakdown = .model
    @State private var hoveredDay: Date?

    private var scope: UsageScope { app.usageScope }

    /// Only a summary of what the switch asks for — a scan of the previous project never shows.
    private var summary: ProjectUsageSummary? {
        if scope == .project, app.projectUsagePath != app.activePath { return nil }
        return app.projectUsage[scope]?[period]
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let s = summary {
                    if s.isEmpty {
                        Text(scope == .project
                             ? "No Claude Code activity in this project in the \(period.longLabel)."
                             : "No Claude Code activity in the \(period.longLabel).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        hero(s)
                        tiles(s)
                        CostBreakdownView(options: [.model, .tokens], selection: $breakdown,
                                          total: s.cost, segments: segments(s))
                        if !s.topSessions.isEmpty { costliestSessions(s) }
                        if !s.unpriced.isEmpty { pricingNote(s) }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(scope == .project ? "Counting this project's transcripts…"
                                               : "Counting every project's transcripts…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .onChange(of: period) { hoveredDay = nil }
        .onChange(of: app.usageScope) { hoveredDay = nil }
        // No onAppear scan of its own: Home's onAppear reloads sessions, and that reload
        // rescans usage whenever Home is showing — one trigger, not two racing.
    }

    /// Title and period on one row; the scope reads as the subtitle and is its own switch —
    /// two segmented controls side by side don't fit the narrow column.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Usage").font(.headline)
                Spacer(minLength: 8)
                SegmentedControl(selection: $period) { Text($0.rawValue) }
                    .help("Days counted, today included")
            }
            HStack(spacing: 10) {
                ForEach(UsageScope.allCases) { option in
                    Button { app.usageScope = option } label: {
                        Text(option.label)
                            .font(.caption.weight(scope == option ? .semibold : .regular))
                            .foregroundStyle(scope == option ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(option == .project ? "This project and its task worktrees" : "Every project on this Mac")
                }
            }
        }
    }

    // MARK: - Hero: cost + daily bars

    /// Side by side where the column is wide enough, stacked where it isn't.
    private func hero(_ s: ProjectUsageSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                heroFigure(s)
                Spacer(minLength: 0)
                dailyBars(s).frame(minWidth: 180, maxWidth: 260)
            }
            VStack(alignment: .leading, spacing: 12) {
                heroFigure(s)
                dailyBars(s)
            }
        }
    }

    private func heroFigure(_ s: ProjectUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Money.hero(s.cost))
                .font(.system(size: 30, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("at API list prices · \(s.apiCalls.formatted()) API calls")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
        .help("What these tokens would cost at Anthropic API list prices, cache writes and "
              + "fast mode included. Transcripts log tokens, not dollars — on a subscription "
              + "this is a yardstick for comparing work, not your bill.")
    }

    /// One series, so no legend: the readout above the bars names what they are. Bars are the
    /// de-emphasis gray with today in the accent; hovering a day moves the accent and the
    /// readout to it. Every day of the window is a column, idle days a hairline.
    private func dailyBars(_ s: ProjectUsageSummary) -> some View {
        let peak = max(s.daily.map(\.cost).max() ?? 0, 0.01)
        let today = s.daily.last?.day
        let focus = hoveredDay ?? today
        let focused = s.daily.first { $0.day == focus }
        let gap: CGFloat = s.daily.count > 45 ? 1 : 2
        return VStack(alignment: .trailing, spacing: 4) {
            Text(focused.map { readout($0, isToday: $0.day == today) } ?? " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(s.daily) { day in
                    let isFocus = day.day == focus
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if day.cost > 0 {
                            UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5)
                                .fill(isFocus ? Color.accentColor : Color.white.opacity(0.28))
                                .frame(height: max(2, 40 * day.cost / peak))
                        } else {
                            Rectangle()
                                .fill(Color.white.opacity(isFocus ? 0.3 : 0.08))
                                .frame(height: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The whole column is the hit target, not the (often hairline) bar.
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day.day } else if hoveredDay == day.day { hoveredDay = nil }
                    }
                }
            }
            .frame(height: 40)
            HStack {
                if let first = s.daily.first {
                    Text(first.day.formatted(.dateTime.month(.abbreviated).day()))
                }
                Spacer()
                Text("today")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func readout(_ day: DayCost, isToday: Bool) -> String {
        let label = isToday ? "Today" : day.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(label) · \(Money.compact(day.cost))"
    }

    // MARK: - Tiles

    private func tiles(_ s: ProjectUsageSummary) -> some View {
        StatTileGrid {
            StatTile(label: "Sessions", value: s.sessions.formatted(),
                     sub: "\(s.prompts.formatted()) prompt\(s.prompts == 1 ? "" : "s")",
                     help: "Sessions active in the period, and the prompts you typed in them")
            StatTile(label: "Active time", value: Elapsed.hours(s.activeSeconds), sub: "idle gaps excluded",
                     help: "Time between a session's events, with any gap over five minutes left out")
            StatTile(label: "Cache hit rate", value: Percent.text(s.cacheHitRate), sub: "of input from cache",
                     help: "Cache reads ÷ every input token (uncached input + cache reads + cache writes)")
            StatTile(label: "Subagents", value: Percent.text(s.subagentShare), sub: "of cost",
                     help: "Share of cost from subagent calls")
            StatTile(label: "Task worktrees", value: Percent.text(s.worktreeShare), sub: "of cost",
                     help: "Share of cost from sessions in .claude/worktrees checkouts")
            StatTile(label: "Peak context", value: s.medianPeakContext.map(CompactCount.tokens) ?? "—",
                     sub: "median per session",
                     help: "Each session's largest main-thread context, median across sessions")
        }
    }

    // MARK: - Breakdown

    private func segments(_ s: ProjectUsageSummary) -> [UsageSegment] {
        switch breakdown {
        case .tokens: return UsagePalette.tokenSegments(s.byTokenType)
        case .model, .thread: return UsagePalette.modelSegments(s.byModel)
        }
    }

    // MARK: - Costliest sessions

    private func costliestSessions(_ s: ProjectUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            UsageSectionTitle(title: "Costliest sessions")
                .padding(.bottom, 4)
            ForEach(s.topSessions) { session in
                // Opens in Sessions only when it belongs to the open project — the list there
                // is scoped to it. Other projects' rows name where they ran instead.
                let listed = app.sessions.first { $0.id == session.id }
                let place = scope == .all ? SessionPlace.label(cwd: session.cwd) : nil
                Button {
                    app.focusSessionID = session.id
                    app.selected = .sessions
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(listed?.title ?? session.title ?? String(session.id.prefix(8)))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let place {
                                Text(place)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(session.lastActive.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Money.compact(session.cost))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(listed == nil)
                .help(listed == nil ? "Open that project to see this session" : "Open this session")
            }
        }
    }

    private func pricingNote(_ s: ProjectUsageSummary) -> some View {
        let parts = s.unpriced.map { m in
            m.pricedAs.map { "\(ModelNames.display(m.model)) priced as \(ModelNames.display($0))" }
                ?? "\(ModelNames.display(m.model)) not priced"
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
