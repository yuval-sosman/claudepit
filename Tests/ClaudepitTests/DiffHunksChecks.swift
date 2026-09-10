import Foundation
@testable import ClaudepitCore

func diffHunksChecks() -> [Bool] {
    var results: [Bool] = []

    let sample = """
    diff --git a/f.swift b/f.swift
    index 111..222 100644
    --- a/f.swift
    +++ b/f.swift
    @@ -1,3 +1,3 @@
     let a = 1
    -let b = 2
    +let b = 3
    @@ -10,2 +10,3 @@
     let z = 9
    +let w = 10
    """

    results.append(check("parseHunks: splits preamble and two hunks") {
        let (header, hunks) = parseHunks(sample)
        try expect(header.first == "diff --git a/f.swift b/f.swift", "preamble first line")
        try expect(header.contains("--- a/f.swift"), "has --- line")
        try expect(header.contains("+++ b/f.swift"), "has +++ line")
        try expect(!header.contains { $0.hasPrefix("@@") }, "no @@ in preamble")
        try expectEqual(hunks.count, 2, "two hunks")
        try expect(hunks[0].header.hasPrefix("@@ -1,3 +1,3 @@"), "hunk0 header")
        try expect(hunks[0].lines.contains("-let b = 2"), "hunk0 keeps remove line")
        try expect(hunks[0].lines.contains("+let b = 3"), "hunk0 keeps add line")
        try expect(hunks[1].header.hasPrefix("@@ -10,2 +10,3 @@"), "hunk1 header")
        try expect(hunks[1].lines.contains("+let w = 10"), "hunk1 add line")
        try expectEqual(hunks[0].id, 0, "id is index 0")
        try expectEqual(hunks[1].id, 1, "id is index 1")
    })

    results.append(check("parseHunks: empty -> empty") {
        let (header, hunks) = parseHunks("")
        try expectEqual(header.count, 0, "no preamble")
        try expectEqual(hunks.count, 0, "no hunks")
    })

    results.append(check("buildPatch: single hunk round-trips into valid patch") {
        let (header, hunks) = parseHunks(sample)
        let patch = buildPatch(fileHeader: header, hunk: hunks[1])
        try expect(patch.hasPrefix("diff --git a/f.swift b/f.swift"), "starts with diff --git")
        try expect(patch.contains("--- a/f.swift"), "has --- ")
        try expect(patch.contains("+++ b/f.swift"), "has +++ ")
        let atCount = patch.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }.count
        try expectEqual(atCount, 1, "exactly one @@ hunk")
        try expect(patch.contains("+let w = 10"), "hunk body preserved")
        try expect(patch.hasSuffix("\n"), "trailing newline (git apply needs it)")
    })

    return results
}
