import Foundation

/// Which `~/.claude/projects/<slug>` folders hold a project's transcripts, and which project a
/// folder belongs to. `SessionScanner` and `ProjectUsageScanner` both ask here, so the Sessions
/// list and the usage numbers always count the same set.
///
/// Claude Code names a folder after the session's cwd with `/`, `.` and `+` turned into `-`, so a
/// slug *prefix* is ambiguous: `-Dev-app-` starts the project's own subdirectories
/// (`/Dev/app/Sources`), its worktrees (`/Dev/app/.claude/worktrees/x`) **and** an unrelated
/// sibling (`/Dev/app-v2`, `/Dev/app.old`). Matching on the prefix alone listed the sibling's
/// sessions as this project's — and with `~` open, every project on the machine. Worktree folders
/// are recognised by their `--claude-worktrees-` infix; any other prefixed folder is settled by
/// the `cwd` its transcripts record.
public enum ProjectFolders {
    /// `/.claude/worktrees/` as it appears inside a folder name.
    public static let worktreeInfix = "--claude-worktrees-"

    /// `base`'s path without a trailing slash (an open-panel folder URL ends in one).
    public static func normalizedPath(_ base: URL) -> String {
        var path = base.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Every folder name Claude Code may have used for `base`: its own (`/ . +` → `-`, the rule
    /// `WorktreeScanner.claudeSlug` and the hooks follow) and `Paths.slug`'s `/`-only form, which
    /// is what the app keys its own storage by. They differ only for a path holding `.` or `+` —
    /// for which the `/`-only form alone found no sessions at all.
    public static func candidateSlugs(for base: URL) -> [String] {
        let path = normalizedPath(base)
        let claude = WorktreeScanner.claudeSlug(for: path)
        let plain = path.replacingOccurrences(of: "/", with: "-")
        return claude == plain ? [claude] : [claude, plain]
    }

    /// The folders holding `base`'s transcripts: its own, its worktrees', and its
    /// subdirectories' — never a sibling's whose name merely extends it.
    /// `cwdOf` reads the cwd a folder's transcripts record; injectable for tests.
    public static func folders(for base: URL, in projectsRoot: URL,
                               cwdOf: (URL) -> String? = recordedCwd(inFolder:)) -> [URL] {
        let basePath = normalizedPath(base)
        let slugs = candidateSlugs(for: base)
        let all = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return all.filter { dir in
            let name = dir.lastPathComponent
            for slug in slugs {
                if name == slug || name.hasPrefix(slug + worktreeInfix) { return true }
                guard name.hasPrefix(slug + "-") else { continue }
                return verdict(for: dir, basePath: basePath, cwdOf: cwdOf)
            }
            return false
        }
    }

    /// The project path a session ran for: a worktree checkout (`<p>/.claude/worktrees/<name>…`)
    /// belongs to `<p>`; anything else is its own project.
    public static func ownerPath(ofCwd cwd: String, knownProjects: [String] = []) -> String {
        if let known = knownProjects.filter({ cwd == $0 || cwd.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return known
        }
        if let r = cwd.range(of: "/.claude/worktrees/") { return String(cwd[..<r.lowerBound]) }
        return cwd
    }

    /// The same fold for a bare folder name, when no cwd is known.
    public static func ownerSlug(ofFolder slug: String) -> String {
        if let r = slug.range(of: worktreeInfix) { return String(slug[..<r.lowerBound]) }
        return slug
    }

    // MARK: - cwd verification

    /// A folder's verdict never changes (its name is derived from one cwd), so it is decided once.
    private static let verdicts = VerdictCache()

    private static func verdict(for dir: URL, basePath: String, cwdOf: (URL) -> String?) -> Bool {
        let key = basePath + "\u{0}" + dir.path
        if let known = verdicts.get(key) { return known }
        // No transcript records a cwd yet (an empty folder): leave it out, but ask again next scan.
        guard let cwd = cwdOf(dir) else { return false }
        let inside = cwd == basePath || cwd.hasPrefix(basePath + "/")
        verdicts.set(key, inside)
        return inside
    }

    /// The `cwd` the folder's newest transcripts record.
    public static func recordedCwd(inFolder dir: URL) -> String? {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for file in files.prefix(3) {
            for line in TranscriptLines.first(3, containing: "\"cwd\":\"", in: file) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
                return cwd
            }
        }
        return nil
    }

    private final class VerdictCache: @unchecked Sendable {
        private var map: [String: Bool] = [:]
        private let lock = NSLock()
        func get(_ k: String) -> Bool? { lock.lock(); defer { lock.unlock() }; return map[k] }
        func set(_ k: String, _ v: Bool) { lock.lock(); map[k] = v; lock.unlock() }
    }
}
