import Foundation
@testable import ClaudepitCore

func configStoreChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("precedence: project overrides global") {
        let g = ConfigScanner(claudeDir: try copyFixture("global"), scope: .global).scan()
        let p = ConfigScanner(claudeDir: try copyFixture("project"), scope: .project).scan()
        let merged = ConfigStore.merge(global: g, project: p, local: LayerResult(),
                                       projectLocal: LayerResult(), plugins: [], contribs: [])
        let pencils = merged.mcp.filter { $0.id == "pencil" }
        try expectEqual(pencils.count, 2, "pencil count")
        let winner = pencils.first { !$0.isOverridden }
        try expect(winner != nil, "winner exists")
        try expectEqual(winner?.command, "/proj/pencil", "winner command")
        try expectEqual(winner?.scope, .project, "winner scope")
        try expect(pencils.contains { $0.isOverridden && $0.scope == .global }, "overridden global exists")
    })

    results.append(check("plugin contribution tagged distinctly") {
        let g = ConfigScanner(claudeDir: try copyFixture("global"), scope: .global).scan()
        let contribs = [PluginContribution(pluginID: "coolplug@acme", kind: .skill,
                                            name: "dothing", path: URL(filePath: "/x/SKILL.md"))]
        let plug = Plugin(id: "coolplug@acme", name: "coolplug", marketplace: "acme", version: "1.0.0",
                          enabled: true, installPath: URL(filePath: "/x"), scope: .global,
                          sourcePath: URL(filePath: "/x/plugin.json"), origin: .plugin(id: "coolplug@acme"),
                          allInstalls: [PluginInstall(scope: .global, projectPath: nil, installPath: URL(filePath: "/x"), version: "1.0.0")])
        let merged = ConfigStore.merge(global: g, project: LayerResult(), local: LayerResult(),
                                       projectLocal: LayerResult(), plugins: [plug], contribs: contribs)
        let skill = merged.skills.first { $0.id == "dothing" }
        try expect(skill != nil, "dothing skill exists")
        try expectEqual(skill?.scope, .plugin, "scope is plugin")
        try expectEqual(skill?.origin, .plugin(id: "coolplug@acme"), "origin is plugin")
    })

    results.append(check("plugin contribution hidden when plugin not active for path") {
        let contribs = [PluginContribution(pluginID: "duck@dev", kind: .skill,
                                            name: "rubber-duck", path: URL(filePath: "/x/SKILL.md"))]
        // Plugin installed only in a DIFFERENT project's scope.
        let plug = Plugin(id: "duck@dev", name: "duck", marketplace: "dev", version: "1.0.0",
                          enabled: true, installPath: URL(filePath: "/x"), scope: .project,
                          sourcePath: URL(filePath: "/x/plugin.json"), origin: .plugin(id: "duck@dev"),
                          projectPath: "/other/project",
                          allInstalls: [PluginInstall(scope: .project, projectPath: "/other/project", installPath: URL(filePath: "/x"), version: "1.0.0")])
        // Active in a different project → contribution must NOT appear.
        let hidden = ConfigStore.merge(global: LayerResult(), project: LayerResult(), local: LayerResult(),
                                       projectLocal: LayerResult(), plugins: [plug], contribs: contribs,
                                       activePath: "/my/project")
        try expect(hidden.skills.first { $0.id == "rubber-duck" } == nil, "rubber-duck hidden for /my/project")
        // Active in its own project → contribution appears.
        let shown = ConfigStore.merge(global: LayerResult(), project: LayerResult(), local: LayerResult(),
                                      projectLocal: LayerResult(), plugins: [plug], contribs: contribs,
                                      activePath: "/other/project")
        try expect(shown.skills.first { $0.id == "rubber-duck" } != nil, "rubber-duck shown for /other/project")
    })

    results.append(check("model resolves from global") {
        let g = ConfigScanner(claudeDir: try copyFixture("global"), scope: .global).scan()
        let merged = ConfigStore.merge(global: g, project: LayerResult(), local: LayerResult(),
                                       projectLocal: LayerResult(), plugins: [], contribs: [])
        try expect(merged.model != nil, "model exists")
        try expectEqual(merged.model?.effectiveModel, "opus", "effectiveModel")
    })

    results.append(check("model: higher layer overrides global") {
        let g = ConfigScanner(claudeDir: try copyFixture("global"), scope: .global).scan()
        var proj = LayerResult()
        proj.settings = ["model": "sonnet"]
        proj.settingsSourcePath = URL(filePath: "/tmp/proj/.claude/settings.json")
        let merged = ConfigStore.merge(global: g, project: proj, local: LayerResult(),
                                       projectLocal: LayerResult(), plugins: [], contribs: [])
        try expectEqual(merged.model?.effectiveModel, "sonnet", "project model overrides global")
    })

    results.append(check("applySkillOverrides: project wins, plugin skills untouched") {
        let mk = { (id: String, origin: Origin) in
            Skill(id: id, description: "", scope: .global, sourcePath: URL(filePath: "/x"), origin: origin)
        }
        let skills = [mk("a", .user), mk("b", .user), mk("c", .user), mk("p", .plugin(id: "x@y"))]
        let global: [String: Any] = ["skillOverrides": ["a": "off", "b": "on"]]
        let project: [String: Any] = ["skillOverrides": ["b": "user-invocable-only"]]
        let out = ConfigStore.applySkillOverrides(skills, project: project, global: global)
        func en(_ id: String) -> Bool? { out.first { $0.id == id }?.skillEnabled }
        try expectEqual(en("a"), false, "a disabled by global")
        try expectEqual(en("b"), false, "b: project user-invocable-only overrides global on")
        try expectEqual(en("c"), true, "c absent → enabled")
        try expectEqual(en("p"), true, "plugin skill untouched by skillOverrides")
    })

    return results
}
