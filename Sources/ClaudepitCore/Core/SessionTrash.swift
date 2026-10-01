import Foundation

/// Moving a session to the Trash, completely. Trashing the `.jsonl` alone (the old menu item)
/// left its `<id>/` folder — subagent transcripts, tool output — plus its summary and its group
/// assignment behind as orphans. The transcript and folder go to the Trash (recoverable with
/// Put Back); the summary and assignment are app bookkeeping about a session that is no longer
/// listed, so they are removed.
public struct SessionTrash: Sendable {
    private let groupStore: GroupStore
    private let summaryStore: SummaryStore
    private let moveToTrash: @Sendable (URL) throws -> Void

    public static let live = SessionTrash(groupStore: .shared, summaryStore: .shared) { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public init(groupStore: GroupStore, summaryStore: SummaryStore, moveToTrash: @escaping @Sendable (URL) throws -> Void) {
        self.groupStore = groupStore
        self.summaryStore = summaryStore
        self.moveToTrash = moveToTrash
    }

    /// The session's own folder next to its transcript (`<project>/<id>/`), if it has one.
    public static func sessionFolder(of s: SessionSummary) -> URL? {
        let dir = s.fileURL.deletingLastPathComponent().appending(path: s.id)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    /// Trash each session; returns the ids that could not be moved (the rest are gone).
    @discardableResult
    public func trash(_ sessions: [SessionSummary]) -> [String] {
        var failed: [String] = []
        var unassign: [String: [String]] = [:]
        for s in sessions {
            do {
                try moveToTrash(s.fileURL)
            } catch {
                failed.append(s.id)
                continue
            }
            if let folder = Self.sessionFolder(of: s) { try? moveToTrash(folder) }
            summaryStore.delete(projectSlug: s.projectSlug, sessionID: s.id)
            unassign[s.groupKey, default: []].append(s.id)
        }
        for (key, ids) in unassign { try? groupStore.unassign(sessionIDs: ids, projectSlug: key) }
        return failed
    }
}
