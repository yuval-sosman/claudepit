import Foundation
@testable import ClaudepitCore

func projectUsageChecks() -> [Bool] {
    var results: [Bool] = []

    // MARK: - Fixture builders

    let t0 = 1_790_000_000.0   // 2026-09-21T12:53:20Z — any fixed instant works
    func iso(_ t: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }
    func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               encoding: .utf8)!
    }
    func assistant(id: String, request: String = "req", session: String = "s1", at t: TimeInterval,
                   model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0,
                   read: Int = 0, write5m: Int? = nil, write1h: Int? = nil, legacyWrite: Int? = nil,
                   speed: String? = nil, agent: String? = nil) -> String {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output,
                                    "cache_read_input_tokens": read]
        if let legacyWrite {
            usage["cache_creation_input_tokens"] = legacyWrite
        } else {
            let w5 = write5m ?? 0, w1 = write1h ?? 0
            usage["cache_creation_input_tokens"] = w5 + w1
            usage["cache_creation"] = ["ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1]
        }
        if let speed { usage["speed"] = speed }
        var record: [String: Any] = [
            "type": "assistant", "sessionId": session, "timestamp": iso(t), "requestId": request,
            "message": ["id": id, "model": model, "usage": usage,
                        "content": [["type": "text", "text": "ok"]]]]
        if let agent { record["agentId"] = agent; record["isSidechain"] = true }
        return line(record)
    }
    func user(_ text: String, session: String = "s1", at t: TimeInterval, source: String? = "typed",
              sidechain: Bool = false) -> String {
        var record: [String: Any] = ["type": "user", "sessionId": session, "timestamp": iso(t),
                                     "isSidechain": sidechain,
                                     "message": ["role": "user", "content": text]]
        if let source { record["promptSource"] = source }
        return line(record)
    }
    func toolResult(session: String = "s1", at t: TimeInterval) -> String {
        line(["type": "user", "sessionId": session, "timestamp": iso(t), "promptSource": "typed",
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "x"]]]])
    }
    func queuedAttachment(_ text: String, session: String = "s1", at t: TimeInterval,
                          mode: String = "prompt", origin: String = "human") -> String {
        line(["type": "attachment", "sessionId": session, "timestamp": iso(t),
              "attachment": ["type": "queued_command", "prompt": text, "commandMode": mode,
                             "origin": ["kind": origin]]])
    }
    func digest(_ lines: [String], subagent: Bool = false, worktree: Bool = false) -> TranscriptDigest {
        TranscriptDigest.parse(Data(lines.joined(separator: "\n").utf8),
                               isSubagent: subagent, inWorktree: worktree)
    }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func close(_ a: Double, _ b: Double, _ label: String) throws {
        try expect(abs(a - b) < 1e-9, "\(label): expected \(b), got \(a)")
    }
    // Yesterday and today (UTC) around t0 — midnight-aligned, as UsagePeriod windows are.
    let midnight = utc.startOfDay(for: Date(timeIntervalSince1970: t0))
    let wide = DayRange(start: midnight.addingTimeInterval(-86_400), end: midnight.addingTimeInterval(86_400))

    // MARK: - Model ids and prices

    results.append(check("canonical: one id per model, whatever the provider wrote") {
        let cases = [
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0": "claude-sonnet-4-5",
            "claude-sonnet-4-5@20250929": "claude-sonnet-4-5",
            "claude-opus-5[1m]": "claude-opus-5",
            "claude-3-5-sonnet-latest": "claude-sonnet-3-5",
            "claude-haiku-4-5-20251001": "claude-haiku-4-5",
            "claude-opus-4-0": "claude-opus-4",
            "claude-opus-5-5": "claude-opus-5-5",
            "gpt-4o": "gpt-4o",
        ]
        for (raw, want) in cases { try expectEqual(ModelPricing.canonical(raw), want, raw) }
    })

    results.append(check("rate: exact, nearest sibling, or missing") {
        try expectEqual(ModelPricing.rate(for: "claude-opus-5-5").match, .exact, "listed")
        try expectEqual(ModelPricing.rate(for: "claude-opus-5-7").match,
                        .estimated(from: "claude-opus-5-5"), "newer version → newest older sibling")
        try expectEqual(ModelPricing.rate(for: "claude-sonnet-2").match,
                        .estimated(from: "claude-sonnet-3"), "older than all → oldest sibling")
        try expectEqual(ModelPricing.rate(for: "gpt-4o").match, .missing, "not Claude")
        try expect(ModelPricing.rate(for: "gpt-4o").rate == nil, "missing has no rate")
    })

    results.append(check("multiplier: fast mode and regional routing") {
        let opus = ModelPricing.rate(for: "claude-opus-5-5").rate
        try close(ModelPricing.multiplier(rawModel: "claude-opus-5-5", canonical: "claude-opus-5-5",
                                          rate: opus, inferenceGeo: "not_available", fast: true), 2, "fast")
        let sonnet45 = ModelPricing.rate(for: "claude-sonnet-4-5").rate
        try close(ModelPricing.multiplier(rawModel: "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
                                          canonical: "claude-sonnet-4-5", rate: sonnet45,
                                          inferenceGeo: nil, fast: false), 1.1, "bedrock regional")
        try close(ModelPricing.multiplier(rawModel: "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
                                          canonical: "claude-sonnet-4-5", rate: sonnet45,
                                          inferenceGeo: nil, fast: false), 1, "bedrock global")
        try close(ModelPricing.multiplier(rawModel: "claude-opus-4-6", canonical: "claude-opus-4-6",
                                          rate: nil, inferenceGeo: "us", fast: false), 1.1, "api regional")
        try close(ModelPricing.multiplier(rawModel: "claude-sonnet-4-5", canonical: "claude-sonnet-4-5",
                                          rate: sonnet45, inferenceGeo: "us", fast: false), 1,
                  "api regional applies from 4.6 on")
    })

    // MARK: - Parsing

    results.append(check("parse: one call per message.id + requestId, max output, earliest time") {
        let d = digest([
            assistant(id: "m1", at: t0 + 5, input: 10, output: 3, read: 100),
            assistant(id: "m1", at: t0, input: 10, output: 120, read: 100),
            assistant(id: "m1", request: "other", at: t0 + 9, output: 1),
            assistant(id: "m2", at: t0 + 20, model: "<synthetic>", output: 50),
        ])
        try expectEqual(d.calls.count, 2, "m1 twice (two requests), synthetic dropped")
        let m1 = d.calls["m1|req"]
        try expectEqual(m1?.output, 120, "the line with the most output wins")
        try expectEqual(m1?.time, t0, "earliest line")
    })

    results.append(check("parse: cost by token type, 5-minute and 1-hour writes priced apart") {
        let d = digest([assistant(id: "m1", at: t0, input: 1000, output: 120, read: 10_000,
                                  write5m: 2000, write1h: 1000)])
        let c = try (d.calls["m1|req"]).unwrapped("call")
        // Opus 5.5: $4 in, $20 out, $0.20 read, $5 5m write, $8 1h write per MTok.
        try close(c.cost.input, 0.004, "input")
        try close(c.cost.output, 0.0024, "output")
        try close(c.cost.cacheRead, 0.002, "cache read")
        try close(c.cost.cacheWrite, 0.01 + 0.008, "cache write")
        try expectEqual(c.context, 1000 + 10_000 + 3000, "context")
        let legacy = digest([assistant(id: "m1", at: t0, legacyWrite: 1000)]).calls["m1|req"]
        try close(legacy?.cost.cacheWrite ?? -1, 0.005, "unsplit writes priced as 5-minute")
        let fast = digest([assistant(id: "m1", at: t0, output: 1_000_000, speed: "fast")]).calls["m1|req"]
        try close(fast?.cost.output ?? -1, 40, "fast mode doubles Opus 5.5")
    })

    results.append(check("parse: human prompts only, queued ones counted once") {
        let d = digest([
            user("fix the bug", at: t0),
            toolResult(at: t0 + 1),
            user("auto", at: t0 + 2, source: "system"),
            user("subagent brief", at: t0 + 3, sidechain: true),
            user("do this next", at: t0 + 4, source: "queued"),
            queuedAttachment("do this next", at: t0 + 4),
            queuedAttachment("typed while busy", at: t0 + 5),
            queuedAttachment("<task-notification>…", at: t0 + 6, mode: "task-notification"),
        ])
        try expectEqual(d.prompts["s1"]?.count, 3, "typed + queued + unmatched queued attachment")
    })

    results.append(check("parse: older transcripts without promptSource infer typed prompts") {
        let d = digest([
            user("plain request", at: t0, source: nil),
            user("<command-name>/clear</command-name>", at: t0 + 1, source: nil),
            user("[Request interrupted by user]", at: t0 + 2, source: nil),
        ])
        try expectEqual(d.prompts["s1"]?.count, 1, "only the plain text")
    })

    results.append(check("parse: subagent files add calls but no session timeline") {
        let d = digest([assistant(id: "m1", at: t0, output: 1, agent: "a1"), user("brief", at: t0, sidechain: true)],
                       subagent: true, worktree: true)
        try expect(d.sessionTimes.isEmpty, "no session times from a subagent file")
        try expectEqual(d.calls["m1|req"]?.isSubagent, true, "subagent call")
        try expectEqual(d.calls["m1|req"]?.inWorktree, true, "worktree flag carried")
    })

    results.append(check("timestamps: hand parser agrees with ISO8601DateFormatter") {
        let parser = TimestampParser()
        for s in ["2026-09-10T10:38:02.346Z", "2026-02-28T23:59:59Z", "2024-02-29T00:00:00.5Z",
                  "2026-09-10T13:38:02.346+03:00"] {
            let want = ISO8601Pair().date(s)?.timeIntervalSince1970
            let got = parser.seconds(s)
            try expect(want != nil && got != nil && abs(want! - got!) < 0.001, "\(s): \(String(describing: got)) vs \(String(describing: want))")
        }
        try expect(parser.seconds("not a date") == nil, "garbage is nil")
    })

    // MARK: - Summary

    results.append(check("summary: window, active time cap, hit rate and shares") {
        let main = digest([
            user("go", at: t0),
            assistant(id: "a", at: t0 + 60, input: 100, output: 10, read: 900),
            assistant(id: "b", at: t0 + 660, input: 100, output: 10, read: 900),   // 600 s gap → capped at 300
            assistant(id: "old", at: t0 - 10 * 86_400, output: 5000),              // outside the window
        ])
        let sub = digest([assistant(id: "c", at: t0 + 30, input: 0, output: 10, read: 1000, agent: "x")],
                         subagent: true, worktree: true)
        let s = ProjectUsageSummary.build(TranscriptDigest.merged([main, sub]), window: wide, calendar: utc)
        try expectEqual(s.apiCalls, 3, "old call outside the window")
        try expectEqual(s.sessions, 1, "one session")
        try expectEqual(s.prompts, 1, "one prompt")
        try close(s.activeSeconds, 60 + 300, "second gap capped at five minutes")
        try close(s.cacheHitRate ?? -1, 2800.0 / 3000.0, "Σ reads ÷ Σ context")
        let subCost = sub.calls.values.reduce(0) { $0 + $1.cost.total }
        try close(s.subagentShare ?? -1, subCost / s.cost, "subagent share")
        try close(s.worktreeShare ?? -1, subCost / s.cost, "worktree share")
        try expectEqual(s.daily.count, 2, "one bar per day of the window")
        try close(s.daily.reduce(0) { $0 + $1.cost }, s.cost, "daily bars sum to the total")
    })

    results.append(check("summary: median peak context averages the middle pair") {
        let d = digest([
            assistant(id: "a", session: "s1", at: t0, input: 100),
            assistant(id: "b", session: "s1", at: t0 + 1, input: 300),
            assistant(id: "c", session: "s2", at: t0, input: 200),
            assistant(id: "d", session: "s3", at: t0, input: 900, agent: "x"),   // subagents don't set peaks
        ])
        let s = ProjectUsageSummary.build(d, window: wide, calendar: utc)
        try expectEqual(s.medianPeakContext, 250, "peaks 300 and 200")
    })

    results.append(check("summary: breakdowns and costliest sessions are ordered") {
        let d = digest([
            assistant(id: "a", session: "cheap", at: t0, model: "claude-haiku-4-5", output: 1000),
            assistant(id: "b", session: "big", at: t0, model: "claude-opus-5-5", output: 100_000),
            assistant(id: "c", session: "mid", at: t0, model: "claude-sonnet-5", output: 10_000),
            assistant(id: "e", session: "odd", at: t0, model: "claude-opus-5-9", output: 1),
        ])
        let s = ProjectUsageSummary.build(d, window: wide, calendar: utc, topSessionCount: 2)
        try expectEqual(s.byModel.first?.id, "claude-opus-5-5", "most expensive model first")
        try expectEqual(s.topSessions.map(\.id), ["big", "mid"], "top two by cost")
        try expectEqual(s.byTokenType.map(\.id), ["output"], "only token types that cost something")
        try expectEqual(s.unpriced, [UnpricedModel(model: "claude-opus-5-9", pricedAs: "claude-opus-5-5")],
                        "estimated model reported")
    })

    results.append(check("UsagePeriod.window: today plus the days before it") {
        let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21T12:53:20Z
        let w = UsagePeriod.week.window(now: now, calendar: utc)
        try expectEqual(w.start, utc.date(from: DateComponents(year: 2026, month: 9, day: 15))!, "start")
        try expectEqual(w.end, utc.date(from: DateComponents(year: 2026, month: 9, day: 22))!, "end")
    })

    // MARK: - Scanner

    results.append(check("scanner: checkout, worktrees and subagents; not a sibling project") {
        let root = try tempDir()
        let fm = FileManager.default
        func write(_ path: String, _ lines: [String]) throws {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let now = Date().timeIntervalSince1970
        try write("-proj-a/s1.jsonl", [assistant(id: "m1", session: "s1", at: now, output: 1)])
        try write("-proj-a/s1/subagents/agent-x.jsonl",
                  [assistant(id: "m2", session: "s1", at: now, output: 1, agent: "x")])
        try write("-proj-a--claude-worktrees-t1/s2.jsonl", [assistant(id: "m3", session: "s2", at: now, output: 1)])
        try write("-proj-ab/s3.jsonl", [assistant(id: "m4", session: "s3", at: now, output: 1)])

        let scanner = ProjectUsageScanner(projectsRoot: root)
        let since = Date(timeIntervalSince1970: now - 86_400)
        // A folder URL from an open panel ends in "/" — the checkout must still be found.
        let d = scanner.digest(for: URL(filePath: "/proj/a/", directoryHint: .isDirectory), since: since)
        try expectEqual(Set(d.calls.keys), ["m1|req", "m2|req", "m3|req"], "no -proj-ab")
        try expectEqual(d.calls["m2|req"]?.isSubagent, true, "subagent file")
        try expectEqual(d.calls["m3|req"]?.inWorktree, true, "worktree folder")

        // Appending changes the size, so the cached digest is replaced.
        try write("-proj-a/s1.jsonl", [assistant(id: "m1", session: "s1", at: now, output: 1),
                                       assistant(id: "m5", session: "s1", at: now, output: 1)])
        let again = scanner.digest(for: URL(filePath: "/proj/a"), since: since)
        try expect(again.calls["m5|req"] != nil, "changed file re-read")

        // A transcript untouched since before the window is skipped.
        let old = root.appending(path: "-proj-a--claude-worktrees-t1/s2.jsonl")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 100 * 86_400)],
                             ofItemAtPath: old.path)
        let pruned = scanner.digest(for: URL(filePath: "/proj/a"), since: since)
        try expect(pruned.calls["m3|req"] == nil, "old file skipped")
    })

    // MARK: - Session report

    func detailed(_ lines: [String], subagent: Bool = false) -> TranscriptDigest {
        TranscriptDigest.parse(Data(lines.joined(separator: "\n").utf8), isSubagent: subagent,
                               inWorktree: false, detail: true)
    }
    func compact(at t: TimeInterval) -> String {
        line(["type": "system", "subtype": "compact_boundary", "sessionId": "s1", "timestamp": iso(t)])
    }
    func toolCall(id: String, tool: String, toolID: String, at t: TimeInterval, read: Int, write1h: Int) -> String {
        line(["type": "assistant", "sessionId": "s1", "timestamp": iso(t), "requestId": "req",
              "message": ["id": id, "model": "claude-opus-5-5", "stop_reason": "tool_use",
                          "usage": ["input_tokens": 0, "output_tokens": 10, "cache_read_input_tokens": read,
                                    "cache_creation_input_tokens": write1h,
                                    "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": write1h]],
                          "content": [["type": "tool_use", "id": toolID, "name": tool, "input": [:]]]]])
    }
    func result(_ toolID: String, at t: TimeInterval, error: Bool = false) -> String {
        line(["type": "user", "sessionId": "s1", "timestamp": iso(t),
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID,
                                                       "content": "x", "is_error": error]]]])
    }

    results.append(check("report: a return after the cache lifetime is a costed miss") {
        let d = detailed([
            user("start", at: t0),
            assistant(id: "a", at: t0 + 1, output: 10, read: 0, write1h: 50_000),
            user("back after lunch", at: t0 + 2 * 3600),
            assistant(id: "b", at: t0 + 2 * 3600 + 1, output: 10, read: 0, write1h: 50_020),
        ])
        let r = SessionReport.build(d, sessionID: "s1")
        try expectEqual(r.misses.count, 1, "one miss")
        let m = try r.misses.first.unwrapped("miss")
        try expectEqual(m.rewritten, 50_000, "previous context re-written")
        try expectEqual(m.cause, "You came back after a break", "cause")
        try expectEqual(r.mainCacheLifetime, 3600, "1-hour writes → 1-hour lifetime")
        try close(m.extraCost, 50_000 * (8 - 0.20) / 1_000_000, "write − read price on re-written tokens")
        try expectEqual(r.context.map(\.isMiss), [false, true], "context series marks the miss")
    })

    results.append(check("report: a compaction is not a miss; tools are counted with errors") {
        let d = detailed([
            user("go", at: t0),
            toolCall(id: "a", tool: "Bash", toolID: "t1", at: t0 + 1, read: 0, write1h: 80_000),
            result("t1", at: t0 + 3, error: true),
            compact(at: t0 + 4),
            toolCall(id: "b", tool: "Bash", toolID: "t2", at: t0 + 5, read: 0, write1h: 20_000),
            result("t2", at: t0 + 9),
        ])
        let r = SessionReport.build(d, sessionID: "s1")
        try expect(r.misses.isEmpty, "compaction replaces the conversation")
        try expectEqual(r.compactions, 1, "compactions")
        try expectEqual(r.tools.first?.name, "Bash", "tool name")
        try expectEqual(r.tools.first?.calls, 2, "tool calls")
        try expectEqual(r.tools.first?.errors, 1, "errors")
    })

    results.append(check("report: a subagent resumed after finishing re-writes its history") {
        let sub = detailed([
            user("brief", at: t0, sidechain: true),
            assistant(id: "a", at: t0 + 1, output: 10, read: 0, write5m: 30_000, agent: "ag1"),
            line(["type": "user", "sessionId": "s1", "timestamp": iso(t0 + 200), "isSidechain": true,
                  "agentId": "ag1", "message": ["role": "user", "content": "one more thing"]]),
            assistant(id: "b", at: t0 + 201, output: 10, read: 0, write5m: 30_010, agent: "ag1"),
        ], subagent: true)
        let r = SessionReport.build(TranscriptDigest.merged([detailed([user("go", at: t0 - 1)]), sub]),
                                    sessionID: "s1", subagents: ["ag1": (type: "Explore", description: "look")])
        try expectEqual(r.misses.first?.cause, "Subagent resumed via SendMessage", "cause")
        try expectEqual(r.misses.first?.thread, "Explore", "thread labelled by type")
        try expectEqual(r.subagents.first?.misses, 1, "per-subagent miss count")
        try expectEqual(r.subagentCalls, 2, "subagent calls")
    })

    return results
}

private extension Optional {
    func unwrapped(_ label: String) throws -> Wrapped {
        guard let self else { throw CheckFailure(message: "\(label): nil") }
        return self
    }
}
