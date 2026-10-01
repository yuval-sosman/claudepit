import Foundation
@testable import ClaudepitCore

func markdownDocChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("plan title is the first # heading, outside fences and frontmatter") {
        let md = """
        ---
        title: not this
        ---
        ```
        # not a heading inside a fence
        ```
        ## Context first
        # **One-click** merge from `base` ##
        """
        try expectEqual(MarkdownOutline.title(of: md), "One-click merge from base", "h1 wins, markup stripped")
        try expectEqual(MarkdownOutline.title(of: "intro\n\n## Only an h2\n"), "Only an h2", "falls back to any level")
        try expectEqual(MarkdownOutline.title(of: "#hashtag is not a heading\nplain"), nil, "needs a space after #")
    })

    results.append(check("a plan without a heading is titled by its slug") {
        let doc = MarkdownDoc(url: URL(filePath: "/p/glowing-crafting-pike.md"), text: "just notes", modifiedAt: Date())
        try expectEqual(doc.title, "Glowing crafting pike", "humanized slug")
        try expectEqual(doc.tag, "glowing-crafting-pike", "slug kept as the tag")
    })

    results.append(check("summary is the first prose paragraph, flattened") {
        let md = """
        # Title

        ## Context
        The **Plans** page lists `slug` names
        that nobody recognises — see [the doc](./x.md).

        Second paragraph.
        """
        try expectEqual(MarkdownOutline.summary(of: md),
                        "The Plans page lists slug names that nobody recognises — see the doc.", "paragraph")
        try expectEqual(MarkdownOutline.summary(of: "# T\n\n**Goal:** Ship it.\n"), "Goal: Ship it.", "bold label")
        try expectEqual(MarkdownOutline.summary(of: "# T\n\n- [ ] first task\n- second\n"), "first task", "first list item")
        try expectEqual(MarkdownOutline.summary(of: "# T\n\n| a | b |\n|---|---|\n\n---\n"), nil, "tables and rules are not prose")
    })

    results.append(check("summary is capped at a word boundary") {
        let long = "# T\n\n" + Array(repeating: "word", count: 100).joined(separator: " ")
        let s = try unwrap(MarkdownOutline.summary(of: long, limit: 30))
        try expect(s.hasSuffix("…") && s.count <= 31, "capped with ellipsis: \(s)")
        try expect(!s.dropLast().hasSuffix(" "), "no trailing space")
    })

    results.append(check("plan search needs every word, in title, slug or text") {
        let doc = MarkdownDoc(url: URL(filePath: "/p/wondrous-meandering-conway.md"),
                          text: "# Cache simulation\n\nCompare 5-minute and 1-hour writes in herdr panes.",
                          modifiedAt: Date())
        try expect(doc.matches(""), "empty matches")
        try expect(doc.matches("cache HERDR"), "title + body, case-insensitive")
        try expect(doc.matches("conway"), "slug")
        try expect(!doc.matches("cache payments"), "every word required")
    })

    results.append(check("snippet shows the match the row doesn't already show") {
        let text = "# Cache simulation\n\nA long preamble about nothing in particular. Then the herdr pane opens."
        let snip = try unwrap(SearchText.snippet(in: text, query: "cache herdr", visible: ["Cache simulation"], radius: 12))
        try expect(snip.contains("herdr"), "excerpt around the hidden word: \(snip)")
        try expect(snip.hasPrefix("…"), "marks the cut")
        try expect(snip.dropFirst().first.map { $0.isUppercase || $0.isLowercase } == true
                   && text.contains(" " + snip.dropFirst().prefix(4)), "starts on a whole word: \(snip)")
        try expectEqual(SearchText.snippet(in: text, query: "cache", visible: ["Cache simulation"]), nil,
                        "nothing to add when the title shows it")
    })

    results.append(check("loader lists newest first and re-reads only changed files") {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "alpha-one.md"), b = dir.appending(path: "beta-two.md")
        try "# Alpha".write(to: a, atomically: true, encoding: .utf8)
        try "# Beta".write(to: b, atomically: true, encoding: .utf8)
        try "not a plan".write(to: dir.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: a.path)
        let loader = MarkdownDocLoader()
        try expectEqual(loader.loadPlans(dir: dir).map(\.title), ["Beta", "Alpha"], "newest first, .md only")

        try "# Alpha, renamed".write(to: a, atomically: true, encoding: .utf8)
        try expectEqual(loader.loadPlans(dir: dir).first?.title, "Alpha, renamed", "a changed file is re-read")
        try FileManager.default.removeItem(at: b)
        try expectEqual(loader.loadPlans(dir: dir).map(\.tag), ["alpha-one"], "a removed file drops out")
    })

    results.append(check("a spec's byline is not its summary") {
        let spec = "# Spec — Close the pane\n\nTask `56cf65b6` · topic `tasks` · 2026-09-13\n\n## Overview\n\nEach phase owns one pane.\n"
        try expectEqual(MarkdownOutline.summary(of: spec), "Each phase owns one pane.", "byline skipped")
        try expectEqual(MarkdownOutline.summary(of: "# T\n\nA · B\n"), nil, "a document that is only a byline has none")
        try expectEqual(MarkdownOutline.summary(of: "# T\n\nFirst real line.\n\nA · B\n"), "First real line.",
                        "only an opening byline is skipped")
    })

    results.append(check("specs load from task folders, named by their task") {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["aaa11111", "bbb22222", "ccc33333"] {
            try FileManager.default.createDirectory(at: root.appending(path: id), withIntermediateDirectories: true)
        }
        try "# Spec — Alpha\n\nTask `aaa11111` · 2026-09-13\n\nWhat alpha does.".write(
            to: root.appending(path: "aaa11111/spec.md"), atomically: true, encoding: .utf8)
        try "# Spec — Orphan".write(to: root.appending(path: "bbb22222/spec.md"), atomically: true, encoding: .utf8)
        let loader = MarkdownDocLoader()
        var specs = loader.loadSpecs(tasksRoot: root, taskNames: ["aaa11111": "Alpha task"])
        let byTag = Dictionary(uniqueKeysWithValues: specs.map { ($0.tag, $0) })
        try expectEqual(Set(byTag.keys), ["aaa11111", "bbb22222"], "a task folder without spec.md is skipped")
        try expectEqual(byTag["aaa11111"]?.title, "Alpha task", "named by its task")
        try expectEqual(byTag["aaa11111"]?.summary, "What alpha does.", "summary past the byline")
        try expectEqual(byTag["bbb22222"]?.title, "Spec — Orphan", "an orphaned folder falls back to the heading")
        try expect(byTag["aaa11111"]?.matches("aaa11111") == true, "searchable by task id")
        specs = loader.loadSpecs(tasksRoot: root, taskNames: ["aaa11111": "Alpha, renamed"])
        try expectEqual(specs.first { $0.tag == "aaa11111" }?.title, "Alpha, renamed", "a renamed task renames its spec")
    })

    results.append(check("brainstorm draft: one line, the file attached, ending where the ask goes") {
        let path = "/Users/me/.claude/plans/glowing-crafting-pike.md"
        let draft = DocumentBrainstorm.draft(noun: "plan", path: path)
        // send-text types characters: a newline would press Return and send the draft unfinished.
        try expect(!draft.contains("\n") && !draft.contains("\r"), "single line")
        try expect(draft.contains("@" + path + " "), "attached as an @mention, closed by a space")
        try expect(draft.hasSuffix("My ask: "), "ends where the cursor waits for the ask")
        try expect(DocumentBrainstorm.draft(noun: "spec", path: "/t/a\nb/spec.md").contains("@/t/a b/spec.md"),
                   "a newline in a path is flattened, never typed")
        try expect(draft.contains("this plan"), "names what it is")
    })

    results.append(check("brainstorm agent: one stable name per document that herdr accepts") {
        // herdr 0.8.2 rejects anything else with invalid_agent_name — after the tab is open.
        func valid(_ n: String) -> Bool {
            n.count <= 32 && n.first.map { $0.isASCII && $0.isLowercase } == true
                && n.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" || $0 == "_" }
        }
        try expectEqual(DocumentBrainstorm.agentName(noun: "spec", tag: "56cf65b6"), "brainstorm-spec-56cf65b6",
                        "a name that fits is kept as is")
        let long = "2026-09-13-close-previous-phase-herdr-pane"
        let a = DocumentBrainstorm.agentName(noun: "plan", tag: long)
        let b = DocumentBrainstorm.agentName(noun: "plan", tag: long + "-v2")
        try expect(valid(a) && valid(b), "long slugs fit: \(a), \(b)")
        try expect(a != b, "two long slugs sharing a prefix stay distinct")
        try expectEqual(DocumentBrainstorm.agentName(noun: "plan", tag: long), a, "stable — a second click finds the agent")
        try expect(a.hasPrefix("brainstorm-plan-"), "still readable")
        for raw in ["My Plan.v2", "ÉLAN café", "9lives", "", "memory-fix-My Very Long Project Folder Name"] {
            try expect(valid(Herdr.agentName(raw)), "valid for “\(raw)”: \(Herdr.agentName(raw))")
        }
        try expectEqual(Herdr.agentName("task-56cf65b6-merge"), "task-56cf65b6-merge", "task agent names unchanged")
    })

    results.append(check("date sections are shared: plans group like sessions") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US")
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15))!
        let dates = [0.1, 0.2, 1, 45].map { now.addingTimeInterval(-$0 * 86_400) }
        let sections = DateSections.group(Array(dates.enumerated()), date: \.element, now: now, calendar: cal)
        try expectEqual(sections.map(\.title), ["Today", "Yesterday", "August"], "titles")
        try expectEqual(sections.map { $0.items.map(\.offset) }, [[0, 1], [2], [3]], "members, newest first")
    })

    return results
}

private func unwrap<T>(_ value: T?, _ label: String = "value") throws -> T {
    guard let value else { throw CheckFailure(message: "\(label) was nil") }
    return value
}
