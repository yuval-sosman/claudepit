import Foundation
@testable import ClaudepitCore

func configScannerChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("Frontmatter parses folded/literal block scalars + quotes") {
        let dir = try tempDir()
        let f = dir.appending(path: "SKILL.md")
        try """
        ---
        name: ponytail-audit
        description: >
          Whole-repo audit for over-engineering. Scans the entire codebase
          instead of a diff. Use when the user says "audit this codebase".
        allowed-tools: "Read, Grep"
        model: |
          line one
          line two
        ---

        # Body heading
        Body text here.
        """.write(to: f, atomically: true, encoding: .utf8)

        let (fields, body) = Frontmatter.parseWithBody(f)
        try expectEqual(fields["name"], "ponytail-audit", "name")
        try expect(fields["description"]?.hasPrefix("Whole-repo audit for over-engineering.") == true,
                   "folded description starts correctly")
        try expect(fields["description"]?.contains("\"audit this codebase\".") == true,
                   "folded description includes full text")
        try expect(fields["description"]?.contains("\n") == false, "folded scalar has no newlines")
        try expectEqual(fields["allowed-tools"], "Read, Grep", "quotes stripped")
        try expectEqual(fields["model"], "line one\nline two", "literal scalar keeps newlines")
        try expect(body.hasPrefix("# Body heading"), "body starts after frontmatter")
    })

    results.append(check("ConfigScanner reads all kinds") {
        let dir = try copyFixture("global")
        let r = ConfigScanner(claudeDir: dir, scope: .global).scan()

        try expectEqual(r.mcpServers.map(\.id), ["pencil"], "mcpServers ids")
        try expectEqual(r.mcpServers.first?.command, "/bin/pencil", "pencil command")
        try expectEqual(r.skills.map(\.id), ["myskill"], "skills ids")
        try expectEqual(r.skills.first?.description, "my global skill", "skill description")
        try expectEqual(r.commands.map(\.id), ["mycmd"], "commands ids")
        try expectEqual(r.agents.map(\.id), ["myagent"], "agents ids")
        try expectEqual(r.agents.first?.meta["description"], "my agent", "agent meta carries frontmatter")
        try expectEqual(r.hooks.first?.event, "SessionStart", "first hook event")
        try expectEqual(r.hooks.first?.command, "echo hi", "first hook command")

        // secret masking
        let token = r.envVars.first { $0.id == "ANTHROPIC_AUTH_TOKEN" }
        try expect(token != nil, "ANTHROPIC_AUTH_TOKEN found")
        try expectEqual(token?.displayValue, "••••1234", "displayValue masked")
    })

    // Regression: .local scope reads only settings.local.json — it must NOT pick up
    // skills/commands/agents directories (those belong to global/project scopes).
    results.append(check("ConfigScanner .local ignores skill/command/agent dirs") {
        let dir = try copyFixture("global")   // fixture has skills/, commands/, agents/
        let r = ConfigScanner(claudeDir: dir, scope: .local).scan()
        try expect(r.skills.isEmpty, "local scope must not scan skills dir (got \(r.skills.map(\.id)))")
        try expect(r.commands.isEmpty, "local scope must not scan commands dir")
        try expect(r.agents.isEmpty, "local scope must not scan agents dir")
    })

    // Project MCP servers can be declared in a standalone .mcp.json (project root).
    results.append(check("ConfigScanner reads .mcp.json file") {
        let dir = try tempDir()
        let mcpURL = dir.appending(path: ".mcp.json")
        try #"{"mcpServers":{"proj-server":{"command":"/bin/x","args":["--a"]}}}"#
            .write(to: mcpURL, atomically: true, encoding: .utf8)
        let servers = ConfigScanner.parseMcpJsonFile(mcpURL, scope: .project)
        try expectEqual(servers.map(\.id), ["proj-server"], "mcp.json server ids")
        try expectEqual(servers.first?.command, "/bin/x", "mcp.json server command")
        try expectEqual(servers.first?.scope, .project, "mcp.json server scope is project")
        // absent file → empty, no crash
        try expect(ConfigScanner.parseMcpJsonFile(dir.appending(path: "nope.json"), scope: .project).isEmpty,
                   "absent .mcp.json returns empty")
    })

    return results
}
