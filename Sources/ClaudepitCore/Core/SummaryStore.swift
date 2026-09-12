import Foundation

public struct SummaryStore: Sendable {
    private let root: URL

    public static let shared = SummaryStore(root: Paths.projectsRoot)

    public init(root: URL) {
        self.root = root
    }

    private func summaryDir(projectSlug: String) -> URL {
        root.appending(path: projectSlug).appending(path: "summary")
    }

    private func summaryFile(projectSlug: String, sessionID: String) -> URL {
        summaryDir(projectSlug: projectSlug).appending(path: "\(sessionID).json")
    }

    public func load(projectSlug: String, sessionID: String) -> SessionBulletSummary? {
        let file = summaryFile(projectSlug: projectSlug, sessionID: sessionID)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(SessionBulletSummary.self, from: data)
    }

    public func loadAll(projectSlug: String) -> ProjectSummaries {
        let dir = summaryDir(projectSlug: projectSlug)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        var ps = ProjectSummaries.empty
        for file in files where file.pathExtension == "json" {
            let sessionID = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let entry = try? dec.decode(SessionBulletSummary.self, from: data) else { continue }
            ps.summaries[sessionID] = entry
        }
        return ps
    }

    public func save(_ entry: SessionBulletSummary, projectSlug: String, sessionID: String) throws {
        let dir = summaryDir(projectSlug: projectSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = summaryFile(projectSlug: projectSlug, sessionID: sessionID)
        let tmp  = dir.appending(path: "\(sessionID).json.tmp")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let data = try enc.encode(entry)
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }
}
