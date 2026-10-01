import Foundation
@testable import ClaudepitCore

func memoryLoaderChecks() -> [Bool] {
    var results: [Bool] = []

    func write(_ text: String, _ name: String, in dir: URL) throws {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    results.append(check("files no link from MEMORY.md reaches are listed as orphans") {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("# Index\n- [Hooks](./hooks.md)\n", "MEMORY.md", in: dir)
        try write("# Hooks\nSee [deep](./deep.md)\n", "hooks.md", in: dir)
        try write("# Deep\nSee [deeper](./deeper.md)\n", "deep.md", in: dir)
        try write("# Deeper\n", "deeper.md", in: dir)
        try write("# Lost\nPoints at [hooks](./hooks.md)\n", "lost.md", in: dir)
        try write("# Nested\n", "domain/nested.md", in: dir)
        try write("[]", "log.json", in: dir)
        let graph = MemoryLoader.load(dir: dir)
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        try expectEqual(Set(byID.keys), ["MEMORY.md", "hooks.md", "deep.md", "deeper.md", "lost.md", "domain/nested.md"],
                        "every .md file, nested ones by relative path, no json")
        try expect(byID["deeper.md"]?.isOrphan == false, "links are followed to any depth")
        try expect(byID["lost.md"]?.isOrphan == true, "unlinked file is an orphan")
        try expect(byID["domain/nested.md"]?.isOrphan == true, "nested unlinked file is an orphan")
        try expect(byID["MEMORY.md"]?.isOrphan == false, "the index is never an orphan")
        try expect(graph.edges.contains { $0.from == "lost.md" && $0.to == "hooks.md" }, "an orphan's own links still draw")
        try expect(byID["hooks.md"]?.isOrphan == false, "an orphan linking a topic doesn't change the topic")
    })

    results.append(check("index labels win over a topic naming the same file") {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("- [Alpha topic](./a.md)\n- [Beta topic](./b.md)\n", "MEMORY.md", in: dir)
        try write("[b](./b.md)", "a.md", in: dir)
        try write("[a](./a.md)", "b.md", in: dir)
        let byID = Dictionary(uniqueKeysWithValues: MemoryLoader.load(dir: dir).nodes.map { ($0.id, $0.title) })
        try expectEqual(byID["b.md"], "Beta topic", "label from MEMORY.md, not the cross-link")
    })

    results.append(check("with no MEMORY.md, the files still show — all as orphans") {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("# Solo\n", "solo.md", in: dir)
        let graph = MemoryLoader.load(dir: dir)
        try expectEqual(graph.nodes.map(\.id), ["solo.md"], "listed")
        try expect(graph.nodes.allSatisfy(\.isOrphan), "orphan")
        try expect(MemoryLoader.load(dir: dir.appending(path: "missing")).nodes.isEmpty, "a missing dir is empty")
    })

    results.append(check("nodes carry description, date and body for the list and search") {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("- [Hooks](./hooks.md)\n- [Plain](./plain.md)\n", "MEMORY.md", in: dir)
        try write("---\nname: hooks\ndescription: What Claudepit writes into settings.json\n---\n# Hooks\nThe Stop hook stays silent.\n",
                  "hooks.md", in: dir)
        try write("# Plain\n\nNo frontmatter here, just a first line of prose.\n", "plain.md", in: dir)
        let byID = Dictionary(uniqueKeysWithValues: MemoryLoader.load(dir: dir).nodes.map { ($0.id, $0) })
        let hooks = try unwrap(byID["hooks.md"])
        try expectEqual(hooks.description, "What Claudepit writes into settings.json", "frontmatter description")
        try expect(hooks.modifiedAt != nil, "date stamped")
        try expect(!hooks.body.contains("description:"), "body excludes frontmatter")
        try expectEqual(byID["plain.md"]?.description, "No frontmatter here, just a first line of prose.",
                        "falls back to the first prose line")
        try expectEqual(byID["MEMORY.md"]?.description, nil, "the index has no description")
        try expect(hooks.matches("stop SILENT"), "search reads the body")
        try expect(hooks.matches("settings.json hooks"), "and the description")
        try expect(!hooks.matches("hooks payments"), "every word required")
        try expectEqual(byID["MEMORY.md"]?.displayTitle, "MEMORY.md", "index title")
    })

    return results
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure(message: "unexpected nil") }
    return value
}
