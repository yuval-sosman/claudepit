import Foundation
@testable import ClaudepitCore

func worktreeStagerChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("parseStatusV1: staged/unstaged/both/untracked/rename") {
        // "M " staged-only, " M" unstaged-only, "MM" both, "A " added-staged,
        // " D" deleted-unstaged, "??" untracked, "R  new\0old" rename (staged)
        let raw = "M  a.swift\0 M b.swift\0MM c.swift\0A  d.swift\0 D e.swift\0?? f.txt\0R  new.swift\0old.swift\0"
        let files = WorktreeStager.parseStatusV1(raw)
        try expectEqual(files.count, 7, "seven files")

        func f(_ p: String) throws -> StagedFile {
            guard let x = files.first(where: { $0.path == p }) else { throw CheckFailure(message: "missing \(p)") }
            return x
        }
        let a = try f("a.swift")
        try expect(a.staged && !a.unstaged, "a staged only")
        try expectEqual(a.change, .modified, "a modified")

        let b = try f("b.swift")
        try expect(!b.staged && b.unstaged, "b unstaged only")

        let c = try f("c.swift")
        try expect(c.staged && c.unstaged, "c both")

        let d = try f("d.swift")
        try expect(d.staged, "d staged"); try expectEqual(d.change, .added, "d added")

        let e = try f("e.swift")
        try expect(e.unstaged, "e unstaged"); try expectEqual(e.change, .deleted, "e deleted")

        let ff = try f("f.txt")
        try expect(ff.untracked, "f untracked"); try expectEqual(ff.change, .untracked, "f untracked change")

        let r = try f("new.swift")
        try expectEqual(r.change, .renamed, "rename kept new path"); try expect(r.staged, "rename staged")
    })

    results.append(check("parseStatusV1: empty -> []") {
        try expectEqual(WorktreeStager.parseStatusV1("").count, 0, "empty")
    })

    return results
}
