import Foundation
@testable import ClaudepitCore

func sessionScannerChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("Paths.slug replaces slashes with dashes") {
        let slug = Paths.slug(for: URL(filePath: "/Users/me/Dev/claudepit"))
        try expectEqual(slug, "-Users-me-Dev-claudepit", "slug")
    })

    results.append(check("SessionScanner lists all projects when no active path") {
        let root = try copyFixture("sessions")   // copies Fixtures/sessions → temp
        let scanner = SessionScanner(projectsRoot: root, now: Date(timeIntervalSince1970: 0))
        let all = scanner.list(activePath: nil)
        try expectEqual(Set(all.map(\.id)), Set(["1111", "2222"]), "all session ids")
        // title: aiTitle when present, else first user prompt
        let a = all.first { $0.id == "1111" }
        try expectEqual(a?.title, "Session A", "title from aiTitle")
        let b = all.first { $0.id == "2222" }
        try expectEqual(b?.title, "first prompt here", "title from first prompt")
        // none active (now = epoch, files far newer → not within 60s of epoch)
        try expect(all.allSatisfy { !$0.isActive }, "none active relative to epoch")
    })

    results.append(check("SessionScanner scopes to active project's slug") {
        let root = try copyFixture("sessions")
        // active path whose slug is "-proj-a" → base path "/proj/a"
        let scanner = SessionScanner(projectsRoot: root, now: Date(timeIntervalSince1970: 0))
        let scoped = scanner.list(activePath: URL(filePath: "/proj/a"))
        try expectEqual(scoped.map(\.id), ["1111"], "scoped to -proj-a")
    })

    results.append(check("SessionScanner active badge within 60s of now") {
        let root = try copyFixture("sessions")
        let f = root.appending(path: "-proj-a").appending(path: "1111.jsonl")
        let recent = Date()
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: f.path)
        let scanner = SessionScanner(projectsRoot: root, now: recent.addingTimeInterval(5))
        let a = scanner.list(activePath: URL(filePath: "/proj/a")).first { $0.id == "1111" }
        try expect(a?.isActive == true, "1111 active (mtime 5s ago)")
    })

    results.append(check("bulletSummary stamped from SummaryStore") {
        // Write a minimal session fixture
        let projectsRoot = try tempDir()
        let slug = "-fake-proj"
        let sessDir = projectsRoot.appending(path: slug)
        try FileManager.default.createDirectory(at: sessDir, withIntermediateDirectories: true)
        let sessID = "aaaaaaaa-0000-0000-0000-000000000001"
        let jsonl = "{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}\n"
        try jsonl.write(to: sessDir.appending(path: "\(sessID).jsonl"), atomically: true, encoding: .utf8)

        // Write a summaries file, rooted at the same temp projectsRoot as the session fixture.
        let store = SummaryStore(root: projectsRoot)
        let entry = SessionBulletSummary(bullets: ["Built login feature"], updatedAt: Date())
        try store.save(entry, projectSlug: slug, sessionID: sessID)

        let scanner = SessionScanner(projectsRoot: projectsRoot, summaryStore: store)
        let sessions = scanner.list(activePath: nil)
        let s = try { guard let s = sessions.first(where: { $0.id == sessID }) else { throw CheckFailure(message: "session not found") }; return s }()
        try expectEqual(s.bulletSummary?.bullets, ["Built login feature"], "bullets stamped")
    })

    return results
}
