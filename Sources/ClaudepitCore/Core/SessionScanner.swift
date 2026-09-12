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

    /// If activePath is set, list only that project's sessions; otherwise all projects.
    public func list(activePath: URL?) -> [SessionSummary] {
        let fm = FileManager.default
        let projectDirs: [URL]
        if let base = activePath {
            let prefix = Paths.slug(for: base)
            let all = (try? fm.contentsOfDirectory(at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            projectDirs = all.filter {
                let slug = $0.lastPathComponent
                return slug == prefix || slug.hasPrefix(prefix + "-")
            }
        } else {
            projectDirs = (try? fm.contentsOfDirectory(at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }

        var out: [SessionSummary] = []
        for dir in projectDirs {
            let slug = dir.lastPathComponent
            let files = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let summary = summarize(file, slug: slug) else { continue }
                out.append(summary)
            }
        }
        // Stamp groupID from GroupStore — one load per project slug
        let slugs = Set(out.map(\.projectSlug))
        var pgBySlug: [String: ProjectGroups] = [:]
        for slug in slugs {
            pgBySlug[slug] = groupStore.load(projectSlug: slug)
        }
        for i in out.indices {
            out[i].groupID = pgBySlug[out[i].projectSlug]?.assignments[out[i].id]
        }
        // Stamp bulletSummary from SummaryStore — one load per project slug
        var psBySlug: [String: ProjectSummaries] = [:]
        for slug in slugs {
            psBySlug[slug] = summaryStore.loadAll(projectSlug: slug)
        }
        for i in out.indices {
            out[i].bulletSummary = psBySlug[out[i].projectSlug]?.summaries[out[i].id]
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func summarize(_ file: URL, slug: String) -> SessionSummary? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: file.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let fileSize = (attrs?[.size] as? Int) ?? 0

        // ponytail: grep -m1 for both ai-title and the first user prompt — the first user record
        // now sits past a growing metadata preamble (last-prompt/mode/permission-mode + context),
        // so a fixed head-read window missed it (session showed as a bare UUID). grep stops at the
        // first match, fast on any file size, and doesn't care where the record lands.
        var aiTitle: String?
        var aiTitleSessionId: String?
        let firstPrompt = Self.grepFirstUserPrompt(in: file)

        // grep -m 1 stops at first match — fast regardless of file size
        let grepResult = Self.grepFirstAiTitle(in: file)
        aiTitle = grepResult?.title
        aiTitleSessionId = grepResult?.sessionId
        // Approximate turn count from file size: ~1200 bytes/turn median across sessions
        let turnCount = max(1, fileSize / 1200)
        let sessionID = file.deletingPathExtension().lastPathComponent
        // If ai-title belongs to a different session (stale after /clear), fall back to firstPrompt
        let titleIsStale = aiTitle != nil && aiTitleSessionId != nil && aiTitleSessionId != sessionID
        let title = (titleIsStale ? nil : aiTitle) ?? firstPrompt ?? file.deletingPathExtension().lastPathComponent
        let isActive = now.timeIntervalSince(mtime) <= Self.activeWindow && now >= mtime
        let subagents = scanSubagents(sessionID: sessionID, slug: slug)
        return SessionSummary(id: sessionID, fileURL: file, projectSlug: slug, title: title,
                              modifiedAt: mtime, turnCount: turnCount, isActive: isActive,
                              subagents: subagents)
    }

    private static func grepFirstAiTitle(in file: URL) -> (title: String, sessionId: String?)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-m", "1", "\"type\":\"ai-title\"", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let title = obj["aiTitle"] as? String else { return nil }
        return (title, obj["sessionId"] as? String)
    }

    /// First real user prompt, via `grep '"type":"user"'` (offset-independent — the record now sits
    /// past a metadata preamble too big for a head read). Scans the first few user lines rather than
    /// just one, since a leading user record can be a tool_result with no text block.
    private static func grepFirstUserPrompt(in file: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-m", "5", "\"type\":\"user\"", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let m = obj["message"] as? [String: Any] else { continue }
            let text: String?
            if let c = m["content"] as? String {
                text = c
            } else if let blocks = m["content"] as? [[String: Any]] {
                text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
            } else { text = nil }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("{") {
                return t
            }
        }
        return nil
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
