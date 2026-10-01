import Foundation
@testable import ClaudepitCore

private func wt(_ name: String, branch: String? = nil, locked: Bool = false, lockReason: String = "",
                dirty: Int = 0, tracked: Int = 0, ahead: Int = 0, behind: Int = 0, base: String = "",
                merging: Bool = false, conflicted: [String] = [],
                owner: String? = nil, active: Bool = false) -> WorktreeInfo {
    WorktreeInfo(name: name, path: "/r/.claude/worktrees/\(name)", branch: branch ?? name, head: "abc1234",
                 isLocked: locked, lockReason: lockReason, dirtyCount: dirty, aheadCount: ahead,
                 behindCount: behind, trackedDirtyCount: tracked,
                 baseBranch: base, baseRef: base.isEmpty ? "" : "origin/\(base)",
                 mergeInProgress: merging, conflictedFiles: conflicted,
                 ownerSessionID: owner, isActive: active)
}

/// A pid no process can have (above any `kern.pidmax`), so a lock naming it is provably stale.
private let deadPID = 99_999_999

func worktreeListingChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("activity: running, open in herdr, held by a live lock, idle, no session") {
        try expectEqual(WorktreeListing.activity(of: wt("a", owner: "s", active: true)), .running, "active session")
        try expectEqual(WorktreeListing.activity(of: wt("a", owner: "s"), liveAgent: "task-1-implement"),
                        .open(agent: "task-1-implement"), "herdr agent in the checkout")
        let held = wt("a", locked: true, lockReason: "claude agent (pid \(getpid()))")
        try expectEqual(WorktreeListing.activity(of: held), .open(agent: nil), "a live pid holds the lock")
        // Locked with no pid: can't be proven stale, but nothing is known to hold it either.
        try expectEqual(WorktreeListing.activity(of: wt("a", locked: true, owner: "s")), .idle, "pid-less lock")
        try expectEqual(WorktreeListing.activity(of: wt("a", owner: "s")), .idle, "owner, nothing live")
        try expectEqual(WorktreeListing.activity(of: wt("a")), .noSession, "no owner")
        try expectEqual(WorktreeActivity.open(agent: nil).label, "In use", "lock label")
        try expectEqual(WorktreeActivity.open(agent: "x").label, "Open in herdr", "agent label")
    })

    results.append(check("group: a merge or a stale lock needs attention before anything else") {
        try expectEqual(WorktreeListing.group(of: wt("m", merging: true, owner: "s", active: true)), .attention,
                        "a merge wins over running")
        try expectEqual(WorktreeListing.group(of: wt("l", locked: true, lockReason: "pid \(deadPID)")), .attention,
                        "stale lock")
        try expectEqual(WorktreeListing.group(of: wt("r", owner: "s", active: true)), .live, "running")
        try expectEqual(WorktreeListing.group(of: wt("o", owner: "s"), liveAgent: "agent"), .live, "open agent")
        try expectEqual(WorktreeListing.group(of: wt("d", dirty: 5, tracked: 5, owner: "s")), .idle,
                        "uncommitted changes alone are not attention")
        try expectEqual(WorktreeListing.attentionReason(wt("m", merging: true, conflicted: ["a", "b"])),
                        "Merge conflict in 2 files", "conflict reason")
        try expectEqual(WorktreeListing.attentionReason(wt("m", merging: true)), "Merge ready to commit",
                        "staged resolutions, merge still open")
        try expectEqual(WorktreeListing.attentionReason(wt("c")), nil, "nothing to say")
    })

    results.append(check("sections: groups in order, empty ones dropped, scan order kept, search filters") {
        let list = [wt("idle-1", owner: "s1"), wt("run", owner: "s2", active: true), wt("idle-2"),
                     wt("merge", merging: true)]
        let sections = WorktreeListing.sections(list)
        try expectEqual(sections.map(\.group), [.attention, .live, .idle], "group order")
        try expectEqual(sections.last?.items.map(\.name), ["idle-1", "idle-2"], "scan order within a group")
        let names = ["/r/.claude/worktrees/idle-2": "Fix the login screen"]
        let found = WorktreeListing.sections(list, query: "login", taskNames: names)
        try expectEqual(found.flatMap(\.items).map(\.name), ["idle-2"], "search reads the task name")
        try expectEqual(WorktreeListing.sections(list, query: "nothing-matches").count, 0, "no match, no sections")
        try expect(WorktreeListing.matches(wt("x", branch: "feature/auth"), query: "AUTH feature"),
                   "every word, any field, case-insensitive")
    })

    results.append(check("title and facts: the task's name, then only the counts that say something") {
        try expectEqual(WorktreeListing.title(of: wt("task-1-x"), taskName: "Add a button"), "Add a button", "task name")
        try expectEqual(WorktreeListing.title(of: wt("feature-auth"), taskName: nil), "feature-auth", "folder name")
        try expectEqual(WorktreeListing.title(of: wt("feature-auth"), taskName: ""), "feature-auth", "empty name")
        try expectEqual(WorktreeListing.facts(of: wt("c", base: "main")), [], "clean and current says nothing")
        try expectEqual(WorktreeListing.facts(of: wt("d", dirty: 1, ahead: 2, behind: 3, base: "main")),
                        ["1 change", "3 behind main", "2 ahead"], "counts, most actionable first")
        try expectEqual(WorktreeListing.facts(of: wt("n", behind: 3)), [], "no base: no behind count")
        try expectEqual(WorktreeListing.facts(of: wt("m", dirty: 2, merging: true, conflicted: ["a"])),
                        ["Merge conflict in 1 file", "2 changes"], "attention leads")
    })

    results.append(check("tasks in a worktree: the creating task first, its fix tasks after") {
        let path = "/r/.claude/worktrees/task-1-x"
        let parent = ProjectTask(id: "p1", name: "Parent", worktree: TaskWorktree(branch: "b", path: path))
        let fix = ProjectTask(id: "f1", name: "Fix", worktree: TaskWorktree(branch: "b", path: path),
                              followUp: TaskFollowUp(parentTaskID: "p1", findingIDs: []))
        let other = ProjectTask(id: "o1", name: "Other", worktree: TaskWorktree(branch: "c", path: "/elsewhere"))
        try expectEqual(WorktreeListing.tasks(in: path, from: [fix, other, parent]).map(\.id), ["p1", "f1"], "order")
        let names = WorktreeListing.taskNames([wt("task-1-x")], tasks: [fix, parent])
        try expectEqual(names[path], "Parent", "the worktree is named by its creator")
    })

    results.append(check("neighbour: the row below takes a removed worktree's place, else the one above") {
        try expectEqual(WorktreeListing.neighbour(of: "b", in: ["a", "b", "c"]), "c", "below")
        try expectEqual(WorktreeListing.neighbour(of: "c", in: ["a", "b", "c"]), "b", "last → above")
        try expectEqual(WorktreeListing.neighbour(of: "a", in: ["a"]), nil, "only one")
    })

    results.append(check("dominant mention: a clear winner among candidates; a tie names no one") {
        let c: Set = ["/w/a", "/w/b"]
        try expectEqual(WorktreeScanner.dominant(["/w/a": 6, "/w/b": 2, "/w/z": 99], among: c), "/w/a", "winner")
        try expectEqual(WorktreeScanner.dominant(["/w/a": 2, "/w/b": 2], among: c), nil, "tie")
        try expectEqual(WorktreeScanner.dominant(["/w/z": 4], among: c), nil, "only non-candidates")
    })

    results.append(check("mention counts: names end at the path component; overlapping names count apart") {
        var counts: [String: Int] = [:]
        let text = #"{"cwd":"/r/.claude/worktrees/task-a/Sources","x":"see /r/.claude/worktrees/task-ab."}"#
            + "\n" + #"cd /r/.claude/worktrees/task-a && ls /r/.claude/worktrees/"# + "\n"
        WorktreeScanner.MentionCache.count(Data(text.utf8), prefix: "/r/.claude/worktrees/", into: &counts)
        try expectEqual(counts, ["/r/.claude/worktrees/task-a": 2, "/r/.claude/worktrees/task-ab": 1], "counts")
    })

    results.append(check("mention cache: reads only what was appended, waits for a whole line, recounts a shorter file") {
        let dir = try tempDir()
        let file = dir.appending(path: "s.jsonl")
        let prefix = "/r/.claude/worktrees/"
        let cache = WorktreeScanner.MentionCache()
        func stat() throws -> (Int, Date) {
            let a = try FileManager.default.attributesOfItem(atPath: file.path)
            return ((a[.size] as? Int) ?? 0, (a[.modificationDate] as? Date) ?? .distantPast)
        }
        func counts() throws -> [String: Int] {
            let (size, date) = try stat()
            return cache.counts(in: file, size: size, modified: date, prefix: prefix)
        }
        func append(_ s: String) throws {
            let h = try FileHandle(forWritingTo: file); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data(s.utf8))
        }
        try Data("{\"cwd\":\"/r/.claude/worktrees/a\"}\n".utf8).write(to: file)
        try expectEqual(try counts()["/r/.claude/worktrees/a"], 1, "first read")
        try append("{\"cwd\":\"/r/.claude/worktrees/a")          // half-written line
        try expectEqual(try counts()["/r/.claude/worktrees/a"], 1, "a half-written line is not counted yet")
        try append("\"}\n")
        try expectEqual(try counts()["/r/.claude/worktrees/a"], 2, "…and is counted once it is whole")
        try Data("{\"cwd\":\"/r/.claude/worktrees/b\"}\n".utf8).write(to: file)   // rewritten shorter
        let after = try counts()
        try expectEqual(after["/r/.claude/worktrees/a"], nil, "a shorter file is recounted from the start")
        try expectEqual(after["/r/.claude/worktrees/b"], 1, "…with its new content")
        cache.prune(inFolder: dir.path, keeping: [])
        try FileManager.default.removeItem(at: dir)
    })

    results.append(check("Source Control selection follows a file into the other list, and lets go of a gone one") {
        let unstagedA = ChangeSelection(path: "a", staged: false, untracked: false)
        try expectEqual(ChangeSelection.follow(unstagedA, staged: [], unstaged: ["a", "b"]), unstagedA, "stays")
        try expectEqual(ChangeSelection.follow(unstagedA, staged: ["a"], unstaged: ["b"])?.staged, true,
                        "just staged: follows it into Staged")
        let stagedA = ChangeSelection(path: "a", staged: true, untracked: false)
        try expectEqual(ChangeSelection.follow(stagedA, staged: ["a"], unstaged: ["a"]), stagedA,
                        "partly staged: stays in the list it was picked in")
        try expectEqual(ChangeSelection.follow(stagedA, staged: [], unstaged: ["a"])?.staged, false, "just unstaged")
        try expectEqual(ChangeSelection.follow(stagedA, staged: [], unstaged: []), nil, "committed")
        try expectEqual(ChangeSelection.follow(nil, staged: ["a"], unstaged: []), nil, "nothing selected")
    })

    return results
}
