import Foundation
@testable import ClaudepitCore

func groupStoreChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("load returns empty when file missing") {
        let store = GroupStore(root: try tempDir())
        let pg = store.load(projectSlug: "no-such-project")
        try expectEqual(pg.groups.count, 0, "no groups")
        try expectEqual(pg.assignments.count, 0, "no assignments")
        try expectEqual(pg.version, 1, "version 1")
    })

    results.append(check("createGroup then load round-trips") {
        let store = GroupStore(root: try tempDir())
        let g = try store.createGroup(name: "feature-auth", color: .blue, projectSlug: "proj")
        try expectEqual(g.name, "feature-auth", "name")
        try expectEqual(g.color, .blue, "color")
        let pg = store.load(projectSlug: "proj")
        try expectEqual(pg.groups.count, 1, "one group persisted")
        try expectEqual(pg.groups[0].id, g.id, "id matches")
    })

    results.append(check("assign and unassign") {
        let store = GroupStore(root: try tempDir())
        let g = try store.createGroup(name: "bugs", color: .red, projectSlug: "proj")
        try store.assign(sessionID: "sess-1", groupID: g.id, projectSlug: "proj")
        var pg = store.load(projectSlug: "proj")
        try expectEqual(pg.assignments["sess-1"], g.id, "assigned")
        try store.unassign(sessionID: "sess-1", projectSlug: "proj")
        pg = store.load(projectSlug: "proj")
        try expect(pg.assignments["sess-1"] == nil, "unassigned")
    })

    results.append(check("deleteGroup removes group and its assignments") {
        let store = GroupStore(root: try tempDir())
        let g = try store.createGroup(name: "old", color: .green, projectSlug: "proj")
        try store.assign(sessionID: "sess-a", groupID: g.id, projectSlug: "proj")
        try store.deleteGroup(id: g.id, projectSlug: "proj")
        let pg = store.load(projectSlug: "proj")
        try expectEqual(pg.groups.count, 0, "group deleted")
        try expect(pg.assignments["sess-a"] == nil, "assignment cleared")
    })

    results.append(check("renameGroup and recolorGroup") {
        let store = GroupStore(root: try tempDir())
        let g = try store.createGroup(name: "old-name", color: .orange, projectSlug: "proj")
        try store.renameGroup(id: g.id, name: "new-name", projectSlug: "proj")
        try store.recolorGroup(id: g.id, color: .purple, projectSlug: "proj")
        let pg = store.load(projectSlug: "proj")
        try expectEqual(pg.groups[0].name, "new-name", "renamed")
        try expectEqual(pg.groups[0].color, .purple, "recolored")
    })

    results.append(check("save is atomic (writes via tmp file)") {
        let root = try tempDir()
        let store = GroupStore(root: root)
        _ = try store.createGroup(name: "x", color: .teal, projectSlug: "p")
        let tmpFiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        try expect(!tmpFiles.contains { $0.hasSuffix(".tmp") }, "no leftover .tmp files")
    })

    return results
}
