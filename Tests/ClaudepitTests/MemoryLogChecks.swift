import Foundation
@testable import ClaudepitCore

func memoryLogChecks() -> [Bool] {
    var results: [Bool] = []

    // A mixed array: one legacy thin entry + one new rich entry + a dream.
    let json = """
    [
      {"type": "write", "file": "hooks.md", "sessionId": "s1", "ts": 100, "note": "legacy note"},
      {"type": "write", "sessionId": "s2", "ts": 200, "title": "Rework worktree state",
       "summary": "Split the section", "changes": [
         {"action": "create", "file": "worktrees.md"},
         {"action": "update", "file": "MEMORY.md"},
         {"action": "delete", "file": "old.md"}]},
      {"type": "dream", "sessionId": "s3", "ts": 300, "title": "Consolidation",
       "changes": [{"action": "delete", "file": "merged-away.md"}]}
    ]
    """
    let entries = try! JSONDecoder().decode([MemoryLogEntry].self, from: Data(json.utf8))

    results.append(check("decodes both legacy and new entry shapes") {
        try expectEqual(entries.count, 3, "three entries")
    })

    results.append(check("legacy entry normalizes file→update, note→summary") {
        let e = entries[0]
        try expectEqual(e.displayChanges.count, 1, "one change")
        try expectEqual(e.displayChanges[0].action, .update, "legacy file is an update")
        try expectEqual(e.displayChanges[0].file, "hooks.md", "file preserved")
        try expectEqual(e.displayTitle, "hooks.md", "title falls back to file")
        try expectEqual(e.displaySummary, "legacy note", "summary falls back to note")
    })

    results.append(check("new entry keeps title/summary and all changes") {
        let e = entries[1]
        try expectEqual(e.displayTitle, "Rework worktree state", "title")
        try expectEqual(e.displaySummary, "Split the section", "summary")
        try expectEqual(e.displayChanges.count, 3, "three changes")
        try expectEqual(e.displayChanges.filter { $0.action == .create }.count, 1, "one create")
        try expectEqual(e.displayChanges.filter { $0.action == .delete }.count, 1, "one delete")
    })

    results.append(check("dream entry with no summary falls back to nil, keeps changes") {
        let e = entries[2]
        try expectEqual(e.type, .dream, "dream kind")
        try expect(e.displaySummary == nil, "no summary")
        try expectEqual(e.displayChanges.count, 1, "one change")
        try expectEqual(e.displayChanges[0].action, .delete, "delete")
    })

    results.append(check("load returns [] when file missing") {
        try expectEqual(MemoryLog.load(projectSlug: "-no-such-project-\(UUID().uuidString)").count, 0, "empty")
    })

    return results
}
