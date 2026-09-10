import Foundation

public struct MemoryNode: Identifiable, Equatable, Hashable, Sendable {
    public let id: String       // filename, e.g. "hooks.md"
    public let title: String    // link label from MEMORY.md, or filename stem
    public let url: URL
    public let isRoot: Bool

    public init(id: String, title: String, url: URL, isRoot: Bool = false) {
        self.id = id; self.title = title; self.url = url; self.isRoot = isRoot
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
        let dir = Paths.memoryDir(projectSlug: projectSlug)
        let rootURL = dir.appending(path: "MEMORY.md")
        guard let rootText = try? String(contentsOf: rootURL, encoding: .utf8) else {
            return .empty
        }

        let rootID = "MEMORY.md"
        let rootNode = MemoryNode(id: rootID, title: "MEMORY.md", url: rootURL, isRoot: true)
        var nodes: [String: MemoryNode] = [rootID: rootNode]
        var edges: [MemoryEdge] = []

        // Parse links from MEMORY.md → topic nodes + root edges
        for (label, filename) in extractLinks(from: rootText) {
            let nodeID = filename
            let url = dir.appending(path: filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if nodes[nodeID] == nil {
                nodes[nodeID] = MemoryNode(id: nodeID, title: label, url: url)
            }
            edges.append(MemoryEdge(from: rootID, to: nodeID))
        }

        // Parse cross-links within each topic file
        for (nodeID, node) in nodes where !node.isRoot {
            guard let text = try? String(contentsOf: node.url, encoding: .utf8) else { continue }
            for (_, filename) in extractLinks(from: text) {
                guard filename != rootID else { continue }
                let url = dir.appending(path: filename)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if nodes[filename] == nil {
                    let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                    nodes[filename] = MemoryNode(id: filename, title: stem, url: url)
                }
                let alreadyExists = edges.contains { $0.from == nodeID && $0.to == filename }
                if !alreadyExists {
                    edges.append(MemoryEdge(from: nodeID, to: filename))
                }
            }
        }

        return MemoryGraph(nodes: Array(nodes.values), edges: edges)
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
