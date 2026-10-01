import Foundation

public enum GroupColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink
}

public struct SessionGroup: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var color: GroupColor
    public var createdAt: TimeInterval
    /// Folded in the Groups tab. Optional so files written before it existed still decode.
    public var collapsed: Bool?

    public init(id: String, name: String, color: GroupColor, createdAt: TimeInterval, collapsed: Bool? = nil) {
        self.id = id; self.name = name; self.color = color; self.createdAt = createdAt
        self.collapsed = collapsed
    }

    public var isCollapsed: Bool { collapsed ?? false }
}

public struct ProjectGroups: Codable, Equatable {
    public var version: Int
    public var groups: [SessionGroup]
    public var assignments: [String: String]   // sessionID → groupID

    public init(version: Int = 1, groups: [SessionGroup] = [], assignments: [String: String] = [:]) {
        self.version = version; self.groups = groups; self.assignments = assignments
    }

    public static var empty: ProjectGroups { ProjectGroups() }

    /// The session's group, if the group it was assigned to still exists. An assignment can
    /// outlive its group (a file edited elsewhere, a delete that raced a write); a stale id must
    /// read as ungrouped, or the session belongs to no header and is listed nowhere.
    public func validGroupID(for sessionID: String) -> String? {
        guard let id = assignments[sessionID], groups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    public func group(_ id: String?) -> SessionGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }
}

public enum GroupNameError: Error, Equatable {
    case empty
    case duplicate(String)

    public var message: String {
        switch self {
        case .empty: return "Give the group a name."
        case .duplicate(let n): return "“\(n)” already exists."
        }
    }
}

extension GroupColor {
    /// The first colour no group uses yet, so new groups stay distinguishable; once all nine are
    /// taken, the least-used one.
    public static func next(after groups: [SessionGroup]) -> GroupColor {
        let counts = Dictionary(grouping: groups, by: \.color).mapValues(\.count)
        return allCases.min { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .blue
    }
}

extension SessionGroup {
    /// A trimmed, non-empty name no other group in `groups` already has (case-insensitively).
    /// `excluding` is the group being renamed, which may keep its own name.
    public static func validatedName(_ raw: String, among groups: [SessionGroup],
                                     excluding id: String? = nil) -> Result<String, GroupNameError> {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { return .failure(.empty) }
        if let clash = groups.first(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return .failure(.duplicate(clash.name))
        }
        return .success(name)
    }
}
