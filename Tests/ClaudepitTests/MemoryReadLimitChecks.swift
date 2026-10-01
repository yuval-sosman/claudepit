import Foundation
@testable import ClaudepitCore

func memoryReadLimitChecks() -> [Bool] {
    var results: [Bool] = []

    let lines = { (n: Int) in (1...n).map { "line \($0)" }.joined(separator: "\n") }

    results.append(check("a body at exactly 200 lines fits") {
        try expect(MemoryReadLimit.split(lines(200)) == nil, "200 lines is within the limit")
        try expect(!MemoryReadLimit.size(of: lines(200)).exceedsLimit, "size agrees")
    })

    results.append(check("201 lines cuts after line 200") {
        let cut = try unwrap(MemoryReadLimit.split(lines(201)))
        try expectEqual(cut.kept.components(separatedBy: "\n").count, 200, "kept")
        try expectEqual(cut.remainder, "line 201", "remainder")
        try expect(MemoryReadLimit.size(of: lines(201)).exceedsLimit, "size agrees")
    })

    results.append(check("a few huge lines cut on bytes, never mid-line") {
        let big = String(repeating: "x", count: 9_999)          // 10,000 bytes with its newline
        let body = [big, big, big, "tail"].joined(separator: "\n")
        let cut = try unwrap(MemoryReadLimit.split(body))
        try expectEqual(cut.kept, [big, big].joined(separator: "\n"), "two lines fit in 25 KB")
        try expectEqual(cut.remainder, [big, "tail"].joined(separator: "\n"), "rest is the remainder")
        try expect(MemoryReadLimit.size(of: body).exceedsLimit, "size agrees with split")
    })

    results.append(check("size label uses the limit's units") {
        try expectEqual(MemoryReadLimit.Size(lines: 459, bytes: 52_874).label, "459 lines · 52.9 KB", "label")
    })

    results.append(check("loader stamps body size, excluding frontmatter") {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Index\n- [Big](./big.md)\n- [Small](./small.md)\n"
            .write(to: dir.appending(path: "MEMORY.md"), atomically: true, encoding: .utf8)
        // 195 body lines + a frontmatter block that would push the raw file past 200.
        let frontmatter = "---\nname: big\n" + (1...10).map { "k\($0): v" }.joined(separator: "\n") + "\n---\n"
        try (frontmatter + lines(195)).write(to: dir.appending(path: "small.md"), atomically: true, encoding: .utf8)
        try ("---\nname: big\n---\n" + lines(250)).write(to: dir.appending(path: "big.md"), atomically: true, encoding: .utf8)
        let graph = MemoryLoader.load(dir: dir)
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        try expectEqual(byID["small.md"]?.size?.lines, 195, "frontmatter is not counted")
        try expect(byID["small.md"]?.exceedsReadLimit == false, "small fits")
        try expect(byID["big.md"]?.exceedsReadLimit == true, "big is flagged")
        try expect(byID["MEMORY.md"]?.exceedsReadLimit == false, "root fits")
    })

    results.append(check("fix prompt names each file, the reason, the goal and the directory") {
        let dir = URL(filePath: "/tmp/mem/memory")
        let prompt = MemoryReadLimit.fixPrompt(memoryDir: dir, files: [
            .init(filename: "home-dashboard.md", size: .init(lines: 459, bytes: 52_874)),
            .init(filename: "hooks.md", size: .init(lines: 120, bytes: 26_000)),
        ])
        try expect(prompt.contains("- `home-dashboard.md` — 459 lines · 52.9 KB"), "first file listed")
        try expect(prompt.contains("- `hooks.md` — 120 lines · 26.0 KB"), "second file listed")
        try expect(prompt.contains("## Why") && prompt.contains("200 lines or 25 KB"), "reason with the limit")
        try expect(prompt.contains("Split what is still too big"), "split goal")
        try expect(prompt.contains("Make it shorter where possible"), "shorten goal")
        try expect(prompt.contains("\nmemoryDir=/tmp/mem/memory"), "absolute dir on its own line")
        try expect(!prompt.hasPrefix("/"), "line 1 is not read as a slash command")
    })

    results.append(check("fix agent name is per project") {
        try expectEqual(MemoryReadLimit.fixAgentName(projectPath: URL(filePath: "/Users/a/Dev/claudepit")),
                        "memory-fix-claudepit", "name")
    })

    return results
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure(message: "unexpected nil") }
    return value
}
