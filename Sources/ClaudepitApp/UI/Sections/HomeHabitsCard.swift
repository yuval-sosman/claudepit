import SwiftUI
import ClaudepitCore

/// Home's Activity card: the habit view of every project — a year of daily messages as a
/// heatmap, with the streak and rhythm figures the CLI's Stats tab derives from the same cache
/// (`~/.claude/stats-cache.json`). It deliberately shows no tokens or models: what the work cost
/// and on which models is the Usage card's job, counted from the transcripts.
struct HomeHabitsCard: View {
    @ObservedObject var app: AppState

    var body: some View {
        if let stats = app.statsSnapshot, !stats.days.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Activity").font(.headline)
                        Spacer()
                        Text("all projects · messages per day")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    heatmap(stats)
                    statGrid(stats)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
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

    /// Rhythm, not volume: token and session totals belong to the Usage card.
    private func overviewCells(_ stats: StatsSnapshot) -> [(String, String)] {
        var out: [(String, String)] = []
        if stats.totalMessages > 0 { out.append(("Messages", stats.totalMessages.formatted())) }
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

}
