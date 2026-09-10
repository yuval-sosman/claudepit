import Foundation

/// Read-only git reader for a single worktree. Fetched lazily on card expand;
/// never mutates git state. Parsers are pure and unit-tested; the async
/// readers shell out to `git -C <dir> …` and return "" / [] / nil on any failure.
public struct ChangedFile: Sendable, Identifiable {
    public enum Change: String, Sendable { case modified, added, deleted, renamed, untracked }
    public var id: String { path }
    public let change: Change
    public let path: String
    public init(change: Change, path: String) { self.change = change; self.path = path }
}

public struct CommitInfo: Sendable {
    public let shortHash: String
    public let author: String
    public let relativeDate: String
    public let subject: String
    public let body: String
    public init(shortHash: String, author: String, relativeDate: String, subject: String, body: String) {
        self.shortHash = shortHash; self.author = author; self.relativeDate = relativeDate
        self.subject = subject; self.body = body
    }
}

public struct RecentCommit: Sendable, Identifiable {
    public var id: String { fullHash }
    public let fullHash: String
    public let shortHash: String
    public let relativeDate: String   // human-readable, e.g. "2 hours ago"
    public let subject: String
    public init(fullHash: String, shortHash: String, relativeDate: String, subject: String) {
        self.fullHash = fullHash; self.shortHash = shortHash
        self.relativeDate = relativeDate; self.subject = subject
    }
}

public enum WorktreeInspector {

    // MARK: - Pure parsers

    /// Parse `git status --porcelain -z`. Records are NUL-separated; each is
    /// a 2-char status "XY", a space, then the path. A rename/copy (R/C) is
    /// followed by a SECOND NUL-terminated field (the old path) which we skip.
    static func parsePorcelainZ(_ raw: String) -> [ChangedFile] {
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var out: [ChangedFile] = []
        var i = 0
        while i < fields.count {
            let rec = fields[i]
            guard rec.count >= 3 else { i += 1; continue }
            let x = rec[rec.startIndex]
            let y = rec[rec.index(rec.startIndex, offsetBy: 1)]
            let path = String(rec[rec.index(rec.startIndex, offsetBy: 3)...])
            let change: ChangedFile.Change
            if x == "?" && y == "?" {
                change = .untracked
            } else if x == "R" || y == "R" || x == "C" || y == "C" {
                change = .renamed
                i += 1   // consume the old-path field
            } else if x == "A" || y == "A" {
                change = .added
            } else if x == "D" || y == "D" {
                change = .deleted
            } else {
                change = .modified
            }
            out.append(ChangedFile(change: change, path: path))
            i += 1
        }
        return out
    }

    /// Parse `git show -s --format=%h%n%an%n%ar%n%s%n%b HEAD`.
    static func parseShow(_ raw: String) -> CommitInfo? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.count >= 4 else { return nil }
        let body = lines.count > 4
            ? lines[4...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return CommitInfo(shortHash: lines[0], author: lines[1],
                          relativeDate: lines[2], subject: lines[3], body: body)
    }

    /// Parse `git log --format=%H%x00%h%x00%ar%x00%s` (records newline-separated,
    /// fields NUL-separated).
    static func parseLog(_ raw: String) -> [RecentCommit] {
        raw.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                let f = line.components(separatedBy: "\0")
                guard f.count >= 4 else { return nil }
                return RecentCommit(fullHash: f[0], shortHash: f[1], relativeDate: f[2], subject: f[3])
            }
    }

    // MARK: - Async git readers (read-only)

    public static func changedFiles(at dir: String) async -> [ChangedFile] {
        parsePorcelainZ(await git(["status", "--porcelain", "-z"], at: dir))
    }
    public static func commitInfo(at dir: String) async -> CommitInfo? {
        parseShow(await git(["show", "-s", "--format=%h%n%an%n%ar%n%s%n%b", "HEAD"], at: dir))
    }
    public static func recentCommits(at dir: String, limit: Int = 5) async -> [RecentCommit] {
        parseLog(await git(["log", "--format=%H%x00%h%x00%ar%x00%s", "-\(limit)"], at: dir))
    }
    public static func diff(at dir: String, path: String, untracked: Bool = false) async -> String {
        if untracked {
            // git diff --no-index exits 1 when differences exist (always for new files),
            // so we can't use the git() helper that discards non-zero output.
            // Read the file directly and synthesize a unified diff instead.
            let fullPath = (dir as NSString).appendingPathComponent(path)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return "" }
            let lines = content.components(separatedBy: "\n")
            let body = lines.map { "+\($0)" }.joined(separator: "\n")
            return "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n\(body)\n"
        }
        return await git(["diff", "--", path], at: dir)
    }

    /// Web base URL for the `origin` remote (github/gitlab/bitbucket over ssh or https),
    /// e.g. `https://github.com/owner/repo`. nil if no remote or an unrecognized host.
    /// Append `/commit/<hash>` for a commit link.
    public static func remoteWebURL(at dir: String) async -> String? {
        webURL(fromRemote: await git(["remote", "get-url", "origin"], at: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Pure: convert a git remote URL to an https web base URL. Handles
    /// `git@host:owner/repo.git`, `ssh://git@host/owner/repo.git`, and
    /// `https://host/owner/repo(.git)`.
    static func webURL(fromRemote remote: String) -> String? {
        guard !remote.isEmpty else { return nil }
        var host = "", path = ""
        if remote.hasPrefix("git@") {
            // git@github.com:owner/repo.git
            let body = remote.dropFirst("git@".count)
            guard let colon = body.firstIndex(of: ":") else { return nil }
            host = String(body[..<colon]); path = String(body[body.index(after: colon)...])
        } else if let range = remote.range(of: "://") {
            // scheme://[user@]host/owner/repo.git
            var rest = String(remote[range.upperBound...])
            if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash]); path = String(rest[rest.index(after: slash)...])
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return "https://\(host)/\(path)"
    }

    /// Run a read-only git command in `dir`. Returns "" on any failure.
    private static func git(_ args: [String], at dir: String) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = ["git", "-C", dir] + args
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? (String(data: data, encoding: .utf8) ?? "") : "")
            }
        }
    }
}
