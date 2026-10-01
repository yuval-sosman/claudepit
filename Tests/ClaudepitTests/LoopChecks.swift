import Foundation
@testable import ClaudepitCore

// Checks for the Loops page's Core: the CLI's cron dialect, jitter and expiry; `/loop`'s interval
// table and argument rules; rebuilding loops from transcript records; durable tasks, the live
// session registry and the CLI's flags; and what the New Loop dialog promises.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// 2026-10-01T<h>:<m>:<s>Z (a Thursday).
private func at(_ h: Int, _ m: Int, _ s: Int = 0, day: Int = 1, month: Int = 10, year: Int = 2026) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: h, minute: m, second: s))!
}

private func iso(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

/// One transcript line the way the CLI writes it: compact JSON, slashes unescaped.
private func line(_ o: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), encoding: .utf8)!
}

private func toolUse(_ id: String, _ name: String, _ input: [String: Any], _ t: Date) -> String {
    line(["type": "assistant", "timestamp": iso(t),
          "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
}

private func toolResult(_ id: String, _ text: String, _ t: Date, detail: [String: Any]? = nil, error: Bool = false) -> String {
    var o: [String: Any] = ["type": "user", "timestamp": iso(t),
                            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id,
                                                                     "content": text, "is_error": error]]]]
    if let detail { o["toolUseResult"] = detail }
    return line(o)
}

private func fire(_ task: String, cron: String, prompt: String, kind: String, _ t: Date) -> [String] {
    [line(["type": "system", "subtype": "scheduled_task_fire", "timestamp": iso(t), "taskId": task, "cron": cron,
           "prompt": prompt, "taskKind": kind, "content": "Running scheduled task"]),
     line(["type": "user", "isMeta": true, "promptSource": "system", "scheduledTaskId": task, "turnOrigin": "scheduled",
           "permissionMode": "auto", "timestamp": iso(t.addingTimeInterval(0.01)),
           "message": ["role": "user", "content": prompt]])]
}

private func typed(_ text: String, _ t: Date) -> String {
    line(["type": "user", "promptSource": "typed", "permissionMode": "acceptEdits", "timestamp": iso(t),
          "message": ["role": "user", "content": text]])
}

private func loopCommand(_ args: String, _ t: Date) -> String {
    line(["type": "user", "timestamp": iso(t),
          "message": ["role": "user", "content": "<command-name>/loop</command-name>\n<command-message>loop</command-message>\n<command-args>\(args)</command-args>"]])
}

private func log(_ lines: [String]) -> LoopLog {
    var l = LoopLog()
    LoopLogReader.ingest(Data((lines.joined(separator: "\n") + "\n").utf8), baseOffset: 0, into: &l)
    return l
}

private let session = LoopBuilder.SessionRef(id: "s1", transcript: URL(filePath: "/tmp/s1.jsonl"), title: "Session one",
                                             cwd: "/r", modifiedAt: at(10, 0))

private func live(busy: Bool = false) -> LiveSession {
    LiveSession(pid: 42, sessionID: "s1", cwd: "/r", status: busy ? "busy" : "idle")
}

func loopChecks() -> [Bool] {
    var results: [Bool] = []

    // MARK: Cron dialect

    results.append(check("cron: the CLI's grammar — steps, ranges, lists, Sunday as 7; no names, L, ? or 4 fields") {
        let e = try unwrap(CronExpression("*/15 9-17 1,15 * 1-5"), "valid")
        try expectEqual(e.minutes, [0, 15, 30, 45], "*/15")
        try expectEqual(e.hours, Array(9...17), "9-17")
        try expectEqual(e.daysOfMonth, [1, 15], "list")
        try expectEqual(e.daysOfWeek, [1, 2, 3, 4, 5], "weekdays")
        try expectEqual(CronExpression("0 0 * * 7")?.daysOfWeek, [0], "7 is Sunday")
        try expectEqual(CronExpression("0 0 * * 5-7")?.daysOfWeek, [0, 5, 6], "a range may end at 7")
        try expectEqual(CronExpression("0-30/10 * * * *")?.minutes, [0, 10, 20, 30], "range with a step")
        for bad in ["0 9 * * MON", "0 9 L * *", "0 9 ? * *", "60 * * * *", "* 24 * * *", "* * 0 * *",
                    "* * * 13 *", "* * * * 8", "*/0 * * * *", "1,,2 * * * *", "5-1 * * * *", "* * * *", "a b c d e"] {
            try expect(CronExpression(bad) == nil, "\(bad) should be rejected")
        }
        guard case .invalid(let field, _) = CronExpression.validate("0 25 * * *") else { throw CheckFailure(message: "25h") }
        try expectEqual(field, 1, "the hour field is at fault")
        guard case .invalid(let none, _) = CronExpression.validate("0 9 *") else { throw CheckFailure(message: "3 fields") }
        try expectEqual(none, nil, "a field-count problem names no field")
    })

    results.append(check("cron: next match — after the minute, weekday ranges, day-of-month OR day-of-week, leap day, never") {
        try expectEqual(CronExpression("*/5 * * * *")?.next(after: at(10, 2, 30), calendar: utc), at(10, 5), "next 5-minute mark")
        try expectEqual(CronExpression("*/5 * * * *")?.next(after: at(10, 5), calendar: utc), at(10, 10), "strictly after")
        // Thursday Oct 1 → the next weekday 09:00 is Friday Oct 2.
        try expectEqual(CronExpression("0 9 * * 1-5")?.next(after: at(10, 0), calendar: utc), at(9, 0, day: 2), "weekdays")
        // Friday after 9 → Monday Oct 5.
        try expectEqual(CronExpression("0 9 * * 1-5")?.next(after: at(10, 0, day: 2), calendar: utc), at(9, 0, day: 5), "skips the weekend")
        // Both day fields restricted: either matches (vixie). Oct 5 is a Monday, before Nov 1.
        try expectEqual(CronExpression("0 0 1 * 1")?.next(after: at(10, 0), calendar: utc), at(0, 0, day: 5), "dom OR dow")
        try expectEqual(CronExpression("0 0 29 2 *")?.next(after: at(10, 0), calendar: utc),
                        at(0, 0, day: 29, month: 2, year: 2028), "the next leap day")
        try expect(CronExpression("0 0 31 2 *")?.next(after: at(10, 0), calendar: utc) == nil, "Feb 31 never comes")
        let fires = CronExpression("0 */6 * * *")!.nextFires(after: at(10, 0), count: 3, calendar: utc)
        try expectEqual(fires, [at(12, 0), at(18, 0), at(0, 0, day: 2)], "nextFires")
        try expectEqual(CronExpression("7 * * * *")?.period(after: at(10, 0), calendar: utc), 3600, "period")
    })

    results.append(check("cron: the CLI's English, and the expression itself for what it can't say") {
        let cases: [(String, String)] = [
            ("* * * * *", "Every minute"), ("*/1 * * * *", "Every minute"), ("*/5 * * * *", "Every 5 minutes"),
            ("0 * * * *", "Every hour"), ("7 * * * *", "Every hour at :07"), ("0 */1 * * *", "Every hour"),
            ("0 */2 * * *", "Every 2 hours"), ("30 */4 * * *", "Every 4 hours at :30"),
            ("3 9 * * *", "Every day at 9:03 AM"), ("0 0 * * *", "Every day at 12:00 AM"),
            ("30 14 * * *", "Every day at 2:30 PM"), ("0 9 * * 1", "Every Monday at 9:00 AM"),
            ("0 9 * * 7", "Every Sunday at 9:00 AM"), ("0 9 * * 1-5", "Weekdays at 9:00 AM"),
            ("0 0 */3 * *", "0 0 */3 * *"), ("*/5 9-17 * * *", "*/5 9-17 * * *"), ("30 14 1 10 *", "30 14 1 10 *"),
        ]
        for (cron, english) in cases { try expectEqual(CronExpression.humanize(cron), english, cron) }
        try expectEqual(LoopCadence.describe(cron: "30 14 1 10 *", recurring: false), "Once, Oct 1 at 2:30 PM", "pinned one-shot")
        try expectEqual(LoopCadence.describe(cron: "*/5 * * * *", recurring: true), "Every 5 minutes", "recurring")
        let badges: [(String, Bool, String)] = [("*/5 * * * *", true, "5m"), ("* * * * *", true, "1m"), ("*/1 * * * *", true, "1m"),
                                                ("0 */1 * * *", true, "1h"), ("0 0 */1 * *", true, "1d"), ("7 * * * *", true, "1h"),
                                                ("0 */2 * * *", true, "2h"), ("0 0 */3 * *", true, "3d"), ("3 9 * * *", true, "daily"),
                                                ("0 9 * * 1-5", true, "wkdays"), ("0 9 * * 1", true, "Mon"),
                                                ("30 14 1 10 *", false, "once"), ("*/5 9-17 * * *", true, "cron")]
        for (cron, recurring, badge) in badges { try expectEqual(LoopCadence.badge(cron: cron, recurring: recurring), badge, cron) }
        try expectEqual(LoopCadence.duration(285), "4m 45s", "duration")
        try expectEqual(LoopCadence.duration(1800), "30m", "minutes")
        try expectEqual(LoopCadence.duration(5400), "1h 30m", "hours")
    })

    // MARK: Jitter and expiry

    results.append(check("jitter: a fixed offset from the task id — half the period, capped at 30 min; */5 keeps the cache warm") {
        try expectEqual(CronJitter.fraction(taskID: "00000000"), 0, "zero")
        try expectEqual(CronJitter.fraction(taskID: "80000000"), 0.5, "half")
        try expectEqual(CronJitter.fraction(taskID: "abc-1234"), Double(0xabc) / 4_294_967_296, "leading hex digits only")
        try expectEqual(CronJitter.fraction(taskID: "zz"), 0, "no hex → 0")
        let j = CronJitter.cliDefault
        let hourly = CronExpression("7 * * * *")!
        try expectEqual(j.recurringFire(hourly, from: at(10, 0), taskID: "00000000", calendar: utc), at(10, 7), "no offset")
        // A fraction of 0.5 × half the 1-hour period = 15 min.
        try expectEqual(j.recurringFire(hourly, from: at(10, 0), taskID: "80000000", calendar: utc), at(10, 22), "0.5 × 0.5 × 1h")
        let tenMin = CronExpression("*/10 * * * *")!
        try expectEqual(j.recurringFire(tenMin, from: at(10, 0), taskID: "80000000", calendar: utc), at(10, 12, 30), "0.5 × 0.5 × 10m")
        let daily = CronExpression("3 9 * * *")!
        try expectEqual(j.maxRecurringDelay(daily, from: at(10, 0), calendar: utc), 1800, "capped at 30 min")
        let five = CronExpression("*/5 * * * *")!
        try expect(j.keepsCacheWarm(five, period: 300), "*/5 keeps the prompt cache warm")
        try expect(!j.keepsCacheWarm(tenMin, period: 600), "*/10 doesn't")
        try expectEqual(j.recurringFire(five, from: at(10, 1, 13), taskID: "ffffffff", calendar: utc), at(10, 5, 58),
                        "4m 45s after the last fire, not on the clock")
        try expectEqual(j.maxRecurringDelay(five, from: at(10, 0), calendar: utc), 0, "no jitter window for */5")
    })

    results.append(check("jitter: a one-shot on :00 or :30 fires up to 90 s early, never before it was made; 7-day expiry") {
        let j = CronJitter.cliDefault
        let half = CronExpression("30 14 1 10 *")!
        try expectEqual(j.oneShotFire(half, from: at(10, 0), taskID: "80000000", calendar: utc), at(14, 29, 15), "45 s early")
        let odd = CronExpression("31 14 1 10 *")!
        try expectEqual(j.oneShotFire(odd, from: at(10, 0), taskID: "ffffffff", calendar: utc), at(14, 31), "off-minute: exact")
        try expectEqual(j.oneShotFire(CronExpression("0 10 1 10 *")!, from: at(9, 59, 30), taskID: "ffffffff", calendar: utc),
                        at(9, 59, 30), "never before its creation")
        try expectEqual(j.expiry(createdAt: at(10, 0)), at(10, 0, day: 8), "7 days")
        let custom = CronJitter(config: ["recurringFrac": 0.1, "recurringCapMs": 900_000, "recurringMaxAgeMs": 0, "cacheLeadMs": 99_999])
        try expectEqual(custom.recurringFraction, 0.1, "remote fraction")
        try expectEqual(custom.recurringCap, 900, "remote cap")
        try expect(custom.expiry(createdAt: at(10, 0)) == nil, "expiry switched off")
        try expectEqual(custom.cacheLead, 15, "an out-of-range key keeps its default")
    })

    // MARK: /loop

    results.append(check("interval: /loop's conversion table, clean steps and the nearest clean alternatives") {
        let table: [(LoopInterval, String?)] = [
            (LoopInterval(5, .m), "*/5 * * * *"), (LoopInterval(1, .m), "*/1 * * * *"), (LoopInterval(30, .s), "*/1 * * * *"),
            (LoopInterval(90, .s), "*/2 * * * *"), (LoopInterval(120, .m), "0 */2 * * *"), (LoopInterval(1, .h), "0 */1 * * *"),
            (LoopInterval(6, .h), "0 */6 * * *"), (LoopInterval(48, .h), "0 0 */2 * *"), (LoopInterval(1, .d), "0 0 */1 * *"),
            (LoopInterval(3, .d), "0 0 */3 * *"), (LoopInterval(90, .m), nil), (LoopInterval(0, .m), nil),
        ]
        for (i, cron) in table { try expectEqual(i.cron, cron, i.token) }
        try expect(LoopInterval(15, .m).isClean && LoopInterval(8, .h).isClean, "clean")
        try expect(!LoopInterval(7, .m).isClean && !LoopInterval(90, .m).isClean && !LoopInterval(5, .h).isClean, "unclean")
        try expectEqual(LoopInterval(7, .m).cleanAlternatives.map(\.token), ["6m", "10m"], "7m")
        try expectEqual(LoopInterval(90, .m).cleanAlternatives.map(\.token), ["1h", "2h"], "90m (a tie goes to the shorter)")
        try expectEqual(LoopInterval(5, .h).cleanAlternatives.map(\.token), ["4h", "6h"], "5h")
        try expectEqual(LoopInterval(token: "5m"), LoopInterval(5, .m), "token")
        try expect(LoopInterval(token: "5M") == nil && LoopInterval(token: "m") == nil && LoopInterval(token: "5x") == nil, "not tokens")
    })

    results.append(check("arguments: /loop's rules — a leading interval, else a trailing “every …”, else self-paced") {
        let a = LoopArguments.parse("5m /babysit-prs")
        try expectEqual(a, LoopArguments(interval: LoopInterval(5, .m), prompt: "/babysit-prs", rule: 1), "rule 1")
        try expectEqual(LoopArguments.parse("check the deploy every 20m"),
                        LoopArguments(interval: LoopInterval(20, .m), prompt: "check the deploy", rule: 2), "rule 2")
        try expectEqual(LoopArguments.parse("run tests every 5 minutes").interval, LoopInterval(5, .m), "unit word")
        try expectEqual(LoopArguments.parse("ping every 2 Hours").interval, LoopInterval(2, .h), "any case")
        try expectEqual(LoopArguments.parse("check the deploy"), LoopArguments(interval: nil, prompt: "check the deploy", rule: nil), "rule 3")
        try expectEqual(LoopArguments.parse("check every PR").interval, nil, "“every” not followed by a time")
        try expectEqual(LoopArguments.parse("5m"), LoopArguments(interval: LoopInterval(5, .m), prompt: "", rule: 1), "interval only")
    })

    results.append(check("prompt kinds: the four sentinels, a command, a custom prompt") {
        try expectEqual(LoopPromptKind(prompt: "<<autonomous-loop-dynamic>>"), .maintenance(dynamic: true), "maintenance")
        try expectEqual(LoopPromptKind(prompt: "<<autonomous-loop>>"), .maintenance(dynamic: false), "maintenance fixed")
        try expectEqual(LoopPromptKind(prompt: "<<loop.md>>"), .loopFile(dynamic: false), "loop.md")
        try expectEqual(LoopPromptKind(prompt: "<<loop.md-dynamic>>").title, "loop.md tasks", "title")
        try expectEqual(LoopPromptKind(prompt: "/review-pr 1234"), .command(name: "/review-pr", args: "1234"), "command")
        try expectEqual(LoopPromptKind(prompt: "check CI\nthen fix it").title, "check CI", "first line")
    })

    // MARK: Transcripts

    results.append(check("transcript: calls, results, fires (written twice, counted once), deletes, /loop, goals") {
        let t0 = at(10, 0)
        var lines = [loopCommand("10m check the deploy", t0),
                     toolUse("tc1", "CronCreate", ["cron": "*/10 * * * *", "prompt": "check the deploy", "recurring": true], t0.addingTimeInterval(5)),
                     toolResult("tc1", "Scheduled recurring job 4a2b3c1d", t0.addingTimeInterval(6),
                                detail: ["id": "4a2b3c1d", "recurring": true, "durable": false])]
        lines += fire("4a2b3c1d", cron: "*/10 * * * *", prompt: "check the deploy", kind: "cron", at(10, 13))
        lines.append(typed("thanks", at(10, 20)))
        lines.append(toolUse("td1", "CronDelete", ["id": "4a2b3c1d"], at(10, 21)))
        lines.append(toolResult("td1", "Cancelled job 4a2b3c1d", at(10, 21, 1)))
        lines.append(line(["type": "attachment", "timestamp": iso(at(10, 30)),
                           "attachment": ["type": "goal_status", "met": false, "sentinel": true, "condition": "tests pass"]]))
        lines.append(line(["type": "user", "timestamp": iso(at(10, 31)), "message": ["role": "user", "content": "unrelated, mentions \"name\":\"CronCreate\" as text"]]))
        let l = log(lines)
        try expectEqual(l.invocations.map(\.args), ["10m check the deploy"], "the /loop")
        try expectEqual(l.creates.count, 1, "one create")
        try expectEqual(l.creates.first?.result?.jobID, "4a2b3c1d", "job id from the structured result")
        try expectEqual(l.fires.count, 1, "the system record and the prompt are one fire")
        try expectEqual(l.fires.first?.cron, "*/10 * * * *", "the fire keeps the system record's cron")
        try expectEqual(l.deletes.first?.ok, true, "delete succeeded")
        try expectEqual(l.goals.first?.condition, "tests pass", "goal")
        try expectEqual(l.lastTurnStartAt, at(10, 20), "last typed prompt")
        try expectEqual(l.fires.first?.deliveredAt, at(10, 13).addingTimeInterval(0.01), "delivered by its prompt record")
        try expectEqual(l.permissionMode, "acceptEdits", "permission mode from the newest prompt")
        let named = log(lines + [line(["type": "custom-title", "customTitle": "loop: deploy watch", "sessionId": "s1"])])
        try expectEqual(named.customTitle, "loop: deploy watch", "the session's name (untimed record)")
        try expect(l.pending.isEmpty, "no result left waiting")
    })

    results.append(check("transcript: a result in a later chunk is found by its tool-use id (incremental cache)") {
        let dir = try tempDir()
        let file = dir.appending(path: "s.jsonl")
        let first = toolUse("w1", "ScheduleWakeup", ["delaySeconds": 1200, "reason": "waiting on CI", "prompt": "check CI"], at(10, 0)) + "\n"
            + #"{"type":"user","timestamp":""#   // a half-written line
        try first.write(to: file, atomically: true, encoding: .utf8)
        let cache = LoopLogCache()
        var l = cache.log(for: file)
        try expectEqual(l.wakeups.count, 1, "the call")
        try expect(l.wakeups.first?.scheduledFor == nil, "no result yet")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // Finish the half line (as junk the parser skips), then the real result.
        try handle.write(contentsOf: Data((#"2026-10-01T10:00:00.500Z"}"# + "\n"
            + toolResult("w1", "Next wakeup scheduled for 10:20:00", at(10, 0, 1),
                         detail: ["scheduledFor": at(10, 20).timeIntervalSince1970 * 1000, "clampedDelaySeconds": 1200,
                                  "wasClamped": false]) + "\n").utf8))
        try handle.close()
        l = cache.log(for: file)
        try expectEqual(l.wakeups.count, 1, "not read twice")
        try expectEqual(l.wakeups.first?.scheduledFor, at(10, 20), "the result, read from the appended bytes")
        try expectEqual(l.wakeups.first?.reason, "waiting on CI", "reason")
    })

    // MARK: Building loops

    results.append(check("build: a recurring cron loop — scheduled, due, running, paused, expired, cancelled, failed") {
        let t0 = at(10, 0)
        let create = [loopCommand("10m check", t0),
                      toolUse("tc", "CronCreate", ["cron": "*/10 * * * *", "prompt": "check"], t0.addingTimeInterval(2)),
                      toolResult("tc", "ok", t0.addingTimeInterval(3), detail: ["id": "00000000", "recurring": true])]
        let l1 = log(create + fire("00000000", cron: "*/10 * * * *", prompt: "check", kind: "cron", at(10, 10)))
        var r = try unwrap(LoopBuilder.records(from: l1, session: session, live: live(), now: at(10, 15), calendar: utc).first, "record")
        try expectEqual(r.kind, .recurring, "kind")
        try expectEqual(r.state, .scheduled, "live, next ahead")
        try expectEqual(r.nextFire, at(10, 20), "counted from the last fire (id 0 → no offset)")
        try expectEqual(r.fires.first?.dueAt, at(10, 10), "the fire's due time")
        try expectEqual(r.origin, .loopCommand(args: "10m check", viaSkill: false), "made by /loop")
        try expectEqual(r.expiresAt, at(10, 0, 2, day: 8), "7 days after creation")
        try expectEqual(r.permissionMode, "auto", "the fire's permission mode")

        r = LoopBuilder.records(from: l1, session: session, live: live(busy: true), now: at(10, 25), calendar: utc)[0]
        try expectEqual(r.state, .running, "busy since its own fire: that iteration is still running")
        try expect(r.note?.contains("already due") == true, "and the next fire waits for it")
        let l1b = log(create + fire("00000000", cron: "*/10 * * * *", prompt: "check", kind: "cron", at(10, 10))
                      + [typed("other work", at(10, 22))])
        r = LoopBuilder.records(from: l1b, session: session, live: live(busy: true), now: at(10, 25), calendar: utc)[0]
        try expectEqual(r.state, .due, "past its time while the person's turn runs")
        try expectEqual(r.note, "Waiting for the session's current turn to end", "says why")
        r = LoopBuilder.records(from: l1, session: session, live: live(busy: true), now: at(10, 11), calendar: utc)[0]
        try expectEqual(r.state, .running, "busy, and its fire started the latest turn")
        let waiting = LiveSession(pid: 42, sessionID: "s1", cwd: "/r", status: "waiting", waitingFor: "permission prompt")
        r = LoopBuilder.records(from: l1, session: session, live: waiting, now: at(10, 15), calendar: utc)[0]
        try expectEqual(r.state, .blocked, "a session on a permission prompt fires nothing")
        try expect(r.note?.contains("permission prompt") == true, "says what it's waiting for")
        r = LoopBuilder.records(from: l1, session: session, live: nil, now: at(10, 25), calendar: utc)[0]
        try expectEqual(r.state, .paused, "session closed, comes back on resume")
        r = LoopBuilder.records(from: l1, session: session, live: nil, now: at(10, 1, day: 8), calendar: utc)[0]
        try expectEqual(r.state, .expired, "closed past 7 days — a resume won't bring it back")

        let deleted = log(create + [toolUse("td", "CronDelete", ["id": "00000000"], at(10, 5)), toolResult("td", "done", at(10, 5, 1))])
        try expectEqual(LoopBuilder.records(from: deleted, session: session, live: live(), now: at(10, 6), calendar: utc)[0].state,
                        .cancelled, "deleted")
        let failed = log([toolUse("tf", "CronCreate", ["cron": "*/5 * * * *", "prompt": "x"], t0),
                          toolResult("tf", "Too many scheduled tasks (max 50)", t0.addingTimeInterval(1), error: true)])
        let f = LoopBuilder.records(from: failed, session: session, live: live(), now: at(10, 6), calendar: utc)[0]
        try expectEqual(f.state, .failed, "rejected call")
        try expectEqual(f.note, "Too many scheduled tasks (max 50)", "the CLI's reason")
    })

    results.append(check("build: a recurring loop past 7 days fires once more and is then expired") {
        let t0 = at(10, 0)
        var lines = [toolUse("tc", "CronCreate", ["cron": "0 * * * *", "prompt": "hourly"], t0),
                     toolResult("tc", "ok", t0.addingTimeInterval(1), detail: ["id": "00000000", "recurring": true])]
        lines += fire("00000000", cron: "0 * * * *", prompt: "hourly", kind: "cron", at(11, 0))
        lines += fire("00000000", cron: "0 * * * *", prompt: "hourly", kind: "cron", at(10, 0, 5, day: 8))
        let r = LoopBuilder.records(from: log(lines), session: session, live: live(), now: at(12, 0, day: 8), calendar: utc)[0]
        try expectEqual(r.state, .expired, "expired")
        try expectEqual(r.endedAt, at(10, 0, 5, day: 8), "at its final fire")
    })

    results.append(check("build: a one-shot — scheduled, done after firing, paused or missed while its session is closed") {
        let t0 = at(10, 0)
        let create = [toolUse("t1", "CronCreate", ["cron": "31 14 1 10 *", "prompt": "push the branch", "recurring": false], t0),
                      toolResult("t1", "ok", t0.addingTimeInterval(1), detail: ["id": "ffffffff", "recurring": false])]
        var r = LoopBuilder.records(from: log(create), session: session, live: live(), now: at(12, 0), calendar: utc)[0]
        try expectEqual(r.kind, .oneShot, "kind")
        try expectEqual(r.state, .scheduled, "ahead")
        try expectEqual(r.nextFire, at(14, 31), "off-minute: exact")
        try expectEqual(r.origin, .conversation, "asked for in words")
        r = LoopBuilder.records(from: log(create + fire("ffffffff", cron: "31 14 1 10 *", prompt: "push the branch", kind: "cron", at(14, 31))),
                                session: session, live: live(), now: at(15, 0), calendar: utc)[0]
        try expectEqual(r.state, .completed, "fired once")
        r = LoopBuilder.records(from: log(create), session: session, live: nil, now: at(12, 0), calendar: utc)[0]
        try expectEqual(r.state, .paused, "closed before its time")
        r = LoopBuilder.records(from: log(create), session: session, live: nil, now: at(15, 0), calendar: utc)[0]
        try expectEqual(r.state, .missed, "closed past its time")
    })

    results.append(check("build: a self-paced loop — decisions, a late fire, the CLI's fallback, stop, and its session closing") {
        let t0 = at(7, 41)
        var lines = [loopCommand("check whether CI passed", at(7, 30)),
                     toolUse("w1", "ScheduleWakeup", ["delaySeconds": 1200, "reason": "CI still running", "prompt": "check whether CI passed"], t0),
                     toolResult("w1", "Next wakeup scheduled", t0.addingTimeInterval(1),
                                detail: ["scheduledFor": at(8, 2).timeIntervalSince1970 * 1000, "clampedDelaySeconds": 1200])]
        // Due 8:02, but the session was busy until 8:57.
        lines += fire("92112fd6", cron: "2 8 * * *", prompt: "check whether CI passed", kind: "loop", at(8, 57, 34))
        var r = try unwrap(LoopBuilder.records(from: log(lines), session: session, live: live(), now: at(9, 0), calendar: utc).first, "loop")
        try expectEqual(r.kind, .selfPaced, "kind")
        try expectEqual(r.origin, .loopCommand(args: "check whether CI passed", viaSkill: false), "made by /loop")
        try expectEqual(r.fires.first?.dueAt, at(8, 2), "due when the wakeup said")
        try expectEqual(r.fires.first.flatMap(\.delay).map { Int($0) }, 3334, "waited 55 min for the session")
        try expectEqual(r.state, .scheduled, "not re-armed: the fallback is pending")
        try expect(r.nextFireIsEstimate, "an estimate")
        try expectEqual(r.nextFire, at(9, 18), "20 minutes after the iteration, at the next whole minute")

        // The fallback fired (no wakeup answers it) and wasn't re-armed either: the loop ended.
        var ended = lines + fire("51622e73", cron: "19 9 * * *", prompt: "check whether CI passed", kind: "loop", at(9, 19))
        r = LoopBuilder.records(from: log(ended), session: session, live: live(), now: at(9, 30), calendar: utc)[0]
        try expect(r.fires.last?.isFallback == true, "the second fire is the fallback")
        try expectEqual(r.state, .lapsed, "ended")
        try expectEqual(r.taskIDs, ["92112fd6", "51622e73"], "a task id per wakeup")

        // Re-armed after the fallback: scheduled again.
        ended.append(toolUse("w2", "ScheduleWakeup", ["delaySeconds": 600, "reason": "PR quiet", "prompt": "check whether CI passed"], at(9, 25)))
        ended.append(toolResult("w2", "ok", at(9, 25, 1), detail: ["scheduledFor": at(9, 35).timeIntervalSince1970 * 1000]))
        r = LoopBuilder.records(from: log(ended), session: session, live: live(), now: at(9, 30), calendar: utc)[0]
        try expectEqual(r.state, .scheduled, "re-armed")
        try expectEqual(r.nextFire, at(9, 35), "its wakeup")
        try expectEqual(r.wakeups.map(\.reason), ["CI still running", "PR quiet"], "Claude's reasons")

        ended.append(toolUse("w3", "ScheduleWakeup", ["stop": true], at(9, 40)))
        r = LoopBuilder.records(from: log(ended), session: session, live: live(), now: at(9, 45), calendar: utc)[0]
        try expectEqual(r.state, .stopped, "stop: true ends it")
        r = LoopBuilder.records(from: log(lines), session: session, live: nil, now: at(9, 0), calendar: utc)[0]
        try expectEqual(r.state, .lapsed, "a closed session ends a self-paced loop — it isn't restored")
    })

    results.append(check("build: a /loop whose first iteration is still running shows as setting up") {
        let l = log([loopCommand("watch the deploy", at(10, 0))])
        let r = try unwrap(LoopBuilder.records(from: l, session: session, live: live(busy: true), now: at(10, 2), calendar: utc).first, "setting up")
        try expectEqual(r.state, .running, "running")
        try expectEqual(r.kind, .selfPaced, "no interval")
        try expect(LoopBuilder.records(from: l, session: session, live: live(), now: at(10, 2), calendar: utc).isEmpty,
                   "nothing once the session is idle without a wakeup")
    })

    results.append(check("build: durable tasks — off in this CLI, no session in the folder, run by the lock holder, missed") {
        var caps = LoopCapabilities()
        let task = DurableTask(id: "00000000", cron: "*/10 * * * *", prompt: "sweep", createdAt: at(10, 0), recurring: true)
        caps.durable = .off
        var r = LoopBuilder.durableRecords([task], file: URL(filePath: "/r/.claude/scheduled_tasks.json"), capabilities: caps,
                                           liveInProject: [live()], lock: nil, lockHolderAlive: false, knownSessionIDs: [],
                                           now: at(10, 5), calendar: utc)[0]
        try expectEqual(r.state, .notRunning, "durable off")
        try expect(r.note?.contains("switched off") == true, "says so")
        caps.durable = .on
        r = LoopBuilder.durableRecords([task], file: URL(filePath: "/x"), capabilities: caps, liveInProject: [],
                                       lock: nil, lockHolderAlive: false, knownSessionIDs: [], now: at(10, 5), calendar: utc)[0]
        try expectEqual(r.state, .notRunning, "no session open")
        let lock = SchedulerLock(sessionID: "s1abcdef", pid: 42, procStart: nil, acquiredAt: nil)
        r = LoopBuilder.durableRecords([task], file: URL(filePath: "/x"), capabilities: caps, liveInProject: [live()],
                                       lock: lock, lockHolderAlive: true, knownSessionIDs: [], now: at(10, 5), calendar: utc)[0]
        try expectEqual(r.state, .scheduled, "running")
        try expectEqual(r.nextFire, at(10, 10), "next")
        try expect(r.note?.contains("s1abcdef") == true, "names the lock holder")
        let foreign = DurableTask(id: "1", cron: "*/10 * * * *", prompt: "p", createdAt: at(10, 0), recurring: true,
                                  createdBySessionID: "elsewhere")
        r = LoopBuilder.durableRecords([foreign], file: URL(filePath: "/x"), capabilities: caps, liveInProject: [live()],
                                       lock: nil, lockHolderAlive: false, knownSessionIDs: ["s1"], now: at(10, 5), calendar: utc)[0]
        try expectEqual(r.state, .notRunning, "made in another checkout")
        let once = DurableTask(id: "2", cron: "31 10 1 10 *", prompt: "p", createdAt: at(10, 0), recurring: false)
        r = LoopBuilder.durableRecords([once], file: URL(filePath: "/x"), capabilities: caps, liveInProject: [],
                                       lock: nil, lockHolderAlive: false, knownSessionIDs: [], now: at(11, 0), calendar: utc)[0]
        try expectEqual(r.state, .missed, "a missed one-shot")
    })

    results.append(check("review: a long multi-line self-paced prompt stays one loop; the fire record's copy is cut at 200") {
        let long = "Check whether CI passed.\n\nThen " + String(repeating: "read every failing job's log and say what broke ", count: 6)
        let squashed = String(long.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
        var lines = [toolUse("w1", "ScheduleWakeup", ["delaySeconds": 600, "reason": "waiting", "prompt": long], at(10, 0)),
                     toolResult("w1", "ok", at(10, 0, 1), detail: ["scheduledFor": at(10, 10).timeIntervalSince1970 * 1000])]
        // The fire record keeps the squashed copy; the prompt record (full) lands later.
        lines.append(line(["type": "system", "subtype": "scheduled_task_fire", "timestamp": iso(at(10, 10)), "taskId": "t1",
                           "cron": "10 10 * * *", "prompt": squashed, "taskKind": "loop", "content": "resuming"]))
        let records = LoopBuilder.records(from: log(lines), session: session, live: live(busy: true), now: at(10, 11), calendar: utc)
        try expectEqual(records.count, 1, "one loop, not a phantom second one")
        try expectEqual(records.first?.fires.first?.isFallback, false, "the fire answers its wakeup")
        try expectEqual(records.first?.state, .due, "fired, its prompt not delivered yet")
        try expect(LoopBuilder.samePrompt(long, squashed + "…"), "a cut copy matches the full prompt")
        try expect(!LoopBuilder.samePrompt("check the deploy", "check the build"), "different prompts don't")
    })

    results.append(check("review: a fire written before the previous turn's end reads its own iteration") {
        let dir = try tempDir()
        let file = dir.appending(path: "t.jsonl")
        var lines = [typed("start", at(10, 0))]
        // The fire record lands before the previous turn's last text and its turn_duration.
        lines += [line(["type": "system", "subtype": "scheduled_task_fire", "timestamp": iso(at(10, 5)), "taskId": "f1",
                        "cron": "5 10 * * *", "prompt": "tick", "taskKind": "loop", "content": "resuming"]),
                  line(["type": "assistant", "timestamp": iso(at(10, 5, 1)), "message": ["id": "m0", "content": [["type": "text", "text": "the previous turn's answer"]]]]),
                  line(["type": "system", "subtype": "turn_duration", "timestamp": iso(at(10, 5, 2)), "durationMs": 300_000]),
                  line(["type": "user", "isMeta": true, "promptSource": "system", "turnOrigin": "scheduled", "scheduledTaskId": "f1",
                        "timestamp": iso(at(10, 5, 3)), "message": ["role": "user", "content": "tick"]]),
                  line(["type": "assistant", "timestamp": iso(at(10, 5, 5)), "message": ["id": "m1", "content": [
                        ["type": "tool_use", "id": "b1", "name": "Bash", "input": ["command": "ls"]]]]]),
                  line(["type": "user", "timestamp": iso(at(10, 5, 6)), "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "b1", "content": "ok"]]]]),
                  line(["type": "assistant", "timestamp": iso(at(10, 5, 9)), "message": ["id": "m2", "content": [["type": "text", "text": "tock"]]]]),
                  line(["type": "system", "subtype": "turn_duration", "timestamp": iso(at(10, 5, 10)), "durationMs": 7_000])]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let l = LoopLogReader.read(file)
        let f = try unwrap(l.fires.first, "fire")
        try expectEqual(f.deliveredAt, at(10, 5, 3), "delivered by the later prompt record")
        let it = try unwrap(LoopIterationReader.read(file: file, from: try unwrap(f.promptOffset, "prompt offset")), "read")
        try expectEqual(it.lastText, "tock", "its own reply, not the previous turn's")
        try expectEqual(it.toolCalls, 1, "its own tool call")
        try expectEqual(it.durationMs, 7_000, "its own duration")
        try expectEqual(l.turnEnds.count, 2, "both turn ends recorded")
    })

    results.append(check("review: a restart drops self-paced wakeups and what expired; slash commands and notifications are turns") {
        let wake = [toolUse("w1", "ScheduleWakeup", ["delaySeconds": 1200, "reason": "r", "prompt": "check"], at(10, 0)),
                    toolResult("w1", "ok", at(10, 0, 1), detail: ["scheduledFor": at(10, 20).timeIntervalSince1970 * 1000])]
        let restarted = LiveSession(pid: 42, sessionID: "s1", cwd: "/r", startedAt: at(10, 5), status: "idle")
        let r = LoopBuilder.records(from: log(wake), session: session, live: restarted, now: at(10, 6), calendar: utc)[0]
        try expectEqual(r.state, .lapsed, "the wakeup didn't survive the resume")
        let create = [toolUse("tc", "CronCreate", ["cron": "*/10 * * * *", "prompt": "p"], at(10, 0)),
                      toolResult("tc", "ok", at(10, 0, 1), detail: ["id": "00000000", "recurring": true])]
        let late = LiveSession(pid: 42, sessionID: "s1", cwd: "/r", startedAt: at(10, 5, day: 9), status: "idle")
        try expectEqual(LoopBuilder.records(from: log(create), session: session, live: late, now: at(10, 6, day: 9), calendar: utc)[0].state,
                        .expired, "resumed after 7 days: not restored")
        let early = LiveSession(pid: 42, sessionID: "s1", cwd: "/r", startedAt: at(11, 0), status: "busy")
        let slash = line(["type": "user", "turnOrigin": "human", "timestamp": iso(at(11, 15)),
                          "message": ["role": "user", "content": "<command-name>/review</command-name>"]])
        let withFire = create + fire("00000000", cron: "*/10 * * * *", prompt: "p", kind: "cron", at(11, 10)) + [slash]
        try expectEqual(LoopBuilder.records(from: log(withFire), session: session, live: early, now: at(11, 16), calendar: utc)[0].state,
                        .scheduled, "a slash command is the running turn, not the loop's fire")
        let foreign = log(fire("deadbeef", cron: "0 9 * * *", prompt: "a durable task", kind: "cron", at(9, 0)))
        try expect(LoopBuilder.records(from: foreign, session: session, live: live(), now: at(9, 1), calendar: utc).isEmpty,
                   "a fire of a task this transcript didn't make (no taskKind loop) makes no phantom loop")
    })

    results.append(check("review: the cron walk survives a DST fall-back hour and a non-Gregorian calendar setting") {
        var jerusalem = Calendar(identifier: .gregorian)
        jerusalem.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        // 2026-10-25 02:00 IDT falls back to 01:00 IST: 01:15 happens twice. Take the second (UTC 23:15).
        let second = Date(timeIntervalSince1970: 1_792_538_100)   // 2026-10-24T23:15:00Z
        let next = try unwrap(CronExpression("*/5 * * * *")?.next(after: second, calendar: jerusalem), "next")
        try expect(next > second, "never in the past (got \(next))")
        try expect(next.timeIntervalSince(second) <= 300, "within five minutes")
        try expectEqual(Calendar.cron.identifier, .gregorian, "cron reads in Gregorian")
        try expectEqual(LoopInterval(Int.max / 2, .d).minutes > 0, true, "a huge interval doesn't trap")
    })

    results.append(check("listing: Running by next fire, then Paused, Saved, Desktop, Ended; search; projected fires") {
        func rec(_ id: String, _ state: LoopState, kind: LoopRecord.Kind = .recurring, next: Date? = nil, created: Date = at(9, 0)) -> LoopRecord {
            var r = LoopRecord(id: id, kind: kind, origin: .conversation, prompt: "prompt \(id)", cron: "*/10 * * * *",
                               recurring: true, createdAt: created, state: state)
            r.nextFire = next
            r.taskID = "00000000"
            return r
        }
        let records = [rec("late", .scheduled, next: at(11, 0)), rec("soon", .due, next: at(10, 0)), rec("old", .completed),
                       rec("closed", .paused), rec("file", .notRunning, kind: .durable), rec("app", .external, kind: .desktop)]
        let sections = LoopListing.sections(records)
        try expectEqual(sections.map(\.group), [.running, .paused, .saved, .desktop, .ended], "group order")
        try expectEqual(sections[0].items.map(\.id), ["soon", "late"], "by next fire")
        try expectEqual(LoopListing.sections(records, query: "closed").flatMap(\.items).map(\.id), ["closed"], "search")
        var r = rec("p", .scheduled, next: at(10, 10))
        r.expiresAt = at(10, 40)
        let fires = r.projectedFires(in: DateInterval(start: at(10, 0), end: at(11, 0)), calendar: utc)
        try expectEqual(fires, [at(10, 10), at(10, 20), at(10, 30), at(10, 40)], "every 10 minutes, ending at the final fire")
        try expect(rec("x", .completed, next: at(10, 10)).projectedFires(in: DateInterval(start: at(10, 0), end: at(11, 0))).isEmpty,
                   "an ended loop projects nothing")
    })

    results.append(check("goal: the session's /goal — active with its last reason, achieved, cleared") {
        var lines = [line(["type": "attachment", "timestamp": iso(at(10, 0)),
                           "attachment": ["type": "goal_status", "met": false, "sentinel": true, "condition": "tests pass"]]),
                     line(["type": "attachment", "timestamp": iso(at(10, 5)),
                           "attachment": ["type": "goal_status", "met": false, "condition": "tests pass", "reason": "2 failing"]])]
        var g = try unwrap(LoopBuilder.goal(from: log(lines)), "goal")
        try expectEqual(g.state, .active, "active")
        try expectEqual(g.lastReason, "2 failing", "reason")
        try expectEqual(g.since, at(10, 0), "since it was set")
        lines.append(line(["type": "attachment", "timestamp": iso(at(10, 9)),
                           "attachment": ["type": "goal_status", "met": true, "condition": "tests pass", "reason": "all green", "iterations": 3]]))
        g = try unwrap(LoopBuilder.goal(from: log(lines)), "goal")
        try expectEqual(g.state, .achieved, "achieved")
        try expectEqual(g.iterations, 3, "turns")
        lines.append(line(["type": "user", "timestamp": iso(at(10, 20)),
                           "message": ["role": "user", "content": "<command-name>/goal</command-name>\n<command-args>clear</command-args>"]]))
        try expectEqual(LoopBuilder.goal(from: log(lines))?.state, .cleared, "cleared")
    })

    // MARK: The machine

    results.append(check("capabilities: the CLI's cached flags, its jitter config, and CLAUDE_CODE_DISABLE_CRON") {
        let json = #"{"cachedGrowthBookFeatures":{"tengu_kairos_cron":true,"tengu_kairos_cron_durable":false,"#
            + #""tengu_kairos_loop_dynamic":true,"tengu_kairos_cron_config":{"recurringFrac":0.25}},"cachedGrowthBookFeaturesAt":1790000000000}"#
        let caps = LoopCapabilities.parse(claudeJSON: Data(json.utf8))
        try expectEqual(caps.cron, .on, "cron")
        try expectEqual(caps.durable, .off, "durable")
        try expectEqual(caps.selfPaced, .on, "self-paced")
        try expectEqual(caps.maintenancePrompt, .unknown(defaultOn: true), "missing → default")
        try expectEqual(caps.jitter.recurringFraction, 0.25, "remote jitter")
        try expectEqual(caps.flagsFetchedAt, Date(timeIntervalSince1970: 1_790_000_000), "fetched at")
        try expect(LoopCapabilities.parse(claudeJSON: nil).schedulerOn, "no file: the defaults are on")
        try expect(LoopCapabilities.disablesCron(settings: Data(#"{"env":{"CLAUDE_CODE_DISABLE_CRON":"1"}}"#.utf8)), "set")
        try expect(!LoopCapabilities.disablesCron(settings: Data(#"{"env":{"CLAUDE_CODE_DISABLE_CRON":"0"}}"#.utf8)), "0 is off")
        try expect(!LoopCapabilities.disablesCron(settings: Data(#"{"env":{}}"#.utf8)), "absent")
    })

    results.append(check("durable file: absent `recurring` is a one-shot; add writes it only when true; symlinks refused") {
        let file = #"{"tasks":[{"id":"a","cron":"*/5 * * * *","prompt":"p","createdAt":1790000000000},"#
            + #"{"id":"b","cron":"0 9 * * *","prompt":"q","createdAt":1790000000000,"recurring":true,"lastFiredAt":1790000600000},"#
            + #"{"id":"c","cron":"bad","prompt":"r","createdAt":1}, {"id":"d"}]}"#
        let tasks = DurableTaskStore.parse(Data(file.utf8))
        try expectEqual(tasks.map(\.id), ["a", "b"], "malformed and unparseable entries skipped")
        try expect(!tasks[0].recurring && tasks[1].recurring, "recurring only when written true")
        try expectEqual(tasks[1].lastFiredAt, Date(timeIntervalSince1970: 1_790_000_600), "last fired")
        let project = try tempDir()
        let id = try DurableTaskStore.add(cron: "*/5 * * * *", prompt: "sweep", recurring: false, project: project)
        try expectEqual(id.count, 8, "8-character id")
        let raw = try String(contentsOf: DurableTaskStore.file(project: project), encoding: .utf8)
        try expect(!raw.contains("recurring"), "a one-shot has no recurring key")
        try DurableTaskStore.add(cron: "0 * * * *", prompt: "hourly", recurring: true, project: project)
        try expectEqual(DurableTaskStore.load(project: project).map(\.recurring), [false, true], "both")
        try DurableTaskStore.remove(id: id, project: project)
        try expectEqual(DurableTaskStore.load(project: project).map(\.prompt), ["hourly"], "removed")
        do {
            try DurableTaskStore.add(cron: "nope", prompt: "x", recurring: true, project: project)
            throw CheckFailure(message: "invalid cron accepted")
        } catch let e as DurableTaskStore.WriteError { try expectEqual(e, .invalidCron("nope"), "invalid cron") }
        let target = try tempDir()
        let linked = try tempDir()
        try FileManager.default.createSymbolicLink(at: linked.appending(path: ".claude"), withDestinationURL: target)
        do {
            try DurableTaskStore.add(cron: "* * * * *", prompt: "x", recurring: true, project: linked)
            throw CheckFailure(message: "symlinked .claude accepted")
        } catch let e as DurableTaskStore.WriteError {
            guard case .symlink = e else { throw CheckFailure(message: "wrong error \(e)") }
        }
        // A file it can't read is refused, never replaced; an entry it doesn't understand is kept.
        let broken = try tempDir()
        try FileManager.default.createDirectory(at: Paths.projectClaude(broken), withIntermediateDirectories: true)
        try "{ not json".write(to: DurableTaskStore.file(project: broken), atomically: true, encoding: .utf8)
        do {
            try DurableTaskStore.add(cron: "* * * * *", prompt: "x", recurring: true, project: broken)
            throw CheckFailure(message: "an unreadable file was overwritten")
        } catch let e as DurableTaskStore.WriteError {
            guard case .io = e else { throw CheckFailure(message: "wrong error \(e)") }
        }
        try expectEqual(try String(contentsOf: DurableTaskStore.file(project: broken), encoding: .utf8), "{ not json", "left as it was")
        let odd = try tempDir()
        try FileManager.default.createDirectory(at: Paths.projectClaude(odd), withIntermediateDirectories: true)
        try #"{"tasks":["a stray string",{"id":"keep","cron":"0 9 * * *","prompt":"p","createdAt":1}]}"#
            .write(to: DurableTaskStore.file(project: odd), atomically: true, encoding: .utf8)
        try DurableTaskStore.add(cron: "*/5 * * * *", prompt: "new", recurring: true, project: odd)
        let after = try String(contentsOf: DurableTaskStore.file(project: odd), encoding: .utf8)
        try expect(after.contains("a stray string") && after.contains("keep") && after.contains("new"), "nothing dropped")
        let lock = DurableTaskStore.parseLock(Data(#"{"sessionId":"869c","pid":3144,"procStart":"Wed Sep 30 14:46:09 2026","acquiredAt":1790840468537}"#.utf8))
        try expectEqual(lock?.pid, 3144, "lock pid")
    })

    results.append(check("live sessions: the registry file, dead processes dropped, procStart read") {
        let dir = try tempDir()
        let alive = #"{"pid":48030,"sessionId":"3d5f","cwd":"/r","startedAt":1790863756226,"procStart":"Thu Oct  1 14:09:14 2026","status":"waiting","waitingFor":"permission prompt","name":"claudepit-ca","kind":"interactive"}"#
        try alive.write(to: dir.appending(path: "48030.json"), atomically: true, encoding: .utf8)
        try #"{"pid":7,"sessionId":"dead","cwd":"/r"}"#.write(to: dir.appending(path: "7.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: dir.appending(path: "x.json"), atomically: true, encoding: .utf8)
        let sessions = LiveSessionRegistry.load(directory: dir) { $0.pid == 48030 }
        try expectEqual(sessions.map(\.sessionID), ["3d5f"], "only the live one")
        try expect(sessions[0].isWaiting && sessions[0].waitingFor == "permission prompt", "waiting, and what for")
        try expectEqual(sessions[0].name, "claudepit-ca", "name")
        try expectEqual(LiveSessionRegistry.procStartCandidates("Thu Oct  1 14:09:14 2026").first, at(14, 9, 14), "UTC first")
        try expect(LiveSessionRegistry.processStartTime(pid: getpid()) != nil, "the kernel knows our start time")
        try expect(LiveSessionRegistry.processMatches(LiveSession(pid: getpid(), sessionID: "me", cwd: "")), "we are alive")
        try expect(!LiveSessionRegistry.processMatches(LiveSession(pid: getpid(), sessionID: "me", cwd: "",
                                                                   procStart: "Mon Jan  1 00:00:00 2001")),
                   "a pid reused by another process is not the session")
    })

    results.append(check("desktop tasks and loop.md: SKILL.md frontmatter; project loop.md wins; 25,000-byte cut") {
        let root = try tempDir()
        let task = root.appending(path: "daily-review")
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
        try "---\nname: daily-review\ndescription: \"Review yesterday's commits\"\n---\nReview the commits merged yesterday.\n"
            .write(to: task.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let tasks = DesktopScheduledTask.load(root: root)
        try expectEqual(tasks.map(\.name), ["daily-review"], "name")
        try expectEqual(tasks.first?.description, "Review yesterday's commits", "quotes stripped")
        try expectEqual(tasks.first?.prompt, "Review the commits merged yesterday.", "the body is the prompt")
        let project = try tempDir()
        try FileManager.default.createDirectory(at: Paths.projectClaude(project), withIntermediateDirectories: true)
        try String(repeating: "x", count: 25_001).write(to: Paths.projectClaude(project).appending(path: "loop.md"),
                                                        atomically: true, encoding: .utf8)
        let file = try unwrap(LoopFile.read(.project, project: project), "project loop.md")
        try expect(file.isTruncated, "over the limit")
        try expectEqual(LoopFile.active(project: project)?.scope, .project, "the project's wins")
        try expectEqual(file.deliveredText.utf8.count, 25_000, "a fire gets the first 25,000 bytes")
        try expectEqual(file.cutText, "x", "the rest is cut")
        try expect(file.isComplete, "small enough to edit in place")
    })

    results.append(check("loop.md: the cut never splits a character; save refuses a file changed since the edit began") {
        // 24,999 ASCII bytes then a 4-byte emoji: the limit falls inside it, so it is cut whole.
        let text = String(repeating: "a", count: 24_999) + "🙂" + "tail"
        let cut = LoopFile.cutIndex(text)
        try expectEqual(text[..<cut].utf8.count, 24_999, "cut before the emoji")
        try expectEqual(String(text[cut...]), "🙂tail", "the emoji goes with the cut part")
        try expectEqual(LoopFile.cutIndex("short"), "short".endIndex, "nothing cut under the limit")

        let dir = try tempDir()
        let url = dir.appending(path: ".claude/loop.md")
        try LoopFile.save("first\n", to: url, base: nil)
        try expectEqual(try String(contentsOf: url, encoding: .utf8), "first\n", "created with its folder")
        try expectThrows(LoopFile.SaveError.exists, "create refuses an existing file") {
            try LoopFile.save("again\n", to: url, base: nil)
        }
        try LoopFile.save("second\n", to: url, base: "first\n")
        try expectEqual(try String(contentsOf: url, encoding: .utf8), "second\n", "saved over the text it started from")
        try expectThrows(LoopFile.SaveError.changedOnDisk, "an edit begun on stale text is refused") {
            try LoopFile.save("third\n", to: url, base: "first\n")
        }
        try FileManager.default.removeItem(at: url)
        try expectThrows(LoopFile.SaveError.changedOnDisk, "a file removed meanwhile is a change too") {
            try LoopFile.save("third\n", to: url, base: "second\n")
        }
        try LoopFile.save("forced\n", to: url, base: "first\n", force: true)
        try expectEqual(LoopFile.read(at: url, scope: .project)?.text, "forced\n", "overwrite skips the check")
        try expect(LoopFile.read(at: dir, scope: .project) == nil, "a folder is not a loop.md")
    })

    results.append(check("snapshot: a loop blocked on a prompt is not the next fire; recent fires newest first") {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func rec(_ id: String, _ state: LoopState, next: TimeInterval, fires: [TimeInterval]) -> LoopRecord {
            var r = LoopRecord(id: id, kind: .recurring, origin: .conversation, prompt: id, cron: "*/5 * * * *",
                               recurring: true, createdAt: now.addingTimeInterval(-9000), state: state)
            r.nextFire = now.addingTimeInterval(next)
            r.fires = fires.map { LoopFire(time: now.addingTimeInterval($0), taskID: id, dueAt: nil, offset: 1,
                                           isFallback: false, label: nil, deliveredAt: nil, promptOffset: 1) }
            return r
        }
        var snap = LoopSnapshot()
        var durable = rec("durable", .notRunning, next: 10, fires: [-30])
        durable.fires[0].offset = -1
        snap.records = [rec("stuck", .blocked, next: -300, fires: [-100_000, -600]),
                        rec("ok", .scheduled, next: 120, fires: [-60, -360]), durable]
        try expectEqual(snap.nextFire?.record.id, "ok", "the blocked loop's overdue time isn't next")
        try expectEqual(snap.blocked.map(\.id), ["stuck"], "blocked")
        let recent = snap.recentFires(limit: 3, within: 86_400, now: now)
        try expectEqual(recent.map(\.record.id), ["ok", "ok", "stuck"], "newest first, past a day and off-transcript left out")
    })

    // MARK: The New Loop dialog

    results.append(check("draft: the exact text sent — /loop for intervals and self-paced, CronCreate in words for cron and once") {
        var d = LoopDraft()
        d.task = .prompt("check the deploy")
        d.cadence = .interval(LoopInterval(10, .m))
        try expectEqual(d.message(calendar: utc), "/loop 10m check the deploy", "interval")
        d.cadence = .interval(LoopInterval(90, .s))
        try expectEqual(d.message(calendar: utc), "/loop 2m check the deploy", "seconds rounded")
        d.cadence = .selfPaced
        try expectEqual(d.message(calendar: utc), "/loop check the deploy", "self-paced")
        d.task = .defaultPrompt
        try expectEqual(d.message(calendar: utc), "/loop", "maintenance / loop.md, self-paced")
        d.cadence = .interval(LoopInterval(15, .m))
        try expectEqual(d.message(calendar: utc), "/loop 15m", "maintenance / loop.md, fixed")
        d.task = .command(name: "review-pr", args: "1234")
        d.cadence = .interval(LoopInterval(20, .m))
        try expectEqual(d.message(calendar: utc), "/loop 20m /review-pr 1234", "a skill")
        d.task = .prompt("say \"hi\"\nthen stop")
        d.cadence = .cron("3 9 * * 1-5")
        let cron = try unwrap(d.message(calendar: utc), "cron message")
        try expect(cron.contains("cron \"3 9 * * 1-5\" (Weekdays at 9:03 AM"), "names the schedule: \(cron)")
        try expect(cron.contains(#""say \"hi\"\nthen stop""#), "the prompt, JSON-quoted: \(cron)")
        d.cadence = .once(at(14, 31))
        try expect(d.message(calendar: utc)?.contains("cron \"31 14 1 10 *\"") == true, "pinned one-shot")
        try expect(d.message(calendar: utc)?.contains("recurring: false") == true, "one-shot")
        d.destination = .cloud
        d.task = .prompt("summarize merged PRs")
        d.cadence = .interval(LoopInterval(2, .h))
        try expectEqual(d.message(calendar: utc), "/schedule every 2 hours: summarize merged PRs", "cloud")
        d.cadence = .cron("3 9 * * *")
        try expectEqual(d.message(calendar: utc), "/schedule every day at 9:03 AM: summarize merged PRs", "cloud cron")
        d.destination = .newSession
        d.sessionName = ""
        d.permissionMode = "auto"
        d.model = "sonnet"
        try expectEqual(d.claudeArguments(sessionID: "u-1"),
                        ["--session-id", "u-1", "-n", "loop: summarize merged PRs", "--permission-mode", "auto", "--model", "sonnet"],
                        "claude arguments")
    })

    results.append(check("draft: the dialog's warnings — uneven intervals, cloud offer, self-paced pitfalls, :00, the past, durable off") {
        let ctx = LoopDraftContext(now: at(10, 0), calendar: utc)
        var d = LoopDraft()
        d.task = .prompt("check")
        d.cadence = .interval(LoopInterval(7, .m))
        var p = d.preview(in: ctx)
        let uneven = try unwrap(p.notes.first { $0.text.contains("doesn't divide evenly") }, "uneven")
        try expectEqual(uneven.level, .warning, "a warning in a session")
        try expectEqual(uneven.fixes.map(\.label), ["6m", "10m"], "the two nearest clean intervals")
        try expect(p.canSubmit, "still sendable — /loop rounds it")
        try expect(p.runsNow, "/loop runs it now")

        d.cadence = .interval(LoopInterval(2, .h))
        p = d.preview(in: ctx)
        try expect(p.notes.contains { $0.text.contains("cloud routine") }, "an hour or more: the cloud offer")
        try expectEqual(p.maxDelay, 1800, "a 30-minute jitter window")
        try expectEqual(p.expiresAt, at(10, 0, day: 8), "7 days")

        d.cadence = .interval(LoopInterval(5, .m))
        p = d.preview(in: ctx)
        try expect(p.keepsCacheWarm && p.scheduleNote?.contains("4m 45s") == true, "*/5 explained")
        try expect(p.maxDelay == nil, "no jitter window for */5")

        d.cadence = .selfPaced
        d.task = .prompt("run the tests every 5 minutes")
        p = d.preview(in: ctx)
        let pitfall = try unwrap(p.notes.first { $0.text.contains("reads that as the interval") }, "pitfall")
        try expectEqual(pitfall.fixes.first?.fix, .cadence(.interval(LoopInterval(5, .m))), "offers the interval")

        d.task = .prompt("check")
        d.cadence = .cron("0 9 * * *")
        p = d.preview(in: ctx)
        try expectEqual(p.notes.first { $0.text.contains("Fires on :00") }?.fixes.first?.fix, .cron("3 9 * * *"), "off-minute fix")
        try expectEqual(p.cadence, "Every day at 9:00 AM", "the CLI's English")
        try expectEqual(p.nextFires.first, at(9, 0, day: 2), "next fire")

        d.cadence = .cron("0 9 * MON *")
        try expect(!d.preview(in: ctx).canSubmit, "invalid cron blocks")
        d.cadence = .once(at(9, 0))
        try expect(d.preview(in: ctx).notes.contains { $0.text == "That time has passed." && $0.level == .error }, "the past")
        d.cadence = .once(at(14, 30))
        p = d.preview(in: ctx)
        try expect(p.notes.contains { $0.text.contains("up to 1m 30s early") }, "on the half hour: early")
        try expectEqual(p.cron, "30 14 1 10 *", "pinned")

        d.cadence = .interval(LoopInterval(10, .m))
        d.destination = .durableFile
        var caps = LoopCapabilities()
        caps.durable = .off
        p = d.preview(in: LoopDraftContext(now: at(10, 0), capabilities: caps, calendar: utc))
        try expect(!p.canSubmit && p.notes.contains { $0.text.contains("durable tasks switched off") }, "durable off blocks")

        d.destination = .newSession
        d.permissionMode = "manual"
        p = d.preview(in: ctx)
        try expectEqual(p.notes.first { $0.text.contains("permission prompt") }?.fixes.first?.fix, .permissionMode("auto"), "fix")
        caps = LoopCapabilities()
        caps.disabledBy = [URL(filePath: "/u/.claude/settings.json")]
        try expect(!d.preview(in: LoopDraftContext(now: at(10, 0), capabilities: caps, calendar: utc)).canSubmit, "disabled scheduler")
        try expect(!d.preview(in: LoopDraftContext(now: at(10, 0), herdrAvailable: false, calendar: utc)).canSubmit, "no herdr")

        d.task = .command(name: "/deploy", args: "")
        p = d.preview(in: LoopDraftContext(now: at(10, 0), commands: ["/deploy": CommandAvailability(
            modelInvocable: false, reason: "disable-model-invocation: true")], calendar: utc))
        try expect(p.notes.contains { $0.text.contains("can't be run by Claude on its own") }, "user-only skill")
        d.task = .command(name: "/mcp__github__list_prs", args: "")
        try expect(d.preview(in: ctx).notes.contains { $0.text.contains("MCP prompt") }, "MCP prompt")
        d.task = .command(name: "/clear", args: "")
        try expect(d.preview(in: ctx).notes.contains { $0.text.contains("built-in command") }, "built-in")

        d.task = .defaultPrompt
        d.cadence = .cron("3 9 * * *")
        try expect(!d.preview(in: ctx).canSubmit, "the default prompt needs /loop")
        d.cadence = .interval(LoopInterval(30, .m))
        d.destination = .cloud
        d.task = .prompt("x")
        try expect(!d.preview(in: ctx).canSubmit, "cloud: at most hourly")
    })

    return results
}

private func unwrap<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw CheckFailure(message: "\(what): nil") }
    return value
}
