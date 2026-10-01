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
        try expectEqual(blocks[2], .list([.bullet("a"), .bullet("b")]), "bullets")
        try expectEqual(blocks[3], .list([.number(1, "one"), .number(2, "two")]), "ordered: a new list")
    })

    results.append(check("parseMarkdownBlocks: nested lists keep their numbers, tasks, continuations, rules") {
        let md = """
        1. **Step one**
           - detail a
           - [x] done thing
        2. Step two
           continues here

        3. Step three
        ---
        after
        """
        let b = parseMarkdownBlocks(md)
        try expectEqual(b[0], .list([
            .number(1, "**Step one**"),
            .bullet("detail a", level: 1),
            MarkdownListItem(level: 1, marker: .task(checked: true), text: "done thing"),
            .number(2, "Step two\ncontinues here"),
            .number(3, "Step three"),
        ]), "one list: sub-bullets nested, numbering kept, a blank line inside the list")
        try expectEqual(b[1], .rule, "rule")
        try expectEqual(b[2], .paragraph("after"), "then text")
        try expectEqual(parseMarkdownBlocks("- - -"), [.rule], "spaced dashes are a rule, not an item")
        try expectEqual(parseMarkdownBlocks("#hashtag")[0], .paragraph("#hashtag"), "no space → not a heading")
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
        try expectEqual(b1[1], .list([.number(1, "one"), .number(2, "two")]), "ordered list separated")

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

    results.append(check("parseTaskListLines: id, status and subject, leniently") {
        let lines = parseTaskListLines("Tasks:\n#1 [completed] Fix bugs\n  #12. [in progress] Ship it\n#3 Write notes\n\nno id here")
        try expectEqual(lines, [
            TaskListLine(id: "1", status: "completed", subject: "Fix bugs"),
            TaskListLine(id: "12", status: "in_progress", subject: "Ship it"),
            TaskListLine(id: "3", status: "pending", subject: "Write notes"),
        ], "three tasks; the heading and the id-less line skipped")
    })

    results.append(check("parseCreatedTaskId extracts numeric id") {
        try expectEqual(parseCreatedTaskId("Task #7 created successfully: Foo"), "7", "id 7")
        try expectEqual(parseCreatedTaskId("Updated task #3 status"), "3", "id 3 from update text")
        try expect(parseCreatedTaskId("no number here") == nil, "no id → nil")
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

    results.append(check("relativeLines / splitExitCode: search roots said once, exit codes pulled out") {
        let r = relativeLines("/a/b/x.swift:3:foo\n/a/b/y.swift:9:bar", to: "/a/b")
        try expectEqual(r.text, "x.swift:3:foo\ny.swift:9:bar", "relative"); try expectEqual(r.root, "/a/b", "root")
        let mixed = relativeLines("/a/b/x\n/c/y\n/c/z", to: "/a/b")
        try expect(mixed.root == nil, "most lines elsewhere → untouched")
        try expect(relativeLines("x", to: nil).root == nil, "no root → untouched")
        let e = splitExitCode("Exit code 127\nbash: nope: command not found")
        try expectEqual(e.code, 127, "code"); try expectEqual(e.output, "bash: nope: command not found", "rest")
        try expect(splitExitCode("fine").code == nil, "no prefix → nil")
    })

    results.append(check("diffLines(patch:) numbers lines from the CLI's structured hunks") {
        let hunks: [[String: Any]] = [
            ["oldStart": 52, "oldLines": 3, "newStart": 52, "newLines": 3,
             "lines": [" keep", "-old line", "+new line", " tail"]],
            ["oldStart": 90, "oldLines": 1, "newStart": 90, "newLines": 2,
             "lines": [" ctx", "+added", "\\ No newline at end of file"]],
        ]
        let lines = diffLines(patch: hunks, path: "/x/File.swift")
        try expectEqual(lines.first, DiffLine(kind: .file, text: "/x/File.swift"), "file header first")
        try expectEqual(lines[1], DiffLine(kind: .context, text: "keep", oldLine: 52, newLine: 52), "context carries both numbers")
        try expectEqual(lines[2], DiffLine(kind: .remove, text: "old line", oldLine: 53), "removal: old number only")
        try expectEqual(lines[3], DiffLine(kind: .add, text: "new line", newLine: 53), "addition: new number only")
        try expectEqual(lines[4], DiffLine(kind: .context, text: "tail", oldLine: 54, newLine: 54), "numbers advance")
        try expectEqual(lines[5].kind, .note, "separator between hunks")
        try expectEqual(lines[6], DiffLine(kind: .context, text: "ctx", oldLine: 90, newLine: 90), "second hunk restarts numbering")
        try expectEqual(lines.count, 8, "no-newline marker dropped")
        let stat = diffStat(lines)
        try expectEqual(stat.added, 2, "two added"); try expectEqual(stat.removed, 1, "one removed")
    })

    return results
}
