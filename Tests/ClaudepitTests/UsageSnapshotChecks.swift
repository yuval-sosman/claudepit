import Foundation
@testable import ClaudepitCore

func usageSnapshotChecks() -> [Bool] {
    var results: [Bool] = []

    /// Shaped exactly like the CLI's own `cachedUsageUtilization` subtree, fractional
    /// `resets_at` included — that spelling is what the plain ISO8601 parser rejects.
    let fixture = """
    {
      "cachedUsageUtilization": {
        "fetchedAtMs": 1789052063470,
        "utilization": {
          "five_hour": {"utilization": 20, "resets_at": "2026-09-10T17:20:00.373961+00:00"},
          "seven_day": {"utilization": 91, "resets_at": "2026-09-13T21:00:00+00:00"},
          "seven_day_opus": null,
          "limits": [
            {"kind": "session", "percent": 20, "severity": "normal",
             "resets_at": "2026-09-10T17:20:00.373961+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_all", "percent": 9, "severity": "normal",
             "resets_at": null, "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "percent": 6, "severity": "warning",
             "resets_at": "2026-09-13T21:00:00.374383+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
             "is_active": false}
          ]
        }
      }
    }
    """
    func parseFixture(_ json: String) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        return UsageSnapshot.parse(root: root)
    }

    results.append(check("parses both headline windows and fetchedAt") {
        guard let snap = parseFixture(fixture) else { throw CheckFailure(message: "no snapshot") }
        try expectEqual(snap.fiveHour?.percent, 20, "five_hour percent")
        try expectEqual(snap.sevenDay?.percent, 91, "seven_day percent")
        // fetchedAtMs is milliseconds; the snapshot stores seconds.
        try expectEqual(Int((snap.fetchedAt.timeIntervalSince1970 * 1000).rounded()),
                        1789052063470, "fetchedAt")
    })

    results.append(check("resets_at: fractional seconds parse") {
        guard let snap = parseFixture(fixture), let d = snap.fiveHour?.resetsAt else {
            throw CheckFailure(message: "no five_hour resetsAt")
        }
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 10; c.hour = 17; c.minute = 20
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        try expectEqual(d.timeIntervalSince1970.rounded(), cal.date(from: c)!.timeIntervalSince1970, "UTC instant")
    })

    results.append(check("resets_at: non-fractional spelling still parses") {
        guard let snap = parseFixture(fixture) else { throw CheckFailure(message: "no snapshot") }
        try expect(snap.sevenDay?.resetsAt != nil, "seven_day resetsAt parsed without fractional seconds")
    })

    results.append(check("resets_at: null yields nil rather than a bogus date") {
        guard let snap = parseFixture(fixture),
              let weeklyAll = snap.limits.first(where: { $0.kind == "weekly_all" })
        else { throw CheckFailure(message: "no weekly_all limit") }
        try expect(weeklyAll.resetsAt == nil, "null resets_at is nil")
    })

    results.append(check("limits carry kind/severity/isActive, and weekly_scoped its model name") {
        guard let snap = parseFixture(fixture) else { throw CheckFailure(message: "no snapshot") }
        try expectEqual(snap.limits.count, 3, "three rows")
        try expectEqual(snap.limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"], "kinds")
        try expectEqual(snap.limits[0].isActive, true, "session is_active")
        try expectEqual(snap.limits[1].isActive, false, "weekly_all is_active")
        try expect(snap.limits[0].modelDisplayName == nil, "unscoped row has no model name")
        try expectEqual(snap.scopedWeekly.count, 1, "one scoped weekly row")
        try expectEqual(snap.scopedWeekly[0].modelDisplayName, "Fable", "scope.model.display_name")
        try expectEqual(snap.scopedWeekly[0].severity, "warning", "severity verbatim")
    })

    results.append(check("extra_usage absent → nil (older CLI cache)") {
        guard let snap = parseFixture(fixture) else { throw CheckFailure(message: "no snapshot") }
        try expect(snap.extraUsage == nil, "no extra_usage subtree")
    })

    results.append(check("extra_usage disabled with null numbers parses to the off state") {
        let json = """
        {"cachedUsageUtilization": {"fetchedAtMs": 1, "utilization": {
          "extra_usage": {"is_enabled": false, "monthly_limit": null,
                          "used_credits": null, "utilization": null}}}}
        """
        guard let extra = parseFixture(json)?.extraUsage else {
            throw CheckFailure(message: "no extra usage")
        }
        try expectEqual(extra.isEnabled, false, "off")
        try expect(extra.usedCredits == nil && extra.monthlyLimit == nil
                   && extra.utilization == nil, "all numbers nil")
    })

    results.append(check("extra_usage enabled carries its numbers") {
        let json = """
        {"cachedUsageUtilization": {"fetchedAtMs": 1, "utilization": {
          "extra_usage": {"is_enabled": true, "monthly_limit": 10,
                          "used_credits": 4.2, "utilization": 42}}}}
        """
        guard let extra = parseFixture(json)?.extraUsage else {
            throw CheckFailure(message: "no extra usage")
        }
        try expectEqual(extra.isEnabled, true, "on")
        try expectEqual(extra.usedCredits, 4.2, "used")
        try expectEqual(extra.monthlyLimit, 10, "limit")
        try expectEqual(extra.utilization, 42, "percent")
    })

    results.append(check("missing cachedUsageUtilization subtree → nil") {
        try expect(parseFixture(#"{"numStartups": 3}"#) == nil, "no subtree means no snapshot")
    })

    results.append(check("missing fetchedAtMs → nil (a cache with no age can't be staleness-checked)") {
        try expect(parseFixture(#"{"cachedUsageUtilization": {"utilization": {}}}"#) == nil, "nil")
    })

    results.append(check("missing file → nil") {
        let dir = try tempDir()
        try expect(UsageSnapshot.load(url: dir.appending(path: "nope.json")) == nil, "nil")
    })

    results.append(check("load() reads a file written to disk") {
        let dir = try tempDir()
        let url = dir.appending(path: "claude.json")
        try Data(fixture.utf8).write(to: url)
        try expectEqual(UsageSnapshot.load(url: url)?.fiveHour?.percent, 20, "round-trips through disk")
    })

    results.append(check("isStale flips at the 15-minute mark") {
        let snap = UsageSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_000_000),
                                 fiveHour: nil, sevenDay: nil, limits: [])
        try expectEqual(snap.isStale(now: Date(timeIntervalSince1970: 1_000_899)), false, "899s is fresh")
        try expectEqual(snap.isStale(now: Date(timeIntervalSince1970: 1_000_900)), true, "900s is stale")
    })

    results.append(check("UsageWindow.Level thresholds: 69 normal, 70 warning, 89 warning, 90 critical") {
        func level(_ p: Int) -> UsageWindow.Level { UsageWindow(percent: p, resetsAt: nil).level }
        try expect(level(69) == .normal, "69 normal")
        try expect(level(70) == .warning, "70 warning")
        try expect(level(89) == .warning, "89 warning")
        try expect(level(90) == .critical, "90 critical")
    })

    results.append(check("UsageWindow.fraction clamps a >100 report to a full gauge") {
        try expectEqual(UsageWindow(percent: 140, resetsAt: nil).fraction, 1.0, "clamped")
        try expectEqual(UsageWindow(percent: 50, resetsAt: nil).fraction, 0.5, "midpoint")
    })

    // MARK: StatsCache

    let statsJSON = """
    {
      "version": 5,
      "dailyActivity": [
        {"date": "2026-09-06", "messageCount": 74, "sessionCount": 2, "toolCallCount": 14},
        {"date": "2026-09-07", "messageCount": 4, "sessionCount": 2, "toolCallCount": 0}
      ]
    }
    """
    func statsRoot(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func noonUTC(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    results.append(check("StatsCache.parseDaily reads the v5 array form") {
        let days = StatsCache.parseDaily(root: statsRoot(statsJSON))
        try expectEqual(days.count, 2, "two days")
        try expectEqual(days[0], StatsCacheDay(date: "2026-09-06", messageCount: 74,
                                               sessionCount: 2, toolCallCount: 14), "first row")
    })

    results.append(check("StatsCache.parseDaily ignores the legacy object form") {
        let legacy = #"{"dailyActivity": {"2026-09-06": {"messageCount": 74}}}"#
        try expectEqual(StatsCache.parseDaily(root: statsRoot(legacy)).count, 0, "no rows")
    })

    results.append(check("StatsCache.today matches the row for now's calendar day") {
        let days = StatsCache.parseDaily(root: statsRoot(statsJSON))
        let hit = StatsCache.today(days, now: noonUTC(2026, 9, 7), calendar: utc)
        try expectEqual(hit?.messageCount, 4, "2026-09-07 row")
    })

    results.append(check("StatsCache.today returns nil when the CLI wrote no row for today") {
        let days = StatsCache.parseDaily(root: statsRoot(statsJSON))
        try expect(StatsCache.today(days, now: noonUTC(2026, 9, 9), calendar: utc) == nil, "no row")
    })

    results.append(check("gauges list session, week, then each model-scoped week") {
        let snap = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: UsageWindow(percent: 93, resetsAt: nil),
            sevenDay: UsageWindow(percent: 30, resetsAt: nil),
            limits: [
                UsageLimit(kind: "session", percent: 93, severity: "critical",
                           resetsAt: nil, isActive: true, modelDisplayName: nil),
                UsageLimit(kind: "weekly_scoped", percent: 31, severity: "normal",
                           resetsAt: nil, isActive: true, modelDisplayName: "Fable"),
            ])
        let labels = snap.gauges.map(\.label)
        try expectEqual(labels, ["Session (5h)", "Week (all models)", "Week · Fable"], "order + labels")
        // The two surfaces color by the same thresholds, not by the CLI's `severity` string.
        try expect(snap.gauges[0].level == .critical, "93% is critical")
        try expect(snap.gauges[1].level == .normal, "30% is normal")
        try expect(snap.gauges[2].level == .normal, "scoped row uses the window thresholds")
    })

    results.append(check("gauges omit a window the cache does not carry") {
        let snap = UsageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0),
                                 fiveHour: nil, sevenDay: nil, limits: [])
        try expectEqual(snap.gauges.count, 0, "nothing to draw")
    })

    results.append(check("busiestGauge picks the fullest window, earliest on a tie") {
        let snap = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: UsageWindow(percent: 30, resetsAt: nil),
            sevenDay: UsageWindow(percent: 71, resetsAt: nil),
            limits: [UsageLimit(kind: "weekly_scoped", percent: 71, severity: "warning",
                                resetsAt: nil, isActive: true, modelDisplayName: "Fable")])
        try expectEqual(snap.busiestGauge?.label, "Week (all models)", "first of the tied maxima")
        let empty = UsageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0),
                                  fiveHour: nil, sevenDay: nil, limits: [])
        try expect(empty.busiestGauge == nil, "nothing cached, nothing to report")
    })

    results.append(check("a gauge fraction clamps an over-100 window") {
        let snap = UsageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0),
                                 fiveHour: UsageWindow(percent: 120, resetsAt: nil),
                                 sevenDay: nil, limits: [])
        try expectEqual(snap.gauges[0].fraction, 1, "bar never overflows its track")
        try expectEqual(snap.gauges[0].percent, 120, "but the number stays verbatim")
    })

    results.append(check("StatsCache.load on a missing file returns empty") {
        let dir = try tempDir()
        try expectEqual(StatsCache.load(url: dir.appending(path: "nope.json")).count, 0, "empty")
    })

    return results
}
