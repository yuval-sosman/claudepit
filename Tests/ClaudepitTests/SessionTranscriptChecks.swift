import Foundation
@testable import ClaudepitCore

private func toolInvs(_ events: [SessionEvent]) -> [ToolInvocation] {
    events.compactMap { if case .tool(let t) = $0 { return t } else { return nil } }
}

func sessionTranscriptChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("SessionTranscript parses ordered events + matches tool_result") {
        let dir = try copyFixture("transcript")
        let url = dir.appending(path: "full.jsonl")
        var t = SessionTranscript()
        let events = t.parse(data: try Data(contentsOf: url))

        // order: userMessage, assistantText, tool(t1), tool(t2)
        guard case .userMessage(let blocks) = events[0], case .text(let u) = blocks[0] else { throw CheckFailure(message: "e0 not userMessage") }
        try expectEqual(u, "do a thing", "user text")
        guard case .assistantText(let a) = events[1] else { throw CheckFailure(message: "e1 not assistantText") }
        try expectEqual(a, "on it", "assistant text")

        let tools = toolInvs(events)
        try expectEqual(tools.count, 2, "two tools")
        try expectEqual(tools[0].name, "Bash", "first tool bash")
        try expectEqual(tools[0].argSummary, "swift build", "bash summary")
        try expectEqual(tools[0].resultText, "Compiling...", "bash result matched")
        try expectEqual(tools[0].isError, false, "bash not error")
        // second tool has no result yet (pending)
        try expect(tools[1].resultText == nil, "t2 pending result")
    })

    results.append(check("SessionTranscript incremental parse appends only new events") {
        let full = """
        {"type":"user","message":{"role":"user","content":"a"},"timestamp":"t"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"b"}]},"timestamp":"t"}

        """
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        // feed first line + partial second line, then the rest
        let firstChunk = lines[0] + "\n" + lines[1].prefix(20)   // partial second line
        var t = SessionTranscript()
        let e1 = t.parse(data: Data(firstChunk.utf8))
        try expectEqual(e1.count, 1, "only complete first line parsed")
        // feed remaining bytes of the second line + trailing newline
        let rest = String(lines[1].dropFirst(20)) + "\n"
        let e2 = t.parse(data: Data(rest.utf8))
        try expectEqual(e2.count, 2, "second line now complete")
    })

    results.append(check("SessionTranscript skips malformed lines") {
        let junk = "not json\n{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"ok\"}}\n"
        var t = SessionTranscript()
        let e = t.parse(data: Data(junk.utf8))
        try expectEqual(e.count, 1, "malformed line skipped, valid kept")
    })

    results.append(check("SessionTranscript preserves multibyte char split across chunks") {
        // A user line containing "🎉" (F0 9F 8E 89), fed split mid-emoji.
        let line = #"{"type":"user","message":{"role":"user","content":"hi 🎉"}}"# + "\n"
        let bytes = Array(line.utf8)
        // find a split point in the middle of the emoji's 4 bytes
        let emoji = Array("🎉".utf8)          // 4 bytes
        let start = bytes.firstIndex(of: emoji[0])!
        let splitAt = start + 2                 // mid-codepoint
        var t = SessionTranscript()
        let e1 = t.parse(data: Data(bytes[0..<splitAt]))
        try expect(e1.isEmpty, "no event until newline arrives")
        let e2 = t.parse(data: Data(bytes[splitAt...]))
        try expectEqual(e2.count, 1, "one event after full line")
        guard case .userMessage(let blocks2) = e2[0], case .text(let txt) = blocks2[0] else { throw CheckFailure(message: "not userMessage") }
        try expectEqual(txt, "hi 🎉", "emoji intact across chunk boundary")
    })

    results.append(check("SessionTranscript emits turnUsage from assistant usage, skips synthetic") {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":12,"output_tokens":1388,"cache_read_input_tokens":82247,"cache_creation_input_tokens":12642}},"timestamp":"t"}
        {"type":"assistant","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"output_tokens":1}},"timestamp":"t"}

        """
        var t = SessionTranscript()
        let e = t.parse(data: Data(jsonl.utf8))
        let usages = e.compactMap { if case .turnUsage(let u) = $0 { return u } else { return nil } }
        try expectEqual(usages.count, 1, "one turnUsage (synthetic skipped)")
        try expectEqual(usages[0].inputTokens, 12, "input")
        try expectEqual(usages[0].outputTokens, 1388, "output")
        try expectEqual(usages[0].cacheReadTokens, 82247, "cache read")
        try expectEqual(usages[0].cacheWriteTokens, 12642, "cache write")
        try expectEqual(usages[0].model, "claude-opus-4-8", "model")
    })

    return results
}
