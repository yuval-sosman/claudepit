import Foundation
@testable import ClaudepitCore

func toolInvocationChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("ToolInvocation classifies mcp/agent/skill/builtin") {
        let (mcp, _) = ToolInvocation.classify(name: "mcp__pencil__batch_get", input: [:])
        try expectEqual(mcp, .mcp(server: "pencil", tool: "batch_get"), "mcp class")

        let (agent, agentSummary) = ToolInvocation.classify(
            name: "Agent", input: ["subagent_type": "Explore", "description": "search code"])
        try expectEqual(agent, .agent(type: "Explore"), "agent class")
        try expectEqual(agentSummary, "search code", "agent summary is description")

        let (skill, _) = ToolInvocation.classify(name: "Skill", input: ["skill": "code-review"])
        try expectEqual(skill, .skill(name: "code-review"), "skill class")

        let (bash, bashSummary) = ToolInvocation.classify(
            name: "Bash", input: ["command": "swift build", "description": "x"])
        try expectEqual(bash, .builtin, "bash is builtin")
        try expectEqual(bashSummary, "swift build", "bash summary is command")

        let (read, readSummary) = ToolInvocation.classify(name: "Read", input: ["file_path": "/a/b.swift"])
        try expectEqual(read, .builtin, "read is builtin")
        try expectEqual(readSummary, "/a/b.swift", "read summary is file_path")
    })

    results.append(check("ToolInvocation displayName + counts") {
        let mcp = ToolInvocation(id: "1", name: "mcp__pencil__batch_get",
                                 toolClass: .mcp(server: "pencil", tool: "batch_get"),
                                 argSummary: "", input: [:], resultText: nil, isError: nil)
        try expectEqual(mcp.displayName, "mcp__pencil (batch_get)", "mcp displayName")

        let agent = ToolInvocation(id: "2", name: "Agent", toolClass: .agent(type: "Explore"),
                                   argSummary: "", input: [:], resultText: nil, isError: nil)
        try expectEqual(agent.displayName, "Agent → Explore", "agent displayName")

        let counts = ToolInvocation.counts([mcp, agent, mcp])
        // sorted by count desc then label
        try expectEqual(counts.first?.label, "mcp__pencil", "top label")
        try expectEqual(counts.first?.count, 2, "top count")
    })

    return results
}
