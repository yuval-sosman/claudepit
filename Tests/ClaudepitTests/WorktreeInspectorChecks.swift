import Foundation
@testable import ClaudepitCore

/// Bridge an async op into the synchronous check harness.
private func runAsync<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = LockedBox<T>()
    Task { box.set(await op()); sem.signal() }
    sem.wait()
    return box.get()
}

private final class LockedBox<T>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value! }
}

func worktreeInspectorChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("parsePorcelainZ: modified/added/deleted/untracked/renamed") {
        // porcelain -z: "XY <path>\0"; rename emits "R  new\0old\0"
        let raw = " M src/a.swift\0A  src/b.swift\0 D src/c.swift\0?? note.txt\0R  new.swift\0old.swift\0"
        let files = WorktreeInspector.parsePorcelainZ(raw)
        try expectEqual(files.count, 5, "five entries")
        try expectEqual(files[0].change, .modified, "a modified")
        try expectEqual(files[0].path, "src/a.swift", "a path")
        try expectEqual(files[1].change, .added, "b added")
        try expectEqual(files[2].change, .deleted, "c deleted")
        try expectEqual(files[3].change, .untracked, "note untracked")
        try expectEqual(files[4].change, .renamed, "rename kept as renamed")
        try expectEqual(files[4].path, "new.swift", "rename keeps NEW path")
    })

    results.append(check("parsePorcelainZ: empty -> []") {
        try expectEqual(WorktreeInspector.parsePorcelainZ("").count, 0, "empty")
    })

    results.append(check("parseShow: full record") {
        let raw = "a1b2c3d\nJane Dev\n2 hours ago\nfix: the thing\nlonger body line 1\nline 2"
        guard let c = WorktreeInspector.parseShow(raw) else { throw CheckFailure(message: "nil") }
        try expectEqual(c.shortHash, "a1b2c3d", "hash")
        try expectEqual(c.author, "Jane Dev", "author")
        try expectEqual(c.relativeDate, "2 hours ago", "date")
        try expectEqual(c.subject, "fix: the thing", "subject")
        try expectEqual(c.body, "longer body line 1\nline 2", "body joined")
    })

    results.append(check("parseShow: empty body") {
        guard let c = WorktreeInspector.parseShow("a1b2c3d\nJane\n1 day ago\nsubject only\n") else {
            throw CheckFailure(message: "nil")
        }
        try expectEqual(c.body, "", "empty body")
    })

    results.append(check("parseShow: malformed -> nil") {
        try expect(WorktreeInspector.parseShow("only\ntwo") == nil, "too few lines")
    })

    results.append(check("parseLog: NUL fields + empty") {
        let n = "\u{0}"
        let raw = "aaa111\(n)aaa\(n)2 hours ago\(n)subject one\nbbb222\(n)bbb\(n)3 days ago\(n)subject two"
        let cs = WorktreeInspector.parseLog(raw)
        try expectEqual(cs.count, 2, "two")
        try expectEqual(cs[0].fullHash, "aaa111", "full hash 0")
        try expectEqual(cs[0].shortHash, "aaa", "short hash 0")
        try expectEqual(cs[0].relativeDate, "2 hours ago", "date 0")
        try expectEqual(cs[0].subject, "subject one", "subj 0")
        try expectEqual(WorktreeInspector.parseLog("").count, 0, "empty -> []")
    })

    results.append(check("webURL(fromRemote:) handles ssh/https/scheme forms") {
        try expectEqual(WorktreeInspector.webURL(fromRemote: "git@github.com:owner/repo.git"),
                        "https://github.com/owner/repo", "scp-like ssh")
        try expectEqual(WorktreeInspector.webURL(fromRemote: "https://gitlab.com/owner/repo.git"),
                        "https://gitlab.com/owner/repo", "https")
        try expectEqual(WorktreeInspector.webURL(fromRemote: "ssh://git@github.com/owner/repo.git"),
                        "https://github.com/owner/repo", "ssh scheme")
        try expect(WorktreeInspector.webURL(fromRemote: "") == nil, "empty -> nil")
        try expect(WorktreeInspector.webURL(fromRemote: "not-a-url") == nil, "garbage -> nil")
    })

    results.append(check("diffLinesFromUnified: kinds + hunk header dropped") {
        let raw = """
        diff --git a/f.swift b/f.swift
        index 111..222 100644
        --- a/f.swift
        +++ b/f.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        """
        let ls = diffLinesFromUnified(raw, path: "f.swift")
        try expectEqual(ls.first?.kind, .file, "leads with file")
        try expectEqual(ls.first?.text, "f.swift", "file path")
        try expect(ls.contains { $0.kind == .context && $0.text == "let a = 1" }, "context")
        try expect(ls.contains { $0.kind == .remove && $0.text == "let b = 2" }, "remove")
        try expect(ls.contains { $0.kind == .add && $0.text == "let b = 3" }, "add")
        try expect(!ls.contains { $0.text.hasPrefix("diff --git") }, "diff header dropped")
    })

    results.append(check("diffLinesFromUnified: empty -> just file line") {
        let ls = diffLinesFromUnified("", path: "x")
        try expectEqual(ls.count, 1, "only file line")
        try expectEqual(ls[0].kind, .file, "file")
    })

    // Real-repo integration: shape only, skip silently if not a git repo.
    results.append(check("changedFiles/recentCommits run on repo root without crashing") {
        let dir = FileManager.default.currentDirectoryPath
        guard FileManager.default.fileExists(atPath: dir + "/.git") else { return }
        let commits = runAsync { await WorktreeInspector.recentCommits(at: dir) }
        try expect(commits.count >= 0, "no crash")
        _ = runAsync { await WorktreeInspector.changedFiles(at: dir) }
    })

    return results
}
