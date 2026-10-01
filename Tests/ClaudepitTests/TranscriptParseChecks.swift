import Foundation
@testable import ClaudepitCore

// Record builders shaped like the CLI's JSONL (catalogued from real transcripts, CLI 2.1.236–285).

func tsAt(_ second: Int) -> String {
    "2026-09-30T10:\(String(format: "%02d", second / 60)):\(String(format: "%02d", second % 60)).000Z"
}

func transcriptData(_ records: [[String: Any]]) -> Data {
    let lines = records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

func parseRecords(_ records: [[String: Any]]) -> (events: [SessionEvent], meta: TranscriptMetadata) {
    var t = SessionTranscript()
    let events = t.parse(data: transcriptData(records))
    return (events, t.metadata)
}

func userRecord(_ content: Any, at s: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
    var r: [String: Any] = ["type": "user", "message": ["role": "user", "content": content], "timestamp": tsAt(s)]
    for (k, v) in extra { r[k] = v }
    return r
}

func assistantRecord(_ blocks: [[String: Any]], at s: Int, model: String = "claude-opus-5-5",
                     id: String? = nil, usage: [String: Any]? = nil, _ extra: [String: Any] = [:]) -> [String: Any] {
    var m: [String: Any] = ["role": "assistant", "model": model, "content": blocks]
    if let id { m["id"] = id }
    if let usage { m["usage"] = usage }
    var r: [String: Any] = ["type": "assistant", "message": m, "timestamp": tsAt(s)]
    for (k, v) in extra { r[k] = v }
    return r
}

func toolUseBlock(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
    ["type": "tool_use", "id": id, "name": name, "input": input]
}

func toolResultRecord(_ id: String, _ content: Any, at s: Int, isError: Bool = false,
                      detail: [String: Any]? = nil) -> [String: Any] {
    var r = userRecord([["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]], at: s)
    if let detail { r["toolUseResult"] = detail }
    return r
}

func attachmentRecord(_ att: [String: Any], at s: Int, rendered: String? = nil, role: String? = nil) -> [String: Any] {
    var r: [String: Any] = ["type": "attachment", "attachment": att, "timestamp": tsAt(s)]
    if let rendered { r["rendered"] = [["content": rendered]] }
    if let role { r["renderedRole"] = role }
    return r
}

func systemRecord(_ subtype: String, at s: Int, _ fields: [String: Any] = [:]) -> [String: Any] {
    var r: [String: Any] = ["type": "system", "subtype": subtype, "timestamp": tsAt(s)]
    for (k, v) in fields { r[k] = v }
    return r
}

func toolsIn(_ events: [SessionEvent]) -> [ToolInvocation] {
    events.compactMap { if case .tool(let t) = $0 { return t } else { return nil } }
}

func transcriptParseChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("parse: thinking kept, with text or signed-and-empty") {
        let (e, _) = parseRecords([
            assistantRecord([["type": "thinking", "thinking": "Plan: read the file first.", "signature": "x"],
                             ["type": "thinking", "thinking": "", "signature": "y"],
                             ["type": "redacted_thinking", "data": "z"]], at: 1),
        ])
        let thinking = e.compactMap { if case .thinking(let t) = $0 { return t } else { return nil } }
        try expectEqual(thinking.count, 3, "three thinking blocks")
        try expectEqual(thinking[0].text, "Plan: read the file first.", "text kept")
        try expect(!thinking[0].isRedacted, "with text → not redacted")
        try expect(thinking[1].isRedacted && thinking[2].isRedacted, "empty and redacted_thinking read as redacted")
    })

    results.append(check("parse: tool result keeps structured detail, images, duration; drops heavy duplicates") {
        let pixel = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let (e, _) = parseRecords([
            assistantRecord([toolUseBlock("t1", "Edit", ["file_path": "/p/A.swift", "old_string": "a", "new_string": "b"])], at: 10),
            toolResultRecord("t1", "The file /p/A.swift has been updated.", at: 12, detail: [
                "filePath": "/p/A.swift", "originalFile": String(repeating: "x", count: 5000),
                "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-a", "+b"]]],
            ]),
            assistantRecord([toolUseBlock("t2", "Read", ["file_path": "/p/shot.png"])], at: 13),
            toolResultRecord("t2", [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pixel]]],
                             at: 14, detail: ["type": "image", "file": ["filePath": "/p/shot.png", "content": "dup"]]),
            assistantRecord([toolUseBlock("t3", "ToolSearch", ["query": "select:Monitor"])], at: 15),
            toolResultRecord("t3", [["type": "tool_reference", "tool_name": "Monitor"]], at: 15),
        ])
        let tools = toolsIn(e)
        try expectEqual(tools[0].duration, 2, "call at :10, result at :12")
        try expect(tools[0].detail?["structuredPatch"] != nil, "patch kept")
        try expect(tools[0].detail?["originalFile"] == nil, "whole original file dropped")
        try expectEqual(tools[1].resultImages.count, 1, "image result decoded")
        try expectEqual(tools[1].resultImages.first?.mediaType, "image/png", "media type")
        try expect((tools[1].detail?["file"] as? [String: Any])?["content"] == nil, "Read's duplicate content dropped")
        try expectEqual(tools[2].resultText, "Monitor", "tool_reference names the loaded tool")
    })

    results.append(check("parse: a skill's injected body attaches to its Skill call, not a row") {
        let (e, _) = parseRecords([
            assistantRecord([toolUseBlock("s1", "Skill", ["skill": "rerun"])], at: 1),
            toolResultRecord("s1", "Launching skill: rerun", at: 2, detail: ["success": true, "commandName": "rerun"]),
            userRecord([["type": "text", "text": "Base directory for this skill: /x\n\n# Rerun"]], at: 2,
                       ["isMeta": true, "sourceToolUseID": "s1"]),
        ])
        try expectEqual(e.count, 1, "only the call — the body is part of it")
        try expectEqual(toolsIn(e)[0].injectedContent, "Base directory for this skill: /x\n\n# Rerun", "body attached")
    })

    results.append(check("parse: task notification reattaches to its launching call and opens a turn") {
        let note = """
        <task-notification>
        <task-id>a1</task-id>
        <tool-use-id>ag1</tool-use-id>
        <output-file>/tmp/a1.output</output-file>
        <status>completed</status>
        <summary>Agent "Review plan" finished</summary>
        <result>## Status: done</result>
        </task-notification>
        """
        let (e, _) = parseRecords([
            assistantRecord([toolUseBlock("ag1", "Agent", ["subagent_type": "Explore", "description": "Review plan", "prompt": "p"])], at: 1),
            toolResultRecord("ag1", "Async agent launched successfully.", at: 2, detail: ["status": "async_launched", "agentId": "a1"]),
            userRecord(note, at: 90, ["origin": ["kind": "task-notification"], "promptSource": "system"]),
        ])
        let call = toolsIn(e)[0]
        try expectEqual(call.completion?.status, "completed", "completion on the call")
        try expectEqual(call.completion?.result, "## Status: done", "result carried")
        guard case .userMessage(let m) = e.last else { throw CheckFailure(message: "no notification message") }
        try expectEqual(m.kind, .taskNotification, "notification kind")
        try expectEqual(m.notification?.summary, "Agent \"Review plan\" finished", "summary parsed")
        try expect(m.startsTurn, "a notification hands Claude work")
    })

    results.append(check("parse: a queued report arrives mid-turn and opens no turn") {
        let (e, _) = parseRecords([
            attachmentRecord(["type": "queued_command", "commandMode": "task-notification",
                              "prompt": "<task-notification><task-id>b1</task-id><status>completed</status><summary>Background command \"wait\" completed (exit code 0)</summary></task-notification>"], at: 5),
        ])
        guard case .userMessage(let m) = e.first else { throw CheckFailure(message: "no message") }
        try expectEqual(m.kind, .taskNotification, "still a notification")
        try expect(m.isQueued && !m.startsTurn, "queued → no new turn")
    })

    results.append(check("parse: slash command folds its output and expansion; caveat dropped") {
        let (e, _) = parseRecords([
            userRecord("<local-command-caveat>Caveat: ignore</local-command-caveat>", at: 1, ["isMeta": true]),
            userRecord("<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>ship it</command-args>", at: 2),
            userRecord("<local-command-stdout>Goal set: ship it</local-command-stdout>", at: 2),
            attachmentRecord(["type": "hook_additional_context", "hookName": "UserPromptSubmit", "hookEvent": "UserPromptSubmit",
                              "toolUseID": "hook-1", "content": ["ctx"]], at: 2),
            userRecord("A session-scoped Stop hook is now active", at: 2, ["isMeta": true]),
            userRecord("<local-command-stdout>stray output</local-command-stdout>", at: 3),
        ])
        guard case .userMessage(let cmd) = e[0] else { throw CheckFailure(message: "e0 not the command") }
        try expectEqual(cmd.kind, .command, "command kind")
        try expectEqual(cmd.commandName, "/goal", "name"); try expectEqual(cmd.commandArgs, "ship it", "args")
        try expectEqual(cmd.commandOutput, "Goal set: ship it", "output folded in")
        try expectEqual(cmd.expansion, "A session-scoped Stop hook is now active", "expansion folded in across the hook")
        guard case .hook = e[1] else { throw CheckFailure(message: "e1 should be the hook") }
        guard case .userMessage(let stray) = e[2] else { throw CheckFailure(message: "e2 not a message") }
        try expectEqual(stray.kind, .commandOutput, "output with no open command stands alone")
        try expectEqual(e.count, 3, "caveat left out")
    })

    results.append(check("parse: interrupts, API errors and system subtypes become notices") {
        let (e, _) = parseRecords([
            userRecord([["type": "text", "text": "[Request interrupted by user for tool use]"]], at: 1),
            assistantRecord([["type": "text", "text": "Not logged in · Please run /login"]], at: 2, model: "<synthetic>",
                            ["isApiErrorMessage": true, "error": "authentication_failed"]),
            systemRecord("turn_duration", at: 3, ["durationMs": 40215, "messageCount": 26]),
            systemRecord("compact_boundary", at: 4, ["content": "Conversation compacted",
                                                     "compactMetadata": ["trigger": "manual", "preTokens": 600681, "postTokens": 17434]]),
            systemRecord("away_summary", at: 5, ["content": "Added a badge."]),
            systemRecord("informational", at: 6, ["content": "Unknown command: /cleart", "level": "warning"]),
        ])
        let notices = e.compactMap { if case .notice(let n) = $0 { return n } else { return nil } }
        try expectEqual(notices.map(\.kind), [.interrupted, .apiError, .turnEnd, .compaction, .awaySummary, .informational], "kinds in order")
        try expectEqual(notices[0].title, "Interrupted during a tool call", "tool-use interrupt")
        try expect(notices[1].isError, "API error is an error")
        try expectEqual(notices[1].detail, "authentication_failed", "error code kept")
        try expectEqual(notices[2].durationMs, 40215, "turn duration"); try expectEqual(notices[2].messageCount, 26, "message count")
        try expectEqual(notices[3].preTokens, 600681, "pre"); try expectEqual(notices[3].postTokens, 17434, "post")
        try expectEqual(notices[5].level, "warning", "level kept")
    })

    results.append(check("parse: Stop-hook summary merges into its run, or stands in for a missing one") {
        let (e, _) = parseRecords([
            attachmentRecord(["type": "hook_success", "hookName": "Stop", "hookEvent": "Stop", "toolUseID": "h1",
                              "command": "bash '/u/.claude/claudepit-memory-hook.sh' Stop", "stdout": "{}", "exitCode": 0, "durationMs": 187], at: 1),
            systemRecord("stop_hook_summary", at: 1, ["toolUseID": "h1", "hookAdditionalContext": ["Remember memory."],
                                                      "hookInfos": [["command": "x", "durationMs": 187]], "preventedContinuation": true]),
            systemRecord("stop_hook_summary", at: 2, ["toolUseID": "h2", "hookAdditionalContext": [],
                                                      "hookInfos": [["command": "bash /a/b/other.sh", "durationMs": 9]], "hookErrors": ["boom"]]),
        ])
        let hooks = e.compactMap { if case .hook(let h) = $0 { return h } else { return nil } }
        try expectEqual(hooks.count, 2, "one merged + one synthesized")
        try expectEqual(hooks[0].content, "Remember memory.", "context merged in")
        try expect(hooks[0].preventedContinuation, "continuation flag merged")
        try expectEqual(hooks[0].scriptName, "claudepit-memory-hook.sh", "script name from the command")
        try expect(hooks[1].isError, "summary with errors → error run")
        try expectEqual(hooks[1].durationMs, 9, "duration from hookInfos")
    })

    results.append(check("parse: hook records of one run merge; Pre and Post of one call stay apart") {
        let (e, _) = parseRecords([
            attachmentRecord(["type": "hook_success", "hookName": "UserPromptSubmit", "hookEvent": "UserPromptSubmit",
                              "toolUseID": "h9", "command": "bash x.sh", "durationMs": 61], at: 1),
            attachmentRecord(["type": "hook_additional_context", "hookName": "UserPromptSubmit", "hookEvent": "UserPromptSubmit",
                              "toolUseID": "h9", "content": ["<ctx/>"]], at: 1),
            attachmentRecord(["type": "hook_success", "hookName": "PreToolUse:Bash", "hookEvent": "PreToolUse", "toolUseID": "t1"], at: 2),
            attachmentRecord(["type": "hook_non_blocking_error", "hookName": "PostToolUse:Bash", "hookEvent": "PostToolUse",
                              "toolUseID": "t1", "stderr": "exit 127", "exitCode": 127], at: 3),
        ])
        let hooks = e.compactMap { if case .hook(let h) = $0 { return h } else { return nil } }
        try expectEqual(hooks.count, 3, "UserPromptSubmit merged; Pre/Post separate")
        try expectEqual(hooks[0].content, "<ctx/>", "context joined the run"); try expectEqual(hooks[0].durationMs, 61, "duration kept")
        try expectEqual(hooks[2].outcome, .nonBlockingError, "outcome from the record type")
        try expect(hooks[2].isError, "error")
    })

    results.append(check("parse: context attachments become titled items; bookkeeping is skipped") {
        let (e, _) = parseRecords([
            attachmentRecord(["type": "instructions", "files": [
                ["path": "/p/CLAUDE.md", "type": "Project", "content": "# Project"],
                ["path": "/u/.claude/projects/x/memory/MEMORY.md", "type": "AutoMem", "content": "# Memory Index"]]],
                             at: 1, rendered: "<system-reminder>\nContents of /p/CLAUDE.md…\n</system-reminder>", role: "user"),
            attachmentRecord(["type": "environment", "snapshot": ["workingDirectory": "/p", "platform": "darwin", "shell": "zsh", "isGitRepo": true]], at: 1),
            attachmentRecord(["type": "total_tokens_reminder", "text": "<total_tokens>1 left</total_tokens>"], at: 1),
            attachmentRecord(["type": "deferred_tools_record", "entries": []], at: 1),
            attachmentRecord(["type": "brand_new_thing", "x": 1], at: 2, rendered: "<system-reminder>\nSomething new.\n</system-reminder>"),
            attachmentRecord(["type": "mystery", "x": 1], at: 2),
            attachmentRecord(["type": "command_permissions", "allowedTools": []], at: 2),
        ])
        let items = e.compactMap { if case .context(let c) = $0 { return c } else { return nil } }
        try expectEqual(items.count, 3, "instructions, environment, the unknown-but-rendered one")
        try expectEqual(items[0].sections.map(\.title), ["CLAUDE.md", "MEMORY.md"], "one section per file")
        try expectEqual(items[0].sections[1].subtitle, "Auto-memory index", "kind named")
        try expectEqual(items[0].role, "user", "role kept")
        try expect(items[0].rendered?.contains("Contents of /p/CLAUDE.md") == true, "exact text the model saw kept")
        try expectEqual(items[1].summary, "/p · darwin · zsh", "environment summary")
        try expectEqual(items[2].summary, "Something new.", "unknown item summarized from its rendered text")
        let raw = e.compactMap { if case .attachment(let a) = $0 { return a } else { return nil } }
        try expectEqual(raw.map(\.type), ["mystery"], "unknown, unrendered → raw; empty grant dropped")
    })

    results.append(check("parse: one system-prompt row per distinct prompt; a tools-only follow-up fills it in") {
        let parts = ["You are Claude Code.", "__SYSTEM_PROMPT_DYNAMIC_BOUNDARY__", "# Environment"]
        let (e, _) = parseRecords([
            attachmentRecord(["type": "prompt_snapshot", "systemPrompt": parts], at: 1),
            attachmentRecord(["type": "prompt_snapshot", "systemPrompt": parts, "cliPrefix": "You are Claude Code, Anthropic's official CLI.",
                              "tools": [["name": "Bash", "description": "Run", "schema": [:]], ["name": "Read", "description": "Read", "schema": [:]]]], at: 2),
            attachmentRecord(["type": "prompt_snapshot", "systemPrompt": parts,
                              "tools": [["name": "Bash", "description": "Run"], ["name": "Read", "description": "Read"]]], at: 3),
            attachmentRecord(["type": "prompt_snapshot", "systemPrompt": ["A different prompt."]], at: 4),
        ])
        let snaps = e.compactMap { if case .systemPrompt(let s) = $0 { return s } else { return nil } }
        try expectEqual(snaps.count, 2, "repeat collapsed, change kept")
        try expectEqual(snaps[0].parts, ["You are Claude Code.", "# Environment"], "boundary marker dropped")
        try expectEqual(snaps[0].tools.map(\.name), ["Bash", "Read"], "tools filled into the first row")
        try expectEqual(snaps[0].cliPrefix, "You are Claude Code, Anthropic's official CLI.", "prefix kept")
    })

    results.append(check("parse: permission-mode change is a notice; repeats are not") {
        let (e, meta) = parseRecords([
            ["type": "permission-mode", "permissionMode": "auto"],
            ["type": "permission-mode", "permissionMode": "auto"],
            ["type": "permission-mode", "permissionMode": "plan"],
            ["type": "permission-mode", "permissionMode": "plan"],
        ])
        let notices = e.compactMap { if case .notice(let n) = $0 { return n } else { return nil } }
        try expectEqual(notices.count, 1, "one change")
        try expectEqual(notices[0].title, "Permission mode: plan", "names the new mode")
        try expectEqual(notices[0].detail, "was auto", "and the old one")
        try expectEqual(meta.permissionMode, "plan", "metadata tracks the current mode")
    })

    results.append(check("parse: metadata from the records — cwd, branch, version, title, time span") {
        let (_, meta) = parseRecords([
            userRecord("hi", at: 5, ["cwd": "/p", "gitBranch": "HEAD", "version": "2.1.236"]),
            assistantRecord([["type": "text", "text": "yo"]], at: 65, ["cwd": "/elsewhere", "gitBranch": "main", "version": "2.1.285"]),
            ["type": "ai-title", "aiTitle": "Fix the thing"],
        ])
        try expectEqual(meta.cwd, "/p", "first cwd")
        try expectEqual(meta.gitBranch, "main", "detached HEAD ignored")
        try expectEqual(meta.version, "2.1.285", "latest version")
        try expectEqual(meta.aiTitle, "Fix the thing", "title")
        if let a = meta.firstTime, let b = meta.lastTime { try expectEqual(b - a, 60, "a minute apart") }
        else { throw CheckFailure(message: "no time span") }
    })

    results.append(check("parse: peer hand-back and meta text keep their kinds; image-scale notes drop") {
        let (e, _) = parseRecords([
            userRecord("[Subagent hand-back] report", at: 1, ["isMeta": true, "origin": ["kind": "peer", "from": "a98"], "promptSource": "system"]),
            userRecord("[Image: original 1240x2400, displayed at 1033x2000.]", at: 1, ["isMeta": true]),
            userRecord("<system-reminder>be brief</system-reminder>", at: 2, ["isMeta": true, "origin": ["kind": "coordinator"]]),
            userRecord("This session is being continued…", at: 3, ["isCompactSummary": true, "isVisibleInTranscriptOnly": true]),
        ])
        let kinds = e.compactMap { if case .userMessage(let m) = $0 { return m.kind } else { return nil } }
        try expectEqual(kinds, [.peer, .meta, .compactSummary], "kinds")
        if case .userMessage(let peer) = e[0] { try expectEqual(peer.sender, "a98", "sender") }
    })

    results.append(check("parse: notification bodies unescaped; ANSI stripped from command output; image notes dropped") {
        let note = "<task-notification><task-id>a</task-id><tool-use-id>t1</tool-use-id><status>completed</status>" +
                   "<summary>Background command \"make &amp;&amp; run\" completed</summary>" +
                   "<result>func f() -&gt; Int</result></task-notification>"
        let (e, _) = parseRecords([
            assistantRecord([toolUseBlock("t1", "Bash", ["command": "make && run", "run_in_background": true])], at: 10),
            toolResultRecord("t1", "Command running in background", at: 11, detail: ["backgroundTaskId": "a"]),
            userRecord(note, at: 70, ["origin": ["kind": "task-notification"]]),
            userRecord("<command-name>/model</command-name>", at: 80),
            userRecord("<local-command-stdout>Set model to \u{1B}[1mSonnet 5\u{1B}[22m</local-command-stdout>", at: 80),
            userRecord("[Image: source: /nonexistent/1.png]", at: 81, ["isMeta": true]),
        ])
        let call = toolsIn(e)[0]
        try expectEqual(call.completion?.summary, "Background command \"make && run\" completed", "entities unescaped")
        try expectEqual(call.completion?.result, "func f() -> Int", "result unescaped")
        try expectEqual(call.duration, 60, "a background call lasts until its report, not its launch result")
        guard case .userMessage(let cmd) = e[2] else { throw CheckFailure(message: "no command") }
        try expectEqual(cmd.commandOutput, "Set model to Sonnet 5", "ANSI codes stripped")
        try expectEqual(e.count, 3, "call, notification, command — the image note is dropped")
        try expectEqual(stripANSI("\u{1B}[31mred\u{1B}[0m plain"), "red plain", "stripANSI")
        try expectEqual(xmlUnescape("a &lt;b&gt; &amp;amp;"), "a <b> &amp;", "unescape once, & last")
    })

    results.append(check("parse: queued deliveries — a subagent's report, and a typed prompt with an image") {
        let pixel = Data([0x89, 0x50]).base64EncodedString()
        let (e, _) = parseRecords([
            attachmentRecord(["type": "queued_command", "commandMode": "prompt", "isMeta": true,
                              "prompt": "<agent-message from=\"af9\">\n[Subagent hand-back] envelope…",
                              "origin": ["kind": "peer", "from": "af9", "body": "## Report\nAll done."]], at: 1),
            attachmentRecord(["type": "queued_command", "commandMode": "prompt", "origin": ["kind": "human"],
                              "prompt": [["type": "text", "text": "Change this [Image #17]"],
                                         ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pixel]]]], at: 2),
        ])
        guard case .userMessage(let peer) = e[0], case .userMessage(let typed) = e[1] else { throw CheckFailure(message: "two messages") }
        try expectEqual(peer.kind, .peer, "the report is the subagent's, not yours")
        try expectEqual(peer.sender, "af9", "sender")
        try expectEqual(peer.text, "## Report\nAll done.", "the clean body, envelope dropped")
        try expect(peer.isQueued && !peer.startsTurn, "mid-turn")
        try expectEqual(typed.kind, .prompt, "typed while Claude worked")
        try expectEqual(typed.blocks.count, 2, "text and image both kept")
    })

    results.append(check("parse: a prompt written after its reply is put back in front of it") {
        let (e, _) = parseRecords([
            assistantRecord([["type": "text", "text": "Not logged in · Please run /login"]], at: 14, model: "<synthetic>",
                            ["isApiErrorMessage": true]),
            assistantRecord([toolUseBlock("t1", "Bash", ["command": "ls"])], at: 15),
            userRecord("hi", at: 13),
            toolResultRecord("t1", "ok", at: 16),
        ])
        guard case .userMessage(let m) = e[0] else { throw CheckFailure(message: "the prompt should come first") }
        try expectEqual(m.text, "hi", "prompt first")
        guard case .notice = e[1], case .tool(let t) = e[2] else { throw CheckFailure(message: "then the reply, in order") }
        try expectEqual(t.resultText, "ok", "the call's result still found it after the shift")
        let m2 = TranscriptModel(events: e)
        try expectEqual(m2.turns.map(\.opener), [.prompt], "one turn, no preamble")

        // A notification stamped a hair before the reply it follows stays where it was written.
        let (e3, _) = parseRecords([
            userRecord("go", at: 1),
            assistantRecord([["type": "text", "text": "done"]], at: 10),
            userRecord("<task-notification><task-id>x</task-id><status>completed</status><summary>bg done</summary></task-notification>",
                       at: 9, ["origin": ["kind": "task-notification"]]),
        ])
        guard case .assistantText = e3[1], case .userMessage(let n) = e3[2] else { throw CheckFailure(message: "order kept") }
        try expectEqual(n.kind, .taskNotification, "notification last, as written")

        // A hook inside the early-written reply doesn't stop the prompt short of the reply's start.
        let (e4, _) = parseRecords([
            assistantRecord([["type": "text", "text": "a"]], at: 11),
            assistantRecord([toolUseBlock("t1", "Bash", ["command": "ls"])], at: 12),
            attachmentRecord(["type": "hook_success", "hookName": "PostToolUse:Bash", "hookEvent": "PostToolUse", "toolUseID": "t1"], at: 13),
            assistantRecord([["type": "text", "text": "b"]], at: 14),
            userRecord("go", at: 10),
        ])
        guard case .userMessage(let first) = e4[0] else { throw CheckFailure(message: "prompt should lead the whole reply") }
        try expectEqual(first.text, "go", "prompt first, reply intact after it")
    })

    results.append(check("tail: reads appends, waits out a half-written line, restarts after truncation") {
        let dir = try tempDir()
        let url = dir.appending(path: "s.jsonl")
        let one = String(data: transcriptData([userRecord("first", at: 1)]), encoding: .utf8)!
        let two = String(data: transcriptData([assistantRecord([["type": "text", "text": "second"]], at: 2)]), encoding: .utf8)!
        try one.write(to: url, atomically: false, encoding: .utf8)
        var tail = TranscriptFileTail(url: url)
        try expectEqual(tail.read()?.events.count, 1, "first read")
        try expect(tail.read() == nil, "unchanged → nil")
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data(two.prefix(20).utf8))
        try expectEqual(tail.read()?.events.count, 1, "half a line parses nothing yet")
        try h.write(contentsOf: Data(two.dropFirst(20).utf8)); try h.close()
        try expectEqual(tail.read()?.events.count, 2, "the rest of the line lands")
        try "".write(to: url, atomically: false, encoding: .utf8)
        try one.write(to: url, atomically: false, encoding: .utf8)
        try expectEqual(tail.read()?.events.count, 1, "rewritten shorter → read from the start")
        try? FileManager.default.removeItem(at: dir)
    })

    results.append(check("model: a turn's API calls come from its own event range") {
        let (e, _) = parseRecords([
            userRecord("one", at: 1),
            assistantRecord([["type": "text", "text": "a"]], at: 2, id: "m1", usage: ["input_tokens": 5, "output_tokens": 9]),
            userRecord("two", at: 3),
            assistantRecord([["type": "text", "text": "b"]], at: 4, id: "m2", usage: ["input_tokens": 7, "output_tokens": 1]),
            assistantRecord([["type": "text", "text": "c"]], at: 5, id: "m3", usage: ["input_tokens": 8, "output_tokens": 2]),
        ])
        let m = TranscriptModel(events: e)
        try expectEqual(m.apiCalls(in: m.turns[0]).map(\.outputTokens), [9], "turn 1's one call")
        try expectEqual(m.apiCalls(in: m.turns[1]).map(\.outputTokens), [1, 2], "turn 2's two calls")
    })

    results.append(check("parse: a system-recorded /command folds its output; a moved cwd names itself") {
        let (e, _) = parseRecords([
            systemRecord("local_command", at: 1, ["content": "<command-name>/model</command-name>\n<command-args></command-args>"]),
            systemRecord("local_command", at: 1, ["content": "<local-command-stdout>Kept model as Opus</local-command-stdout>"]),
            attachmentRecord(["type": "environment", "snapshot": ["workingDirectory": "/p", "shell": "zsh"]], at: 2),
            attachmentRecord(["type": "environment", "snapshot": ["workingDirectory": "/p/sub", "shell": "zsh"]], at: 3),
            attachmentRecord(["type": "environment", "snapshot": ["workingDirectory": "/p/sub", "shell": "zsh"]], at: 4),
        ])
        guard case .userMessage(let cmd) = e[0] else { throw CheckFailure(message: "command first") }
        try expectEqual(cmd.kind, .command, "a command, not a notice")
        try expectEqual(cmd.commandName, "/model", "name"); try expectEqual(cmd.commandOutput, "Kept model as Opus", "output folded")
        let env = e.compactMap { if case .context(let c) = $0 { return c } else { return nil } }
        try expectEqual(env.map(\.title), ["Environment", "Working directory", "Environment"], "titles")
        try expectEqual(env[1].summary, "→ /p/sub", "the new directory")
        try expectEqual(env[2].summary, "re-sent, unchanged", "a repeat says so")
    })

    results.append(check("context: humanizeKey survives multi-character case mappings") {
        try expectEqual(ContextItemBuilder.humanizeKey("gitStatus"), "Git status", "camel case")
        try expectEqual(ContextItemBuilder.humanizeKey("ßetaKey"), "SSeta key", "ß uppercases to two letters, no trap")
    })

    results.append(check("model: overlapping rewinds resolve the same way every time") {
        // Turn 1 is resent as turn 4; inside turn 1's abandoned branch, turn 2 was resent as turn 3.
        let (e, _) = parseRecords([
            userRecord("one", at: 1, ["uuid": "u1", "parentUuid": "root"]),
            userRecord("two", at: 2, ["uuid": "u2", "parentUuid": "u1"]),
            userRecord("two again", at: 3, ["uuid": "u3", "parentUuid": "u1"]),
            userRecord("one again", at: 4, ["uuid": "u4", "parentUuid": "root"]),
        ])
        for _ in 0..<5 {
            let m = TranscriptModel(events: e)
            try expectEqual(m.turns.map(\.replacedBy), [3, 2, 3, nil], "nearest resend wins, deterministically")
        }
    })

    results.append(check("model: a prompt sent again from the same point marks the abandoned branch rewound") {
        let (e, _) = parseRecords([
            userRecord("first try", at: 1, ["uuid": "u1", "parentUuid": "root"]),
            assistantRecord([["type": "text", "text": "working on it"]], at: 2, ["uuid": "a1", "parentUuid": "u1"]),
            userRecord("tweak", at: 3, ["uuid": "u2", "parentUuid": "a1"]),
            userRecord("second try", at: 4, ["uuid": "u3", "parentUuid": "root"]),
            assistantRecord([["type": "text", "text": "done"]], at: 5, ["uuid": "a2", "parentUuid": "u3"]),
        ])
        let m = TranscriptModel(events: e)
        try expectEqual(m.turns.map(\.rewound), [true, true, false], "both turns of the dropped branch")
        try expectEqual(m.turns[0].replacedBy, 2, "replaced by the resend")
        try expectEqual(m.turns[1].replacedBy, 2, "the follow-up went with it")
    })

    return results
}
