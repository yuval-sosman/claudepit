import Foundation

/// Per-project free-text task topics — a plain `[String]` at ~/.claude/claudepit-task-topics/<slug>.json.
/// Seeds the New Task "Topic" combo box. Mirrors GroupStore's atomic write pattern.
public struct TopicStore: Sendable {
    private let root: URL

    public static let shared = TopicStore(root: Paths.topicsRoot)

    public init(root: URL) { self.root = root }

    public func load(projectSlug: String) -> [String] {
        let file = root.appending(path: "\(projectSlug).json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    public func save(_ topics: [String], projectSlug: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appending(path: "\(projectSlug).json")
        let tmp  = root.appending(path: "\(projectSlug).json.tmp")
        let data = try JSONEncoder().encode(topics)
        try data.write(to: tmp, options: .atomic)
        _ = try? fm.replaceItemAt(dest, withItemAt: tmp)
    }

    public func add(_ topic: String, projectSlug: String) throws {
        let t = topic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var list = load(projectSlug: projectSlug)
        guard !list.contains(t) else { return }
        list.append(t)
        try save(list, projectSlug: projectSlug)
    }
}
