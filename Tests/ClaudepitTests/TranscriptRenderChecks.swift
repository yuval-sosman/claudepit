import Foundation
@testable import ClaudepitCore

func transcriptRenderChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("parseMarkdownBlocks: paragraph, heading, lists") {
        let md = """
        # Title
        Some **bold** text.
        - a
        - b
        1. one
        2. two
        """
        let blocks = parseMarkdownBlocks(md)
        try expectEqual(blocks[0], .heading(level: 1, text: "Title"), "heading")
        try expectEqual(blocks[1], .paragraph("Some **bold** text."), "paragraph")
        try expectEqual(blocks[2], .bulletList(["a", "b"]), "bullets")
        try expectEqual(blocks[3], .orderedList(["one", "two"]), "ordered")
    })

    results.append(check("parseMarkdownBlocks: fenced code, incl unterminated") {
        let md = "```swift\nlet x = 1\n```\nafter"
        let b = parseMarkdownBlocks(md)
        try expectEqual(b[0], .code(language: "swift", body: "let x = 1"), "code block")
        try expectEqual(b[1], .paragraph("after"), "after code")

        let un = parseMarkdownBlocks("```\nno end")
        try expectEqual(un[0], .code(language: nil, body: "no end"), "unterminated fence → code to end")
    })

    results.append(check("parseMarkdownBlocks: table + blockquote") {
        let md = """
        | A | B |
        | --- | --- |
        | 1 | 2 |
        > quoted
        """
        let b = parseMarkdownBlocks(md)
        try expectEqual(b[0], .table(header: ["A", "B"], rows: [["1", "2"]]), "table")
        try expectEqual(b[1], .quote("quoted"), "quote")
    })

    results.append(check("parseMarkdownBlocks: paragraph stops at ordered list and table (no blank line)") {
        let md1 = "Here is the plan:\n1. one\n2. two"
        let b1 = parseMarkdownBlocks(md1)
        try expectEqual(b1.count, 2, "para + ordered = 2 blocks")
        try expectEqual(b1[0], .paragraph("Here is the plan:"), "para not swallowing list")
        try expectEqual(b1[1], .orderedList(["one", "two"]), "ordered list separated")

        let md2 = "Results below.\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let b2 = parseMarkdownBlocks(md2)
        try expectEqual(b2.count, 2, "para + table = 2 blocks")
        try expectEqual(b2[0], .paragraph("Results below."), "para not swallowing table")
        try expectEqual(b2[1], .table(header: ["A", "B"], rows: [["1", "2"]]), "table separated")
    })

    results.append(check("diffLines: Edit, Write, MultiEdit") {
        let edit = diffLines(toolName: "Edit", input: [
            "file_path": "/a.swift", "old_string": "let x = 1\nlet y = 2", "new_string": "let x = 9"])
        try expect(edit.contains(where: { $0.kind == .remove && $0.text == "let x = 1" }), "edit remove")
        try expect(edit.contains(where: { $0.kind == .add && $0.text == "let x = 9" }), "edit add")
        try expect(edit.contains(where: { $0.kind == .file && $0.text == "/a.swift" }), "edit file header")

        let write = diffLines(toolName: "Write", input: ["file_path": "/n.txt", "content": "hello\nworld"])
        try expect(write.allSatisfy { $0.kind == .add || $0.kind == .file }, "write all add/file")
        try expect(write.contains(where: { $0.kind == .add && $0.text == "world" }), "write add line")

        let multi = diffLines(toolName: "MultiEdit", input: [
            "file_path": "/m.swift",
            "edits": [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d"]]])
        try expect(multi.filter { $0.kind == .remove }.count == 2, "multiedit 2 removes")
        try expect(multi.filter { $0.kind == .add }.count == 2, "multiedit 2 adds")

        try expect(diffLines(toolName: "Bash", input: ["command": "ls"]).isEmpty, "non-edit → no diff")
    })

    results.append(check("classifyResult: json/markdown/plain") {
        try expectEqual(classifyResult("{\"a\":1}"), .json, "json obj")
        try expectEqual(classifyResult("[1,2,3]"), .json, "json arr")
        try expectEqual(classifyResult("# Heading\ntext"), .markdown, "md heading")
        try expectEqual(classifyResult("- a\n- b"), .markdown, "md list")
        try expectEqual(classifyResult("plain output here"), .plain, "plain")
    })

    results.append(check("deepLinkTarget: found vs not found") {
        let skills: Set<String> = ["code-review"]
        let t = deepLinkTarget(for: .skill(name: "code-review"),
                               skillIDs: skills, agentIDs: [], mcpServerIDs: [], commandIDs: [], hookIDs: [])
        try expectEqual(t, HighlightTarget(sectionRaw: "skills", itemID: "code-review"), "skill link")

        let miss = deepLinkTarget(for: .skill(name: "nope"),
                                  skillIDs: skills, agentIDs: [], mcpServerIDs: [], commandIDs: [], hookIDs: [])
        try expect(miss == nil, "unknown skill → no link")

        let mcp = deepLinkTarget(for: .mcp(server: "pencil", tool: "x"),
                                 skillIDs: [], agentIDs: [], mcpServerIDs: ["pencil"], commandIDs: [], hookIDs: [])
        try expectEqual(mcp, HighlightTarget(sectionRaw: "mcp", itemID: "pencil"), "mcp link")

        try expect(deepLinkTarget(for: .builtin, skillIDs: [], agentIDs: [], mcpServerIDs: [], commandIDs: [], hookIDs: []) == nil,
                   "plain builtin → no link")
    })

    results.append(check("parseCreatedTaskId extracts numeric id") {
        try expectEqual(parseCreatedTaskId("Task #7 created successfully: Foo"), "7", "id 7")
        try expectEqual(parseCreatedTaskId("Updated task #3 status"), "3", "id 3 from update text")
        try expect(parseCreatedTaskId("no number here") == nil, "no id → nil")
    })

    results.append(check("taskSpans + subjects from event sequence") {
        // Build events: create(1), update(1,in_progress), a tool, update(1,completed),
        // then create(2), update(2,in_progress), a tool  [span 2 stays open to end]
        func toolEvent(_ name: String, _ input: [String: Any], result: String?) -> SessionEvent {
            let (cls, sum) = ToolInvocation.classify(name: name, input: input)
            return .tool(ToolInvocation(id: name + (result ?? ""), name: name, toolClass: cls,
                                        argSummary: sum, input: input, resultText: result, isError: false))
        }
        let events: [SessionEvent] = [
            .assistantText("intro"),                                                    // 0 ungrouped
            toolEvent("TaskCreate", ["subject": "Task 1: alpha"], result: "Task #1 created successfully: Task 1: alpha"), // 1
            toolEvent("TaskUpdate", ["taskId": "1", "status": "in_progress"], result: "Updated task #1 status"),          // 2 span1 start
            toolEvent("Bash", ["command": "ls"], result: "ok"),                          // 3 in span1
            toolEvent("TaskUpdate", ["taskId": "1", "status": "completed"], result: "Updated task #1"),                   // 4 span1 end
            .assistantText("between"),                                                   // 5 ungrouped
            toolEvent("TaskCreate", ["subject": "Task 2: beta"], result: "Task #2 created successfully: Task 2: beta"),   // 6
            toolEvent("TaskUpdate", ["taskId": "2", "status": "in_progress"], result: "Updated task #2 status"),          // 7 span2 start
            toolEvent("Read", ["file_path": "/x"], result: "data"),                      // 8 in span2 (open to end)
        ]

        let subjects = taskSubjects(events)
        try expectEqual(subjects["1"], "Task 1: alpha", "subject 1")
        try expectEqual(subjects["2"], "Task 2: beta", "subject 2")

        let spans = taskSpans(events)
        try expectEqual(spans.count, 2, "two spans")
        try expectEqual(spans[0], TaskSpan(taskId: "1", label: "Task 1: alpha", startIndex: 2, endIndex: 4), "span1")
        try expectEqual(spans[1], TaskSpan(taskId: "2", label: "Task 2: beta", startIndex: 7, endIndex: 8), "span2 open to end")
    })

    results.append(check("taskSpans: switching in_progress closes previous; fallback label") {
        func upd(_ id: String, _ st: String) -> SessionEvent {
            let (c, s) = ToolInvocation.classify(name: "TaskUpdate", input: ["taskId": id, "status": st])
            return .tool(ToolInvocation(id: id+st, name: "TaskUpdate", toolClass: c, argSummary: s,
                                        input: ["taskId": id, "status": st], resultText: "Updated task #\(id)", isError: false))
        }
        let events: [SessionEvent] = [ upd("1", "in_progress"), .assistantText("a"), upd("2", "in_progress"), .assistantText("b") ]
        let spans = taskSpans(events)
        try expectEqual(spans.count, 2, "two spans")
        try expectEqual(spans[0], TaskSpan(taskId: "1", label: "Task 1", startIndex: 0, endIndex: 1), "span1 ends before task2 in_progress; fallback label")
        try expectEqual(spans[1], TaskSpan(taskId: "2", label: "Task 2", startIndex: 2, endIndex: 3), "span2 to end")
    })

    results.append(check("parseAskQuestions decodes questions/options") {
        let input: [String: Any] = ["questions": [
            ["header": "Branch", "question": "Where to build?", "multiSelect": false,
             "options": [["label": "On master", "description": "commit to master"],
                         ["label": "Feature branch", "description": "new branch"]]]
        ]]
        let qs = parseAskQuestions(input)
        try expectEqual(qs.count, 1, "one question")
        try expectEqual(qs[0].header, "Branch", "header")
        try expectEqual(qs[0].question, "Where to build?", "question text")
        try expectEqual(qs[0].multiSelect, false, "multiSelect")
        try expectEqual(qs[0].options.count, 2, "two options")
        try expectEqual(qs[0].options[0], AskOption(label: "On master", description: "commit to master"), "opt0")
        // missing keys tolerated
        try expect(parseAskQuestions([:]).isEmpty, "no questions key → empty")
    })

    results.append(check("parseAskAnswers extracts chosen labels") {
        let r = #"Your questions have been answered: "Where to build?"="On master". You can now continue."#
        let a = parseAskAnswers(r)
        try expectEqual(a["Where to build?"], "On master", "single answer")

        let r2 = #"Your questions have been answered: "Q1"="A1", "Q2"="A2". More."#
        let a2 = parseAskAnswers(r2)
        try expectEqual(a2["Q1"], "A1", "multi q1")
        try expectEqual(a2["Q2"], "A2", "multi q2")

        try expect(parseAskAnswers("no answers here").isEmpty, "no match → empty")
    })

    results.append(check("timelineMarkers: only notable events, correct kinds/order/labels") {
        func tool(_ name: String, _ input: [String: Any], result: String? = nil) -> SessionEvent {
            let (c, s) = ToolInvocation.classify(name: name, input: input)
            return .tool(ToolInvocation(id: name, name: name, toolClass: c, argSummary: s,
                                        input: input, resultText: result, isError: false))
        }
        let events: [SessionEvent] = [
            .userMessage([.text("hello there this is my message")]),          // 0 → .user
            tool("Bash", ["command": "ls"]),                       // 1 → none
            tool("TaskCreate", ["subject": "Task 1: alpha"],
                 result: "Task #1 created successfully: Task 1: alpha"), // 2 → .task
            .assistantText("working"),                             // 3 → none
            tool("Agent", ["subagent_type": "Explore", "description": "look"]), // 4 → .subagent
            tool("Read", ["file_path": "/x"]),                     // 5 → none
            tool("Skill", ["skill": "code-review"]),               // 6 → .skill
            tool("AskUserQuestion", ["questions": [["question": "Pick?", "header": "H", "options": []]]]), // 7 → .question
        ]
        let m = timelineMarkers(events)
        try expectEqual(m.count, 5, "only 5 notable markers")
        try expectEqual(m[0], TimelineMarker(index: 0, kind: .user, label: "hello there this is my message"), "user marker")
        try expectEqual(m[1], TimelineMarker(index: 2, kind: .task, label: "Task 1: alpha"), "task marker")
        try expectEqual(m[2].kind, .subagent, "subagent kind")
        try expectEqual(m[2].index, 4, "subagent index")
        try expectEqual(m[3].kind, .skill, "skill kind")
        try expectEqual(m[4].kind, .question, "question kind")
        try expectEqual(m[4].label, "Pick?", "question label")
    })

    results.append(check("commandChipLabel: slash command + local wrappers, else nil") {
        let cmd = "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
        try expectEqual(commandChipLabel(cmd), "ran /clear", "slash command chip")
        let cmdArgs = "<command-name>/loop</command-name><command-args>5m /foo</command-args>"
        try expectEqual(commandChipLabel(cmdArgs), "ran /loop 5m /foo", "with args")
        try expectEqual(commandChipLabel("<local-command-caveat>Caveat: ...</local-command-caveat>"), "local command output", "caveat")
        try expect(commandChipLabel("just a normal message") == nil, "normal text → nil")
    })

    results.append(check("rekeyPlugin: basic rekey, alreadyExists, notFound") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed_plugins_\(UUID().uuidString).json")
        let initial: [String: Any] = [
            "version": 2,
            "plugins": [
                "superpowers@claude-plugins-official": [
                    ["scope": "user", "version": "6.2.0", "installPath": "/tmp/sp"]
                ]
            ]
        ]
        try JSONFile.writeObject(initial, to: tmp)
        try WriteOps.rekeyPlugin(id: "superpowers@claude-plugins-official",
                                 newMarketplace: "obra-superpowers", in: tmp)
        let result = try JSONFile.readObject(tmp)
        let plugins = result["plugins"] as! [String: Any]
        try expect(plugins["superpowers@claude-plugins-official"] == nil, "old key removed")
        try expect(plugins["superpowers@obra-superpowers"] != nil, "new key added")
        // Test alreadyExists: add back the old key, then try to rekey it to existing target
        var state2 = try JSONFile.readObject(tmp)
        var plugins2 = state2["plugins"] as! [String: Any]
        plugins2["superpowers@claude-plugins-official"] = plugins2["superpowers@obra-superpowers"]
        state2["plugins"] = plugins2
        try JSONFile.writeObject(state2, to: tmp)
        // Now we have both keys; trying to rekey old→new should throw alreadyExists
        do {
            try WriteOps.rekeyPlugin(id: "superpowers@claude-plugins-official",
                                     newMarketplace: "obra-superpowers", in: tmp)
            throw CheckFailure(message: "should have thrown alreadyExists")
        } catch is WriteOps.RekeyError { }
        // notFound throws
        do {
            try WriteOps.rekeyPlugin(id: "missing@mkt", newMarketplace: "x", in: tmp)
            throw CheckFailure(message: "should have thrown notFound")
        } catch is WriteOps.RekeyError { }
        try? FileManager.default.removeItem(at: tmp)
    })

    results.append(check("sessionStats aggregates tokens, models, messages, tools") {
        let events: [SessionEvent] = [
            .userMessage([.text("hello")]),
            .assistantText("hi"),
            .turnUsage(TurnUsage(inputTokens: 12, outputTokens: 1388, cacheReadTokens: 82247, cacheWriteTokens: 12642, model: "claude-opus-4-8")),
            .tool(ToolInvocation(id: "1", name: "Bash", toolClass: .builtin, argSummary: "x", input: [:], resultText: "ok", isError: false)),
            .userMessage([.text("again")]),
            .turnUsage(TurnUsage(inputTokens: 211, outputTokens: 22, cacheReadTokens: 0, cacheWriteTokens: 0, model: "claude-4-5-haiku")),
        ]
        let s = sessionStats(events)
        try expectEqual(s.input, 223, "total input")
        try expectEqual(s.output, 1410, "total output")
        try expectEqual(s.cacheRead, 82247, "cache read")
        try expectEqual(s.total, 223 + 1410 + 82247 + 12642, "grand total")
        try expectEqual(s.userMessages, 2, "user messages")
        try expectEqual(s.assistantMessages, 2, "assistant messages = turnUsage count")
        try expectEqual(s.toolCalls, 1, "tool calls")
        try expectEqual(s.perModel.count, 2, "two models")
        try expectEqual(s.perModel[0].model, "claude-opus-4-8", "opus first (most tokens)")
        try expectEqual(s.perModel[0].messages, 1, "opus msg count")
    })

    results.append(check("responseUsageSummaries collapses consecutive turnUsage per response") {
        let events: [SessionEvent] = [
            .userMessage([.text("q1")]),
            .turnUsage(TurnUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 100, cacheWriteTokens: 0, model: "claude-opus-4-8")),
            .tool(ToolInvocation(id: "1", name: "Bash", toolClass: .builtin, argSummary: "x", input: [:], resultText: "ok", isError: false)),
            .turnUsage(TurnUsage(inputTokens: 2, outputTokens: 7, cacheReadTokens: 200, cacheWriteTokens: 3, model: "claude-opus-4-8")),
            .userMessage([.text("q2")]),
            .turnUsage(TurnUsage(inputTokens: 1, outputTokens: 4, cacheReadTokens: 50, cacheWriteTokens: 0, model: "claude-sonnet-4-6")),
        ]
        let m = responseUsageSummaries(events)
        try expectEqual(m.count, 2, "two responses")
        // response 1 ends at index 3 (second turnUsage), summed
        let r1 = m[3]
        try expect(r1 != nil, "summary at index 3")
        try expectEqual(r1!.inputTokens, 12, "summed input 10+2")
        try expectEqual(r1!.outputTokens, 12, "summed output 5+7")
        try expectEqual(r1!.cacheReadTokens, 300, "summed cache read")
        // response 2 ends at index 5
        try expect(m[5] != nil, "summary at index 5")
        try expectEqual(m[5]!.outputTokens, 4, "second response output")
        // no summary at index 1 (mid-response)
        try expect(m[1] == nil, "no line mid-response")
    })

    return results
}
