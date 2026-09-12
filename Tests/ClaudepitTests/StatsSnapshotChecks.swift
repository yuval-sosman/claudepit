import Foundation
@testable import ClaudepitCore

func statsSnapshotChecks() -> [Bool] {
    var results: [Bool] = []

    /// Shaped like the real v5 cache on this machine (numbers shrunk where the math matters).
    let fixture = """
    {
      "version": 5,
      "lastComputedDate": "2026-09-11",
      "dailyActivity": [
        {"date": "2026-09-06", "messageCount": 74, "sessionCount": 2, "toolCallCount": 14},
        {"date": "2026-09-07", "messageCount": 4, "sessionCount": 2, "toolCallCount": 0},
        {"date": "2026-09-10", "messageCount": 2571, "sessionCount": 29, "toolCallCount": 1013},
        {"date": "2026-09-11", "messageCount": 3765, "sessionCount": 22, "toolCallCount": 1268}
      ],
      "dailyModelTokens": [
        {"date": "2026-09-10", "tokensByModel": {"claude-opus-5": 100, "claude-sonnet-5": 50}},
        {"date": "2026-09-11", "tokensByModel": {"claude-opus-5": 7}}
      ],
      "modelUsage": {
        "claude-opus-5": {"inputTokens": 10, "outputTokens": 20,
                          "cacheReadInputTokens": 30, "cacheCreationInputTokens": 40},
        "claude-sonnet-5": {"inputTokens": 1, "outputTokens": 2,
                            "cacheReadInputTokens": 3, "cacheCreationInputTokens": 4}
      },
      "totalSessions": 55,
      "totalMessages": 6414,
      "longestSession": {"sessionId": "b6769780", "duration": 58689896,
                         "messageCount": 433, "timestamp": "2026-09-11T14:12:27.825Z"},
      "firstSessionDate": "2026-09-06T18:31:06.340Z",
      "hourCounts": {"9": 3, "15": 26, "17": 6}
    }
    """
    func snapshot(_ json: String = fixture) -> StatsSnapshot {
        let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        return StatsCache.parseSnapshot(root: root)
    }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func noonUTC(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    /// A snapshot with only activity days, for the pure date math.
    func daysOnly(_ dates: [String]) -> StatsSnapshot {
        StatsSnapshot(days: dates.map {
            StatsCacheDay(date: $0, messageCount: 1, sessionCount: 1, toolCallCount: 0)
        }, dailyModelTokens: [], modelTotals: [:], totalSessions: 0, totalMessages: 0,
           longestSession: nil, firstSessionDate: nil, hourCounts: [:])
    }

    results.append(check("parseSnapshot reads every v5 key") {
        let snap = snapshot()
        try expectEqual(snap.days.count, 4, "activity days")
        try expectEqual(snap.totalSessions, 55, "sessions")
        try expectEqual(snap.totalMessages, 6414, "messages")
        try expectEqual(snap.longestSession,
                        LongestSession(durationMs: 58689896, messageCount: 433), "longest")
        try expectEqual(snap.firstSessionDate, "2026-09-06T18:31:06.340Z", "first session")
        try expectEqual(snap.hourCounts[15], 26, "hour counts keyed by Int")
        try expectEqual(snap.dailyModelTokens.count, 2, "daily model tokens")
        try expectEqual(snap.dailyModelTokens[0].tokensByModel["claude-sonnet-5"], 50, "day tokens")
        try expectEqual(snap.modelTotals["claude-opus-5"],
                        ModelTotals(inputTokens: 10, outputTokens: 20,
                                    cacheReadTokens: 30, cacheCreationTokens: 40), "model totals")
    })

    results.append(check("an empty or older-schema root parses to an empty snapshot, not nil") {
        let snap = snapshot("{}")
        try expectEqual(snap.days.count, 0, "no days")
        try expectEqual(snap.totalSessions, 0, "zero sessions")
        try expect(snap.longestSession == nil && snap.favoriteModel == nil, "empty derivations")
    })

    results.append(check("favoriteModel is the largest total-token model, totalTokens the sum") {
        let snap = snapshot()
        try expectEqual(snap.favoriteModel, "claude-opus-5", "favorite")
        try expectEqual(snap.totalTokens, 110, "100 + 10")
        try expectEqual(snap.aggregateTotals,
                        ModelTotals(inputTokens: 11, outputTokens: 22,
                                    cacheReadTokens: 33, cacheCreationTokens: 44), "field-wise sum")
    })

    results.append(check("mostActiveDay and peakHour pick the maxima") {
        try expectEqual(snapshot().mostActiveDay, "2026-09-11", "busiest day")
        try expectEqual(snapshot().peakHour, 15, "busiest hour")
    })

    results.append(check("daysSinceFirstSession counts calendar days inclusive") {
        // First session Sep 6 → Sep 12 spans 7 calendar days (the CLI's "Active days: N/7").
        try expectEqual(snapshot().daysSinceFirstSession(now: noonUTC(2026, 9, 12), calendar: utc),
                        7, "denominator")
        try expectEqual(snapshot().activeDayCount, 4, "numerator")
    })

    results.append(check("currentStreak counts back from today, or yesterday when today is quiet") {
        let snap = snapshot()   // active: 06, 07, 10, 11
        try expectEqual(snap.currentStreak(now: noonUTC(2026, 9, 11), calendar: utc), 2, "11+10")
        try expectEqual(snap.currentStreak(now: noonUTC(2026, 9, 12), calendar: utc), 2,
                        "quiet today falls back to yesterday's run")
        try expectEqual(snap.currentStreak(now: noonUTC(2026, 9, 14), calendar: utc), 0,
                        "two quiet days break the streak")
    })

    results.append(check("longestStreak finds the longest consecutive run anywhere") {
        let snap = daysOnly(["2026-09-01", "2026-09-02", "2026-09-03",
                             "2026-09-05", "2026-09-06"])
        try expectEqual(snap.longestStreak(calendar: utc), 3, "run of three")
        try expectEqual(daysOnly([]).longestStreak(calendar: utc), 0, "no days, no streak")
    })

    results.append(check("loadSnapshot: missing file → nil, real file round-trips") {
        let dir = try tempDir()
        try expect(StatsCache.loadSnapshot(url: dir.appending(path: "nope.json")) == nil, "nil")
        let url = dir.appending(path: "stats.json")
        try Data(fixture.utf8).write(to: url)
        try expectEqual(StatsCache.loadSnapshot(url: url)?.totalSessions, 55, "from disk")
    })

    // MARK: ModelNames

    results.append(check("ModelNames.display matches the CLI's Stats spellings") {
        try expectEqual(ModelNames.display("claude-opus-5"), "Opus 5", "opus")
        try expectEqual(ModelNames.display("claude-fable-5"), "Fable 5", "fable")
        try expectEqual(ModelNames.display("claude-haiku-4-5-20251001"), "Haiku 4.5",
                        "date stamp stripped, version dotted")
        try expectEqual(ModelNames.display("claude-3-5-sonnet-20241022"), "Sonnet 3.5",
                        "legacy version-first ids")
        try expectEqual(ModelNames.display("12345"), "12345", "no family → id verbatim")
    })

    // MARK: CompactCount

    results.append(check("CompactCount.tokens uses the CLI's lowercase one-decimal spelling") {
        try expectEqual(CompactCount.tokens(162), "162", "plain under 1k")
        try expectEqual(CompactCount.tokens(999), "999", "999 stays plain")
        try expectEqual(CompactCount.tokens(1_000), "1.0k", "k keeps one decimal")
        try expectEqual(CompactCount.tokens(9_600), "9.6k", "9.6k")
        try expectEqual(CompactCount.tokens(775_200), "775.2k", "775.2k")
        try expectEqual(CompactCount.tokens(154_000), "154.0k", "154.0k like the CLI")
        try expectEqual(CompactCount.tokens(3_200_000), "3.2m", "3.2m")
        try expectEqual(CompactCount.tokens(617_900_000), "617.9m", "617.9m")
        try expectEqual(CompactCount.tokens(1_500_000_000), "1.5b", "billions")
    })

    // MARK: ClaudeVersion

    results.append(check("ClaudeVersion.parse takes the semver token and rejects noise") {
        try expectEqual(ClaudeVersion.parse("2.1.236 (Claude Code)"), "2.1.236", "real output")
        try expectEqual(ClaudeVersion.parse("  2.1.236\n"), "2.1.236", "whitespace tolerated")
        try expect(ClaudeVersion.parse("command not found") == nil, "error text rejected")
        try expect(ClaudeVersion.parse("") == nil, "empty rejected")
    })

    return results
}
