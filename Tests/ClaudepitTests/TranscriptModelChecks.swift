import Foundation
@testable import ClaudepitCore

private func prompt(_ text: String, at t: TimeInterval = 0) -> SessionEvent {
    .userMessage(UserMessage(kind: .prompt, blocks: [.text(text)], time: t))
}

private func say(_ text: String, at t: TimeInterval = 0) -> SessionEvent {
    .assistantText(AssistantText(text: text, time: t, model: "claude-opus-5-5"))
}

private func call(_ id: String, _ name: String, _ input: [String: Any] = [:], result: String? = "ok",
                  error: Bool = false, at t: TimeInterval = 0) -> SessionEvent {
    let (cls, sum) = ToolInvocation.classify(name: name, input: input)
    var inv = ToolInvocation(id: id, name: name, toolClass: cls, argSummary: sum, input: input,
                             resultText: result, isError: error)
    inv.startedAt = t
    inv.finishedAt = t + 1
    return .tool(inv)
}

private func usage(_ input: Int, _ output: Int, read: Int = 0, write: Int = 0,
                   model: String = "claude-opus-5-5") -> SessionEvent {
    .turnUsage(TurnUsage(inputTokens: input, outputTokens: output, cacheReadTokens: read,
                         cacheWriteTokens: write, model: model, effort: "max"))
}

private func hook(_ id: String, _ name: String, stderr: String? = nil) -> SessionEvent {
    var h = HookExecution(id: id, hookName: name, hookEvent: String(name.split(separator: ":").first ?? ""),
                          command: "bash x.sh", stdout: nil, stderr: stderr, content: nil,
                          exitCode: stderr == nil ? 0 : 1, durationMs: 5)
    h.outcome = stderr == nil ? .success : .nonBlockingError
    return .hook(h)
}

private func kinds(_ rows: [TranscriptRow]) -> [String] {
    rows.map { r in
        switch r.kind {
        case .turnHeader: return "H\(r.turn)"
        case .turnFooter: return "F\(r.turn)"
        case .message(let i): return "msg\(i)"
        case .assistant(let i): return "say\(i)"
        case .thinking(let a): return "think\(a)"
        case .tool(let i): return "tool\(i)"
        case .toolRun(let a): return "run\(a)"
        case .context(let a): return "ctx\(a)"
        case .systemPrompt(let i): return "sys\(i)"
        case .hook(let i): return "hook\(i)"
        case .notice(let i): return "note\(i)"
        case .attachment(let i): return "att\(i)"
        }
    }
}

func transcriptModelChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("model: turns open on prompts, commands, notifications; queued messages don't") {
        var queued = UserMessage(kind: .prompt, blocks: [.text("also do Y")], time: 3)
        queued.isQueued = true
        var cmd = UserMessage(kind: .command, blocks: [.text("<command-name>/model</command-name>")], time: 5)
        cmd.commandName = "/model"
        var note = UserMessage(kind: .taskNotification, blocks: [.text("<task-notification/>")], time: 9)
        note.notification = TaskNotification(taskID: "a", toolUseID: nil, status: "completed",
                                             summary: "Background command finished", result: nil, outputFile: nil)
        let m = TranscriptModel(events: [
            prompt("do X", at: 1), say("on it", at: 2), usage(5, 5), .userMessage(queued), say("ok", at: 4),
            .userMessage(cmd), .userMessage(note), say("seen", at: 10), usage(5, 5),
        ])
        try expectEqual(m.turns.map(\.opener), [.prompt, .command, .notification], "three turns, no preamble")
        try expectEqual(m.turns.map(\.label), ["do X", "/model", "Background command finished"], "labels")
        try expectEqual(kinds(m.rows), ["H0", "say1", "msg3", "say4", "F0", "H1", "H2", "say7", "F2"],
                        "queued prompt is a row inside turn 0; a bare command turn has no footer")
        try expect(m.turns[1].durationMs == nil, "an idle command turn claims no duration")
        try expectEqual(m.stats.prompts, 1, "one typed prompt")
    })

    results.append(check("model: a preamble turn exists only when something precedes the first prompt") {
        let bare = TranscriptModel(events: [prompt("hi"), say("hello")])
        try expectEqual(bare.turns.first?.opener, .prompt, "no empty preamble")
        let ctx = ContextItem(type: "date", title: "Date", summary: "2026-09-30")
        let withCtx = TranscriptModel(events: [.context(ctx), prompt("hi")])
        try expectEqual(withCtx.turns.map(\.opener), [.preamble, .prompt], "context before the prompt → preamble")
        try expectEqual(withCtx.turns[0].label, "Session start", "preamble label")
        try expectEqual(withCtx.turns.map(\.number), [0, 1], "the preamble is 0, the first prompt 1")
        try expectEqual(bare.turns.map(\.number), [1], "no preamble: the first prompt is still 1")
    })

    results.append(check("model: routine calls fold into runs at the threshold; key tools break them") {
        let m = TranscriptModel(events: [
            prompt("go"),
            call("a", "Read"), call("b", "Grep"), call("c", "Bash"),                  // 3 → individual
            say("found it"),
            call("d", "Read"), call("e", "Read"), call("f", "Glob"), call("g", "Bash", error: true), // 4 → run
            call("h", "Edit", ["file_path": "/x.swift"]),                                // key tool, own row
            call("i", "Read"),
        ])
        try expectEqual(kinds(m.rows), ["H0", "tool1", "tool2", "tool3", "say4", "run[5, 6, 7, 8]", "tool9", "tool10", "F0"], "rows")
        guard let run = m.rows.first(where: { $0.id == "r5" }) else { throw CheckFailure(message: "no run row") }
        try expect(run.filters.contains(.errors) && run.filters.contains(.tools), "run answers to its members' filters")
        try expectEqual(m.runID(containing: 7), "r5", "a folded call knows its run")
        try expect(m.runID(containing: 1) == nil, "an unfolded call has none")
    })

    results.append(check("model: signed thinking is counted but not shown; thinking with text is a row") {
        let m = TranscriptModel(events: [
            prompt("go"),
            .thinking(ThinkingBlock(text: "")), call("a", "Read"),
            .thinking(ThinkingBlock(text: "")), call("b", "Read"),
            .thinking(ThinkingBlock(text: "")), call("c", "Read"),
            .thinking(ThinkingBlock(text: "")), call("d", "Read"),
            .thinking(ThinkingBlock(text: "Now I see the bug.")), say("fixed"),
        ])
        try expectEqual(kinds(m.rows), ["H0", "run[2, 4, 6, 8]", "think[9]", "say10", "F0"],
                        "signed thinking doesn't break the run")
        try expectEqual(m.turns[0].thinkingBlocks, 5, "all five counted")
    })

    results.append(check("model: tool hooks ride on their call; other hooks are rows") {
        let m = TranscriptModel(events: [
            hook("h-ups", "UserPromptSubmit"),
            prompt("go"),
            call("t1", "Bash", ["command": "ls"]),
            hook("t1", "PostToolUse:Bash", stderr: "tip failed"),
            hook("h-stop", "Stop"),
        ])
        try expectEqual(m.hooksByTool["t1"], [3], "PostToolUse attached to the Bash call")
        try expectEqual(kinds(m.rows), ["H0", "hook0", "H1", "tool2", "hook4", "F1"],
                        "attached hook is no row; a preamble with no calls needs no footer")
        guard let bash = m.rows.first(where: { $0.id == "e2" }) else { throw CheckFailure(message: "no bash row") }
        try expect(bash.filters.isSuperset(of: [.tools, .hooks, .errors]), "the call answers to Hooks and Errors")
    })

    results.append(check("model: footer totals — tokens, calls, models, effort, turn_duration wins") {
        var end = TranscriptNotice(kind: .turnEnd, title: "Turn finished")
        end.durationMs = 40_215
        let m = TranscriptModel(events: [
            prompt("go", at: 100),
            usage(10, 5, read: 100, write: 3), call("a", "Edit", ["file_path": "/x"], at: 101),
            usage(2, 7, read: 200, model: "claude-sonnet-5"), say("done", at: 150),
            .notice(end),
            prompt("again", at: 200), call("b", "Write", ["file_path": "/x"]), call("c", "Write", ["file_path": "/y"]),
        ])
        let t = m.turns[0]
        try expectEqual(t.apiCalls, 2, "two calls")
        try expectEqual(t.inputTokens, 12, "input"); try expectEqual(t.outputTokens, 12, "output")
        try expectEqual(t.cacheReadTokens, 300, "cache read"); try expectEqual(t.cacheWriteTokens, 3, "cache write")
        try expectEqual(t.models, ["claude-opus-5-5", "claude-sonnet-5"], "models in order")
        try expectEqual(t.effort, "max", "effort")
        try expectEqual(t.contextAtEnd, 202, "last call's context")
        try expectEqual(t.durationMs, 40_215, "the CLI's own measure beats first-to-last")
        try expect(!m.rows.contains { if case .notice = $0.kind { return true } else { return false } }, "turn end is no row")
        try expectEqual(m.stats.apiCalls, 2, "session calls")
        try expectEqual(m.stats.filesChanged, 2, "distinct files: /x, /y")
        try expectEqual(m.stats.models, ["claude-opus-5-5", "claude-sonnet-5"], "session models")
    })

    results.append(check("model: filters dissolve runs, keep headers as anchors, drop footers") {
        let m = TranscriptModel(events: [
            prompt("first"), call("a", "Read"), call("b", "Read"), call("c", "Read"), call("d", "Bash", error: true),
            say("hm"),
            prompt("second"), say("fine"),
        ])
        try expectEqual(kinds(m.visibleRows(filters: [.errors])), ["H0", "tool4"], "just the failure, under its prompt")
        try expectEqual(kinds(m.visibleRows(filters: [.responses])), ["H0", "say5", "H1", "say7"], "responses with anchors")
        try expectEqual(kinds(m.visibleRows(filters: [.prompts])), ["H0", "H1"], "Prompts → the outline")
        try expectEqual(kinds(m.visibleRows(runExpanded: { $0 == "r1" })), ["H0", "run[1, 2, 3, 4]", "tool1", "tool2", "tool3", "tool4", "say5", "F0", "H1", "say7"],
                        "an expanded run is followed by its calls (turn 1 made no calls: no footer)")
        try expectEqual(m.counts[.errors], 1, "error count"); try expectEqual(m.counts[.tools], 4, "tool count: runs dissolved")
        try expectEqual(m.counts[.prompts], 2, "prompt count")
    })

    results.append(check("model: search reaches tool results, attached hooks and headers") {
        let m = TranscriptModel(events: [
            prompt("Find the Needle please"),
            call("a", "Read", result: "…haystack…"), call("b", "Grep", result: "needle.swift:3"),
            call("c", "Read"), call("d", "Read"),
            call("t9", "Bash", ["command": "make"]), hook("t9", "PostToolUse:Bash", stderr: "NEEDLE in stderr"),
            say("nothing here"),
        ])
        try expectEqual(kinds(m.visibleRows(query: "needle")), ["H0", "tool2", "tool5"],
                        "header (own match), the Grep inside the run, the Bash via its hook")
        try expectEqual(kinds(m.visibleRows(query: "haystack")), ["H0", "tool1"], "header kept as an anchor")
        try expect(m.visibleRows(query: "absent").isEmpty, "no match → nothing")
    })

    results.append(check("model: task subjects and latest status from TaskCreate/TaskUpdate") {
        var create = ToolInvocation(id: "c1", name: "TaskCreate", toolClass: .builtin, argSummary: "",
                                    input: ["subject": "Fix bugs"], resultText: "Task #1 created successfully: Fix bugs", isError: false)
        create.detail = ["task": ["id": "1", "subject": "Fix bugs"]]
        var update = ToolInvocation(id: "u1", name: "TaskUpdate", toolClass: .builtin, argSummary: "",
                                    input: ["taskId": "1"], resultText: "Updated task #1 status", isError: false)
        update.detail = ["statusChange": ["from": "pending", "to": "in_progress"]]
        let m = TranscriptModel(events: [prompt("go"), .tool(create), .tool(update)])
        try expectEqual(m.taskSubjects["1"], "Fix bugs", "subject")
        try expectEqual(m.taskStatus["1"], "in_progress", "status from the structured change")
    })

    results.append(check("model: API errors and failed calls count as errors; a compaction as a notice") {
        var err = TranscriptNotice(kind: .apiError, title: "Not logged in")
        err.level = "error"
        var compact = TranscriptNotice(kind: .compaction, title: "Conversation compacted")
        compact.preTokens = 600_000
        let m = TranscriptModel(events: [prompt("go"), .notice(err), call("a", "Bash", error: true), .notice(compact)])
        try expectEqual(m.stats.errors, 2, "api error + failed call")
        try expectEqual(m.stats.compactions, 1, "compaction counted")
        try expectEqual(m.counts[.system], 2, "both notices are System")
        try expectEqual(m.counts[.errors], 2, "errors filter finds both")
    })

    results.append(check("export: markdown carries prompts, replies, tool lines and failures") {
        var cmd = UserMessage(kind: .command, blocks: [.text("x")], time: 0)
        cmd.commandName = "/model"; cmd.commandOutput = "Set model to Opus"
        let m = TranscriptModel(events: [
            .userMessage(cmd),
            prompt("fix the bug"),
            say("On it."),
            call("a", "Read", ["file_path": "/p/A.swift"]),
            call("b", "Bash", ["command": "make", "description": "Build"], error: true),
            say("Fixed."),
        ])
        let md = m.markdown()
        try expect(md.contains("`/model` → Set model to Opus"), "command with its output")
        try expect(md.contains("## You"), "prompt heading")
        try expect(md.contains("fix the bug"), "prompt text")
        try expect(md.contains("## Claude"), "Claude heading")
        try expect(md.contains("- `Read` A.swift\n- `Bash` Build — **failed**"), "tool lines grouped, failure marked:\n\(md)")
        try expectEqual(md.components(separatedBy: "## Claude").count - 1, 1, "one Claude heading for one reply run")
    })

    results.append(check("tasks: spans open on in_progress and close on completion; subjects and creators recorded") {
        let m = TranscriptModel(events: [
            say("intro"),                                                                                        // 0
            call("c1", "TaskCreate", ["subject": "Task 1: alpha"], result: "Task #1 created successfully: Task 1: alpha"), // 1
            call("u1", "TaskUpdate", ["taskId": "1", "status": "in_progress"], result: "Updated task #1 status"),  // 2 span 1
            call("b", "Bash", ["command": "ls"]),                                                                // 3
            call("u2", "TaskUpdate", ["taskId": "1", "status": "completed"], result: "Updated task #1"),          // 4 span 1 end
            say("between"),                                                                                      // 5
            call("c2", "TaskCreate", ["subject": "beta"], result: "Task #2 created successfully: beta"),          // 6
            call("u3", "TaskUpdate", ["taskId": "2", "status": "in_progress"], result: "Updated task #2 status"),  // 7 span 2
            call("r", "Read", ["file_path": "/x"]),                                                              // 8 open to the end
        ])
        try expectEqual(m.taskSpans, [
            TranscriptTaskSpan(taskID: "1", label: "Task 1: alpha", start: 2, end: 4),
            TranscriptTaskSpan(taskID: "2", label: "Task 2: beta", start: 7, end: 8),
        ], "two spans, the second open to the end")
        try expectEqual(m.taskSpan(containing: 3)?.taskID, "1", "a call inside span 1")
        try expect(m.taskSpan(containing: 5) == nil, "text between spans belongs to none")
        try expectEqual(m.taskSpan(containing: 8)?.taskID, "2", "the last event is in the open span")
        try expectEqual(m.taskCreateEvent, ["1": 1, "2": 6], "creating events")
        try expectEqual(m.taskStatus, ["1": "completed", "2": "in_progress"], "latest statuses")
    })

    results.append(check("tasks: starting another task closes the open span; unknown subjects fall back") {
        func upd(_ id: String, _ st: String) -> SessionEvent {
            call(id + st, "TaskUpdate", ["taskId": id, "status": st], result: "Updated task #\(id)")
        }
        let m = TranscriptModel(events: [upd("1", "in_progress"), say("a"), upd("1", "in_progress"),
                                         upd("2", "in_progress"), say("b")])
        try expectEqual(m.taskSpans, [
            TranscriptTaskSpan(taskID: "1", label: "Task 1", start: 0, end: 2),
            TranscriptTaskSpan(taskID: "2", label: "Task 2", start: 3, end: 4),
        ], "a repeated in_progress keeps the span; the next task's start ends it")
    })

    results.append(check("filters: plan writes and approvals, task calls and questions have their own chips") {
        let root = "/home/u/.claude/plans"
        var exit = ToolInvocation(id: "x", name: "ExitPlanMode", toolClass: .builtin, argSummary: "",
                                  input: ["plan": "# P", "planFilePath": root + "/p.md"], resultText: "ok", isError: false)
        exit.detail = ["filePath": root + "/p.md"]
        let m = TranscriptModel(events: [
            prompt("plan it"),
            .context(ContextItem(type: "plan_mode", title: "Plan mode", summary: "on", path: root + "/p.md")),
            call("w", "Write", ["file_path": root + "/p.md", "content": "# P"]),
            call("e", "Edit", ["file_path": "/proj/README.md", "old_string": "a", "new_string": "b"]),
            .tool(exit),
            .notice(TranscriptNotice(kind: .modeChange, title: "Permission mode: auto", detail: "was plan")),
            call("q", "AskUserQuestion", ["questions": []]),
            call("t1", "TaskCreate", ["subject": "s"]),
            call("t2", "TodoWrite", ["todos": []]),
            call("t3", "TaskList"), call("t4", "TaskGet", ["taskId": "1"]),
            call("t5", "TaskList"), call("t6", "TaskList"),
        ], plansRoot: root)
        try expectEqual(m.counts[.plans], 4, "plan-mode context, plan write, approval, leaving plan mode")
        try expectEqual(m.counts[.edits], 2, "the plan write is still an edit")
        try expectEqual(m.counts[.questions], 1, "one question")
        try expectEqual(m.counts[.tasks], 6, "folded task reads count call by call")
        let plans = m.visibleRows(filters: [.plans])
        try expectEqual(kinds(plans), ["H0", "ctx[1]", "tool2", "tool4", "note5"], "a turn header anchors the plan rows")
        if case .tool(let i) = plans[2].kind, case .tool(let inv) = m.events[i] {
            try expectEqual(m.planPath(of: inv), root + "/p.md", "the write names its plan")
        }
        if case .tool(let inv) = m.events[4] { try expectEqual(m.planPath(of: inv), root + "/p.md", "the approval names its plan") }
        if case .tool(let inv) = m.events[3] { try expect(m.planPath(of: inv) == nil, "a README is not a plan") }
        try expect(!m.isPlanFile(root + "-old/p.md"), "a sibling folder sharing the prefix is not the plans root")
        try expectEqual(m.turns[0].plans, 2, "the turn counts the write and the approval")
        try expectEqual(m.turns[0].tasks, 6, "and every task call")
        try expectEqual(m.turns[0].questions, 1, "and the question")
    })

    results.append(check("rail: one mark per notable row, so a single long turn is not an empty rail") {
        let root = "/home/u/.claude/plans"
        var compact = TranscriptNotice(kind: .compaction, title: "Conversation compacted")
        compact.preTokens = 600_000
        var exit = ToolInvocation(id: "x", name: "ExitPlanMode", toolClass: .builtin, argSummary: "",
                                  input: ["plan": "# P"], resultText: "approved", isError: false)
        exit.detail = ["filePath": root + "/p.md"]
        let m = TranscriptModel(events: [
            prompt("do it all"),                                                     // 0  header → prompt
            say("ok"),                                                               // 1  no mark
            call("r", "Read", ["file_path": "/a"]),                                  // 2  no mark
            call("e", "Edit", ["file_path": "/a", "old_string": "x", "new_string": "y"]), // 3 edit
            call("b", "Bash", ["command": "make"], error: true),                     // 4  error
            call("w", "Write", ["file_path": root + "/p.md", "content": "# P"]),     // 5  plan (not edit)
            .tool(exit),                                                             // 6  plan
            call("q", "AskUserQuestion", ["questions": []]),                         // 7  question
            call("a", "Agent", ["subagent_type": "Explore", "prompt": "look"]),      // 8  subagent
            call("s", "Skill", ["skill": "review"]),                                 // 9  skill
            call("t", "TaskCreate", ["subject": "x"]),                               // 10 task
            call("g1", "Grep"), call("g2", "Grep"), call("g3", "Grep"),
            call("g4", "Grep", error: true),                                         // 11–14 a run with a failure → error
            .notice(compact),                                                        // 15 compaction
        ], plansRoot: root)
        let marks = m.rows.compactMap { r in m.landmark(of: r).map { (r.id, $0) } }
        try expectEqual(marks.map(\.0), ["h0", "e3", "e4", "e5", "e6", "e7", "e8", "e9", "e10", "r11", "e15"],
                        "which rows get a mark")
        try expectEqual(marks.map(\.1), [.prompt, .edit, .error, .plan, .plan, .question, .subagent, .skill,
                                         .task, .error, .compaction], "and of which kind")
        try expect(TranscriptLandmark.error > .edit && TranscriptLandmark.edit > .prompt, "failures draw on top")
    })

    return results
}
