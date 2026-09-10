import Foundation
@testable import ClaudepitCore

func topicStoreChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("load returns [] when file missing") {
        let store = TopicStore(root: try tempDir())
        try expectEqual(store.load(projectSlug: "nope"), [], "no topics")
    })

    results.append(check("add then load round-trips, in order") {
        let store = TopicStore(root: try tempDir())
        try store.add("backend", projectSlug: "p")
        try store.add("frontend", projectSlug: "p")
        try expectEqual(store.load(projectSlug: "p"), ["backend", "frontend"], "ordered")
    })

    results.append(check("add dedupes and trims") {
        let store = TopicStore(root: try tempDir())
        try store.add("infra", projectSlug: "p")
        try store.add("  infra  ", projectSlug: "p")   // trimmed → duplicate
        try store.add("", projectSlug: "p")            // empty ignored
        try expectEqual(store.load(projectSlug: "p"), ["infra"], "one entry")
    })

    results.append(check("save leaves no .tmp file") {
        let root = try tempDir()
        let store = TopicStore(root: root)
        try store.add("x", projectSlug: "p")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        try expect(!files.contains { $0.hasSuffix(".tmp") }, "no leftover .tmp")
    })

    return results
}
