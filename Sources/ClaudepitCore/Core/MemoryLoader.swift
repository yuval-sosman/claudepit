import Foundation

public struct MemoryNode: Identifiable, Equatable, Hashable, Sendable {
    public let id: String       // path relative to the memory dir, e.g. "hooks.md"
    public let title: String    // link label from MEMORY.md, or filename stem
    public let url: URL
    public let isRoot: Bool
    /// The body's size, measured at load so a list can flag an over-limit file without reading
    /// it. Nil when the file couldn't be read.
    public let size: MemoryReadLimit.Size?
    /// The frontmatter's `description`, else the body's first line of prose.
    public let description: String?
    /// The file's modification date on disk.
    public let modifiedAt: Date?
    /// The file sits in the memory directory but nothing links to it — not MEMORY.md, not another
    /// topic file. Claude finds topic files through the index, so it may never read this one.
    public let isOrphan: Bool
    /// The body after the frontmatter block — for search, and for asking about every file at once.
    public let body: String

    public init(id: String, title: String, url: URL, isRoot: Bool = false,
                size: MemoryReadLimit.Size? = nil, description: String? = nil,
                modifiedAt: Date? = nil, isOrphan: Bool = false, body: String = "") {
        self.id = id; self.title = title; self.url = url; self.isRoot = isRoot; self.size = size
        self.description = description; self.modifiedAt = modifiedAt; self.isOrphan = isOrphan
        self.body = body
    }

    /// Claude stops reading this file before its end (see `MemoryReadLimit`).
    public var exceedsReadLimit: Bool { size?.exceedsLimit ?? false }

    /// The name a list shows: the index is always "MEMORY.md".
    public var displayTitle: String { isRoot ? "MEMORY.md" : title }

    /// Every word of `query` appears in the title, the filename, the description or the body.
    public func matches(_ query: String) -> Bool {
        SearchText.matches([title, id, description ?? "", body], query: query)
    }
}

public struct MemoryEdge: Sendable, Equatable {
    public let from: String
    public let to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct MemoryGraph: Sendable, Equatable {
    public let nodes: [MemoryNode]
    public let edges: [MemoryEdge]
    public static let empty = MemoryGraph(nodes: [], edges: [])
    public init(nodes: [MemoryNode], edges: [MemoryEdge]) { self.nodes = nodes; self.edges = edges }
}

public struct MemoryLoader {
    // Matches [label](filename.md) — captures label and filename
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+\.md)\)"#)

    public static func load(projectSlug: String) -> MemoryGraph {
        load(dir: Paths.memoryDir(projectSlug: projectSlug))
    }

    /// `dir` is injectable so checks run against a temp directory, never the real ~/.claude.
    ///
    /// Nodes are MEMORY.md and everything its links reach (followed to any depth), plus — flagged
    /// `isOrphan` — every other `.md` file in the directory. A topic keeps the label MEMORY.md
    /// gives it; a file only other topics link to is titled by its filename.
    public static func load(dir: URL) -> MemoryGraph {
        let rootID = "MEMORY.md"
        let rootURL = dir.appending(path: rootID)
        var nodes: [String: MemoryNode] = [:]
        var edges: [MemoryEdge] = []
        var reachable: Set<String> = []
        func link(_ from: String, _ to: String) {
            if !edges.contains(where: { $0.from == from && $0.to == to }) { edges.append(MemoryEdge(from: from, to: to)) }
        }
        func stem(_ id: String) -> String { URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent }

        // Breadth-first from the index, so every link MEMORY.md makes is labelled before a topic's
        // own links can name the same file by its stem.
        if let rootText = try? String(contentsOf: rootURL, encoding: .utf8) {
            nodes[rootID] = MemoryNode(id: rootID, title: rootID, url: rootURL, isRoot: true)
            reachable.insert(rootID)
            var queue: [(id: String, text: String)] = [(rootID, rootText)]
            while !queue.isEmpty {
                let (from, text) = queue.removeFirst()
                for (label, target) in extractLinks(from: text) where target != rootID && target != from {
                    let url = dir.appending(path: target)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    if nodes[target] == nil {
                        nodes[target] = MemoryNode(id: target, title: from == rootID ? label : stem(target), url: url)
                        reachable.insert(target)
                        if let t = try? String(contentsOf: url, encoding: .utf8) { queue.append((target, t)) }
                    }
                    link(from, target)
                }
            }
        }

        // Files no link from the index reaches. Their own links still draw, so an orphan that
        // points at a topic shows where it belongs.
        let orphans = markdownFiles(in: dir).filter { nodes[$0] == nil && $0 != rootID }
        for id in orphans { nodes[id] = MemoryNode(id: id, title: stem(id), url: dir.appending(path: id)) }
        for id in orphans {
            guard let text = try? String(contentsOf: dir.appending(path: id), encoding: .utf8) else { continue }
            for (_, target) in extractLinks(from: text) where target != rootID && target != id && nodes[target] != nil {
                link(id, target)
            }
        }

        let measured = nodes.values.map { node -> MemoryNode in
            let modified = (try? FileManager.default.attributesOfItem(atPath: node.url.path))?[.modificationDate] as? Date
            let orphan = !reachable.contains(node.id)
            guard let raw = try? String(contentsOf: node.url, encoding: .utf8) else {
                return MemoryNode(id: node.id, title: node.title, url: node.url, isRoot: node.isRoot,
                                  modifiedAt: modified, isOrphan: orphan)
            }
            let (frontmatter, body) = MemoryFrontmatter.parse(from: raw)
            let described = frontmatter?.description.flatMap { $0.isEmpty ? nil : $0 }
            return MemoryNode(id: node.id, title: node.title, url: node.url, isRoot: node.isRoot,
                              size: MemoryReadLimit.size(of: body),
                              description: node.isRoot ? nil : (described ?? MarkdownOutline.summary(of: body, limit: 160)),
                              modifiedAt: modified, isOrphan: orphan, body: body)
        }
        return MemoryGraph(nodes: measured, edges: edges)
    }

    /// Every `.md` file under `dir`, as a path relative to it (hidden files skipped).
    private static func markdownFiles(in dir: URL) -> [String] {
        let base = dir.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where url.pathExtension == "md" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            out.append(String(path.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    private static func extractLinks(from text: String) -> [(label: String, filename: String)] {
        let ns = text as NSString
        let matches = linkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard m.numberOfRanges == 3 else { return nil }
            let label = ns.substring(with: m.range(at: 1))
            let filename = (ns.substring(with: m.range(at: 2)) as String)
                .hasPrefix("./") ? String(ns.substring(with: m.range(at: 2)).dropFirst(2)) : ns.substring(with: m.range(at: 2))
            return (label, filename)
        }
    }
}

// MARK: - Frontmatter

public struct MemoryFrontmatter: Sendable {
    public let name: String?
    public let description: String?
    public let type: String?
    public let originSessionId: String?
    public let sessions: [String]
    public let modified: Date?

    /// Parses the YAML frontmatter block at the start of `raw`.
    /// Returns the parsed struct and the body with the frontmatter block stripped.
    public static func parse(from raw: String) -> (frontmatter: MemoryFrontmatter?, body: String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, raw)
        }
        var closeIdx: Int? = nil
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIdx = i; break
            }
        }
        guard let end = closeIdx else { return (nil, raw) }

        let fmLines = Array(lines[1..<end])
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
            .trimmingCharacters(in: .newlines)

        func value(for key: String) -> String? {
            for line in fmLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let prefix = key + ":"
                if trimmed.hasPrefix(prefix) {
                    return trimmed.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
            return nil
        }

        // sessions: [id1, id2, ...]
        var sessionIDs: [String] = []
        if let raw = value(for: "sessions") {
            let inner = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            sessionIDs = inner.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        var modified: Date? = nil
        if let modStr = value(for: "modified") {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            modified = fmt.date(from: modStr) ?? ISO8601DateFormatter().date(from: modStr)
        }

        return (MemoryFrontmatter(
            name: value(for: "name"),
            description: value(for: "description"),
            type: value(for: "type"),
            originSessionId: value(for: "originSessionId"),
            sessions: sessionIDs,
            modified: modified
        ), body)
    }
}
