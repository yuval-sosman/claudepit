import Foundation

/// Reads a project's transcripts into `TranscriptDigest`s — its own folder under
/// `~/.claude/projects` plus every folder whose slug extends it (the project's
/// `.claude/worktrees/…` checkouts, where task agents run), the same set `SessionScanner` lists.
///
/// Parsing is the whole cost (≈0.7 s for 100 MB), so each file's digest is kept by path and
/// reused while its size and modification date are unchanged: a refresh while an agent works
/// re-reads only the transcripts it is appending to. Call from a background task, never from a
/// view body — it touches the filesystem.
public final class ProjectUsageScanner: @unchecked Sendable {
    private struct Entry {
        let modified: Date
        let size: Int
        let digest: TranscriptDigest
    }

    private let projectsRoot: URL
    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    public init(projectsRoot: URL = Paths.projectsRoot) {
        self.projectsRoot = projectsRoot
    }

    /// The merged digest of every transcript touched on or after `since` (with a day's slack,
    /// since a record can be older than the write that appended it). `base == nil` reads every
    /// project on the machine.
    public func digest(for base: URL?, since: Date) -> TranscriptDigest {
        let cutoff = since.addingTimeInterval(-86_400)
        var digests: [TranscriptDigest] = []
        var seen = Set<String>()
        for file in transcripts(for: base) {
            guard let values = try? file.url.resourceValues(
                      forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            let size = values.fileSize ?? 0
            let path = file.url.path
            seen.insert(path)
            lock.lock()
            let cached = cache[path]
            lock.unlock()
            if let cached, cached.modified == modified, cached.size == size {
                digests.append(cached.digest)
                continue
            }
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { continue }
            let digest = TranscriptDigest.parse(data, isSubagent: file.isSubagent,
                                                inWorktree: file.inWorktree, project: file.project)
            lock.lock()
            cache[path] = Entry(modified: modified, size: size, digest: digest)
            lock.unlock()
            digests.append(digest)
        }
        // Drop what this project no longer has (deleted sessions, removed worktrees) so the
        // cache can't grow without bound across a long-running app.
        // Only inside the folders this scan read: a slug-prefix sweep also evicted sibling
        // projects' digests (cached by Home's all-projects scan), re-parsed on the next switch.
        let scanned = base.map { ProjectFolders.folders(for: $0, in: projectsRoot).map(\.path) }
        lock.lock()
        cache = cache.filter { path, _ in
            if seen.contains(path) { return true }
            guard let scanned else { return !path.hasPrefix(projectsRoot.path) }
            return !scanned.contains { path.hasPrefix($0 + "/") }
        }
        lock.unlock()
        return TranscriptDigest.merged(digests)
    }

    /// `Paths.slug` of `base` without a trailing slash: a folder URL from an open panel ends in
    /// one, and its slug would then end in `-`, matching the worktrees but not the checkout.
    static func slug(_ base: URL) -> String {
        Paths.slug(for: URL(filePath: base.path, directoryHint: .notDirectory))
    }

    struct Transcript {
        let url: URL
        let isSubagent: Bool
        let inWorktree: Bool
        /// The project folder's name (its slug).
        let project: String
    }

    /// `<dir>/*.jsonl` (main sessions) and `<dir>/<session>/subagents/*.jsonl` for each of the
    /// project's folders, or of every folder when `base` is nil.
    func transcripts(for base: URL?) -> [Transcript] {
        let fm = FileManager.default
        // The same folders `SessionScanner` lists (`ProjectFolders`): the project's own, its
        // worktrees' and subdirectories' — not a sibling whose name merely extends the slug.
        let dirs = base.map { ProjectFolders.folders(for: $0, in: projectsRoot) }
            ?? ((try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles])) ?? [])
        var out: [Transcript] = []
        for dir in dirs {
            let project = dir.lastPathComponent
            let inWorktree = project.contains("--claude-worktrees-")
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                if entry.pathExtension == "jsonl" {
                    out.append(Transcript(url: entry, isSubagent: false, inWorktree: inWorktree, project: project))
                    continue
                }
                let subagents = entry.appending(path: "subagents")
                let files = (try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    out.append(Transcript(url: file, isSubagent: true, inWorktree: inWorktree, project: project))
                }
            }
        }
        return out
    }
}
