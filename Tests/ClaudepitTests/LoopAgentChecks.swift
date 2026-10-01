import Foundation
import ClaudepitCore

/// Loops that hand their fires to a subagent, and sessions that run as one — the New Loop dialog's
/// Agent option and `--agent`, and how the Loops page reads them back. Shaped on real `/loop 1m`
/// runs against CLI 2.1.286.
func loopAgentChecks() -> [Bool] {
    var results: [Bool] = []
    func record(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }

    results.append(check("a delegation is written in the words that worked on every fire, and read back") {
        let s = AgentDelegation.sentence(agent: "code-reviewer", task: "Review what changed since the last run", skipWhileRunning: true)
        try expectEqual(s, "Use the code-reviewer subagent to review what changed since the last run. "
                            + AgentDelegation.skipClause("code-reviewer"), "sentence")
        let back = AgentDelegation.parse(s)
        try expectEqual(back?.agent, "code-reviewer", "agent")
        try expectEqual(back?.task, "review what changed since the last run.", "task")
        try expectEqual(back?.skipWhileRunning, true, "guard")
        try expectEqual(AgentDelegation.sentence(agent: "x", task: "PR comments: answer them", skipWhileRunning: false),
                        "Use the x subagent to PR comments: answer them.", "an acronym keeps its case")
        try expect(AgentDelegation.parse("use the test-runner agent to run the suite") != nil, "looser phrasing")
        try expect(AgentDelegation.parse("check CI") == nil, "not a delegation")
    })

    results.append(check("an @agent- mention is found with the rest of the prompt; @files too") {
        let m = AgentDelegation.mention(in: "@agent-code-reviewer look at the auth changes")
        try expectEqual(m?.agent, "code-reviewer", "name")
        try expectEqual(m?.rest, "look at the auth changes", "rest")
        let q = AgentDelegation.mention(in: "please @\"code-reviewer (agent)\" check this")
        try expectEqual(q?.agent, "code-reviewer", "the typeahead's quoted form")
        try expectEqual(q?.rest, "please check this", "rest")
        try expect(AgentDelegation.mention(in: "mail me@agent-x.dev") == nil, "not inside a word")
        try expectEqual(AgentDelegation.fileMentions(in: "read @src/main.swift and @README.md first"),
                        ["src/main.swift", "README.md"], "files")
        try expect(AgentDelegation.fileMentions(in: "ping @alice").isEmpty, "a bare handle isn't a file")
    })

    results.append(check("the Loops page reads a delegating prompt as an agent loop") {
        let s = AgentDelegation.sentence(agent: "code-reviewer", task: "review the diff", skipWhileRunning: true)
        try expectEqual(LoopPromptKind(prompt: s), .agent(name: "code-reviewer", task: "review the diff.", mentioned: false),
                        "delegation")
        try expectEqual(LoopPromptKind(prompt: s).title, "code-reviewer: review the diff.", "title")
        try expectEqual(LoopPromptKind(prompt: "@agent-e2e-echo reply with the word tock"),
                        .agent(name: "e2e-echo", task: "reply with the word tock", mentioned: true), "mention")
        try expectEqual(LoopPromptKind(prompt: "/review-pr 12"), .command(name: "/review-pr", args: "12"), "commands unchanged")
    })

    let reviewer = LoopAgent(name: "code-reviewer", description: "Reviews code", model: "sonnet",
                             tools: ["Read", "Grep", "Glob"], scope: "project")
    let ctx = LoopDraftContext(now: Date(timeIntervalSince1970: 1_790_000_000), agents: [reviewer])

    results.append(check("an Agent task becomes /loop with the delegation, and says what each fire does") {
        var d = LoopDraft()
        d.task = .agent(name: "code-reviewer", task: "review the diff", skipWhileRunning: true)
        d.cadence = .interval(LoopInterval(10, .m))
        try expectEqual(d.message(), "/loop 10m Use the code-reviewer subagent to review the diff. "
                            + AgentDelegation.skipClause("code-reviewer"), "message")
        let p = d.preview(in: ctx)
        try expect(p.canSubmit, "submittable")
        try expect(p.notes.contains { $0.text.contains("fresh code-reviewer (sonnet, tools: Read, Grep, Glob)") }, "what a fire starts")
        try expect(p.notes.contains { $0.text.contains("run in the background") }, "background runs")
        try expect(!p.notes.contains { $0.text.contains("Without the guard") }, "no overlap warning with the guard on")
        d.task = .agent(name: "code-reviewer", task: "review the diff", skipWhileRunning: false)
        let unguarded = d.preview(in: ctx).notes.first { $0.text.contains("Without the guard") }
        try expectEqual(unguarded?.fixes.first?.fix,
                        .task(.agent(name: "code-reviewer", task: "review the diff", skipWhileRunning: true)), "one-click guard")
        d.cadence = .selfPaced
        try expect(!d.preview(in: ctx).notes.contains { $0.text.contains("Without the guard") }, "self-paced: Claude sets the pace")
        d.cadence = .cron("7 * * * *")
        try expect(d.message()?.contains("Use the code-reviewer subagent to review the diff.") == true, "a cron request carries it")
    })

    results.append(check("an Agent task with no agent or nothing to do can't be sent; built-ins are known") {
        var d = LoopDraft()
        d.task = .agent(name: "code-reviewer", task: "  ", skipWhileRunning: true)
        try expect(d.message() == nil, "no message")
        try expect(d.preview(in: ctx).notes.contains { $0.level == .error && $0.text.contains("Say what code-reviewer should do") },
                   "asks for the task")
        d.task = .agent(name: "", task: "review", skipWhileRunning: true)
        try expect(d.preview(in: ctx).notes.contains { $0.level == .error && $0.text.contains("Pick the agent") }, "asks for the agent")
        d.task = .agent(name: "reviewr", task: "review", skipWhileRunning: true)
        try expect(d.preview(in: ctx).notes.contains { $0.level == .warning && $0.text.contains("reviewr isn't an agent") }, "unknown name")
        d.task = .agent(name: "Explore", task: "map the auth code", skipWhileRunning: true)
        try expect(!d.preview(in: ctx).notes.contains { $0.text.contains("isn't an agent") }, "Claude Code's own agents are known")
    })

    results.append(check("a cloud routine warns that your own agents aren't in its fresh clone") {
        var d = LoopDraft()
        d.cadence = .interval(LoopInterval(2, .h))
        d.destination = .cloud
        let c = LoopDraftContext(agents: [LoopAgent(name: "triage", scope: "user"), reviewer])
        d.task = .agent(name: "triage", task: "sort new issues", skipWhileRunning: false)
        try expect(d.preview(in: c).notes.contains { $0.level == .warning && $0.text.contains("won't be there") }, "a user agent")
        d.task = .agent(name: "code-reviewer", task: "review", skipWhileRunning: false)
        try expect(d.preview(in: c).notes.contains { $0.text.contains("only if .claude/agents/ is committed") }, "a project agent")
        let m = d.message() ?? ""
        try expect(m.hasPrefix("/schedule ") && m.hasSuffix(": Use the code-reviewer subagent to review."), "message: \(m)")
    })

    results.append(check("a session run as an agent: --agent, and the tools /loop needs in it") {
        var d = LoopDraft()
        d.task = .prompt("check CI")
        d.cadence = .interval(LoopInterval(5, .m))
        d.sessionAgent = "code-reviewer"
        try expect(Array(d.claudeArguments(sessionID: "s").suffix(2)) == ["--agent", "code-reviewer"], "--agent")
        // A real run: "No such tool available: CronCreate" — the loop never existed.
        let blocked = d.preview(in: ctx).notes.first { $0.level == .error && $0.text.contains("don't include CronCreate") }
        try expectEqual(blocked?.fixes.first?.fix, .sessionAgent(nil), "offers to run as no agent")
        let watcher = LoopAgent(name: "watcher", tools: ["Read", "CronCreate"], scope: "project")
        let c = LoopDraftContext(agents: [watcher, reviewer])
        d.sessionAgent = "watcher"
        let notes = d.preview(in: c).notes
        try expect(!notes.contains { $0.level == .error }, "CronCreate is enough to schedule")
        try expect(notes.contains { $0.level == .warning && $0.text.contains("CronDelete") }, "but asking can't cancel it")
        d.cadence = .selfPaced
        try expect(d.preview(in: c).notes.contains { $0.level == .error && $0.text.contains("ScheduleWakeup") }, "self-paced needs ScheduleWakeup")
        d.cadence = .interval(LoopInterval(5, .m))
        d.model = "haiku"
        try expect(d.preview(in: c).notes.contains { $0.text.contains("haiku, which overrides the agent's own model") },
                   "--model wins over the agent's model (seen in a real run)")
        d.task = .agent(name: "code-reviewer", task: "review", skipWhileRunning: true)
        d.sessionAgent = "all"
        try expect(!d.preview(in: LoopDraftContext(agents: [LoopAgent(name: "all", scope: "user"), reviewer])).notes
                    .contains { $0.level == .error }, "an agent with no tools: line inherits every tool")
        d.sessionAgent = "solo"
        let solo = LoopAgent(name: "solo", tools: ["Read", "CronCreate", "CronDelete"], scope: "user")
        try expect(d.preview(in: LoopDraftContext(agents: [solo, reviewer])).notes
                    .contains { $0.level == .error && $0.text.contains("no Agent tool") }, "it can't hand fires on without Agent")
    })

    results.append(check("@-mentions: a fire leaves them as text, and the fix hands each fire to the agent") {
        var d = LoopDraft()
        d.task = .prompt("@agent-code-reviewer look at the auth changes")
        d.cadence = .interval(LoopInterval(10, .m))
        let n = d.preview(in: ctx).notes.first { $0.text.contains("@agent-code-reviewer") }
        try expectEqual(n?.level, .warning, "warned")
        try expectEqual(n?.fixes.first?.fix,
                        .task(.agent(name: "code-reviewer", task: "look at the auth changes", skipWhileRunning: true)), "fix")
        d.task = .prompt("summarize @docs/notes.md")
        try expect(d.preview(in: ctx).notes.contains { $0.level == .info && $0.text.contains("@docs/notes.md") }, "a file mention")
        d.task = .prompt("check CI")
        try expect(!d.preview(in: ctx).notes.contains { $0.text.contains("@-mention") }, "no mention, no note")
    })

    results.append(check("an agent file's tools and model, in each form the frontmatter takes") {
        try expectEqual(LoopAgent(name: "a", meta: ["tools": "Read, Grep"], scope: "project").tools, ["Read", "Grep"], "comma list")
        try expectEqual(LoopAgent(name: "a", meta: ["tools": "[Read, \"Grep\"]"], scope: "project").tools, ["Read", "Grep"], "flow list")
        try expectEqual(LoopAgent(name: "a", meta: ["tools": "Read\nGrep"], scope: "project").tools, ["Read", "Grep"], "YAML list")
        try expect(LoopAgent(name: "a", meta: [:], scope: "project").tools == nil, "absent: every tool")
        try expect(LoopAgent(name: "a", meta: ["model": "inherit"], scope: "project").model == nil, "inherit")
        try expectEqual(LoopAgent(name: "file-stem", meta: ["name": "reviewer"], scope: "user").name, "reviewer", "name: wins")
        try expect(LoopAgent(name: "a", tools: ["Task"], scope: "user").allows("Agent"), "Task is the Agent tool's old name")
        let denied = LoopAgent(name: "a", disallowedTools: ["CronCreate"], scope: "user")
        try expect(!denied.allows("CronCreate") && denied.allows("Read"), "disallowedTools")
    })

    // A fire that hands its work on, as a real run wrote it: the turn ends at the launch, and the
    // agent's report comes back as a turn of its own.
    let firePrompt = record(["type": "user", "isMeta": true, "turnOrigin": "scheduled", "scheduledTaskId": "cb30fa51",
                             "timestamp": "2026-10-01T16:32:24.000Z",
                             "message": ["role": "user", "content": "Use the e2e-echo subagent to reply with the word tick."]])
    func call(_ id: String) -> String {
        record(["type": "assistant", "timestamp": "2026-10-01T16:32:26.000Z",
                "message": ["id": "m-\(id)", "model": "claude-haiku-4-5",
                            "content": [["type": "tool_use", "id": id, "name": "Agent",
                                         "input": ["subagent_type": "e2e-echo", "description": "Echo tick", "prompt": "tick"]]],
                            "usage": ["output_tokens": 40]]])
    }
    func result(_ id: String, _ text: String) -> String {
        record(["type": "user", "timestamp": "2026-10-01T16:32:26.100Z",
                "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id,
                                                         "content": [["type": "text", "text": text]]]]]])
    }
    let launched = "Async agent launched successfully. (This tool result is internal metadata.)"
    let said = record(["type": "assistant", "timestamp": "2026-10-01T16:32:30.000Z",
                       "message": ["id": "m2", "content": [["type": "text", "text": "New e2e-echo agent launched for this fire."]]]])
    let end = record(["type": "system", "subtype": "turn_duration", "durationMs": 6450, "timestamp": "2026-10-01T16:32:30.100Z"])
    func report(_ id: String) -> String {
        record(["type": "user", "promptSource": "system", "turnOrigin": "task_notification", "origin": ["kind": "task-notification"],
                "timestamp": "2026-10-01T16:32:30.771Z",
                "message": ["role": "user", "content": "<task-notification>\n<task-id>a0</task-id>\n<tool-use-id>\(id)</tool-use-id>\n"
                            + "<status>completed</status>\n<summary>Agent \"Echo tick\" finished</summary>\n<result>tick</result>\n"
                            + "<usage><subagent_tokens>32032</subagent_tokens><duration_ms>1430</duration_ms></usage>\n</task-notification>"]])
    }
    func iteration(_ lines: [String]) throws -> LoopIteration {
        let file = try tempDir().appending(path: "t.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let it = LoopIterationReader.read(file: file, from: 0)
        try expect(it != nil, "the iteration reads")
        return it!
    }

    results.append(check("an iteration follows the agent it started to its report, a later turn") {
        let it = try iteration([firePrompt, call("toolu_1"), result("toolu_1", launched), said, end, report("toolu_1")])
        try expectEqual(it.lastText, "New e2e-echo agent launched for this fire.", "the fire's own words")
        try expect(it.complete && it.durationMs == 6450, "the turn's end")
        try expectEqual(it.delegations.count, 1, "one agent")
        let d = it.delegations[0]
        try expect(d.agent == "e2e-echo" && d.description == "Echo tick", "which agent")
        try expect(d.background, "launched in the background")
        try expectEqual(d.status, "completed", "status")
        try expectEqual(d.result, "tick", "what it reported")
        try expectEqual(d.durationMs, 1430, "its own run time")
        try expect(d.reportedAt != nil && !it.awaitingReports, "reported")
    })

    results.append(check("a report not back yet, one returned in the turn, and one after another fire") {
        let waiting = try iteration([firePrompt, call("toolu_1"), result("toolu_1", launched), said, end])
        try expect(waiting.awaitingReports && waiting.delegations.first?.status == nil, "still running")
        let foreground = try iteration([firePrompt, call("toolu_1"), result("toolu_1", "tick"), said, end])
        try expect(foreground.delegations.first?.background == false, "a foreground run")
        try expectEqual(foreground.delegations.first?.result, "tick", "its report is the call's result")
        // Older CLIs write no turn_duration: the report itself is the next turn.
        let noEnd = try iteration([firePrompt, call("toolu_1"), result("toolu_1", launched), said, report("toolu_1")])
        try expect(noEnd.complete && noEnd.delegations.first?.result == "tick", "the next turn is the report")
        // The agent outlasted the interval: the next fire ran before the report came.
        let nextFire = record(["type": "user", "isMeta": true, "turnOrigin": "scheduled", "scheduledTaskId": "cb30fa51",
                               "timestamp": "2026-10-01T16:33:24.000Z", "message": ["role": "user", "content": "again"]])
        let late = try iteration([firePrompt, call("toolu_1"), result("toolu_1", launched), end,
                                  nextFire, call("toolu_2"), result("toolu_2", launched), end, report("toolu_1")])
        try expect(late.delegations.count == 1 && late.delegations[0].result == "tick", "found past the next fire")
    })

    results.append(check("a session run as an agent is read from its agent-setting record") {
        let bytes = Data((record(["type": "agent-setting", "agentSetting": "e2e-cron", "sessionId": "s"]) + "\n").utf8)
        var log = LoopLog()
        LoopLogReader.ingest(bytes, baseOffset: 0, into: &log)
        try expectEqual(log.agentSetting, "e2e-cron", "agent")
    })

    return results
}

/// The permission mode a loop's new session really gets — checked against two real sessions.
func loopPermissionChecks() -> [Bool] {
    var results: [Bool] = []
    results.append(check("Auto on Haiku warns: the session silently starts in the ask-every-time mode") {
        var d = LoopDraft()
        d.task = .prompt("check CI")
        d.model = "haiku"
        let warned = d.preview(in: LoopDraftContext()).notes.first { $0.text.contains("Auto mode isn't available on Haiku") }
        try expectEqual(warned?.level, .warning, "warned")
        try expectEqual(warned?.fixes.map(\.fix), [.model(nil), .model("sonnet")], "fixes")
        d.model = "sonnet"
        try expect(!d.preview(in: LoopDraftContext()).notes.contains { $0.text.contains("Auto mode isn't available") }, "Sonnet is fine")
        d.model = nil
        d.sessionAgent = "quick"
        let ctx = LoopDraftContext(agents: [LoopAgent(name: "quick", model: "haiku", scope: "project")])
        try expect(d.preview(in: ctx).notes.contains { $0.text.contains("quick's model is Haiku") }, "an agent's own Haiku model too")
        d.permissionMode = "acceptEdits"
        try expect(!d.preview(in: ctx).notes.contains { $0.text.contains("Auto mode isn't available") }, "only for Auto")
    })
    return results
}

/// Capabilities the scheduling docs list that the page and dialog cover since the 2026-10-01
/// audit: background sessions, skills a fire can't run, the self-paced expiry, `/schedule`'s login.
func loopDocsChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("a background session: claude --bg arguments, its printed id, and the registry entry") {
        var d = LoopDraft()
        d.task = .prompt("check CI")
        d.destination = .background
        d.model = "sonnet"
        d.sessionAgent = "watcher"
        let m = d.message() ?? ""
        try expectEqual(m, "/loop 10m check CI", "the same message a session gets")
        try expectEqual(d.backgroundArguments(message: m),
                        ["--bg", "--name", "loop: check CI", "--permission-mode", "auto", "--model", "sonnet", "--agent", "watcher", m],
                        "arguments (no --session-id: --bg ignores it)")
        // Exactly what `claude --bg` printed in a real run (colour codes and all).
        let printed = "backgrounded · \u{1B}[36m847a29dd\u{1B}[39m · bg-e2e (Claudepit test)\n\u{1B}[2m  claude agents             list sessions\u{1B}[22m\n"
            + "\u{1B}[2m  claude attach 847a29dd    open in this terminal\u{1B}[22m\n"
        try expectEqual(BackgroundSession.jobID(fromOutput: printed), "847a29dd", "short id")
        try expect(BackgroundSession.jobID(fromOutput: "error: Workspace not trusted") == nil, "no id on failure")
        let entry = #"{"pid":10960,"sessionId":"847a29dd-ae19-491f-b8f4-c4e52b1c59df","cwd":"/p","startedAt":1790875087454,"kind":"bg","jobId":"847a29dd","status":"idle","name":"bg-e2e"}"#
        let live = LiveSessionRegistry.parse(Data(entry.utf8))
        try expect(live?.isBackground == true && live?.jobID == "847a29dd", "kind bg + jobId")
        let notes = d.preview(in: LoopDraftContext()).notes
        try expect(notes.contains { $0.text.contains("keeps firing after you close the terminal") }, "what a background session is")
        try expect(notes.contains { $0.text.contains("auto mode opted in once") }, "the auto-mode opt-in --bg needs")
        try expect(notes.contains { $0.text.contains("waits until you attach") }, "where a prompt waits")
    })

    results.append(check("skills a fire hands over as plain text: deny rules, /verify — and /init isn't one") {
        let file = URL(filePath: "/p/.claude/settings.json")
        var caps = LoopCapabilities()
        let rules = LoopCapabilities.skillDenyRules(settings: Data(#"{"permissions":{"deny":["Bash(rm:*)","Skill(deploy *)","Skill(skill:release)"]}}"#.utf8))
        try expectEqual(rules, ["Skill(deploy *)", "Skill(skill:release)"], "only Skill rules")
        caps.skillDenyRules = rules.map { .init(rule: $0, file: file) }
        try expect(caps.skillDenyRule(for: "/deploy") != nil && caps.skillDenyRule(for: "apps/web:deploy") != nil, "x and ns:x")
        try expect(caps.skillDenyRule(for: "/release") != nil, "the parameter form")
        try expect(caps.skillDenyRule(for: "/deployer") == nil, "not a prefix of another name")
        try expect(LoopCapabilities.SkillRule(rule: "Skill", file: file).blocks("/anything"), "bare Skill denies all")
        var d = LoopDraft()
        d.task = .command(name: "/deploy", args: "")
        try expect(d.preview(in: LoopDraftContext(capabilities: caps)).notes.contains { $0.text.contains("denied to Claude by “Skill(deploy *)”") },
                   "the dialog names the rule")
        d.task = .command(name: "/verify", args: "")
        try expect(d.preview(in: LoopDraftContext()).notes.contains { $0.level == .warning && $0.text.contains("only you can run") }, "/verify")
        d.task = .command(name: "/init", args: "")
        try expect(!d.preview(in: LoopDraftContext()).notes.contains { $0.level == .warning }, "/init runs through the Skill tool")
    })

    results.append(check("the dialog shows a self-paced loop's seven-day expiry, and /schedule's login") {
        var d = LoopDraft()
        d.task = .prompt("check CI")
        d.cadence = .selfPaced
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try expectEqual(d.preview(in: LoopDraftContext(now: now)).expiresAt, now.addingTimeInterval(7 * 86_400), "expires")
        d.cadence = .interval(LoopInterval(2, .h))
        d.destination = .cloud
        var ctx = LoopDraftContext()
        ctx.scheduleUnavailable = "Claude Code is signed in with apiKey, not claude.ai."
        try expect(d.preview(in: ctx).notes.contains { $0.level == .error && $0.text.contains("needs a claude.ai subscription login") },
                   "an API-key login can't /schedule")
        try expect(!d.preview(in: LoopDraftContext()).notes.contains { $0.text.contains("subscription login") }, "a claude.ai login can")
    })
    return results
}

/// A task whose prompt is the whole `/loop …` command — what a real Haiku run gave CronCreate.
func loopWrappedPromptChecks() -> [Bool] {
    var results: [Bool] = []
    results.append(check("a scheduled “/loop 1m <prompt>” reads as the prompt it fires") {
        let wrapped = "/loop 1m " + AgentDelegation.sentence(agent: "loop-e2e-echo", task: "reply with the word tick", skipWhileRunning: true)
        try expectEqual(LoopPromptKind(prompt: wrapped),
                        .agent(name: "loop-e2e-echo", task: "reply with the word tick.", mentioned: false), "agent loop")
        try expectEqual(LoopPromptKind(prompt: "/loop 5m /review-pr 12"), .command(name: "/review-pr", args: "12"), "a skill inside")
        try expectEqual(LoopPromptKind(prompt: "/loop check the deploy every 5 minutes"), .custom("check the deploy"), "trailing interval")
        try expectEqual(LoopPromptKind(prompt: "/loop 15m"), .command(name: "/loop", args: "15m"), "no prompt inside stays a command")
    })
    return results
}
