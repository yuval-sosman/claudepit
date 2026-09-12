import Foundation
@testable import ClaudepitCore

func menuBarSummaryChecks() -> [Bool] {
    var results: [Bool] = []

    func row(_ id: String, needsAttention: Bool, agentStatus: String? = nil) -> WorkItem {
        WorkItem(id: id, kind: needsAttention ? .attentionTask : .agent,
                 title: id, detail: "", needsAttention: needsAttention,
                 severity: needsAttention ? .blocked : nil,
                 agentStatus: agentStatus, target: .task(id))
    }

    results.append(check("an empty workstream shows no badge and the idle headline") {
        let s = buildMenuBarSummary(workstream: [])
        try expect(s.badge == nil, "no badge")
        try expectEqual(s.headline, "Nothing running", "idle headline")
        try expectEqual(s.symbol, "square.stack.3d.up", "idle symbol")
    })

    results.append(check("attention outranks activity in badge and symbol") {
        let s = buildMenuBarSummary(workstream: [
            row("a", needsAttention: true),
            row("b", needsAttention: false, agentStatus: Herdr.AgentState.working),
        ])
        try expectEqual(s.badge, "1", "badge counts attention, not the working agent")
        try expectEqual(s.symbol, "hand.raised.fill", "raised hand wins")
        try expectEqual(s.headline, "1 needs you · 1 working", "both halves reported")
    })

    results.append(check("attention and activity each get their own icon and count") {
        // The whole point of the label: a blocked item must not hide the working agents behind it,
        // and the working count must not hide the fact that something stopped for you.
        let s = buildMenuBarSummary(workstream: [
            row("a", needsAttention: true),
            row("b", needsAttention: false, agentStatus: Herdr.AgentState.working),
            row("c", needsAttention: false, agentStatus: Herdr.AgentState.working),
        ])
        try expectEqual(s.segments.count, 2, "two segments when both exist")
        try expectEqual(s.segments[0].symbol, "hand.raised.fill", "attention leads")
        try expectEqual(s.segments[0].count, "1", "with its own count")
        try expectEqual(s.segments[1].symbol, "bolt.horizontal.fill", "working follows")
        try expectEqual(s.segments[1].count, "2", "still says how many are working")
    })

    results.append(check("a single state renders a single segment") {
        let busy = buildMenuBarSummary(workstream: [
            row("a", needsAttention: false, agentStatus: Herdr.AgentState.working)])
        try expectEqual(busy.segments.count, 1, "no attention segment when nothing needs you")
        try expectEqual(busy.segments[0].symbol, "bolt.horizontal.fill", "busy alone")

        let waiting = buildMenuBarSummary(workstream: [row("a", needsAttention: true)])
        try expectEqual(waiting.segments.count, 1, "no busy segment when nothing is working")
        try expectEqual(waiting.segments[0].symbol, "hand.raised.fill", "attention alone")

        let idle = buildMenuBarSummary(workstream: [])
        try expectEqual(idle.segments.count, 1, "idle is one bare icon")
        try expect(idle.segments[0].count == nil, "and carries no count")
    })

    results.append(check("a blocked row with a live agent is not counted twice") {
        // The row is both an attention item and an agent; only the attention tally may claim it.
        let s = buildMenuBarSummary(workstream: [
            row("a", needsAttention: true, agentStatus: Herdr.AgentState.working),
        ])
        try expectEqual(s.attentionCount, 1, "counted once as attention")
        try expectEqual(s.workingCount, 0, "not also counted as working")
    })

    results.append(check("working agents alone badge with the bolt") {
        let s = buildMenuBarSummary(workstream: [
            row("a", needsAttention: false, agentStatus: Herdr.AgentState.working),
            row("b", needsAttention: false, agentStatus: Herdr.AgentState.working),
        ])
        try expectEqual(s.badge, "2", "counts the agents")
        try expectEqual(s.symbol, "bolt.horizontal.fill", "busy symbol")
        try expectEqual(s.headline, "2 agents working", "plural headline")
    })

    results.append(check("an idle agent row is listed but badges nothing") {
        let s = buildMenuBarSummary(workstream: [row("a", needsAttention: false, agentStatus: Herdr.AgentState.idle)])
        try expect(s.badge == nil, "idle is not activity")
        try expectEqual(s.rows.count, 1, "still listed in the panel")
    })

    results.append(check("the cap trims rows but never the counts") {
        let rows = (0..<11).map { row("r\($0)", needsAttention: true) }
        let s = buildMenuBarSummary(workstream: rows, limit: 8)
        try expectEqual(s.rows.count, 8, "listed rows capped")
        try expectEqual(s.overflow, 3, "the rest reported as overflow")
        try expectEqual(s.attentionCount, 11, "counts describe the whole list")
    })

    return results
}
