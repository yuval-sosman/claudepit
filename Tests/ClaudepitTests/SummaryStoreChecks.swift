import Foundation
@testable import ClaudepitCore

func summaryStoreChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("loadAll returns empty when directory missing") {
        let ps = SummaryStore.shared.loadAll(projectSlug: "no-such-project-\(Int.random(in: 0..<Int.max))")
        try expectEqual(ps.summaries.count, 0, "no summaries")
        try expectEqual(ps.version, 1, "version 1")
    })

    results.append(check("save and load round-trips bullets") {
        let store = SummaryStore(root: try tempDir())
        let slug = "test-proj"
        let sessID = "sess-abc"
        let entry = SessionBulletSummary(bullets: ["Added dark mode", "Fixed crash"], updatedAt: Date(timeIntervalSince1970: 1000))
        try store.save(entry, projectSlug: slug, sessionID: sessID)
        let loaded = store.load(projectSlug: slug, sessionID: sessID)
        try expectEqual(loaded?.bullets, ["Added dark mode", "Fixed crash"], "bullets match")
    })

    results.append(check("loadAll returns all saved sessions") {
        let store = SummaryStore(root: try tempDir())
        let slug = "test-proj"
        try store.save(SessionBulletSummary(bullets: ["Built X"], updatedAt: Date()), projectSlug: slug, sessionID: "sess-1")
        try store.save(SessionBulletSummary(bullets: ["Fixed Y"], updatedAt: Date()), projectSlug: slug, sessionID: "sess-2")
        let ps = store.loadAll(projectSlug: slug)
        try expectEqual(ps.summaries.count, 2, "both sessions present")
    })

    results.append(check("save is atomic (no leftover .tmp)") {
        let root = try tempDir()
        let store = SummaryStore(root: root)
        let slug = "test-proj"
        let entry = SessionBulletSummary(bullets: ["x"], updatedAt: Date())
        try store.save(entry, projectSlug: slug, sessionID: "s")
        let dir = root.appending(path: slug).appending(path: "summary")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        try expect(!files.contains { $0.hasSuffix(".tmp") }, "no leftover .tmp files")
    })

    return results
}
