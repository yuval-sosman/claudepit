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
    ///
    /// Each transcript's mention counts come from `mentions` (a per-file cache): this runs on
    /// every worktree scan — every FileWatcher tick, and every 10 s while the Worktrees page
    /// shows — and reading every transcript whole each time cost ~6 s of CPU per scan on a
    /// 200 MB project, whenever one worktree had no transcript to settle it.
    private static func buildCWDMap(repoRoot: String, worktreePaths: [String]) -> [String: String] {
        guard !worktreePaths.isEmpty else { return [:] }
        let parentSlug = claudeSlug(for: repoRoot)
        let projectDir = Paths.globalClaude.appendingPathComponent("projects/\(parentSlug)")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return [:] }

        // A fresh listing, so these prefetched values are current (it is a URL kept across
        // listings that goes on answering with stale ones).
        let transcripts = files
            .filter { $0.pathExtension == "jsonl" }
            .map { url -> (url: URL, modified: Date, size: Int) in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }   // newest first — most likely to be the right session

        let wtSet = Set(worktreePaths)
        // Prefix all worktrees share — used to skip unrelated text fast.
        let wtPrefix = repoRoot + "/.claude/worktrees/"
        var result: [String: String] = [:]
        for t in transcripts {
            let counts = mentions.counts(in: t.url, size: t.size, modified: t.modified, prefix: wtPrefix)
            guard let cwd = dominant(counts, among: wtSet) else { continue }
            let sid = t.url.deletingPathExtension().lastPathComponent
            if result[cwd] == nil { result[cwd] = sid }
            if result.count == worktreePaths.count { break }
        }
        mentions.prune(inFolder: projectDir.path, keeping: Set(transcripts.map(\.url.path)))
        return result
    }

    /// The most-mentioned candidate worktree path, counting both explicit `"cwd"` fields and raw
    /// path occurrences in tool calls — sessions whose cwd stays at the main repo still reference
    /// the worktree heavily in bash commands and file reads. A tie names no one: a session that
    /// mentions several worktrees equally (a review across them) owns none of them — and picking
    /// one by dictionary order, as this once did, could change the owner from launch to launch.
    static func dominant(_ counts: [String: Int], among candidates: Set<String>) -> String? {
        let ranked = counts.filter { candidates.contains($0.key) && $0.value > 0 }
            .sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].value == top.value { return nil }
        return top.key
    }

    static let mentions = MentionCache()

    /// Per transcript: how often each worktree path (`<prefix><name>`) is mentioned, with how far
    /// the file has been read. An unchanged file costs nothing; a grown one — a live session's —
    /// is read only from where the last count stopped; a shorter one is recounted from the start.
    final class MentionCache: @unchecked Sendable {
        struct Entry {
            var prefix: String
            /// Bytes counted so far: always just past a newline, so a half-written line is
            /// counted once it is whole, never twice.
            var offset: Int
            var size: Int
            var modified: Date
            var counts: [String: Int]
        }
        private var map: [String: Entry] = [:]
        private let lock = NSLock()

        func counts(in file: URL, size: Int, modified: Date, prefix: String) -> [String: Int] {
            lock.lock()
            let cached = map[file.path]
            lock.unlock()
            if let cached, cached.prefix == prefix, cached.size == size, cached.modified == modified {
                return cached.counts
            }
            var entry = cached ?? Entry(prefix: prefix, offset: 0, size: 0, modified: .distantPast, counts: [:])
            if entry.prefix != prefix || size < entry.offset {
                entry = Entry(prefix: prefix, offset: 0, size: 0, modified: .distantPast, counts: [:])
            }
            if let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                if (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
                   let tail = try? handle.readToEnd(), !tail.isEmpty {
                    let whole = tail.lastIndex(of: UInt8(ascii: "\n")).map { tail.distance(from: tail.startIndex, to: $0) + 1 } ?? 0
                    if whole > 0 {
                        MentionCache.count(tail.prefix(whole), prefix: prefix, into: &entry.counts)
                        entry.offset += whole
                    }
                }
            }
            entry.size = size
            entry.modified = modified
            lock.lock()
            map[file.path] = entry
            lock.unlock()
            return entry.counts
        }

        /// Forget transcripts that are gone from `folder`, so the cache can't grow without bound.
        func prune(inFolder folder: String, keeping live: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            map = map.filter { path, _ in !path.hasPrefix(folder + "/") || live.contains(path) }
        }

        /// Adds one to `counts["<prefix><name>"]` for every `<prefix><name>` in `bytes`, where the
        /// name is the next path component. Byte search (`memmem`): a transcript runs to tens of MB.
        static func count(_ bytes: Data, prefix: String, into counts: inout [String: Int]) {
            let needle = Array(prefix.utf8)
            guard !needle.isEmpty else { return }
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let end = base + raw.count
                var cursor = base
                while cursor < end,
                      let hit = memmem(cursor, end - cursor, needle, needle.count) {
                    var p = hit + needle.count
                    let nameStart = p
                    while p < end, isNameByte(p.load(as: UInt8.self)) { p += 1 }
                    var nameEnd = p
                    // "…/worktrees/foo." at the end of a sentence names foo.
                    while nameEnd > nameStart, (nameEnd - 1).load(as: UInt8.self) == UInt8(ascii: ".") { nameEnd -= 1 }
                    if nameEnd > nameStart {
                        let name = String(decoding: UnsafeRawBufferPointer(start: nameStart, count: nameEnd - nameStart), as: UTF8.self)
                        counts[prefix + name, default: 0] += 1
                    }
                    cursor = max(p, hit + 1)
                }
            }
        }

        private static func isNameByte(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b == UInt8(ascii: ".") || b == UInt8(ascii: "+")
                || b >= 0x80   // UTF-8 continuation of a non-ASCII name
        }
    }
}
