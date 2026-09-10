import Foundation
@testable import ClaudepitCore

func worktreeScannerChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("WorktreeInfo bindingState and isClean") {
        let active = WorktreeInfo(name: "a", path: "/p/a", branch: "worktree-a", head: "abc123",
                                  isLocked: false, dirtyCount: 0, aheadCount: 0,
                                  ownerSessionID: "s1", isActive: true)
        try expectEqual(active.bindingState, .active, "active binding")
        try expect(active.isClean, "active is clean")

        let idle = WorktreeInfo(name: "b", path: "/p/b", branch: "worktree-b", head: "def456",
                                isLocked: false, dirtyCount: 3, aheadCount: 1,
                                ownerSessionID: "s2", isActive: false)
        try expectEqual(idle.bindingState, .idle, "idle binding")
        try expect(!idle.isClean, "idle is dirty")

        let unbound = WorktreeInfo(name: "c", path: "/p/c", branch: "worktree-c", head: "ghi789",
                                   isLocked: true, dirtyCount: 0, aheadCount: 0,
                                   ownerSessionID: nil, isActive: false)
        try expectEqual(unbound.bindingState, .unbound, "unbound binding")
        try expectEqual(unbound.id, "/p/c", "id is path")
    })

    results.append(check("parsePorcelain keeps only .claude worktrees, skips main") {
        let root = "/Users/me/proj"
        let out = """
        worktree /Users/me/proj
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/me/proj/.claude/worktrees/feature-auth
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/worktree-feature-auth

        worktree /Users/me/proj/.claude/worktrees/locked-one
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/worktree-locked-one
        locked

        """
        let parsed = WorktreeScanner.parsePorcelain(out, repoRoot: root)
        try expectEqual(parsed.count, 2, "two claude worktrees")
        try expectEqual(parsed[0].path, "\(root)/.claude/worktrees/feature-auth", "auth path")
        try expectEqual(parsed[0].branch, "worktree-feature-auth", "auth branch")
        try expectEqual(parsed[0].head, "2222222", "auth short head")
        try expect(!parsed[0].isLocked, "auth unlocked")
        try expectEqual(parsed[1].branch, "worktree-locked-one", "locked branch")
        try expect(parsed[1].isLocked, "locked flagged")
    })

    results.append(check("merge binds session by slug and marks unbound") {
        let root = "/Users/me/proj"
        let wtPath = "\(root)/.claude/worktrees/feature-auth"
        let parsed = [
            WorktreeScanner.ParsedWorktree(path: wtPath, branch: "worktree-feature-auth",
                                           head: "2222222", isLocked: false),
            WorktreeScanner.ParsedWorktree(path: "\(root)/.claude/worktrees/hooked",
                                           branch: "worktree-hooked", head: "9999999", isLocked: false),
        ]
        let slug = Paths.slug(for: URL(filePath: wtPath))
        let session = SessionSummary(id: "sess-1", fileURL: URL(filePath: "/x"), projectSlug: slug,
                                     title: "t", modifiedAt: Date(timeIntervalSince1970: 0),
                                     turnCount: 1, isActive: true)

        let merged = WorktreeScanner.merge(parsed: parsed, dirty: [wtPath: 4], ahead: [wtPath: 2],
                                           sessions: [session])

        guard let auth = merged.first(where: { $0.name == "feature-auth" }) else {
            throw CheckFailure(message: "feature-auth missing")
        }
        try expectEqual(auth.ownerSessionID, "sess-1", "owner")
        try expect(auth.isActive, "active")
        try expectEqual(auth.dirtyCount, 4, "dirty")
        try expectEqual(auth.aheadCount, 2, "ahead")
        try expectEqual(auth.bindingState, .active, "active binding")

        guard let hooked = merged.first(where: { $0.name == "hooked" }) else {
            throw CheckFailure(message: "hooked missing")
        }
        try expectEqual(hooked.ownerSessionID, nil, "no owner")
        try expectEqual(hooked.bindingState, .unbound, "unbound")
        try expectEqual(hooked.dirtyCount, 0, "missing key defaults 0")
    })

    results.append(check("scanRaw against a real git repo + worktree") {
        // Build a throwaway repo with one dirty worktree, then scan it.
        let repo = try tempDir()
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/env")
            p.arguments = ["git", "-C", repo.path] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            try expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@t.co"])
        try git(["config", "user.name", "t"])
        try "hi".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"]); try git(["commit", "-qm", "init"])
        try git(["worktree", "add", "-q", ".claude/worktrees/test-wt", "-b", "worktree-test-wt"])
        // make the worktree dirty
        try "x".write(to: repo.appending(path: ".claude/worktrees/test-wt/b.txt"),
                      atomically: true, encoding: .utf8)

        guard let raw = WorktreeScanner().scanRaw(activePath: repo) else {
            throw CheckFailure(message: "scanRaw returned nil for a valid repo")
        }
        try expectEqual(raw.parsed.count, 1, "one .claude worktree (main skipped)")
        let wt = raw.parsed[0]
        try expectEqual(wt.branch, "worktree-test-wt", "branch")
        try expect(wt.path.hasSuffix("/.claude/worktrees/test-wt"), "path under .claude/worktrees")
        try expectEqual(raw.dirty[wt.path], 1, "one dirty file (b.txt)")
    })

    results.append(check("claudeSlug replaces slash, dot, and plus with dash") {
        let s = WorktreeScanner.claudeSlug(for: "/Users/me/proj/.claude/worktrees/feat+kg")
        try expectEqual(s, "-Users-me-proj--claude-worktrees-feat-kg", "dot, slash, plus → dash")
    })

    results.append(check("merge binds worktree session via plus-in-name slug") {
        let wtPath = "/Users/me/proj/.claude/worktrees/feat+kg"
        let parsed = [WorktreeScanner.ParsedWorktree(path: wtPath, branch: "feat+kg",
                                                     head: "abc1234", isLocked: false)]
        let ccSlug = WorktreeScanner.claudeSlug(for: wtPath)  // -Users-me-proj--claude-worktrees-feat-kg
        let session = SessionSummary(id: "sess-plus", fileURL: URL(filePath: "/x"), projectSlug: ccSlug,
                                     title: "t", modifiedAt: Date(timeIntervalSince1970: 0),
                                     turnCount: 1, isActive: false)
        let merged = WorktreeScanner.merge(parsed: parsed, dirty: [:], ahead: [:], sessions: [session])
        try expectEqual(merged[0].ownerSessionID, "sess-plus", "bound via plus-slug")
    })

    results.append(check("merge binds worktree session via Claude Code dot-dash slug") {
        // Real Claude Code slug for a worktree path uses '--claude' (dot replaced), which
        // Paths.slug does NOT produce. merge must still bind the session.
        let wtPath = "/Users/me/proj/.claude/worktrees/featureA"
        let parsed = [WorktreeScanner.ParsedWorktree(path: wtPath, branch: "worktree-featureA",
                                                     head: "3163200", isLocked: false)]
        let ccSlug = WorktreeScanner.claudeSlug(for: wtPath)  // -Users-me-proj--claude-worktrees-featureA
        try expect(ccSlug != Paths.slug(for: URL(filePath: wtPath)), "slugs differ (regression guard)")
        let session = SessionSummary(id: "sess-cc", fileURL: URL(filePath: "/x"), projectSlug: ccSlug,
                                     title: "t", modifiedAt: Date(timeIntervalSince1970: 0),
                                     turnCount: 1, isActive: false)
        let merged = WorktreeScanner.merge(parsed: parsed, dirty: [:], ahead: [:], sessions: [session])
        try expectEqual(merged[0].ownerSessionID, "sess-cc", "bound via dot-dash slug")
        try expectEqual(merged[0].bindingState, .idle, "idle (owner, not active)")
    })

    results.append(check("lockState: reason pid parse + live/stale/unlocked classification") {
        // Unlocked → .unlocked
        let open = WorktreeInfo(name: "o", path: "/p/o", branch: "b", head: "h",
                                isLocked: false, dirtyCount: 0, aheadCount: 0)
        try expectEqual(open.lockState, .unlocked, "not locked")

        // Locked, dead pid, NOT active → stale (99999999 far above any real pid)
        let stale = WorktreeInfo(name: "s", path: "/p/s", branch: "b", head: "h",
                                 isLocked: true,
                                 lockReason: "claude session featureA (pid 99999999 start Thu)",
                                 dirtyCount: 0, aheadCount: 0, isActive: false)
        try expectEqual(stale.lockPID, 99999999, "pid parsed from reason")
        try expectEqual(stale.lockState, .lockedStale(pid: 99999999), "dead pid + idle → stale")

        // Locked, live pid (1 = init/launchd, always alive) → live
        let live = WorktreeInfo(name: "l", path: "/p/l", branch: "b", head: "h",
                                isLocked: true, lockReason: "held (pid 1 start now)",
                                dirtyCount: 0, aheadCount: 0)
        try expectEqual(live.lockState, .lockedLive(pid: 1), "pid 1 alive → live")

        // Locked, dead pid, but session ACTIVE → treated as in-use, not stale
        let activeButDead = WorktreeInfo(name: "a", path: "/p/a", branch: "b", head: "h",
                                         isLocked: true,
                                         lockReason: "claude session (pid 99999999)",
                                         dirtyCount: 0, aheadCount: 0,
                                         ownerSessionID: "s1", isActive: true)
        try expectEqual(activeButDead.lockState, .lockedLive(pid: 99999999),
                        "active session keeps worktree in use even with a dead lock pid")

        // Locked, no pid in reason → in-use (can't prove idle+dead) → live(-1)
        let noPID = WorktreeInfo(name: "n", path: "/p/n", branch: "b", head: "h",
                                 isLocked: true, lockReason: "on removable media",
                                 dirtyCount: 0, aheadCount: 0)
        try expectEqual(noPID.lockPID, nil, "no pid to parse")
        try expectEqual(noPID.lockState, .lockedLive(pid: -1), "no pid → not stale")
    })

    results.append(check("parsePorcelain captures lock reason") {
        let out = """
        worktree /Users/me/proj/.claude/worktrees/locked-one
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/worktree-locked-one
        locked claude session featureA (pid 23121 start Thu)

        """
        let parsed = WorktreeScanner.parsePorcelain(out, repoRoot: "/Users/me/proj")
        try expectEqual(parsed.count, 1, "one worktree")
        try expect(parsed[0].isLocked, "locked")
        try expectEqual(parsed[0].lockReason, "claude session featureA (pid 23121 start Thu)", "reason captured")
    })

    results.append(check("merge binds subagent worktree via subagents/<name>.jsonl") {
        // Simulate Claude Code's multi-agent layout:
        // ~/.claude/projects/<slug>/<session-id>/subagents/<worktree-name>.jsonl
        let tmp = try tempDir()
        let sessionID = "parent-sess-1"
        let wtName = "agent-aa85ee53d8ca1d2e3"
        let subagentDir = tmp.appending(path: "\(sessionID)/subagents")
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        try "{}".write(to: subagentDir.appending(path: "\(wtName).jsonl"), atomically: true, encoding: .utf8)

        let wtPath = "/Users/me/proj/.claude/worktrees/\(wtName)"
        let parsed = [WorktreeScanner.ParsedWorktree(path: wtPath, branch: "worktree-\(wtName)",
                                                     head: "abc1234", isLocked: false)]
        // Session whose fileURL is in the same project dir as the subagents folder.
        let session = SessionSummary(id: sessionID,
                                     fileURL: tmp.appending(path: "\(sessionID).jsonl"),
                                     projectSlug: "some-other-project",
                                     title: "t", modifiedAt: Date(timeIntervalSince1970: 0),
                                     turnCount: 1, isActive: false)
        let merged = WorktreeScanner.merge(parsed: parsed, dirty: [:], ahead: [:], sessions: [session])
        try expectEqual(merged[0].ownerSessionID, sessionID, "bound to parent session via subagent file")
        try expectEqual(merged[0].ownerSubagentID, "aa85ee53d8ca1d2e3", "subagent ID stripped of agent- prefix")
        try expectEqual(merged[0].bindingState, .idle, "idle (owner found, not active)")
    })

    results.append(check("merge binds worktree via cwdMap fallback (main-repo project dir)") {
        // Claude Code stores worktree sessions under the parent repo slug, not a worktree slug.
        // After "Keep worktree" on exit, the session is idle and slug-matching finds nothing.
        let wtPath = "/Users/me/proj/.claude/worktrees/feat+my-feature"
        let parsed = [WorktreeScanner.ParsedWorktree(path: wtPath, branch: "worktree-feat+my-feature",
                                                      head: "abc1234", isLocked: false)]
        let session = SessionSummary(id: "sess-cwd-1",
                                     fileURL: URL(filePath: "/tmp/sess-cwd-1.jsonl"),
                                     projectSlug: "-Users-me-proj",  // main repo slug, not worktree
                                     title: "t", modifiedAt: Date(timeIntervalSince1970: 1),
                                     turnCount: 2, isActive: false)
        // cwdMap built by scanRaw maps the worktree path to the session ID
        let cwdMap: [String: String] = [wtPath: "sess-cwd-1"]
        let merged = WorktreeScanner.merge(parsed: parsed, dirty: [:], ahead: [:],
                                           sessions: [session], cwdMap: cwdMap)
        try expectEqual(merged[0].ownerSessionID, "sess-cwd-1", "bound via cwd fallback")
        try expectEqual(merged[0].bindingState, .idle, "idle (owner found, not active)")
        try expect(merged[0].ownerSubagentID == nil, "no subagent ID")
    })

    return results
}
