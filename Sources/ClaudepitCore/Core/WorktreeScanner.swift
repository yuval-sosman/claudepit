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
    public struct RawScan: Sendable {
        public let parsed: [ParsedWorktree]
        public let dirty: [String: Int]
        public let ahead: [String: Int]
        /// Fallback binding: worktree path → session ID, populated by scanning
        /// transcripts in the parent repo's project dir for a matching `cwd` field.
        public let cwdMap: [String: String]
        public init(parsed: [ParsedWorktree], dirty: [String: Int], ahead: [String: Int],
                    cwdMap: [String: String] = [:]) {
            self.parsed = parsed; self.dirty = dirty; self.ahead = ahead; self.cwdMap = cwdMap
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
    public static func merge(parsed: [ParsedWorktree],
                             dirty: [String: Int],
                             ahead: [String: Int],
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

extension WorktreeScanner {
    /// Runs a git command in `dir`, returns stdout (trimmed) or nil on non-zero exit / launch failure.
    private static func git(_ args: [String], dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read-only git scan of the active project's worktrees. Returns only Sendable data
    /// (safe to compute off the main actor); merge with sessions via `merge(...)`.
    /// Returns nil if activePath is nil, git is absent, or the path is not a git repo.
    public func scanRaw(activePath: URL?) -> RawScan? {
        guard let root = activePath?.path else { return nil }
        guard let top = Self.git(["rev-parse", "--show-toplevel"], dir: root), !top.isEmpty
        else { return nil }
        guard let listing = Self.git(["worktree", "list", "--porcelain"], dir: top) else { return nil }
        let parsed = Self.parsePorcelain(listing, repoRoot: top)

        var dirty: [String: Int] = [:], ahead: [String: Int] = [:]
        for wt in parsed {
            if let status = Self.git(["status", "--porcelain"], dir: wt.path) {
                dirty[wt.path] = status.isEmpty ? 0 : status.split(separator: "\n").count
            }
            if let cnt = Self.git(["rev-list", "--count", "@{upstream}..HEAD"], dir: wt.path),
               let n = Int(cnt) { ahead[wt.path] = n }
        }

        // Build cwd fallback map: scan transcripts in the parent repo's project dir.
        let cwdMap = Self.buildCWDMap(repoRoot: top, worktreePaths: parsed.map { $0.path })
        return RawScan(parsed: parsed, dirty: dirty, ahead: ahead, cwdMap: cwdMap)
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

    /// Convenience: full scan + merge in one call. Returns [] if not a git repo.
    public func scan(activePath: URL?, sessions: [SessionSummary]) -> [WorktreeInfo] {
        guard let raw = scanRaw(activePath: activePath) else { return [] }
        return Self.merge(parsed: raw.parsed, dirty: raw.dirty, ahead: raw.ahead,
                          sessions: sessions, cwdMap: raw.cwdMap)
    }
}
