import Foundation

public struct ProjectPrefs: Codable {
    public var memoryEnabled: Bool = true
}

public enum ProjectPrefsStore {
    public static func load(_ base: URL?) -> ProjectPrefs {
        guard let base else { return ProjectPrefs() }
        let url = Paths.projectPrefs(projectSlug: Paths.slug(for: base))
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(ProjectPrefs.self, from: data)
        else { return ProjectPrefs() }
        return prefs
    }

    public static func save(_ base: URL?, memoryEnabled: Bool) {
        guard let base else { return }
        let url = Paths.projectPrefs(projectSlug: Paths.slug(for: base))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        var prefs = load(base)
        prefs.memoryEnabled = memoryEnabled
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
