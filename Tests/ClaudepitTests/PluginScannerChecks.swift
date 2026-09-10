import Foundation
@testable import ClaudepitCore

func pluginScannerChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("scans plugin and contributions") {
        let root = try copyFixture("plugins")

        // Rewrite __FX__ in installed_plugins.json to the temp dir's path
        let installed = root.appending(path: "installed_plugins.json")
        let text = try String(contentsOf: installed, encoding: .utf8)
            .replacingOccurrences(of: "__FX__", with: root.path)
        try text.write(to: installed, atomically: true, encoding: .utf8)

        let scanner = PluginScanner(pluginsRoot: root, enabledPlugins: ["coolplug@acme": false])
        let (plugins, contribs) = scanner.scan()

        try expectEqual(plugins.count, 1, "plugins.count")
        let p = plugins[0]
        try expectEqual(p.name, "coolplug", "name")
        try expectEqual(p.marketplace, "acme", "marketplace")
        try expectEqual(p.version, "1.0.0", "version")
        try expectEqual(p.enabled, false, "enabled")
        try expectEqual(p.origin, .plugin(id: "coolplug@acme"), "origin")
        try expectEqual(p.skillCount, 1, "skillCount")
        try expectEqual(p.commandCount, 1, "commandCount")

        try expect(contribs.contains { $0.kind == .skill && $0.name == "dothing" },
                   "should have skill 'dothing'")
        try expect(contribs.contains { $0.kind == .command && $0.name == "runit" },
                   "should have command 'runit'")
    })

    results.append(check("populates plugin description and marketplaceURL") {
        // Create a temp plugin dir with a plugin.json that has description and homepage
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write installed_plugins.json
        let installPath = tmp.appending(path: "myplugin")
        try FileManager.default.createDirectory(at: installPath, withIntermediateDirectories: true)
        let pluginsJSON = """
        {"plugins":{"myplugin@test":[{"installPath":"\(installPath.path)","version":"1.0.0"}]}}
        """
        try pluginsJSON.write(to: tmp.appending(path: "installed_plugins.json"), atomically: true, encoding: .utf8)

        // Write plugin.json with description and homepage
        let pluginDir = installPath.appending(path: ".claude-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = """
        {"version":"1.0.0","description":"A test plugin","homepage":"https://example.com/myplugin"}
        """
        try manifest.write(to: pluginDir.appending(path: "plugin.json"), atomically: true, encoding: .utf8)

        let scanner = PluginScanner(pluginsRoot: tmp, enabledPlugins: [:])
        let (plugins, _) = scanner.scan()

        try expectEqual(plugins.count, 1)
        try expectEqual(plugins[0].description, "A test plugin")
        try expectEqual(plugins[0].marketplaceURL, "https://example.com/myplugin")
    })

    results.append(check("populates contribution description") {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let installPath = tmp.appending(path: "myplugin")
        try FileManager.default.createDirectory(at: installPath, withIntermediateDirectories: true)
        let pluginsJSON = """
        {"plugins":{"myplugin@test":[{"installPath":"\(installPath.path)","version":"1.0.0"}]}}
        """
        try pluginsJSON.write(to: tmp.appending(path: "installed_plugins.json"), atomically: true, encoding: .utf8)

        // Write a skill with frontmatter + heading + description
        let skillDir = installPath.appending(path: "skills/my-skill")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillMd = """
        ---
        name: my-skill
        ---

        # My Skill

        Does something useful for you.
        """
        try skillMd.write(to: skillDir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let scanner = PluginScanner(pluginsRoot: tmp, enabledPlugins: [:])
        let (plugins, _) = scanner.scan()

        let skill = plugins[0].contributions.first { $0.kind == .skill }
        try expectEqual(skill?.description, "Does something useful for you.")
    })

    return results
}
