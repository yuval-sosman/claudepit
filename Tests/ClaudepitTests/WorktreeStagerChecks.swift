import Foundation
@testable import ClaudepitCore

// MARK: - Local helpers (file-private; the other check files declare their own)

private func runStager<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = StagerBox<T>()
    Task { box.set(await op()); sem.signal() }
    sem.wait()
    return box.get()
}

private final class StagerBox<T>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value! }
}

/// git in `dir`; stdout untrimmed (porcelain lines open with a space). `ok: false` tolerated.
@discardableResult
private func g(_ dir: URL, _ args: [String], ok: Bool = true) throws -> String {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = ["git", "-C", dir.path] + args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if ok { try expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed") }
    return String(data: data, encoding: .utf8) ?? ""
}

/// A throwaway repo on main with a.txt ("one\ntwo\nthree\n") and b.txt committed.
private func stagerRepo() throws -> URL {
    let repo = try tempDir()
    try g(repo, ["init", "-q", "-b", "main"])
    try g(repo, ["config", "user.email", "t@t.co"])
    try g(repo, ["config", "user.name", "t"])
    try write(repo, "a.txt", "one\ntwo\nthree\n")
    try write(repo, "b.txt", "bee\n")
    try g(repo, ["add", "."])
    try g(repo, ["commit", "-qm", "init"])
    return repo
}

private func write(_ repo: URL, _ name: String, _ text: String) throws {
    try text.write(to: repo.appending(path: name), atomically: true, encoding: .utf8)
}

private func read(_ repo: URL, _ name: String) -> String? {
    try? String(contentsOf: repo.appending(path: name), encoding: .utf8)
}

/// `git status --porcelain` as a set of "XY path" lines.
private func porcelain(_ repo: URL) throws -> Set<String> {
    Set(try g(repo, ["status", "--porcelain", "--untracked-files=all"]).split(separator: "\n").map(String.init))
}

/// A repo mid-merge: feat and main both changed a.txt's second line; main also changed b.txt
/// cleanly. HEAD is feat; merging main stopped on the conflict.
private func conflictedRepo() throws -> URL {
    let repo = try stagerRepo()
    try g(repo, ["checkout", "-qb", "feat"])
    try write(repo, "a.txt", "one\nTWO-feat\nthree\n")
    try g(repo, ["commit", "-qam", "feat"])
    try g(repo, ["checkout", "-q", "main"])
    try write(repo, "a.txt", "one\nTWO-main\nthree\n")
    try write(repo, "b.txt", "bee from main\n")
    try g(repo, ["commit", "-qam", "main"])
    try g(repo, ["checkout", "-q", "feat"])
    try g(repo, ["merge", "--no-edit", "main"], ok: false)
    return repo
}

func worktreeStagerChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("parseStatusV1: staged/unstaged/both/untracked/rename") {
        // "M " staged-only, " M" unstaged-only, "MM" both, "A " added-staged,
        // " D" deleted-unstaged, "??" untracked, "R  new\0old" rename (staged)
        let raw = "M  a.swift\0 M b.swift\0MM c.swift\0A  d.swift\0 D e.swift\0?? f.txt\0R  new.swift\0old.swift\0"
        let files = WorktreeStager.parseStatusV1(raw)
        try expectEqual(files.count, 7, "seven files")

        func f(_ p: String) throws -> StagedFile {
            guard let x = files.first(where: { $0.path == p }) else { throw CheckFailure(message: "missing \(p)") }
            return x
        }
        let a = try f("a.swift")
        try expect(a.staged && !a.unstaged, "a staged only")
        try expectEqual(a.change, .modified, "a modified")

        let b = try f("b.swift")
        try expect(!b.staged && b.unstaged, "b unstaged only")

        let c = try f("c.swift")
        try expect(c.staged && c.unstaged, "c both")

        let d = try f("d.swift")
        try expect(d.staged, "d staged"); try expectEqual(d.change, .added, "d added")

        let e = try f("e.swift")
        try expect(e.unstaged, "e unstaged"); try expectEqual(e.change, .deleted, "e deleted")

        let ff = try f("f.txt")
        try expect(ff.untracked, "f untracked"); try expectEqual(ff.change, .untracked, "f untracked change")

        let r = try f("new.swift")
        try expectEqual(r.change, .renamed, "rename kept new path"); try expect(r.staged, "rename staged")
    })

    results.append(check("parseStatusV1: empty -> []") {
        try expectEqual(WorktreeStager.parseStatusV1("").count, 0, "empty")
    })

    results.append(check("parseStatusV1: a rename keeps its source path; unmerged pairs are conflicts in neither list") {
        let raw = "R  new.swift\0old.swift\0UU both.swift\0AA added.swift\0DU gone.swift\0UD kept.swift\0M  x.swift\0"
        let files = WorktreeStager.parseStatusV1(raw)
        try expectEqual(files.count, 6, "six files")
        try expectEqual(files[0].origPath, "old.swift", "rename source")
        try expectEqual(files[0].allPaths, ["old.swift", "new.swift"], "a rename acts on both paths")
        try expectEqual(files[1].conflict, .bothModified, "UU")
        try expect(!files[1].staged && !files[1].unstaged, "a conflict is neither staged nor unstaged")
        try expectEqual(files[2].conflict, .bothAdded, "AA")
        try expectEqual(files[3].conflict, .deletedByUs, "DU")
        try expect(files[3].conflict?.isDeletion == true, "DU is a keep-or-delete conflict")
        try expectEqual(files[4].conflict, .deletedByThem, "UD")
        try expectEqual(files[5].path, "x.swift", "the record after the conflicts still parses")
        try expect(files[5].conflict == nil && files[5].origPath == nil, "a plain file has neither")
    })

    results.append(check("parseNumstatZ: plain, rename, binary") {
        let raw = "3\t1\ta.swift\0" + "2\t0\t\0old.swift\0new.swift\0" + "-\t-\timg.png\0"
        let stats = WorktreeStager.parseNumstatZ(raw)
        try expectEqual(stats["a.swift"], LineStat(added: 3, removed: 1), "plain")
        try expectEqual(stats["new.swift"], LineStat(added: 2, removed: 0), "rename keyed by its new path")
        try expect(stats["old.swift"] == nil, "not by its old one")
        try expectEqual(stats["img.png"]?.binary, true, "binary")
        try expectEqual(WorktreeStager.parseNumstatZ("").count, 0, "empty")
    })

    results.append(check("cleanMergeMessage drops git's comment lines") {
        let raw = "Merge branch 'main' into feat\n\n# Conflicts:\n#\ta.txt\n"
        try expectEqual(WorktreeStager.cleanMergeMessage(raw), "Merge branch 'main' into feat", "message")
        try expect(WorktreeStager.cleanMergeMessage("# only comments\n") == nil, "nothing left -> nil")
    })

    results.append(check("chunks splits long path lists and keeps every path") {
        let paths = (0..<1001).map { "f\($0)" }
        let c = WorktreeStager.chunks(paths)
        try expectEqual(c.count, 3, "three chunks")
        try expectEqual(c.flatMap { $0 }, paths, "every path, in order")
        try expectEqual(WorktreeStager.chunks([]).count, 0, "none")
    })

    // MARK: - Against real repos

    results.append(check("status: line counts for staged, unstaged and untracked files") {
        let repo = try stagerRepo()
        try write(repo, "a.txt", "one\nTWO\nthree\nfour\n")
        try g(repo, ["add", "a.txt"])
        try write(repo, "b.txt", "bee\nbuzz\n")
        try FileManager.default.createDirectory(at: repo.appending(path: "dir"), withIntermediateDirectories: true)
        try write(repo, "dir/new.txt", "1\n2\n3")
        let files = runStager { await WorktreeStager.status(at: repo.path) }
        let a = files.first { $0.path == "a.txt" }, b = files.first { $0.path == "b.txt" }
        let n = files.first { $0.path == "dir/new.txt" }
        try expectEqual(a?.stagedStat, LineStat(added: 2, removed: 1), "staged a.txt")
        try expectEqual(b?.unstagedStat, LineStat(added: 1, removed: 0), "unstaged b.txt")
        try expect(n != nil, "an untracked folder lists its file")
        try expectEqual(n?.unstagedStat, LineStat(added: 3, removed: 0), "untracked file's lines (no final newline)")
    })

    results.append(check("Stage Block on an untracked file stages THAT file — not a phantom at its absolute path") {
        let repo = try stagerRepo()
        try write(repo, "u.txt", "new1\nnew2\n")
        let file = StagedFile(path: "u.txt", change: .untracked, staged: false, unstaged: true, untracked: true)
        let raw = runStager { await WorktreeStager.diff(at: repo.path, file: file, staged: false) }
        let parsed = parseHunks(raw)
        try expectEqual(parsed.hunks.count, 1, "one block")
        try expect(!raw.contains(repo.path), "the patch names the file relative to the worktree")
        let patch = buildPatch(fileHeader: parsed.fileHeader, hunk: parsed.hunks[0])
        let r = runStager { await WorktreeStager.applyHunk(at: repo.path, patch: patch, reverse: false, cached: true) }
        try expect(r.ok, "git apply --cached: \(r.message)")
        try expectEqual(try porcelain(repo), ["A  u.txt"], "u.txt staged, nothing else in the index")
    })

    results.append(check("Discard on a staged row restores the file to HEAD (it used to do nothing)") {
        let repo = try stagerRepo()
        try write(repo, "a.txt", "changed\n")
        try g(repo, ["add", "a.txt"])
        try write(repo, "a.txt", "changed again\n")   // partly staged too
        let a = StagedFile(path: "a.txt", change: .modified, staged: true, unstaged: true, untracked: false)
        let r = runStager { await WorktreeStager.discardAllChanges(at: repo.path, file: a, toTrash: false) }
        try expect(r.ok, r.message)
        try expectEqual(read(repo, "a.txt"), "one\ntwo\nthree\n", "back to HEAD")
        try expectEqual(try porcelain(repo), [], "clean")
    })

    results.append(check("Discard on a staged added file unstages it and removes it") {
        let repo = try stagerRepo()
        try write(repo, "n.txt", "n\n")
        try g(repo, ["add", "n.txt"])
        let n = StagedFile(path: "n.txt", change: .added, staged: true, unstaged: false, untracked: false)
        let r = runStager { await WorktreeStager.discardAllChanges(at: repo.path, file: n, toTrash: false) }
        try expect(r.ok, r.message)
        try expect(read(repo, "n.txt") == nil, "gone from disk")
        try expectEqual(try porcelain(repo), [], "and from the index")
    })

    results.append(check("A rename: unstage and discard act on both paths") {
        let repo = try stagerRepo()
        try g(repo, ["mv", "b.txt", "c.txt"])
        let files = runStager { await WorktreeStager.status(at: repo.path) }
        guard let c = files.first(where: { $0.path == "c.txt" }) else { throw CheckFailure(message: "no rename row") }
        try expectEqual(c.origPath, "b.txt", "status carries the source")
        let u = runStager { await WorktreeStager.unstageFiles(at: repo.path, [c]) }
        try expect(u.ok, u.message)
        try expectEqual(try porcelain(repo), [" D b.txt", "?? c.txt"], "nothing left staged — not even b.txt's deletion")

        try g(repo, ["add", "-A"])
        let again = runStager { await WorktreeStager.status(at: repo.path) }
        guard let c2 = again.first(where: { $0.path == "c.txt" }) else { throw CheckFailure(message: "no rename row") }
        let d = runStager { await WorktreeStager.discardAllChanges(at: repo.path, file: c2, toTrash: false) }
        try expect(d.ok, d.message)
        try expectEqual(try porcelain(repo), [], "un-renamed")
        try expectEqual(read(repo, "b.txt"), "bee\n", "b.txt back")
    })

    results.append(check("Unstage Block on a renamed, edited file keeps the rename") {
        let repo = try stagerRepo()
        try g(repo, ["mv", "a.txt", "z.txt"])
        try write(repo, "z.txt", "one\ntwo\nthree\nfour\n")
        try g(repo, ["add", "-A"])
        let files = runStager { await WorktreeStager.status(at: repo.path) }
        guard let z = files.first(where: { $0.path == "z.txt" }) else { throw CheckFailure(message: "no rename row") }
        let raw = runStager { await WorktreeStager.diff(at: repo.path, file: z, staged: true) }
        try expect(raw.contains("rename from a.txt"), "diffed as a rename, not a new file")
        let parsed = parseHunks(raw)
        try expectEqual(parsed.hunks.count, 1, "one edit block")
        let patch = buildPatch(fileHeader: parsed.fileHeader, hunk: parsed.hunks[0])
        let r = runStager { await WorktreeStager.applyHunk(at: repo.path, patch: patch, reverse: true, cached: true) }
        try expect(r.ok, "git apply -R --cached: \(r.message)")
        try expectEqual(try porcelain(repo), ["RM a.txt -> z.txt"], "still renamed; the edit is unstaged")
    })

    results.append(check("stageFiles / discardFiles: deletions, untracked files, several at once") {
        let repo = try stagerRepo()
        try FileManager.default.removeItem(at: repo.appending(path: "b.txt"))
        try write(repo, "u.txt", "u\n")
        try write(repo, "a.txt", "edited\n")
        let files = runStager { await WorktreeStager.status(at: repo.path) }
        let s = runStager { await WorktreeStager.stageFiles(at: repo.path, files) }
        try expect(s.ok, s.message)
        try expectEqual(try porcelain(repo), ["M  a.txt", "D  b.txt", "A  u.txt"], "all staged")
        try g(repo, ["reset", "-q"])
        let again = runStager { await WorktreeStager.status(at: repo.path) }
        let d = runStager { await WorktreeStager.discardFiles(at: repo.path, again, toTrash: false) }
        try expect(d.ok, d.message)
        try expectEqual(try porcelain(repo), [], "all discarded")
    })

    results.append(check("A failed batch reports git's error instead of swallowing it") {
        let repo = try stagerRepo()
        let ghost = StagedFile(path: "no-such-file", change: .modified, staged: false, unstaged: true, untracked: false)
        let r = runStager { await WorktreeStager.discardFiles(at: repo.path, [ghost], toTrash: false) }
        try expect(!r.ok && !r.message.isEmpty, "failure with a message")
    })

    results.append(check("Merge conflict: status, context, resolve a block, mark resolved, commit") {
        let repo = try conflictedRepo()
        let files = runStager { await WorktreeStager.status(at: repo.path) }
        guard let a = files.first(where: { $0.path == "a.txt" }) else { throw CheckFailure(message: "no a.txt") }
        try expectEqual(a.conflict, .bothModified, "a.txt conflicted")
        try expect(files.first { $0.path == "b.txt" }?.staged == true, "the clean merge of b.txt is staged")
        let ctx = runStager { await WorktreeStager.context(at: repo.path) }
        try expectEqual(ctx.branch, "feat", "branch")
        try expect(ctx.merging, "merging")
        try expectEqual(ctx.mergeMessage, "Merge branch 'main' into feat", "git's prepared message, comments dropped")

        let url = repo.appending(path: "a.txt")
        guard let doc = ConflictFileIO.load(url), let block = doc.conflicts.first else { throw CheckFailure(message: "no conflict parsed") }
        try expectEqual(block.current, ["TWO-feat"], "current side")
        try expectEqual(block.incoming, ["TWO-main"], "incoming side")
        if case .failure(let f) = ConflictFileIO.resolve(url, index: 0, expected: block, .incoming) { throw CheckFailure(message: "\(f)") }
        try expectEqual(read(repo, "a.txt"), "one\nTWO-main\nthree\n", "resolved to incoming, rest untouched")
        let m = runStager { await WorktreeStager.markResolved(at: repo.path, [a]) }
        try expect(m.ok, m.message)
        let after = runStager { await WorktreeStager.status(at: repo.path) }
        try expect(after.allSatisfy { $0.conflict == nil }, "no conflicts left")
        let c = runStager { await WorktreeStager.commit(at: repo.path, message: ctx.mergeMessage ?? "merge") }
        try expect(c.ok, c.message)
        let done = runStager { await WorktreeStager.context(at: repo.path) }
        try expect(!done.merging, "merge finished")
    })

    results.append(check("A stale conflict view never overwrites the file") {
        let repo = try conflictedRepo()
        let url = repo.appending(path: "a.txt")
        guard let block = ConflictFileIO.load(url)?.conflicts.first else { throw CheckFailure(message: "no conflict") }
        try write(repo, "a.txt", "someone resolved it by hand\n")
        let r = ConflictFileIO.resolve(url, index: 0, expected: block, .current)
        guard case .failure(.changed) = r else { throw CheckFailure(message: "expected .changed, got \(r)") }
        try expectEqual(read(repo, "a.txt"), "someone resolved it by hand\n", "the file is untouched")
    })

    results.append(check("takeSide puts one side's whole file in place; deleteConflicted removes it") {
        let repo = try conflictedRepo()
        let t = runStager { await WorktreeStager.takeSide(at: repo.path, path: "a.txt", .current) }
        try expect(t.ok, t.message)
        try expectEqual(read(repo, "a.txt"), "one\nTWO-feat\nthree\n", "this branch's version")
        let d = runStager { await WorktreeStager.deleteConflicted(at: repo.path, path: "a.txt") }
        try expect(d.ok, d.message)
        try expect(read(repo, "a.txt") == nil, "deleted")
        try expect(try porcelain(repo).contains("D  a.txt"), "the deletion is staged")
    })

    results.append(check("storedCopy copies a binary file's HEAD and index versions byte for byte") {
        let repo = try stagerRepo()
        let v1 = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0A, 0x80, 0x00])
        let v2 = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0xFE, 0x0D, 0x0A, 0x00, 0x7F])
        try v1.write(to: repo.appending(path: "img.png"))
        try g(repo, ["add", "img.png"])
        try g(repo, ["commit", "-qm", "image"])
        try v2.write(to: repo.appending(path: "img.png"))
        try g(repo, ["add", "img.png"])
        let head = runStager { await WorktreeStager.storedCopy(at: repo.path, path: "img.png", .head) }
        let index = runStager { await WorktreeStager.storedCopy(at: repo.path, path: "img.png", .index) }
        try expectEqual(head.flatMap { try? Data(contentsOf: $0) }, v1, "HEAD version")
        try expectEqual(index.flatMap { try? Data(contentsOf: $0) }, v2, "index version")
        try expectEqual(head?.pathExtension, "png", "keeps the extension")
        let none = runStager { await WorktreeStager.storedCopy(at: repo.path, path: "no-such.png", .head) }
        try expect(none == nil, "nil when git has no such version")
    })

    results.append(check("context: a branch, and no merge, outside one") {
        let repo = try stagerRepo()
        let ctx = runStager { await WorktreeStager.context(at: repo.path) }
        try expectEqual(ctx, ChangeContext(branch: "main", merging: false, mergeMessage: nil), "plain repo")
    })

    return results
}
