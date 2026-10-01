import Foundation

public struct SessionScanner {
    public static let activeWindow: TimeInterval = 60

    private let projectsRoot: URL
    private let now: Date
    private let groupStore: GroupStore
    private let summaryStore: SummaryStore

    public init(projectsRoot: URL = Paths.projectsRoot, now: Date = Date(),
                groupStore: GroupStore = .shared, summaryStore: SummaryStore = .shared) {
        self.projectsRoot = projectsRoot
        self.now = now
        self.groupStore = groupStore
        self.summaryStore = summaryStore
    }

    /// The sessions plus the group files they were stamped from, keyed by `SessionSummary.groupKey`.
    public struct Listing {
        public var sessions: [SessionSummary]
        public var groups: [String: ProjectGroups]
    }

    /// If activePath is set, list only that project's sessions; otherwise all projects.
    public func list(activePath: URL?) -> [SessionSummary] { listing(activePath: activePath).sessions }

    public func listing(activePath: URL?) -> Listing {
        let fm = FileManager.default
        let projectDirs: [URL]
        if let base = activePath {
            projectDirs = ProjectFolders.folders(for: base, in: projectsRoot)
        } else {
            projectDirs = (try? fm.contentsOfDirectory(at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        // With a project open, every listed session belongs to it — worktree checkouts and
        // subdirectories included — so all of them share its group file. Keying by each session's
        // own folder (the old rule) gave worktree sessions a group file the Groups tab never read.
        let projectKey = activePath.map { Self.storageKey(forPath: ProjectFolders.normalizedPath($0)) }

        var out: [SessionSummary] = []
        var seen = Set<String>()
        for dir in projectDirs {
            let slug = dir.lastPathComponent
            let files = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                seen.insert(file.path)
                guard var summary = summarize(file, slug: slug) else { continue }
                summary.groupKey = projectKey ?? summary.cwd.map {
                    Self.storageKey(forPath: ProjectFolders.ownerPath(ofCwd: $0))
                } ?? ProjectFolders.ownerSlug(ofFolder: slug)
                out.append(summary)
            }
        }
        Self.cache.prune(under: projectsRoot.path, keeping: seen, scopedTo: activePath == nil ? nil : projectDirs.map(\.path))

        // Stamp groupID from GroupStore — one load per group file. An assignment naming a group
        // that no longer exists reads as ungrouped rather than hiding the session.
        var groups: [String: ProjectGroups] = [:]
        for key in Set(out.map(\.groupKey)) { groups[key] = groupStore.load(projectSlug: key) }
        if let projectKey, groups[projectKey] == nil { groups[projectKey] = groupStore.load(projectSlug: projectKey) }
        for i in out.indices {
            out[i].groupID = groups[out[i].groupKey]?.validGroupID(for: out[i].id)
        }
        // Stamp bulletSummary from SummaryStore — one load per session folder
        var psBySlug: [String: ProjectSummaries] = [:]
        for slug in Set(out.map(\.projectSlug)) {
            psBySlug[slug] = summaryStore.loadAll(projectSlug: slug)
        }
        for i in out.indices {
            out[i].bulletSummary = psBySlug[out[i].projectSlug]?.summaries[out[i].id]
        }
        return Listing(sessions: out.sorted { $0.modifiedAt > $1.modifiedAt }, groups: groups)
    }

    /// The key the app stores per-project data under for a project path (`Paths.slug`'s rule).
    public static func storageKey(forPath path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    private func summarize(_ file: URL, slug: String) -> SessionSummary? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let fileSize = values?.fileSize ?? 0
        let sessionID = file.deletingPathExtension().lastPathComponent
        let head = Self.cache.head(for: file, modified: mtime, size: fileSize)

        // A transcript with no user record is a stub (see `SessionOpening.hasConversation`):
        // listing it gave a UUID-titled row that opened onto an empty transcript. One that only
        // ran local commands (`/model`, `/clear`) and never got a reply is the same nothing.
        guard head.opening.hasConversation, head.opening.isSettled || head.hasReply else { return nil }

        // Approximate turn count from file size: ~1200 bytes/turn median across sessions
        let turnCount = max(1, fileSize / 1200)
        // If ai-title belongs to a different session (stale after /clear), fall back to firstPrompt
        let titleIsStale = head.aiTitle != nil && head.aiTitleSessionID != nil && head.aiTitleSessionID != sessionID
        let title = SessionTitle.resolve(aiTitle: titleIsStale ? nil : head.aiTitle,
                                         opening: head.opening, fallback: sessionID)
        let isActive = now.timeIntervalSince(mtime) <= Self.activeWindow && now >= mtime
        let subagents = scanSubagents(sessionID: sessionID, slug: slug)
        var summary = SessionSummary(id: sessionID, fileURL: file, projectSlug: slug, title: title,
                                     modifiedAt: mtime, turnCount: turnCount, isActive: isActive,
                                     subagents: subagents)
        summary.fileSize = fileSize
        summary.cwd = head.opening.cwd
        summary.task = head.opening.task
        return summary
    }

    // MARK: - Head cache

    /// What the head of one transcript says.
    struct Head {
        var modified: Date
        var size: Int
        var aiTitle: String?
        var aiTitleSessionID: String?
        var opening: SessionOpening
        /// Claude answered at least once. Only looked for when the opening is commands alone.
        var hasReply = false
    }

    /// Each rescan used to spawn two `grep`s per transcript — every one, on every FileWatcher
    /// tick, ~9 s for 59 transcripts. Now a file is re-read only when its size or date changed,
    /// in process (`TranscriptLines`), and only the half that can still change: the first
    /// `ai-title` never moves once found, and a settled opening (a real prompt or a task phase)
    /// is final.
    static let cache = HeadCache()

    final class HeadCache: @unchecked Sendable {
        private var map: [String: Head] = [:]
        private let lock = NSLock()

        func head(for file: URL, modified: Date, size: Int) -> Head {
            lock.lock()
            let cached = map[file.path]
            lock.unlock()
            if let cached, cached.modified == modified, cached.size == size { return cached }

            var head = cached ?? Head(modified: modified, size: size, opening: SessionOpening())
            head.modified = modified
            head.size = size
            if head.aiTitle == nil, let t = SessionScanner.readAITitle(in: file) {
                head.aiTitle = t.title
                head.aiTitleSessionID = t.sessionId
            }
            if !head.opening.isSettled {
                head.opening = SessionScanner.readOpening(of: file)
            }
            if !head.opening.isSettled, !head.hasReply {
                head.hasReply = !TranscriptLines.first(1, containing: "\"type\":\"assistant\"", in: file).isEmpty
            }
            lock.lock()
            map[file.path] = head
            lock.unlock()
            return head
        }

        /// Forget transcripts that are gone, so the cache can't grow without bound. A scoped scan
        /// (one project's folders) only prunes inside those folders.
        func prune(under root: String, keeping seen: Set<String>, scopedTo folders: [String]?) {
            lock.lock(); defer { lock.unlock() }
            map = map.filter { path, _ in
                guard path.hasPrefix(root) else { return true }
                if let folders, !folders.contains(where: { path.hasPrefix($0 + "/") }) { return true }
                return seen.contains(path)
            }
        }
    }

    // MARK: - Reading the head

    private static func readAITitle(in file: URL) -> (title: String, sessionId: String?)? {
        guard let line = TranscriptLines.first(1, containing: "\"type\":\"ai-title\"", in: file).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let title = obj["aiTitle"] as? String else { return nil }
        return (title, obj["sessionId"] as? String)
    }

    /// The first user records (offset-independent — they sit past a metadata preamble too big
    /// for a fixed head read). A dozen, because a session opened with `/clear` → `/model` →
    /// `/goal …` spends six on command echoes and caveats before the one worth a title.
    static func readOpening(of file: URL) -> SessionOpening {
        SessionOpening.parse(userLines: TranscriptLines.first(12, containing: "\"type\":\"user\"", in: file))
    }

    private func scanSubagents(sessionID: String, slug: String) -> [SubagentSummary] {
        let fm = FileManager.default
        let subagentsDir = projectsRoot
            .appending(path: slug)
            .appending(path: sessionID)
            .appending(path: "subagents")
        guard fm.fileExists(atPath: subagentsDir.path) else { return [] }
        let metaFiles = (try? fm.contentsOfDirectory(at: subagentsDir,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var result: [SubagentSummary] = []
        for meta in metaFiles where meta.pathExtension == "json" {
            guard let data = try? Data(contentsOf: meta),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toolUseId = obj["toolUseId"] as? String else { continue }
            let agentType = obj["agentType"] as? String ?? "?"
            let description = obj["description"] as? String ?? agentType
            let spawnDepth = obj["spawnDepth"] as? Int ?? 1
            // agentId is the stem of the meta file: "agent-<id>.meta.json" → "agent-<id>"
            let agentFileStem = meta.deletingPathExtension().deletingPathExtension().lastPathComponent
            let agentID = agentFileStem.hasPrefix("agent-") ? String(agentFileStem.dropFirst(6)) : agentFileStem
            let jsonlURL = subagentsDir.appending(path: "\(agentFileStem).jsonl")
            guard fm.fileExists(atPath: jsonlURL.path) else { continue }
            result.append(SubagentSummary(id: agentID, toolUseId: toolUseId,
                                          agentType: agentType, description: description,
                                          spawnDepth: spawnDepth, fileURL: jsonlURL))
        }
        return result.sorted {
            let d0 = (try? $0.fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d1 = (try? $1.fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d0 < d1
        }
    }
}
