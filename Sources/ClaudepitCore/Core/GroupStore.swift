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
}
