import Foundation
@testable import ClaudepitCore

func usageReportChecks() -> [Bool] {
    var results: [Bool] = []

    /// Verbatim from a real `claude -p "/usage"` run (2026-09-12) — the parser's contract is
    /// this exact shape, so the fixture stays word-for-word.
    let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 15% used · resets Sep 12 at 2:30pm (Asia/Jerusalem)
    Current week (all models): 23% used · resets Sep 14 at 12am (Asia/Jerusalem)
    Current week (Fable): 19% used · resets Sep 14 at 12am (Asia/Jerusalem)

    What's contributing to your limits usage?
    Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.

    Last 24h · 1459 requests · 25 sessions
      70% of your usage came from subagent-heavy sessions
      55% of your usage was at >150k context
      Top skills: /rerun 6%, /claudepit-task-plan 2%, /claudepit-task-spec 1%, /claudepit-task-implement 1%, /claudepit-task-brainstorm 1%
      Top subagents: general-purpose 18%, Explore 3%, Plan 2%, claudepit-task-plan 1%

    Last 7d · 2424 requests · 39 sessions
      77% of your usage came from subagent-heavy sessions
      57% of your usage was at >150k context
      Top skills: /rerun 5%, /claudepit-task-plan 1%, /claudepit-task-spec 1%, /claudepit-task-implement 1%
      Top subagents: claude 15%, general-purpose 11%, Explore 4%, Plan 2%, claudepit-task-plan 1%
    """

    results.append(check("headline is the report's first line, not a Current/What's line") {
        let report = UsageReport.parse(sample)
        try expectEqual(report.headline,
                        "You are currently using your subscription to power your Claude Code usage",
                        "headline")
    })

    results.append(check("both Last-N windows parse with their request/session counts") {
        let report = UsageReport.parse(sample)
        try expectEqual(report.windows.map(\.label), ["Last 24h", "Last 7d"], "labels")
        try expectEqual(report.windows[0].requests, 1459, "24h requests")
        try expectEqual(report.windows[0].sessions, 25, "24h sessions")
        try expectEqual(report.windows[1].requests, 2424, "7d requests")
        try expectEqual(report.windows[1].sessions, 39, "7d sessions")
    })

    results.append(check("behavior lines are the indented free-text ones, in order") {
        let report = UsageReport.parse(sample)
        try expectEqual(report.windows[0].behaviors,
                        ["70% of your usage came from subagent-heavy sessions",
                         "55% of your usage was at >150k context"], "24h behaviors")
        try expectEqual(report.windows[1].behaviors.count, 2, "7d behaviors")
    })

    results.append(check("Top skills/subagents parse to (name, percent) lists") {
        let report = UsageReport.parse(sample)
        try expectEqual(report.windows[0].topSkills.count, 5, "24h skills")
        try expectEqual(report.windows[0].topSkills.first,
                        UsageReport.RankedItem(name: "/rerun", percent: 6), "first skill")
        try expectEqual(report.windows[0].topSubagents.first,
                        UsageReport.RankedItem(name: "general-purpose", percent: 18), "first subagent")
        try expectEqual(report.windows[1].topSubagents.first,
                        UsageReport.RankedItem(name: "claude", percent: 15), "7d first subagent")
        try expectEqual(report.windows[1].topSkills.count, 4, "7d skills")
    })

    results.append(check("a ranked entry without a trailing N% is dropped, not guessed at") {
        let report = UsageReport.parse("Last 24h · 5 requests\n  Top skills: broken entry, /ok 3%")
        try expectEqual(report.windows[0].topSkills,
                        [UsageReport.RankedItem(name: "/ok", percent: 3)], "only the valid one")
    })

    results.append(check("garbage and failure text yield no windows (the section just hides)") {
        try expectEqual(UsageReport.parse("claude exited 1.").windows.count, 0, "failure text")
        try expectEqual(UsageReport.parse("").isEmpty, true, "empty input")
        try expectEqual(UsageReport.parse("Not logged in · Please run /login").windows.count, 0,
                        "signed-out text")
    })

    results.append(check("a window with no indented lines still closes cleanly") {
        let report = UsageReport.parse("Last 30d · 9 requests · 2 sessions")
        try expectEqual(report.windows.count, 1, "one window")
        try expectEqual(report.windows[0].behaviors.count, 0, "no behaviors")
    })

    // MARK: UsageReportCache

    results.append(check("report cache round-trips text and timestamp through disk") {
        let url = try tempDir().appending(path: "report.json")
        UsageReportCache.save(text: sample, fetchedAt: Date(timeIntervalSince1970: 1_000),
                              url: url)
        guard let loaded = UsageReportCache.load(url: url) else {
            throw CheckFailure(message: "no cache read back")
        }
        try expectEqual(loaded.text, sample, "text verbatim")
        try expectEqual(loaded.fetchedAt.timeIntervalSince1970, 1_000, "timestamp")
    })

    results.append(check("report cache: missing file → nil") {
        let url = try tempDir().appending(path: "nope.json")
        try expect(UsageReportCache.load(url: url) == nil, "nil")
    })

    return results
}
