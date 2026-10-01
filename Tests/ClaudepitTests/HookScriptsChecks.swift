import Foundation
@testable import ClaudepitCore

/// Drift guard for the deduped dreaming prompt: `memoryHook` splices a bash-escaped rendering of
/// the same template `memoryHookDreaming` renders with literals, so the two must stay in step.
func hookScriptsChecks() -> [Bool] {
    var results: [Bool] = []

    /// The 11 numbered dreaming steps, by their leading label.
    let steps = [
        "1. Inventory", "2. Full read", "3. Contradiction scan", "4. Staleness check",
        "5. Cross-reference integrity", "6. Synapse formation", "7. Orphan resolution",
        "8. Reachability check", "9. Consolidation", "10. MEMORY.md sync", "11. Log the dream",
    ]

    results.append(check("generated memoryHook contains all 11 dreaming steps") {
        for step in steps {
            try expect(HookScripts.memoryHook.contains(step), "memoryHook has \(step)")
        }
    })

    results.append(check("memoryHookDreaming contains all 11 dreaming steps") {
        for step in steps {
            try expect(HookScripts.memoryHookDreaming.contains(step), "display copy has \(step)")
        }
    })

    results.append(check("both renderings open with the shared reminder") {
        try expect(HookScripts.memoryHookDreaming.hasPrefix(HookScripts.memoryHookReminder),
                   "dreaming opens with the reminder")
        try expect(HookScripts.memoryHook.contains(HookScripts.memoryHookReminder),
                   "script embeds the reminder")
    })

    results.append(check("the display rendering uses literal placeholders, not shell expressions") {
        let d = HookScripts.memoryHookDreaming
        try expect(d.contains("≥10 writes"), "literal count")
        try expect(d.contains("\"sessionId\":\"<session-id>\""), "literal session id")
        try expect(d.contains("\"ts\":<epoch>"), "literal timestamp")
        try expect(!d.contains("${"), "no shell expansion leaked into the display copy")
        try expect(!d.contains("\\\""), "no bash escaping leaked into the display copy")
    })

    results.append(check("the script rendering substitutes and bash-escapes correctly") {
        let s = HookScripts.memoryHook
        try expect(s.contains("${WRITES_SINCE_DREAM} writes"), "count expanded")
        try expect(s.contains("\\\"sessionId\\\":\\\"${SESSION_ID}\\\""), "session id expanded + escaped")
        try expect(s.contains("\\\"ts\\\":\\$(date +%s)"), "timestamp expanded + escaped")
        try expect(!s.contains("{{"), "no template token left unreplaced")
    })

    results.append(check("no template tokens survive in either rendering") {
        for token in ["{{COUNT}}", "{{SESSION_ID}}", "{{TS}}", "{{DREAMING}}", "{{REMINDER}}"] {
            try expect(!HookScripts.memoryHook.contains(token), "memoryHook clean of \(token)")
            try expect(!HookScripts.memoryHookDreaming.contains(token), "dreaming clean of \(token)")
        }
    })

    results.append(check("memoryHook is a runnable bash script with both message branches") {
        let s = HookScripts.memoryHook
        try expect(s.hasPrefix("#!/usr/bin/env bash"), "shebang")
        try expect(s.contains("if [[ \"${WRITES_SINCE_DREAM}\" -ge 10 ]]; then"), "threshold branch")
        try expect(s.contains("MSG=\""), "message assigned")
        try expect(s.hasSuffix("\" \"$EVENT\" \"$MSG\""), "emits the hook JSON last")
    })

    results.append(check("the hook gates on the transcript before doing any memory work") {
        let s = HookScripts.memoryHook
        try expect(s.contains("transcript_path"), "reads the transcript path from the hook input")
        try expect(s.contains("TOUCHED"), "computes a touched-a-file verdict")
        // The silent exit must come before the log read, or a no-change session still pays for it.
        let gate = s.range(of: "if [[ \"${TOUCHED:-1}\" == \"0\" ]]; then")
        let logRead = s.range(of: "WRITES_SINCE_DREAM=$(")
        try expect(gate != nil && logRead != nil, "gate and log read both present")
        if let gate, let logRead {
            try expect(gate.lowerBound < logRead.lowerBound, "gate precedes the log read")
        }
        try expect(!s.contains("{\"name\":\"Edit\""), "matches tool_use blocks, not raw transcript text")
    })

    results.append(check("both the reminder and the strategy tell Claude to skip a no-change session") {
        try expect(HookScripts.memoryHookReminder.contains("skip the memory pass entirely"),
                   "reminder carries the skip clause")
        let p = HookScripts.memorySystemPrompt
        try expect(p.contains("### When to skip"), "strategy has a skip section")
        try expect(p.contains("No memory pass means no log entry"), "log section covers the skip case")
    })

    results.append(check("the summary hook injects per-turn state only; the rules live in the rules file") {
        let hook = HookScripts.summaryHook
        guard let start = hook.range(of: "INSTRUCTION=\""),
              let end = hook.range(of: "</claudepit_summary_instruction>\"") else {
            throw CheckFailure(message: "instruction block not found")
        }
        let block = String(hook[start.upperBound..<end.lowerBound])
        try expect(block.contains("${CURRENT_BULLETS}") && block.contains("${SUMMARY_FILE_PATH}")
                   && block.contains("${NOW}"), "bullets, path and timestamp stay per turn")
        try expect(block.contains("\\\"bullets\\\""), "the JSON shape stays per turn — SummaryStore parses it")
        try expect(block.contains("Session Summary rules"), "points at the rules file")
        try expect(!block.contains("Max 15"), "no static rule re-injected per prompt")
        try expect(block.count < 400, "per-turn block stays small (\(block.count) chars)")
    })

    results.append(check("the summary hook stays quiet on a loop's fires and on reports of the work they start, and speaks to a person") {
        let home = try tempDir()
        let dir = try tempDir()
        let hook = dir.appending(path: "hook.sh")
        try HookScripts.summaryHook.write(to: hook, atomically: true, encoding: .utf8)
        func record(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        let typedFirst = record(["type": "user", "turnOrigin": "human", "promptSource": "typed", "message": ["role": "user", "content": "hi"]])
        let reply = record(["type": "assistant", "message": ["content": []]])
        let turnEnd = record(["type": "system", "subtype": "turn_duration", "durationMs": 900])
        let fire = record(["type": "system", "subtype": "scheduled_task_fire", "taskId": "89115f01", "cron": "*/1 * * * *",
                           "prompt": "tick", "content": "Running scheduled task"])
        let firePrompt = record(["type": "user", "isMeta": true, "promptSource": "system", "turnOrigin": "scheduled",
                                 "scheduledTaskId": "89115f01", "message": ["role": "user", "content": "tick"]])
        // What the hook prints for `prompt`, with the transcript as it stands when the hook runs.
        func run(_ lines: [String], prompt: String) throws -> String {
            let transcript = dir.appending(path: "t-\(UUID().uuidString).jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            let input = dir.appending(path: "in-\(UUID().uuidString).json")
            let payload: [String: Any] = ["session_id": "s1", "cwd": "/r/p", "transcript_path": transcript.path,
                                          "hook_event_name": "UserPromptSubmit", "prompt": prompt]
            try JSONSerialization.data(withJSONObject: payload).write(to: input)
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            let r = Subprocess.runSync("/bin/bash", ["-c", "bash '\(hook.path)' < '\(input.path)'"], environment: env, timeout: 30)
            return r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let quiet = #"{"continue": true}"#
        // As a real fire meets it: its system record written, its own prompt record not yet.
        try expectEqual(try run([typedFirst, reply, turnEnd, fire], prompt: "tick"), quiet, "a fire gets no instruction")
        try expectEqual(try run([typedFirst, reply, turnEnd, fire, firePrompt], prompt: "tick"), quiet,
                        "nor when its prompt record already landed")
        let sentinel = record(["type": "system", "subtype": "scheduled_task_fire", "taskId": "1", "prompt": "<<loop.md>>"])
        try expectEqual(try run([typedFirst, reply, turnEnd, sentinel], prompt: "the loop.md tasks, expanded"), quiet,
                        "a loop.md fire, whose marker expands later")
        // A fire that came due as the previous turn ended: written before that turn's last records.
        try expectEqual(try run([typedFirst, fire, reply, turnEnd], prompt: "tick"), quiet,
                        "a fire written before the previous turn's end")
        // The fire record keeps a long, multi-line prompt squashed and cut at 200 characters.
        let long = "Check the deploy.\n\nThen " + String(repeating: "look at every service carefully and report ", count: 6)
        let squashed = String(long.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
        let longFire = record(["type": "system", "subtype": "scheduled_task_fire", "taskId": "a1", "prompt": squashed])
        try expectEqual(try run([typedFirst, reply, turnEnd, longFire], prompt: long), quiet, "a long prompt's cut copy")
        // A person's prompt that jumped ahead of a waiting fire still gets the instruction.
        let ahead = try run([typedFirst, reply, turnEnd, fire], prompt: "an unrelated question about the build")
        try expect(ahead.contains("claudepit_summary_instruction"), "a typed prompt ahead of a queued fire")
        let typed = try run([typedFirst, reply, turnEnd, fire, firePrompt, reply, turnEnd], prompt: "what did it say?")
        try expect(typed.contains("claudepit_summary_instruction"), "a typed prompt after a fire still gets it: \(typed.prefix(80))")
        try expect(try run([typedFirst], prompt: "hi").contains("claudepit_summary_instruction"), "the first prompt gets it")

        // A loop that hands each fire to a subagent: the fire's turn ends at the launch, and the
        // agent's report arrives as an unattended turn of its own (records as a real run wrote them).
        let loopTyped = record(["type": "user", "turnOrigin": "human", "message": ["role": "user", "content":
            "<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>1m Use the echo subagent to reply tick</command-args>"]])
        let expansion = record(["type": "user", "isMeta": true, "message": ["role": "user", "content": "# /loop — schedule a recurring or self-paced prompt"]])
        func agentCall(_ id: String) -> String {
            record(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": "Agent",
                                                                  "input": ["subagent_type": "echo", "prompt": "reply tick"]]]]])
        }
        func launched(_ id: String) -> String {
            record(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id,
                                                                             "content": "Async agent launched successfully."]]]])
        }
        func report(_ id: String) -> (record: String, text: String) {
            let text = "<task-notification>\n<task-id>a\(id)</task-id>\n<tool-use-id>\(id)</tool-use-id>\n<status>completed</status>\n<result>tick</result>\n</task-notification>"
            return (record(["type": "user", "promptSource": "system", "turnOrigin": "task_notification",
                            "origin": ["kind": "task-notification", "producer": "session-task"],
                            "message": ["role": "user", "content": text]]), text)
        }
        let firstRun = [loopTyped, expansion, agentCall("t1"), launched("t1"), turnEnd, report("t1").record]
        try expectEqual(try run(firstRun, prompt: report("t1").text), quiet, "the report on a /loop's first run")
        let fired = [typedFirst, reply, turnEnd, fire, firePrompt, agentCall("t2"), launched("t2"), turnEnd, report("t2").record]
        try expectEqual(try run(fired, prompt: report("t2").text), quiet, "the report on a fire's agent")
        try expectEqual(try run(fired, prompt: ""), quiet, "found from the transcript when the hook input lacks it")
        let relayed = fired + [agentCall("t3"), launched("t3"), turnEnd, report("t3").record]
        try expectEqual(try run(relayed, prompt: report("t3").text), quiet, "a report on work a loop's report started")
        let asked = [typedFirst, agentCall("t4"), launched("t4"), turnEnd, report("t4").record]
        try expect(try run(asked, prompt: report("t4").text).contains("claudepit_summary_instruction"),
                   "a report on an agent a person asked for still gets it")

        // A fire whose own record hasn't reached the transcript when the hook runs (a recorded hook
        // saw only the previous turn's records): its prompt is one the session scheduled.
        func scheduling(_ id: String, _ tool: String, _ input: [String: Any]) -> [String] {
            [record(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": tool, "input": input]]]]),
             record(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])]
        }
        let raced = [typedFirst] + scheduling("c1", "CronCreate", ["cron": "*/1 * * * *", "prompt": "check the deploy", "recurring": true])
            + [reply, turnEnd]
        try expectEqual(try run(raced, prompt: "check the deploy"), quiet, "a fire before its record lands")
        let paced = [typedFirst] + scheduling("w1", "ScheduleWakeup", ["delaySeconds": 60, "prompt": "/loop watch CI"]) + [turnEnd]
        try expectEqual(try run(paced, prompt: "/loop watch CI"), quiet, "a self-paced wakeup before its record lands")
        try expect(try run(raced, prompt: "what's the deploy status?").contains("claudepit_summary_instruction"),
                   "a person's own words still get it")
    })

    results.append(check("the rules file and the on-demand summary share one copy of the bullet rules") {
        try expect(HookScripts.summaryRulesPrompt.contains(HookScripts.summaryBulletRules), "rules file")
        try expect(HookScripts.onDemandSummaryPrompt(transcriptText: "x").contains(HookScripts.summaryBulletRules),
                   "on-demand prompt")
        try expect(HookScripts.summaryRulesPrompt.contains("<claudepit_summary_instruction>"),
                   "names the block it pairs with")
        try expect(HookScripts.summaryBulletRules.contains("If the session has made no code"),
                   "one-bullet rule is session-scoped")
    })

    results.append(check("task command bodies are non-empty and carry their front matter") {
        for cmd in HookScripts.taskCommands {
            try expect(cmd.body.hasPrefix("---\ndescription:"), "\(cmd.filename) has front matter")
            try expect(cmd.filename.hasPrefix("claudepit-task-"), "\(cmd.filename) naming")
        }
        try expectEqual(HookScripts.taskCommands.count, 7, "five phase commands + the fix and merge variants")
    })

    results.append(check("the fix command keeps the guardrails a findings fix depends on") {
        let b = HookScripts.taskCommandFix
        try expect(b.contains("Don't stage or commit"), "no-commit rule")
        try expect(b.contains("never create another worktree"), "worktree rule")
        try expect(b.contains("Scope is the finding list, and nothing else"), "scope rule")
        try expect(b.contains("Unrequested changes are a defect"), "no drive-by changes")
        // landFinishedTurn has no expectedArtifact for .implement, so the marker is the ONLY
        // signal that the phase finished — without it a fix task parks in .blocked forever.
        try expect(b.contains("CLAUDEPIT_ARTIFACT: <the absolute fixPath you wrote>"), "artifact marker")
        try expect(b.contains("parentReviewPath="), "reads the parent review")
    })

    results.append(check("the review command specifies the structured findings block") {
        let b = HookScripts.taskCommandReview
        // Written INTO review.md, not just printed: the app parses the file, because scrollback is
        // a fixed-length window that a long review overruns.
        try expect(b.contains("out of the file"), "says the block is read from the file")
        try expect(b.contains("must be written\ninto `reviewPath` — not only printed"), "says write, not just print")
        for field in ["`ruleId`", "`severity`", "`category`", "`title`", "`locations`",
                      "`what`", "`why`", "`fix`"] {
            try expect(b.contains(field), "documents \(field)")
        }
        try expect(b.contains("SARIF"), "names the standard the field vocabulary follows")
        try expect(b.contains("CLAUDEPIT_FINDINGS_BEGIN"), "marker")
        try expect(b.contains("CLAUDEPIT_FINDINGS_END"), "end marker")
        try expect(b.contains("do not wrap the array in a code fence"), "fence warning")
    })

    results.append(check("the review command's own example parses") {
        // A worked example the parser rejects would teach every reviewer the wrong shape.
        let out = TaskTransition.parseFindings(from: HookScripts.taskCommandReview)
        try expectEqual(out.count, 2, "both example findings parse")
        try expectEqual(out[0].severity, "high", "first is high")
        try expectEqual(out[0].ruleID, "C1", "ruleId")
        try expectEqual(out[0].locations?.first?.line, 41, "location line")
        try expect(out[0].what?.contains("force-unwraps") == true, "what")
        try expect(out.allSatisfy { $0.isStructured }, "both are structured")
    })

    return results
}
