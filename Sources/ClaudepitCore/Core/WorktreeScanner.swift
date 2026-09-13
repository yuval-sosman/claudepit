import Foundation

public struct WorktreeScanner {
    public struct ParsedWorktree: Equatable, Sendable {
        public let path: String
        public let branch: String
        public let head: String
        public let isLocked: Bool
        /// Reason string from `git worktree lock --reason` (empty if locked without one).
        public let lockReason: String
        public init(path: String, branch: String, head: String, isLocked: Bool, lockReason: String = "") {
            self.path = path; self.branch = branch; self.head = head
            self.isLocked = isLocked; self.lockReason = lockReason
        }
    }

    /// All-Sendable git scan result, ready to merge with sessions on the main actor.
    /// `baseBranch`/`baseRef` are scan-GLOBAL — resolved once at the repo toplevel, not per
    /// worktree — so the scan's base and every worktree's comparison ref are the same answer.
    public struct RawScan: Sendable {
        public let parsed: [ParsedWorktree]
        public let dirty: [String: Int]
        /// `status --porcelain` lines that are not "??" — the merge gate's counter.
        public let trackedDirty: [String: Int]
        public let ahead: [String: Int]
        public let behind: [String: Int]
        /// Worktree paths with a live `MERGE_HEAD`.
        public let mergeInProgress: Set<String>
        /// Unmerged paths per worktree; only populated while `MERGE_HEAD` exists, and
        /// legitimately empty once the user has staged resolutions.
        public let conflicted: [String: [String]]
        public let baseBranch: String
        public let baseRef: String
        /// Fallback binding: worktree path → session ID, populated by scanning
        /// transcripts in the parent repo's project dir for a matching `cwd` field.
        public let cwdMap: [String: String]
        public init(parsed: [ParsedWorktree], dirty: [String: Int], trackedDirty: [String: Int] = [:],
                    ahead: [String: Int], behind: [String: Int] = [:],
                    mergeInProgress: Set<String> = [], conflicted: [String: [String]] = [:],
                    baseBranch: String = "", baseRef: String = "",
                    cwdMap: [String: String] = [:]) {
            self.parsed = parsed; self.dirty = dirty; self.trackedDirty = trackedDirty
            self.ahead = ahead; self.behind = behind
            self.mergeInProgress = mergeInProgress; self.conflicted = conflicted
            self.baseBranch = baseBranch; self.baseRef = baseRef
            self.cwdMap = cwdMap
        }
    }

    public init() {}

    public static func parsePorcelain(_ output: String, repoRoot: String) -> [ParsedWorktree] {
        let prefix = repoRoot + "/.claude/worktrees/"
        var result: [ParsedWorktree] = []
        var path: String?, head = "", branch = "", locked = false, lockReason = ""

        func flush() {
            if let p = path, p.hasPrefix(prefix) {
                result.append(ParsedWorktree(path: p, branch: branch, head: head, isLocked: locked, lockReason: lockReason))
            }
            path = nil; head = ""; branch = ""; locked = false; lockReason = ""
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst("worktree ".count)) }
            else if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count).prefix(7)) }
            else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "")
            }
            else if line == "locked" { locked = true }
            else if line.hasPrefix("locked ") { locked = true; lockReason = String(line.dropFirst("locked ".count)) }
        }
        flush()
        return result
    }
}

extension WorktreeScanner {
    /// New parameters are DEFAULTED and inserted so existing argument order is preserved —
    /// `merge(parsed:dirty:ahead:sessions:)` and `merge(parsed:dirty:ahead:sessions:cwdMap:)`
    /// still compile unedited at their 5 existing call sites.
    public static func merge(parsed: [ParsedWorktree],
                             dirty: [String: Int],
                             trackedDirty: [String: Int] = [:],
                             ahead: [String: Int],
                             behind: [String: Int] = [:],
                             merging: Set<String> = [],
                             conflicted: [String: [String]] = [:],
                             baseBranch: String = "",
                             baseRef: String = "",
                             sessions: [SessionSummary],
                             cwdMap: [String: String] = [:]) -> [WorktreeInfo] {
        parsed.map { wt in
            // A worktree's transcript is homed under Claude Code's slug for its path.
            // Claude Code replaces BOTH '/' and '.' with '-', so "/.claude/worktrees" →
            // "--claude-worktrees". Paths.slug only replaces '/', so match either form.
            let candidates = Set([Paths.slug(for: URL(filePath: wt.path)),
                                  claudeSlug(for: wt.path)])
            let matches = sessions.filter { candidates.contains($0.projectSlug) }
            let owner = matches.first(where: { $0.isActive })
                ?? matches.max(by: { $0.modifiedAt < $1.modifiedAt })
            // Subagent worktrees: Claude Code names them agent-<id> and stores their
            // transcript at <project>/<session-id>/subagents/<worktree-name>.jsonl.
            // No project dir is created for the worktree path itself, so slug-matching
            // above finds nothing. Fall back to checking the subagents directory.
            let subagentMatch = owner == nil ? subagentOwner(for: wt.path, in: sessions) : nil
            // CWD fallback: Claude Code sometimes stores worktree sessions under the
            // parent repo's project dir. cwdMap (built in scanRaw) maps worktree paths
            // to session IDs by peeking at transcript cwd fields.
            let cwdOwner = (owner == nil && subagentMatch == nil)
                ? sessions.first(where: { $0.id == cwdMap[wt.path] })
                : nil
            return WorktreeInfo(
                name: URL(filePath: wt.path).lastPathComponent,
                path: wt.path, branch: wt.branch, head: wt.head, isLocked: wt.isLocked,
                lockReason: wt.lockReason,
                dirtyCount: dirty[wt.path] ?? 0, aheadCount: ahead[wt.path] ?? 0,
                behindCount: behind[wt.path] ?? 0,
                trackedDirtyCount: trackedDirty[wt.path] ?? 0,
                baseBranch: baseBranch, baseRef: baseRef,
                mergeInProgress: merging.contains(wt.path),
                conflictedFiles: conflicted[wt.path] ?? [],
                ownerSessionID: owner?.id ?? subagentMatch?.session.id ?? cwdOwner?.id,
                ownerSubagentID: subagentMatch?.subagentID,
                isActive: owner?.isActive ?? subagentMatch?.session.isActive ?? cwdOwner?.isActive ?? false)
        }
    }

    /// Find the parent session that spawned a subagent worktree by checking if
    /// <project>/<session-id>/subagents/<worktree-name>.jsonl exists.
    /// Returns both the parent session and the subagent's own ID for resume/navigate.
    private static func subagentOwner(for path: String, in sessions: [SessionSummary]) -> (session: SessionSummary, subagentID: String)? {
        let wtName = URL(filePath: path).lastPathComponent
        let fm = FileManager.default
        // Active sessions first, then most-recently-modified.
        let ordered = sessions.filter { $0.isActive } + sessions.filter { !$0.isActive }.sorted { $0.modifiedAt > $1.modifiedAt }
        for session in ordered {
            let subagentFile = session.fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(session.id)
                .appendingPathComponent("subagents")
                .appendingPathComponent("\(wtName).jsonl")
            if fm.fileExists(atPath: subagentFile.path) {
                // The subagent ID matches the worktree name (agent-<id>),
                // but SubagentSummary.id strips the "agent-" prefix.
                let subagentID = wtName.hasPrefix("agent-") ? String(wtName.dropFirst("agent-".count)) : wtName
                return (session, subagentID)
            }
        }
        return nil
    }

    /// Claude Code's project-dir slug: every '/', '.', and '+' becomes '-'.
    /// (Paths.slug only replaces '/', which mismatches paths containing dots like ".claude"
    /// or plus signs like "feat+branch-name".)
    static func claudeSlug(for path: String) -> String {
        String(path.map { ($0 == "/" || $0 == "." || $0 == "+") ? "-" : $0 })
    }
}

// Every git call below goes through the shared `GitBase.git(_:dir:)` — this scan used to keep its
// own hand-rolled copy, which left `standardError` undrained and had no timeout at all.
extension WorktreeScanner {
    /// Read-only git scan of the active project's worktrees. Returns only Sendable data
    /// (safe to compute off the main actor); merge with sessions via `merge(...)`.
    /// Returns nil if activePath is nil, git is absent, or the path is not a git repo.
    ///
    /// `fetchBase` defaults to FALSE: this runs on every FileWatcher tick, and the throttle
    /// that decides when a network call is acceptable lives in the caller
    /// (`AppState.reloadWorktrees`). A failed, skipped or timed-out fetch is silent — the
    /// counts simply come from the refs already on disk.
    ///
    /// Per-worktree git calls: 3 (4 while a merge is in progress). The old upstream-relative
    /// ahead count (`rev-list --count` against the branch's tracking ref) is REPLACED, not
    /// added to — it was permanently 0 on task branches, which never have a tracking ref.
    public func scanRaw(activePath: URL?, fetchBase: Bool = false) async -> RawScan? {
        guard let root = activePath?.path else { return nil }
        guard let top = await GitBase.git(["rev-parse", "--show-toplevel"], dir: root), !top.isEmpty
        else { return nil }
        guard let listing = await GitBase.git(["worktree", "list", "--porcelain"], dir: top) else { return nil }
        let parsed = Self.parsePorcelain(listing, repoRoot: top)

        // Base resolved ONCE per scan, at the toplevel — so no two worktrees can disagree
        // about what they are behind. nil base (detached HEAD, no main/master, no origin) is a
        // legitimate repo shape: ref stays "", counts are skipped, every affordance hides.
        let base = await GitBase.trunkBranch(repoRoot: top)
        if fetchBase, let base { await GitBase.fetchBase(repoRoot: top, base: base) }
        // Spelled out rather than `base.map { ... }`: `Optional.map` takes a non-async closure.
        var ref = ""
        if let base { ref = await GitBase.baseRef(repoRoot: top, base: base) }

        var dirty: [String: Int] = [:], trackedDirty: [String: Int] = [:]
        var ahead: [String: Int] = [:], behind: [String: Int] = [:]
        var merging: Set<String> = [], conflicted: [String: [String]] = [:]
        for wt in parsed {
            // One status call, split by tracked-ness — no extra subprocess.
            if let status = await GitBase.git(["status", "--porcelain"], dir: wt.path) {
                let lines = status.isEmpty ? [] : status.split(separator: "\n")
                dirty[wt.path] = lines.count
                trackedDirty[wt.path] = lines.filter { !$0.hasPrefix("??") }.count
            }
            // One call for BOTH counts. Left side = behind, right side = ahead.
            if !ref.isEmpty,
               let out = await GitBase.git(["rev-list", "--left-right", "--count", "\(ref)...HEAD"], dir: wt.path),
               let c = GitBase.parseLeftRight(out) {
                behind[wt.path] = c.behind
                ahead[wt.path] = c.ahead
            }
            // Merge state is derived every scan, never cached — a merge can be started or
            // finished in a terminal, and the conflict UI must survive an app relaunch.
            if await GitBase.git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], dir: wt.path) != nil {
                merging.insert(wt.path)
                let unmerged = await GitBase.git(["diff", "--name-only", "--diff-filter=U"], dir: wt.path) ?? ""
                conflicted[wt.path] = unmerged
                    .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
        }

        // Build cwd fallback map: scan transcripts in the parent repo's project dir.
        let cwdMap = Self.buildCWDMap(repoRoot: top, worktreePaths: parsed.map { $0.path })
        return RawScan(parsed: parsed, dirty: dirty, trackedDirty: trackedDirty,
                       ahead: ahead, behind: behind,
                       mergeInProgress: merging, conflicted: conflicted,
                       baseBranch: base ?? "", baseRef: ref, cwdMap: cwdMap)
    }

    /// Peeks at transcripts in the parent repo's Claude project dir to find which
    /// session's cwd matches each worktree path. Used when slug-based binding fails
    /// (Claude Code stores worktree sessions under the main repo slug, not a worktree slug).
    private static func buildCWDMap(repoRoot: String, worktreePaths: [String]) -> [String: String] {
        guard !worktreePaths.isEmpty else { return [:] }
        let parentSlug = claudeSlug(for: repoRoot)
        let projectDir = Paths.globalClaude.appendingPathComponent("projects/\(parentSlug)")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [URLResourceKey.contentModificationDateKey],
            options: .skipsHiddenFiles)
        else { return [:] }

        let transcripts = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (a, b) -> Bool in
                let key = URLResourceKey.contentModificationDateKey
                let da = (try? a.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast
                return da > db  // newest first — most likely to be the right session
            }

        let wtSet = Set(worktreePaths)
        // Prefix all worktrees share — used to skip unrelated cwd lines fast.
        let wtPrefix = repoRoot + "/.claude/worktrees/"
        var result: [String: String] = [:]
        for transcript in transcripts {
            let sid = transcript.deletingPathExtension().lastPathComponent
            guard let cwd = Self.dominantWorktreeCWD(transcript: transcript, prefix: wtPrefix, candidates: wtSet)
            else { continue }
            if result[cwd] == nil { result[cwd] = sid }
            if result.count == worktreePaths.count { break }
        }
        return result
    }

    /// Reads the full transcript and returns the most-mentioned candidate worktree path,
    /// counting both explicit `"cwd"` fields and raw path string occurrences in tool calls.
    /// Sessions that never record the worktree as cwd (e.g. cwd stays at main repo throughout)
    /// still reference the worktree path heavily in bash commands and file reads.
    private static func dominantWorktreeCWD(transcript: URL, prefix: String, candidates: Set<String>) -> String? {
        guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { return nil }
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Fast path: skip lines that can't reference any candidate path
            guard line.contains(prefix) else { continue }
            for candidate in candidates {
                // Count every occurrence of the worktree path in the raw line text —
                // covers both "cwd" fields and tool call command/path strings.
                var searchFrom = line.startIndex
                while let r = line.range(of: candidate, range: searchFrom..<line.endIndex) {
                    counts[candidate, default: 0] += 1
                    searchFrom = r.upperBound
                }
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
