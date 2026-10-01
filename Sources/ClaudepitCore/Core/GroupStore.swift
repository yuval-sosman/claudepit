import Foundation

public struct GroupStore: Sendable {
    private let root: URL

    public static let shared = GroupStore(root: Paths.groupsRoot)

    public init(root: URL) {
        self.root = root
    }

    public func load(projectSlug: String) -> ProjectGroups {
        let file = root.appending(path: "\(projectSlug).json")
        guard let data = try? Data(contentsOf: file),
              let pg = try? JSONDecoder().decode(ProjectGroups.self, from: data)
        else { return .empty }
        return pg
    }

    public func save(_ groups: ProjectGroups, projectSlug: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appending(path: "\(projectSlug).json")
        let tmp  = root.appending(path: "\(projectSlug).json.tmp")
        let data = try JSONEncoder().encode(groups)
        try data.write(to: tmp, options: .atomic)
        _ = try? fm.replaceItemAt(dest, withItemAt: tmp)
    }

    public func assign(sessionID: String, groupID: String, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        pg.assignments[sessionID] = groupID
        try save(pg, projectSlug: projectSlug)
    }

    public func unassign(sessionID: String, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        pg.assignments.removeValue(forKey: sessionID)
        try save(pg, projectSlug: projectSlug)
    }

    @discardableResult
    public func createGroup(name: String, color: GroupColor, projectSlug: String) throws -> SessionGroup {
        var pg = load(projectSlug: projectSlug)
        let g = SessionGroup(id: UUID().uuidString, name: name, color: color,
                             createdAt: Date().timeIntervalSince1970)
        pg.groups.append(g)
        try save(pg, projectSlug: projectSlug)
        return g
    }

    public func deleteGroup(id: String, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        pg.groups.removeAll { $0.id == id }
        pg.assignments = pg.assignments.filter { $0.value != id }
        try save(pg, projectSlug: projectSlug)
    }

    public func renameGroup(id: String, name: String, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        guard let idx = pg.groups.firstIndex(where: { $0.id == id }) else { return }
        pg.groups[idx].name = name
        try save(pg, projectSlug: projectSlug)
    }

    public func recolorGroup(id: String, color: GroupColor, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        guard let idx = pg.groups.firstIndex(where: { $0.id == id }) else { return }
        pg.groups[idx].color = color
        try save(pg, projectSlug: projectSlug)
    }

    // MARK: - Batch and layout edits (one load + one write each)

    /// Assign every session to `groupID`. Unknown group → no-op, so a stale menu can't create an
    /// assignment to nothing.
    public func assign(sessionIDs: [String], groupID: String, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        guard pg.groups.contains(where: { $0.id == groupID }), !sessionIDs.isEmpty else { return }
        for id in sessionIDs { pg.assignments[id] = groupID }
        try save(pg, projectSlug: projectSlug)
    }

    public func unassign(sessionIDs: [String], projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        let before = pg.assignments.count
        for id in sessionIDs { pg.assignments.removeValue(forKey: id) }
        guard pg.assignments.count != before else { return }
        try save(pg, projectSlug: projectSlug)
    }

    /// Create a group and move `sessionIDs` into it, in one write.
    @discardableResult
    public func createGroup(name: String, color: GroupColor, assigning sessionIDs: [String],
                            projectSlug: String) throws -> SessionGroup {
        var pg = load(projectSlug: projectSlug)
        let g = SessionGroup(id: UUID().uuidString, name: name, color: color,
                             createdAt: Date().timeIntervalSince1970)
        pg.groups.append(g)
        for id in sessionIDs { pg.assignments[id] = g.id }
        try save(pg, projectSlug: projectSlug)
        return g
    }

    public func setCollapsed(id: String, collapsed: Bool, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        guard let idx = pg.groups.firstIndex(where: { $0.id == id }),
              pg.groups[idx].isCollapsed != collapsed else { return }
        pg.groups[idx].collapsed = collapsed
        try save(pg, projectSlug: projectSlug)
    }

    /// Move a group `offset` places (−1 up, +1 down), clamped to the list.
    public func moveGroup(id: String, by offset: Int, projectSlug: String) throws {
        var pg = load(projectSlug: projectSlug)
        guard let from = pg.groups.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(pg.groups.count - 1, from + offset))
        guard to != from else { return }
        let g = pg.groups.remove(at: from)
        pg.groups.insert(g, at: to)
        try save(pg, projectSlug: projectSlug)
    }
}
