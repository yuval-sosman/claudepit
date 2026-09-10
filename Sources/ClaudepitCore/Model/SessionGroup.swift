import Foundation

public enum GroupColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink
}

public struct SessionGroup: Codable, Identifiable {
    public var id: String
    public var name: String
    public var color: GroupColor
    public var createdAt: TimeInterval

    public init(id: String, name: String, color: GroupColor, createdAt: TimeInterval) {
        self.id = id; self.name = name; self.color = color; self.createdAt = createdAt
    }
}

public struct ProjectGroups: Codable {
    public var version: Int
    public var groups: [SessionGroup]
    public var assignments: [String: String]   // sessionID → groupID

    public init(version: Int = 1, groups: [SessionGroup] = [], assignments: [String: String] = [:]) {
        self.version = version; self.groups = groups; self.assignments = assignments
    }

    public static var empty: ProjectGroups { ProjectGroups() }
}
