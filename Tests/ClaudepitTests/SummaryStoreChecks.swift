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
        let slug = "test-proj-\(Int.random(in: 0..<Int.max))"
        let sessID = "sess-abc"
        let entry = SessionBulletSummary(bullets: ["Added dark mode", "Fixed crash"], updatedAt: Date(timeIntervalSince1970: 1000))
        try SummaryStore.shared.save(entry, projectSlug: slug, sessionID: sessID)
        let loaded = SummaryStore.shared.load(projectSlug: slug, sessionID: sessID)
        try expectEqual(loaded?.bullets, ["Added dark mode", "Fixed crash"], "bullets match")
    })

    results.append(check("loadAll returns all saved sessions") {
        let slug = "test-proj-\(Int.random(in: 0..<Int.max))"
        try SummaryStore.shared.save(SessionBulletSummary(bullets: ["Built X"], updatedAt: Date()), projectSlug: slug, sessionID: "sess-1")
        try SummaryStore.shared.save(SessionBulletSummary(bullets: ["Fixed Y"], updatedAt: Date()), projectSlug: slug, sessionID: "sess-2")
        let ps = SummaryStore.shared.loadAll(projectSlug: slug)
        try expectEqual(ps.summaries.count, 2, "both sessions present")
    })

    results.append(check("save is atomic (no leftover .tmp)") {
        let slug = "test-proj-\(Int.random(in: 0..<Int.max))"
        let entry = SessionBulletSummary(bullets: ["x"], updatedAt: Date())
        try SummaryStore.shared.save(entry, projectSlug: slug, sessionID: "s")
        let dir = Paths.summaryDir(projectSlug: slug)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        try expect(!files.contains { $0.hasSuffix(".tmp") }, "no leftover .tmp files")
    })

    return results
}
