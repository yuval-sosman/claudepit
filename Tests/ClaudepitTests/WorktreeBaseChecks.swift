import Foundation
@testable import ClaudepitCore

// MARK: - Local helpers (file-private; the other check files declare their own)

/// Bridge an async op into the synchronous check harness — same shape as
/// WorktreeInspectorChecks' `runAsync`, renamed so both can coexist in the module.
private func runAsyncGit<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = GitResultBox<T>()
    Task { box.set(await op()); sem.signal() }
    sem.wait()
    return box.get()
}

private final class GitResultBox<T>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value! }
}

/// Run git in `dir`, returning trimmed stdout. Throws a CheckFailure on non-zero exit.
/// `user.email`/`user.name` are set per-repo by `makeRepo` — this machine has no global
/// identity, so a merge commit would fail without it.
@discardableResult
private func rungit(_ dir: URL, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = ["git", "-C", dir.path] + args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    try expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed in \(dir.path)")
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Same as `rungit` but tolerates a non-zero exit; returns nil instead of throwing.
private func rungitOK(_ dir: URL, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = ["git", "-C", dir.path] + args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A throwaway repo on `branch` with one commit, a local identity, and no remote.
private func makeRepo(branch: String = "main") throws -> URL {
    let repo = try tempDir()
    try rungit(repo, ["init", "-q", "-b", branch])
    try rungit(repo, ["config", "user.email", "t@t.co"])
    try rungit(repo, ["config", "user.name", "t"])
    try "hi\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try rungit(repo, ["add", "a.txt"])
    try rungit(repo, ["commit", "-qm", "init"])
    return repo
}

func worktreeBaseChecks() -> [Bool] {
    var results: [Bool] = []

    // MARK: - GitBase pure

    results.append(check("parseLeftRight: tab-separated pair, else nil") {
        guard let p = GitBase.parseLeftRight("3\t5") else { throw CheckFailure(message: "nil for 3\\t5") }
        try expectEqual(p.behind, 3, "behind is the LEFT side")
        try expectEqual(p.ahead, 5, "ahead is the RIGHT side")
        try expect(GitBase.parseLeftRight("") == nil, "empty -> nil")
        try expect(GitBase.parseLeftRight("x y") == nil, "non-integers -> nil")
        try expect(GitBase.parseLeftRight("7") == nil, "single field -> nil")
    })

    results.append(check("shouldFetch: nil last -> true, inside interval -> false, outside -> true") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        try expect(GitBase.shouldFetch(last: nil, now: now, interval: 300), "never fetched -> fetch")
        try expect(!GitBase.shouldFetch(last: now.addingTimeInterval(-10), now: now, interval: 300),
                   "10s ago with a 300s interval -> skip")
        try expect(GitBase.shouldFetch(last: now.addingTimeInterval(-301), now: now, interval: 300),
                   "301s ago -> fetch")
    })

    // MARK: - GitBase against real repos

    results.append(check("trunkBranch: main / master / origin-HEAD symbolic-ref") {
        let onMain = try makeRepo(branch: "main")
        try expectEqual(runAsyncGit { await GitBase.trunkBranch(repoRoot: onMain.path) }, "main", "local main")

        let onMaster = try makeRepo(branch: "master")
        try expectEqual(runAsyncGit { await GitBase.trunkBranch(repoRoot: onMaster.path) }, "master", "local master")

        // origin/HEAD wins over a local main. No network: update-ref + symbolic-ref only.
        let withOriginHead = try makeRepo(branch: "main")
        let sha = try rungit(withOriginHead, ["rev-parse", "HEAD"])
        try rungit(withOriginHead, ["update-ref", "refs/remotes/origin/trunk", sha])
        try rungit(withOriginHead, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"])
        try expectEqual(runAsyncGit { await GitBase.trunkBranch(repoRoot: withOriginHead.path) }, "trunk",
                        "origin/HEAD outranks a local main")

        // Detached HEAD with no main/master and no origin -> nil.
        let detached = try makeRepo(branch: "wip")
        try rungit(detached, ["checkout", "-q", "--detach", "HEAD"])
        try expect(runAsyncGit { await GitBase.trunkBranch(repoRoot: detached.path) } == nil,
                   "detached, no main/master, no origin -> nil")
    })

    results.append(check("trunkBranch: a slashed default branch keeps both segments") {
        // `symbolic-ref refs/remotes/origin/HEAD` prints a full ref, and the old parse took
        // `.split(separator: "/").last` — so a default branch named "release/main" resolved to
        // "main". Here BOTH refs exist, which is what made that dangerous: the app would have
        // displayed "Update from main" and `git merge`d an entirely different branch into the
        // user's worktree. No network: update-ref + symbolic-ref only.
        let repo = try makeRepo(branch: "main")
        let sha = try rungit(repo, ["rev-parse", "HEAD"])
        try rungit(repo, ["update-ref", "refs/remotes/origin/release/main", sha])
        try rungit(repo, ["update-ref", "refs/remotes/origin/main", sha])
        try rungit(repo, ["symbolic-ref", "refs/remotes/origin/HEAD",
                          "refs/remotes/origin/release/main"])

        try expectEqual(runAsyncGit { await GitBase.trunkBranch(repoRoot: repo.path) }, "release/main",
                        "slashed default branch keeps both segments (the old parse said \"main\", "
                        + "a DIFFERENT branch that also exists in this repo)")
        try expectEqual(runAsyncGit { await GitBase.baseRef(repoRoot: repo.path, base: "release/main") },
                        "origin/release/main",
                        "the ref handed to git merge carries both segments too")
    })

    results.append(check("baseRef prefers origin/<base>; hasOrigin tracks the remote") {
        let repo = try makeRepo()
        try expectEqual(runAsyncGit { await GitBase.baseRef(repoRoot: repo.path, base: "main") }, "main",
                        "no remote ref -> local")
        try expect(!runAsyncGit { await GitBase.hasOrigin(repoRoot: repo.path) }, "no origin configured")

        let sha = try rungit(repo, ["rev-parse", "HEAD"])
        try rungit(repo, ["update-ref", "refs/remotes/origin/main", sha])
        try expectEqual(runAsyncGit { await GitBase.baseRef(repoRoot: repo.path, base: "main") }, "origin/main",
                        "remote-tracking ref exists -> origin/main")

        let bare = try tempDir().appending(path: "bare.git")
        try rungit(repo, ["clone", "-q", "--bare", repo.path, bare.path])
        try rungit(repo, ["remote", "add", "origin", bare.path])
        try expect(runAsyncGit { await GitBase.hasOrigin(repoRoot: repo.path) }, "origin added")
    })

    results.append(check("fetchBase: local bare origin moves the ref; no origin / bad origin -> false") {
        // No origin at all -> false, and no fetch is spawned (hasOrigin gate).
        let lonely = try makeRepo()
        try expect(!runAsyncGit { await GitBase.hasOrigin(repoRoot: lonely.path) }, "precondition: no origin")
        try expect(!runAsyncGit { await GitBase.fetchBase(repoRoot: lonely.path, base: "main", timeout: 5) },
                   "no origin -> false")

        // A *local* bare repo as origin — offline, no network, no credentials.
        let repo = try makeRepo()
        let bareParent = try tempDir()
        let bare = bareParent.appending(path: "bare.git")
        try rungit(repo, ["clone", "-q", "--bare", repo.path, bare.path])
        try rungit(repo, ["remote", "add", "origin", bare.path])
        // Advance the bare repo by pushing from a scratch clone, so the fetch has work to do.
        let clone = try tempDir().appending(path: "clone")
        try rungit(bareParent, ["clone", "-q", bare.path, clone.path])
        try rungit(clone, ["config", "user.email", "t@t.co"])
        try rungit(clone, ["config", "user.name", "t"])
        try "second\n".write(to: clone.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try rungit(clone, ["add", "b.txt"]); try rungit(clone, ["commit", "-qm", "second"])
        try rungit(clone, ["push", "-q", "origin", "HEAD:main"])

        try expect(runAsyncGit { await GitBase.fetchBase(repoRoot: repo.path, base: "main", timeout: 15) },
                   "fetch from a local bare origin succeeds")
        try expect(rungitOK(repo, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"]) != nil,
                   "refs/remotes/origin/main now exists")
        try expectEqual(runAsyncGit { await GitBase.baseRef(repoRoot: repo.path, base: "main") }, "origin/main",
                        "baseRef flips to origin/main after the fetch")

        // Unreachable origin -> false, promptly (the timeout parameter is exercised here;
        // git itself fails in milliseconds for a nonexistent path).
        try rungit(repo, ["remote", "set-url", "origin", "/definitely/not/a/repo"])
        try expect(!runAsyncGit { await GitBase.fetchBase(repoRoot: repo.path, base: "main", timeout: 3) },
                   "unreachable origin -> false")
    })

    // MARK: - WorktreeInfo derived state

    results.append(check("isBehindBase / canUpdateFromBase truth table") {
        func wt(behind: Int = 0, trackedDirty: Int = 0, dirty: Int = 0,
                baseRef: String = "origin/main", merging: Bool = false) -> WorktreeInfo {
            WorktreeInfo(name: "w", path: "/p/w", branch: "task/x", head: "abc1234",
                         isLocked: false, dirtyCount: dirty, aheadCount: 0,
                         behindCount: behind, trackedDirtyCount: trackedDirty,
                         baseBranch: "main", baseRef: baseRef, mergeInProgress: merging)
        }

        // No base at all: every base-dependent affordance hides, even with a stale count.
        let noBase = wt(behind: 4, baseRef: "")
        try expect(!noBase.isBehindBase, "no baseRef -> not behind, even with behindCount 4")
        try expect(!noBase.canUpdateFromBase, "no baseRef -> not updatable")

        try expect(wt(behind: 2).isBehindBase, "base + behind 2 -> behind")
        try expect(!wt(behind: 0).isBehindBase, "base + behind 0 -> not behind")

        // Clean and not merging -> runnable (even when already up to date: the user may
        // want to fetch and confirm).
        try expect(wt().canUpdateFromBase, "clean, base, no merge -> updatable")

        // A merge already in flight blocks the action.
        try expect(!wt(merging: true).canUpdateFromBase, "mergeInProgress -> not updatable")

        // TRACKED changes block; UNTRACKED-only does not — git refuses on its own if an
        // untracked file would actually be overwritten, and that lands as .failed.
        try expect(!wt(trackedDirty: 1, dirty: 1).canUpdateFromBase, "tracked dirty -> not updatable")
        let untrackedOnly = wt(trackedDirty: 0, dirty: 3)
        try expect(untrackedOnly.canUpdateFromBase, "untracked-only -> STILL updatable")
        try expect(!untrackedOnly.isClean, "isClean keeps its old meaning (untracked counts)")

        // Defaults keep the 10 existing construction sites honest.
        let legacy = WorktreeInfo(name: "l", path: "/p/l", branch: "b", head: "h",
                                  isLocked: false, dirtyCount: 0, aheadCount: 0)
        try expectEqual(legacy.behindCount, 0, "behind defaults 0")
        try expectEqual(legacy.trackedDirtyCount, 0, "trackedDirty defaults 0")
        try expectEqual(legacy.baseBranch, "", "baseBranch defaults empty")
        try expectEqual(legacy.baseRef, "", "baseRef defaults empty")
        try expect(!legacy.mergeInProgress, "mergeInProgress defaults false")
        try expectEqual(legacy.conflictedFiles, [], "conflictedFiles defaults []")
        try expect(!legacy.canUpdateFromBase, "no base -> not updatable")
    })

    results.append(check("WorktreeLock.isLockedLive marks a held lock, never a stale one") {
        // The enum itself: only a held lock is live. `lockedStale` is provably idle — its owner
        // is gone — so it must NOT gate the merge.
        try expect(!WorktreeLock.unlocked.isLockedLive, "unlocked -> not live")
        try expect(WorktreeLock.lockedLive(pid: 1).isLockedLive, "lockedLive -> live")
        try expect(!WorktreeLock.lockedStale(pid: 1).isLockedLive, "lockedStale(pid) -> not live")
        try expect(!WorktreeLock.lockedStale(pid: nil).isLockedLive, "lockedStale(nil) -> not live")

        // And through `lockState`, which is what the two merge hosts actually read.
        func wt(locked: Bool, active: Bool = false, reason: String = "") -> WorktreeInfo {
            WorktreeInfo(name: "w", path: "/p/w", branch: "task/x", head: "abc1234",
                         isLocked: locked, lockReason: reason, dirtyCount: 0, aheadCount: 0,
                         baseBranch: "main", baseRef: "origin/main", isActive: active)
        }

        let unlocked = wt(locked: false)
        try expectEqual(unlocked.lockState, .unlocked, "not locked -> .unlocked")
        try expect(!unlocked.lockState.isLockedLive, "unlocked worktree -> merge not gated")

        // An active session keeps a worktree in use regardless of the lock's own pid.
        try expect(wt(locked: true, active: true).lockState.isLockedLive,
                   "locked + active session -> live")

        // No parseable pid: cannot be proven idle, so it stays live.
        try expect(wt(locked: true, active: false, reason: "").lockState.isLockedLive,
                   "locked with no pid in the reason -> live (can't prove idle)")

        // pid 999999 exceeds macOS's pid ceiling (kern.maxproc caps pids at 99999), so no such
        // process can ever exist and kill(pid, 0) reports ESRCH -> provably dead -> stale.
        let stale = wt(locked: true, active: false, reason: "claudepit (pid 999999 start x)")
        try expectEqual(stale.lockState, .lockedStale(pid: 999999), "dead pid + idle -> stale")
        try expect(!stale.lockState.isLockedLive, "stale lock -> merge NOT gated")
    })

    // MARK: - WorktreeScanner

    results.append(check("merge carries behind/trackedDirty/base/merge-state by path") {
        let root = "/Users/me/proj"
        let a = "\(root)/.claude/worktrees/aa"
        let b = "\(root)/.claude/worktrees/bb"
        let parsed = [
            WorktreeScanner.ParsedWorktree(path: a, branch: "task/a", head: "aaa1111", isLocked: false),
            WorktreeScanner.ParsedWorktree(path: b, branch: "task/b", head: "bbb2222", isLocked: false),
        ]
        let merged = WorktreeScanner.merge(
            parsed: parsed,
            dirty: [a: 3], trackedDirty: [a: 2],
            ahead: [a: 5], behind: [a: 7],
            merging: [a], conflicted: [a: ["x.swift", "y.swift"]],
            baseBranch: "main", baseRef: "origin/main",
            sessions: [])

        guard let wa = merged.first(where: { $0.path == a }),
              let wb = merged.first(where: { $0.path == b }) else {
            throw CheckFailure(message: "worktrees missing from merge output")
        }
        try expectEqual(wa.behindCount, 7, "behind by path")
        try expectEqual(wa.aheadCount, 5, "ahead by path")
        try expectEqual(wa.trackedDirtyCount, 2, "trackedDirty by path")
        try expectEqual(wa.dirtyCount, 3, "dirty by path")
        try expect(wa.mergeInProgress, "merging set membership")
        try expectEqual(wa.conflictedFiles, ["x.swift", "y.swift"], "conflicted by path")
        try expectEqual(wa.baseBranch, "main", "scan-global baseBranch")
        try expectEqual(wa.baseRef, "origin/main", "scan-global baseRef")

        // Missing keys default, they do not leak from the sibling worktree.
        try expectEqual(wb.behindCount, 0, "missing behind -> 0")
        try expectEqual(wb.trackedDirtyCount, 0, "missing trackedDirty -> 0")
        try expect(!wb.mergeInProgress, "not in merging set -> false")
        try expectEqual(wb.conflictedFiles, [], "missing conflicted -> []")
        try expectEqual(wb.baseRef, "origin/main", "base is scan-global, not per-path")
    })

    results.append(check("scanRaw: real ahead+behind with NO upstream configured") {
        // Regression guard for the old `@{upstream}..HEAD` count, which was permanently 0 on a
        // task branch because a task branch never has an upstream.
        let repo = try makeRepo()
        try rungit(repo, ["worktree", "add", "-q", ".claude/worktrees/test-wt", "-b", "task/x"])
        let wtPath = repo.appending(path: ".claude/worktrees/test-wt")
        // 2 commits on main, 1 in the worktree.
        try "base2\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try rungit(repo, ["commit", "-qam", "c2"])
        try "base3\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try rungit(repo, ["commit", "-qam", "c3"])
        try "wt\n".write(to: wtPath.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try rungit(wtPath, ["add", "b.txt"]); try rungit(wtPath, ["commit", "-qm", "w1"])
        // Proof of the precondition: no upstream on this branch.
        try expect(rungitOK(wtPath, ["rev-parse", "--abbrev-ref", "@{upstream}"]) == nil,
                   "precondition: task branch has NO upstream")

        guard let raw = runAsyncGit({ await WorktreeScanner().scanRaw(activePath: repo) }) else {
            throw CheckFailure(message: "scanRaw returned nil for a valid repo")
        }
        let p = raw.parsed[0].path
        try expectEqual(raw.behind[p], 2, "2 commits on main not in the worktree")
        try expectEqual(raw.ahead[p], 1, "1 worktree commit not on main (NOT 0)")
        try expectEqual(raw.baseBranch, "main", "base resolved once per scan")
        try expectEqual(raw.baseRef, "main", "no origin -> local ref")
        try expect(raw.mergeInProgress.isEmpty, "no merge in flight")
    })

    results.append(check("scanRaw: dirty split tracked vs untracked") {
        let repo = try makeRepo()
        try rungit(repo, ["worktree", "add", "-q", ".claude/worktrees/dirty-wt", "-b", "task/d"])
        let wtPath = repo.appending(path: ".claude/worktrees/dirty-wt")
        try "modified\n".write(to: wtPath.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "scratch\n".write(to: wtPath.appending(path: "note.txt"), atomically: true, encoding: .utf8)

        guard let raw = runAsyncGit({ await WorktreeScanner().scanRaw(activePath: repo) }) else {
            throw CheckFailure(message: "scanRaw nil")
        }
        let p = raw.parsed[0].path
        try expectEqual(raw.dirty[p], 2, "one tracked-modified + one untracked")
        try expectEqual(raw.trackedDirty[p], 1, "only the tracked one counts for the merge gate")
    })

    results.append(check("scanRaw: merge state from MERGE_HEAD, incl. staged-resolution state") {
        let repo = try makeRepo()
        try rungit(repo, ["worktree", "add", "-q", ".claude/worktrees/conf-wt", "-b", "task/c"])
        let wtPath = repo.appending(path: ".claude/worktrees/conf-wt")
        // Overlapping edits to a.txt on both sides -> guaranteed conflict.
        try "main-side\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try rungit(repo, ["commit", "-qam", "main edit"])
        try "wt-side\n".write(to: wtPath.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try rungit(wtPath, ["commit", "-qam", "wt edit"])
        _ = rungitOK(wtPath, ["merge", "--no-edit", "main"])   // expected to fail (conflict)

        guard let conflicted = runAsyncGit({ await WorktreeScanner().scanRaw(activePath: repo) }) else {
            throw CheckFailure(message: "scanRaw nil (conflicted)")
        }
        let p = conflicted.parsed[0].path
        try expect(conflicted.mergeInProgress.contains(p), "MERGE_HEAD present -> merging")
        try expectEqual(conflicted.conflicted[p], ["a.txt"], "one unmerged path")
        // "UU a.txt" is a TRACKED dirty line, so a conflicted worktree also fails the merge
        // gate — which is why the control's state line checks mergeInProgress FIRST and never
        // describes a conflicted worktree as merely dirty.
        try expectEqual(conflicted.dirty[p], 1, "UU counts as dirty")
        try expectEqual(conflicted.trackedDirty[p], 1, "UU is tracked, not untracked")

        // Stage the resolution but do NOT commit: still merging, but zero unmerged paths.
        // This is the state the merge-state block must still render.
        try rungit(wtPath, ["add", "a.txt"])
        guard let staged = runAsyncGit({ await WorktreeScanner().scanRaw(activePath: repo) }) else {
            throw CheckFailure(message: "scanRaw nil (staged)")
        }
        try expect(staged.mergeInProgress.contains(p), "still merging after staging")
        try expectEqual(staged.conflicted[p], [], "no unmerged paths left")

        // Abort -> neither.
        try rungit(wtPath, ["merge", "--abort"])
        guard let aborted = runAsyncGit({ await WorktreeScanner().scanRaw(activePath: repo) }) else {
            throw CheckFailure(message: "scanRaw nil (aborted)")
        }
        try expect(!aborted.mergeInProgress.contains(p), "abort clears MERGE_HEAD")
        try expect((aborted.conflicted[p] ?? []).isEmpty, "no conflicted paths after abort")
    })

    results.append(check("scanRaw is offline by default even with a broken origin") {
        // fetchBase defaults to false, so a nonexistent origin must not slow or break the scan.
        let repo = try makeRepo()
        try rungit(repo, ["remote", "add", "origin", "/definitely/not/a/repo"])
        try rungit(repo, ["worktree", "add", "-q", ".claude/worktrees/off-wt", "-b", "task/o"])
        guard let raw = runAsyncGit({ await WorktreeScanner().scanRaw(activePath: repo) }) else {
            throw CheckFailure(message: "scanRaw nil with a broken origin")
        }
        try expectEqual(raw.parsed.count, 1, "worktree still found")
        try expectEqual(raw.baseRef, "main", "no refs/remotes/origin/main on disk -> local ref")
        try expectEqual(raw.behind[raw.parsed[0].path], 0, "counts computed, nothing fetched")
    })

    // MARK: - WorktreeStager.updateFromBase / abortMerge

    results.append(check("updateFromBase: upToDate / merged / dirty / untracked-ok / failed") {
        /// Repo + worktree, with `extraMainCommits` commits added to main afterwards.
        func setup(extraMainCommits: Int) throws -> (repo: URL, wt: URL) {
            let repo = try makeRepo()
            try rungit(repo, ["worktree", "add", "-q", ".claude/worktrees/wt", "-b", "task/u"])
            for i in 0..<extraMainCommits {
                try "main-\(i)\n".write(to: repo.appending(path: "m\(i).txt"), atomically: true, encoding: .utf8)
                try rungit(repo, ["add", "m\(i).txt"]); try rungit(repo, ["commit", "-qm", "m\(i)"])
            }
            return (repo, repo.appending(path: ".claude/worktrees/wt"))
        }

        // .upToDate — main has nothing new, HEAD does not move.
        let (_, wtSame) = try setup(extraMainCommits: 0)
        let sameBefore = try rungit(wtSame, ["rev-parse", "HEAD"])
        let r1 = runAsyncGit { await WorktreeStager.updateFromBase(worktreePath: wtSame.path, baseRef: "main") }
        try expectEqual(r1, .upToDate, "nothing to merge")
        try expectEqual(try rungit(wtSame, ["rev-parse", "HEAD"]), sameBefore, "HEAD unmoved")

        // .merged — main moved; a rescan then reports behind == 0.
        let (repo2, wt2) = try setup(extraMainCommits: 2)
        let r2 = runAsyncGit { await WorktreeStager.updateFromBase(worktreePath: wt2.path, baseRef: "main") }
        try expectEqual(r2, .merged, "two new commits merged")
        guard let after = runAsyncGit({ await WorktreeScanner().scanRaw(activePath: repo2) }) else {
            throw CheckFailure(message: "scanRaw nil after merge")
        }
        try expectEqual(after.behind[after.parsed[0].path], 0, "no longer behind")

        // .dirty(1) — a modified TRACKED file blocks, and HEAD is provably unchanged.
        let (_, wt3) = try setup(extraMainCommits: 1)
        try "locally modified\n".write(to: wt3.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let head3 = try rungit(wt3, ["rev-parse", "HEAD"])
        let r3 = runAsyncGit { await WorktreeStager.updateFromBase(worktreePath: wt3.path, baseRef: "main") }
        try expectEqual(r3, .dirty(1), "one tracked change refuses the merge")
        try expectEqual(try rungit(wt3, ["rev-parse", "HEAD"]), head3, "nothing was attempted")

        // Untracked-only is NOT dirty for this purpose: it merges.
        let (_, wt4) = try setup(extraMainCommits: 1)
        try "scratch\n".write(to: wt4.appending(path: "scratch.txt"), atomically: true, encoding: .utf8)
        let r4 = runAsyncGit { await WorktreeStager.updateFromBase(worktreePath: wt4.path, baseRef: "main") }
        try expectEqual(r4, .merged, "untracked file does not block the merge")
        try expect(FileManager.default.fileExists(atPath: wt4.appending(path: "scratch.txt").path),
                   "the untracked file survived")

        // .failed on a bogus ref, with git's own message.
        let (_, wt5) = try setup(extraMainCommits: 0)
        let r5 = runAsyncGit { await WorktreeStager.updateFromBase(worktreePath: wt5.path, baseRef: "no/such/ref") }
        switch r5 {
        case .failed(let msg): try expect(!msg.isEmpty, "failure carries git's message")
        default: throw CheckFailure(message: "expected .failed, got \(r5)")
        }
    })

    results.append(check("updateFromBase conflict -> .conflicted, then abortMerge restores HEAD") {
        let repo = try makeRepo()
        try rungit(repo, ["worktree", "add", "-q", ".claude/worktrees/wt", "-b", "task/k"])
        let wt = repo.appending(path: ".claude/worktrees/wt")
        try "main-side\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try rungit(repo, ["commit", "-qam", "main edit"])
        try "wt-side\n".write(to: wt.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try rungit(wt, ["commit", "-qam", "wt edit"])
        let preMerge = try rungit(wt, ["rev-parse", "HEAD"])

        let r = runAsyncGit { await WorktreeStager.updateFromBase(worktreePath: wt.path, baseRef: "main") }
        try expectEqual(r, .conflicted(["a.txt"]), "overlapping edits conflict on a.txt")
        try expect(rungitOK(wt, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"]) != nil,
                   "left mid-merge on purpose — aborting is the user's call")

        // Clicking through again while mid-merge must not touch the tree.
        let again = runAsyncGit { await WorktreeStager.updateFromBase(worktreePath: wt.path, baseRef: "main") }
        try expectEqual(again, .conflicted(["a.txt"]), "re-entry reports the same conflict")
        try expectEqual(try rungit(wt, ["rev-parse", "HEAD"]), preMerge, "HEAD untouched")

        let abort = runAsyncGit { await WorktreeStager.abortMerge(worktreePath: wt.path) }
        try expect(abort.ok, "abort succeeded: \(abort.message)")
        try expect(rungitOK(wt, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"]) == nil,
                   "MERGE_HEAD gone")
        try expectEqual(try rungit(wt, ["status", "--porcelain"]), "", "working tree clean")
        try expectEqual(try rungit(wt, ["rev-parse", "HEAD"]), preMerge, "HEAD back to pre-merge")
    })

    return results
}
