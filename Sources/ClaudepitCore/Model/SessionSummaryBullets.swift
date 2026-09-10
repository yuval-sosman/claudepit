import Foundation

public struct SessionBulletSummary: Codable {
    public let bullets: [String]
    public let updatedAt: Date

    public init(bullets: [String], updatedAt: Date) {
        self.bullets = bullets
        self.updatedAt = updatedAt
    }
}

public struct ProjectSummaries: Codable {
    public var version: Int
    public var summaries: [String: SessionBulletSummary]

    public init(version: Int = 1, summaries: [String: SessionBulletSummary] = [:]) {
        self.version = version
        self.summaries = summaries
    }

    public static var empty: ProjectSummaries { ProjectSummaries() }
}
