import SwiftUI
import ClaudepitCore

/// Home's Claude Code card — the CLI's whole `/usage` panel on one surface, fully expanded
/// (the user's explicit pick over tabs): limit gauges and usage-credits state, the
/// "What's contributing to your limits usage?" insights parsed from the print-mode report,
/// the Stats tab's Overview (activity heatmap, totals, streaks) and Models (per-model tokens,
/// tokens per day), and the CLI version beside the header — the Status tab's one useful fact.
///
/// Data comes from the caches the CLI keeps in `~/.claude.json` and `~/.claude/stats-cache.json`
/// plus the app-persisted report text; Refresh runs `/usage` non-interactively to rewrite them
/// all. State lives on `AppState` — a section's `@State` dies on every section switch, and an
/// in-flight refresh would be orphaned with it.
struct HomeUsageCard: View {
    @ObservedObject var app: AppState

    @State private var failure: String?
    /// Collapsed by default — the insights are reference material, not glanceable status.
    /// Cosmetic only, so `@State` is fine: re-entering Home resets it to collapsed, which is
    /// exactly the default the user asked for.
    @State private var insightsExpanded = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let snap = app.usageSnapshot {
                    gaugeStack(snap)
                    creditsLine(snap)
                } else {
                    Text("No usage data yet — Refresh runs `/usage` to fetch it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let report = app.usageReport, !report.windows.isEmpty {
                    collapsibleSectionHeader("What's using your limits", expanded: $insightsExpanded)
                    if insightsExpanded { insightsStack(report) }
                }
                if let stats = app.statsSnapshot, !stats.days.isEmpty {
                    sectionHeader("Stats")
                    overviewSection(stats)
                    if !stats.modelTotals.isEmpty {
                        sectionHeader("Models")
                        modelsSection(stats)
                    }
                }
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Header + refresh

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Code").font(.headline)
            if let version = app.claudeVersion {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { refresh() } label: {
                if app.isRefreshingUsage {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: Icon.refresh).font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(app.isRefreshingUsage || signedOut)
            .help(signedOut ? "Sign in first — /usage needs a logged-in CLI"
                            : "Run /usage to refresh the cached numbers")
        }
    }

    private var signedOut: Bool { app.claudeAuth?.needsSignIn == true }

    private func refresh() {
        failure = nil
        Task {
            let result = await app.refreshUsage()
            if result.failed { failure = result.text }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.15)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Same look as `sectionHeader`, but the whole row toggles `expanded`.
    private func collapsibleSectionHeader(_ title: String, expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.15)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(expanded.wrappedValue ? .degrees(90) : .zero)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded.wrappedValue ? "Collapse" : "Expand")
        }
    }

    // MARK: - Limits

    /// One visual language for every window — the two headline gauges and the model-scoped
    /// weekly rows all render the same labeled bar, so the card reads as one list. The rows and
    /// the drawing both live in `UsageGaugeStack`, shared with the menu bar panel.
    private func gaugeStack(_ snap: UsageSnapshot) -> some View {
        UsageGaugeStack(gauges: snap.gauges)
    }

    @ViewBuilder private func creditsLine(_ snap: UsageSnapshot) -> some View {
        if let extra = snap.extraUsage {
            Text(extra.isEnabled
                 ? "Usage credits: on" + (extra.utilization.map { " · \($0)% used" } ?? "")
                 : "Usage credits are off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Contributing insights

    private func insightsStack(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(report.windows) { window in insightBlock(window) }
        }
    }

    private func insightBlock(_ window: UsageReport.InsightWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label).font(.caption.weight(.semibold))
                if window.requests != nil || window.sessions != nil {
                    Text([window.requests.map { "\($0) requests" },
                          window.sessions.map { "\($0) sessions" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(window.behaviors, id: \.self) { behavior in
                Text("•  \(behavior)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !window.topSkills.isEmpty { rankedTable("Skills", window.topSkills) }
            if !window.topSubagents.isEmpty { rankedTable("Subagents", window.topSubagents) }
        }
    }

    /// The CLI renders these as an aligned two-column table ("Skills   % of usage") — a wrapped
    /// prose line loses that scanability, so each item gets its own name/percent row.
    private func rankedTable(_ title: String, _ items: [UsageReport.RankedItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            ForEach(items, id: \.name) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(item.percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Stats · Overview

    private func overviewSection(_ stats: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heatmap(stats)
            statGrid(stats)
            ioLine(stats.aggregateTotals)
            if let today = stats.today() {
                Text("Today: \(today.messageCount) message\(today.messageCount == 1 ? "" : "s") · "
                     + "\(today.sessionCount) session\(today.sessionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let heatmapWeekCount = 52
    /// Leading gutter that carries the Mon/Wed/Fri labels, like the CLI's.
    private static let heatmapGutter: CGFloat = 26
    private static let heatmapSpacing: CGFloat = 2
    private static let heatmapCellHeight: CGFloat = 9

    /// The CLI Overview's heatmap, full shape: a year of calendar-week columns with month names
    /// across the top, Mon/Wed/Fri down the left, and a Less→More legend — stretched to the
    /// card's width.
    ///
    /// Cells are **flexible-width** (`maxWidth: .infinity`) with a fixed height, so the grid
    /// always fills exactly the width it is proposed and can never exceed it. The first cut
    /// sized cells from a measured width instead; during live resize the measurement lagged a
    /// frame, the fixed-width grid outgrew the right column, and `GlassCard` (which sizes to
    /// content) pushed the whole card over the Tasks card beside it.
    private func heatmap(_ stats: StatsSnapshot) -> some View {
        let weeks = heatmapWeeks(stats, weekCount: Self.heatmapWeekCount)
        return VStack(alignment: .leading, spacing: 4) {
            monthLabels(weeks)
            HStack(alignment: .top, spacing: 0) {
                weekdayGutter
                HStack(alignment: .top, spacing: Self.heatmapSpacing) {
                    ForEach(weeks) { week in
                        VStack(spacing: Self.heatmapSpacing) {
                            ForEach(week.cells) { day in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(heatColor(day))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.heatmapCellHeight)
                                    .help(day.isFuture ? "" : "\(day.date) · \(day.count) messages")
                            }
                        }
                    }
                }
            }
            heatmapLegend
        }
    }

    /// One label where a week column starts a new month — 13 marks over 52 weeks, exactly the
    /// CLI's "Sep Oct … Sep" strip. Positioned by fraction of the measured row width; the
    /// GeometryReader is safe here because the row's height is fixed (the TasksSection hazard
    /// is a GeometryReader wrapping content whose size it must report).
    private func monthLabels(_ weeks: [HeatWeek]) -> some View {
        GeometryReader { geo in
            let pitch = (geo.size.width - Self.heatmapGutter + Self.heatmapSpacing)
                        / CGFloat(max(1, weeks.count))
            ZStack(alignment: .topLeading) {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                    if let label = week.monthLabel {
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: Self.heatmapGutter + CGFloat(index) * pitch)
                    }
                }
            }
        }
        .frame(height: 10)
    }

    /// Fixed-height rows matching the grid's, so the labels align without any offset math.
    private var weekdayGutter: some View {
        let calendar = Calendar.current
        return VStack(spacing: Self.heatmapSpacing) {
            ForEach(0..<7, id: \.self) { row in
                // Rows follow the calendar's first weekday; label the Mon/Wed/Fri rows wherever
                // they land (weekday units: 1 = Sunday), matched by number so locales still work.
                let weekday = ((calendar.firstWeekday - 1 + row) % 7) + 1
                Text([2, 4, 6].contains(weekday) ? calendar.shortWeekdaySymbols[weekday - 1] : "")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.heatmapGutter, height: Self.heatmapCellHeight,
                           alignment: .leading)
            }
        }
    }

    /// Swatches use the exact `heatColor` bucket opacities so the legend never lies.
    private var heatmapLegend: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach([0.3, 0.5, 0.75, 1.0], id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.orange.opacity(opacity))
                    .frame(width: 7, height: 7)
            }
            Text("More")
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
    }

    private struct HeatCell: Identifiable {
        let date: String
        let count: Int
        let isFuture: Bool
        var id: String { date }
    }

    private struct HeatWeek: Identifiable {
        let cells: [HeatCell]
        /// Short month name when this column starts a new month, nil otherwise.
        let monthLabel: String?
        var id: String { cells.first?.date ?? "" }
    }

    private func heatmapWeeks(_ stats: StatsSnapshot, weekCount: Int) -> [HeatWeek] {
        let calendar = Calendar.current
        let counts = Dictionary(stats.days.map { ($0.date, $0.messageCount) },
                                uniquingKeysWith: { a, _ in a })
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let today = calendar.startOfDay(for: Date())
        // Row 0 is the calendar's first weekday; the last column is the current week.
        let weekdayIndex = ((calendar.component(.weekday, from: today)
                             - calendar.firstWeekday) + 7) % 7
        guard let currentWeekStart = calendar.date(byAdding: .day, value: -weekdayIndex, to: today),
              let gridStart = calendar.date(byAdding: .day, value: -7 * (weekCount - 1),
                                            to: currentWeekStart)
        else { return [] }

        var previousMonth = -1
        return (0..<weekCount).map { week in
            let weekStart = calendar.date(byAdding: .day, value: week * 7, to: gridStart)
            let month = weekStart.map { calendar.component(.month, from: $0) } ?? previousMonth
            let label = month != previousMonth ? calendar.shortMonthSymbols[month - 1] : nil
            previousMonth = month
            let cells = (0..<7).compactMap { row -> HeatCell? in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + row,
                                               to: gridStart) else { return nil }
                let key = fmt.string(from: date)
                return HeatCell(date: key, count: counts[key] ?? 0, isFuture: date > today)
            }
            return HeatWeek(cells: cells, monthLabel: label)
        }
    }

    private func heatColor(_ cell: HeatCell) -> Color {
        if cell.isFuture { return .clear }
        guard cell.count > 0 else { return Color.white.opacity(0.06) }
        // Four intensity buckets like the CLI's "Less ▓▓▓ More" legend, scaled to the busiest day.
        let peak = max(1, app.statsSnapshot?.days.map(\.messageCount).max() ?? 1)
        let fraction = Double(cell.count) / Double(peak)
        let opacity: Double = fraction > 0.75 ? 1.0 : fraction > 0.5 ? 0.75 : fraction > 0.25 ? 0.5 : 0.3
        return Color.orange.opacity(opacity)
    }

    private func statGrid(_ stats: StatsSnapshot) -> some View {
        let cells = overviewCells(stats)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(0..<((cells.count + 1) / 2), id: \.self) { row in
                GridRow {
                    statCell(cells[row * 2])
                    if row * 2 + 1 < cells.count {
                        statCell(cells[row * 2 + 1])
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    private func overviewCells(_ stats: StatsSnapshot) -> [(String, String)] {
        var out: [(String, String)] = []
        if let favorite = stats.favoriteModel {
            out.append(("Favorite model", ModelNames.display(favorite)))
        }
        if stats.totalTokens > 0 {
            out.append(("Total tokens", CompactCount.tokens(stats.totalTokens)))
        }
        out.append(("Sessions", "\(stats.totalSessions)"))
        if let longest = stats.longestSession {
            out.append(("Longest session", longestText(longest)))
        }
        if let denominator = stats.daysSinceFirstSession(now: Date()) {
            out.append(("Active days", "\(stats.activeDayCount)/\(denominator)"))
        }
        let best = stats.longestStreak()
        if best > 0 {
            out.append(("Streak", "\(stats.currentStreak(now: Date()))d now · \(best)d best"))
        }
        if let day = stats.mostActiveDay { out.append(("Most active", shortDay(day))) }
        if let hour = stats.peakHour { out.append(("Peak hour", hourText(hour))) }
        return out
    }

    private func statCell(_ cell: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(cell.0)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(cell.1)
                .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func longestText(_ longest: LongestSession) -> String {
        let minutes = longest.durationMs / 60_000
        let duration = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return "\(duration) · \(longest.messageCount) msgs"
    }

    /// "2026-09-11" → "Sep 11".
    private func shortDay(_ ymd: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: ymd) else { return ymd }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func hourText(_ hour: Int) -> String {
        guard let date = Calendar.current.date(from: DateComponents(hour: hour)) else {
            return "\(hour):00"
        }
        return date.formatted(.dateTime.hour())
    }

    private func ioLine(_ totals: ModelTotals) -> some View {
        Text("In \(CompactCount.tokens(totals.inputTokens))"
             + " · Out \(CompactCount.tokens(totals.outputTokens))"
             + " · Cache \(CompactCount.tokens(totals.cacheReadTokens)) read"
             + " · \(CompactCount.tokens(totals.cacheCreationTokens)) write")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Stats · Models

    private func modelsSection(_ stats: StatsSnapshot) -> some View {
        let sorted = stats.modelTotals.sorted { $0.value.total > $1.value.total }
        let grandTotal = max(1, stats.totalTokens)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(sorted, id: \.key) { id, totals in
                modelRow(id: id, totals: totals,
                         share: Double(totals.total) / Double(grandTotal))
            }
            tokensPerDay(stats)
        }
    }

    private func modelRow(id: String, totals: ModelTotals, share: Double) -> some View {
        let color = ModelBadge.color(for: id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(ModelNames.display(id)).font(.subheadline)
                Spacer(minLength: 8)
                Text("\(Int((share * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(CompactCount.tokens(totals.total))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            UsageBar(fraction: share, tint: color)
            Text("In \(CompactCount.tokens(totals.inputTokens))"
                 + " · Out \(CompactCount.tokens(totals.outputTokens))"
                 + " · Cache \(CompactCount.tokens(totals.cacheReadTokens)) read"
                 + " · \(CompactCount.tokens(totals.cacheCreationTokens)) write")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct DayStack: Identifiable {
        let date: String
        let segments: [(model: String, tokens: Int)]
        var total: Int { segments.reduce(0) { $0 + $1.tokens } }
        var id: String { date }
    }

    /// The CLI's "Tokens per Day" step chart, translated to the narrow column: the last 14 days
    /// as stacked bars colored by model (hand-rolled — the app uses no Swift Charts anywhere).
    @ViewBuilder private func tokensPerDay(_ stats: StatsSnapshot) -> some View {
        let days = dayStacks(stats, dayCount: 14)
        let peak = max(1, days.map(\.total).max() ?? 1)
        if days.contains(where: { $0.total > 0 }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tokens per day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days) { day in
                        VStack(spacing: 0.5) {
                            ForEach(day.segments, id: \.model) { segment in
                                Rectangle()
                                    .fill(ModelBadge.color(for: segment.model))
                                    .frame(height: max(1, 80 * CGFloat(segment.tokens) / CGFloat(peak)))
                            }
                            if day.total == 0 {
                                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 2)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                        .help("\(shortDay(day.date)) · \(CompactCount.tokens(day.total)) tokens")
                    }
                }
                HStack {
                    if let first = days.first { Text(shortDay(first.date)) }
                    Spacer()
                    Text("today")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func dayStacks(_ stats: StatsSnapshot, dayCount: Int) -> [DayStack] {
        let calendar = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let byDate = Dictionary(stats.dailyModelTokens.map { ($0.date, $0.tokensByModel) },
                                uniquingKeysWith: { a, _ in a })
        let today = calendar.startOfDay(for: Date())
        return (0..<dayCount).compactMap { back -> DayStack? in
            guard let date = calendar.date(byAdding: .day, value: back - (dayCount - 1),
                                           to: today) else { return nil }
            let key = fmt.string(from: date)
            // Biggest model at the top of the stack, every day, so colors don't reshuffle.
            let segments = (byDate[key] ?? [:])
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { (model: $0.key, tokens: $0.value) }
            return DayStack(date: key, segments: segments)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            if let snap = app.usageSnapshot {
                Text("updated \(snap.fetchedAt.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(snap.isStale() ? Color.orange : Color.secondary)
            }
        }
        .font(.caption2)
    }
}
