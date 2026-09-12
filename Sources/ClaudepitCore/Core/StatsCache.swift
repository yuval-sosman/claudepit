import Foundation

/// One row of `dailyActivity` in the CLI's `stats-cache.json` (schema v5).
public struct StatsCacheDay: Equatable, Sendable {
    /// `YYYY-MM-DD`, kept as the string the cache stores so no timezone is invented on read.
    public let date: String
    public let messageCount: Int
    public let sessionCount: Int
    public let toolCallCount: Int

    public init(date: String, messageCount: Int, sessionCount: Int, toolCallCount: Int) {
        self.date = date
        self.messageCount = messageCount
        self.sessionCount = sessionCount
        self.toolCallCount = toolCallCount
    }
}

/// One row of `dailyModelTokens` — total tokens per model for one calendar day.
public struct DayModelTokens: Equatable, Sendable {
    public let date: String
    public let tokensByModel: [String: Int]

    public init(date: String, tokensByModel: [String: Int]) {
        self.date = date
        self.tokensByModel = tokensByModel
    }

    public var total: Int { tokensByModel.values.reduce(0, +) }
}

/// One model's all-time totals from `modelUsage`.
public struct ModelTotals: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public init(inputTokens: Int, outputTokens: Int,
                cacheReadTokens: Int, cacheCreationTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    public var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

public struct LongestSession: Equatable, Sendable {
    /// Milliseconds, as the cache stores it.
    public let durationMs: Int
    public let messageCount: Int

    public init(durationMs: Int, messageCount: Int) {
        self.durationMs = durationMs
        self.messageCount = messageCount
    }
}

/// Everything Home renders from `stats-cache.json` — the CLI's Stats tab (Overview + Models)
/// as one value. All derivations are pure; the calendar/now they need is injected so the math
/// is testable against fixed dates (Core purity rule: no filesystem, no ambient clock).
public struct StatsSnapshot: Equatable, Sendable {
    public let days: [StatsCacheDay]
    public let dailyModelTokens: [DayModelTokens]
    public let modelTotals: [String: ModelTotals]
    public let totalSessions: Int
    public let totalMessages: Int
    public let longestSession: LongestSession?
    /// ISO timestamp string, verbatim from the cache (e.g. `2026-09-06T18:31:06.340Z`).
    public let firstSessionDate: String?
    /// Hour-of-day (0–23) → message count.
    public let hourCounts: [Int: Int]

    public init(days: [StatsCacheDay], dailyModelTokens: [DayModelTokens],
                modelTotals: [String: ModelTotals], totalSessions: Int, totalMessages: Int,
                longestSession: LongestSession?, firstSessionDate: String?,
                hourCounts: [Int: Int]) {
        self.days = days
        self.dailyModelTokens = dailyModelTokens
        self.modelTotals = modelTotals
        self.totalSessions = totalSessions
        self.totalMessages = totalMessages
        self.longestSession = longestSession
        self.firstSessionDate = firstSessionDate
        self.hourCounts = hourCounts
    }

    // MARK: - Derivations (Overview tab)

    /// The model that consumed the most tokens all-time. Ties break by name so the answer
    /// is stable across dictionary orderings.
    public var favoriteModel: String? {
        modelTotals.max { a, b in
            a.value.total != b.value.total ? a.value.total < b.value.total : a.key > b.key
        }?.key
    }

    public var totalTokens: Int { modelTotals.values.reduce(0) { $0 + $1.total } }

    /// Field-wise sum across models — the Overview's "Input … · Output … · Cache read …" line.
    public var aggregateTotals: ModelTotals {
        modelTotals.values.reduce(ModelTotals(inputTokens: 0, outputTokens: 0,
                                              cacheReadTokens: 0, cacheCreationTokens: 0)) {
            ModelTotals(inputTokens: $0.inputTokens + $1.inputTokens,
                        outputTokens: $0.outputTokens + $1.outputTokens,
                        cacheReadTokens: $0.cacheReadTokens + $1.cacheReadTokens,
                        cacheCreationTokens: $0.cacheCreationTokens + $1.cacheCreationTokens)
        }
    }

    /// Days that saw any activity — `dailyActivity` only records active days.
    public var activeDayCount: Int { days.count }

    /// Calendar days from the first session through `now`, inclusive — the denominator of the
    /// CLI's "Active days: 5/7". nil when the cache has no first-session stamp.
    public func daysSinceFirstSession(now: Date, calendar: Calendar = .current) -> Int? {
        guard let raw = firstSessionDate, let first = ISO8601Pair().date(raw) else { return nil }
        let from = calendar.startOfDay(for: first)
        let to = calendar.startOfDay(for: now)
        guard let gap = calendar.dateComponents([.day], from: from, to: to).day, gap >= 0
        else { return nil }
        return gap + 1
    }

    /// Consecutive active days ending today — or ending yesterday when today has no row yet,
    /// so the streak doesn't read as broken before the day's first session.
    public func currentStreak(now: Date, calendar: Calendar = .current) -> Int {
        let active = Set(days.map(\.date))
        let fmt = StatsSnapshot.dayFormatter(calendar)
        var cursor = calendar.startOfDay(for: now)
        if !active.contains(fmt.string(from: cursor)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor)
            else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while active.contains(fmt.string(from: cursor)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// Longest run of consecutive active days anywhere in the history.
    public func longestStreak(calendar: Calendar = .current) -> Int {
        let fmt = StatsSnapshot.dayFormatter(calendar)
        let dates = days.compactMap { fmt.date(from: $0.date) }.sorted()
        var best = 0, run = 0
        var previous: Date?
        for date in dates {
            if let p = previous,
               let next = calendar.date(byAdding: .day, value: 1, to: p),
               calendar.isDate(next, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = date
        }
        return best
    }

    /// `YYYY-MM-DD` of the busiest day by message count.
    public var mostActiveDay: String? {
        days.max { a, b in
            a.messageCount != b.messageCount ? a.messageCount < b.messageCount : a.date > b.date
        }?.date
    }

    /// Hour of day (0–23) with the most messages.
    public var peakHour: Int? {
        hourCounts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key
    }

    /// Today's activity row, or nil when nothing ran since midnight.
    public func today(now: Date = Date(), calendar: Calendar = .current) -> StatsCacheDay? {
        StatsCache.today(days, now: now, calendar: calendar)
    }

    static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }
}

/// Reader for `~/.claude/stats-cache.json`. Read-only, best-effort: the CLI owns the file and
/// rewrites it on `/usage`, so every failure path returns empty rather than surfacing an error.
public enum StatsCache {
    /// `dailyActivity` is an **array** in schema v5 (it was a date-keyed object in older ones,
    /// which this deliberately does not read — the counts there are not comparable).
    public static func parseDaily(root: [String: Any]) -> [StatsCacheDay] {
        guard let rows = root["dailyActivity"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let date = row["date"] as? String else { return nil }
            return StatsCacheDay(
                date: date,
                messageCount: (row["messageCount"] as? NSNumber)?.intValue ?? 0,
                sessionCount: (row["sessionCount"] as? NSNumber)?.intValue ?? 0,
                toolCallCount: (row["toolCallCount"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// The whole v5 cache as one snapshot. Every key is optional-tolerant: a truncated or
    /// older-schema file parses to empty collections rather than nil, matching `parseDaily`.
    public static func parseSnapshot(root: [String: Any]) -> StatsSnapshot {
        let dailyTokens = (root["dailyModelTokens"] as? [[String: Any]] ?? []).compactMap {
            row -> DayModelTokens? in
            guard let date = row["date"] as? String else { return nil }
            let tokens = (row["tokensByModel"] as? [String: Any] ?? [:])
                .compactMapValues { ($0 as? NSNumber)?.intValue }
            return DayModelTokens(date: date, tokensByModel: tokens)
        }

        let totals = (root["modelUsage"] as? [String: Any] ?? [:]).compactMapValues {
            value -> ModelTotals? in
            guard let row = value as? [String: Any] else { return nil }
            return ModelTotals(
                inputTokens: (row["inputTokens"] as? NSNumber)?.intValue ?? 0,
                outputTokens: (row["outputTokens"] as? NSNumber)?.intValue ?? 0,
                cacheReadTokens: (row["cacheReadInputTokens"] as? NSNumber)?.intValue ?? 0,
                cacheCreationTokens: (row["cacheCreationInputTokens"] as? NSNumber)?.intValue ?? 0)
        }

        var longest: LongestSession?
        if let row = root["longestSession"] as? [String: Any],
           let duration = (row["duration"] as? NSNumber)?.intValue {
            longest = LongestSession(
                durationMs: duration,
                messageCount: (row["messageCount"] as? NSNumber)?.intValue ?? 0)
        }

        let hours = (root["hourCounts"] as? [String: Any] ?? [:])
            .reduce(into: [Int: Int]()) { acc, pair in
                guard let hour = Int(pair.key),
                      let count = (pair.value as? NSNumber)?.intValue else { return }
                acc[hour] = count
            }

        return StatsSnapshot(
            days: parseDaily(root: root),
            dailyModelTokens: dailyTokens,
            modelTotals: totals,
            totalSessions: (root["totalSessions"] as? NSNumber)?.intValue ?? 0,
            totalMessages: (root["totalMessages"] as? NSNumber)?.intValue ?? 0,
            longestSession: longest,
            firstSessionDate: root["firstSessionDate"] as? String,
            hourCounts: hours)
    }

    /// Today's row, or nil when the CLI hasn't written one yet (no activity since midnight).
    /// `calendar` supplies the timezone the CLI's own day boundary is taken in — local.
    public static func today(_ days: [StatsCacheDay], now: Date = Date(),
                             calendar: Calendar = .current) -> StatsCacheDay? {
        let key = StatsSnapshot.dayFormatter(calendar).string(from: now)
        return days.first { $0.date == key }
    }

    public static func load(url: URL = Paths.statsCache) -> [StatsCacheDay] {
        guard let root = try? JSONFile.readObject(url) else { return [] }
        return parseDaily(root: root)
    }

    /// nil only when the file is missing or unreadable — a readable file always yields a
    /// snapshot, however empty, so the card can tell "no cache yet" from "quiet week".
    public static func loadSnapshot(url: URL = Paths.statsCache) -> StatsSnapshot? {
        guard let root = try? JSONFile.readObject(url) else { return nil }
        return parseSnapshot(root: root)
    }
}
