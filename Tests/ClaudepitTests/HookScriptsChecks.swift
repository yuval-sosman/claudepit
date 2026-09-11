import Foundation
@testable import ClaudepitCore

/// Drift guard for the deduped dreaming prompt: `memoryHook` splices a bash-escaped rendering of
/// the same template `memoryHookDreaming` renders with literals, so the two must stay in step.
func hookScriptsChecks() -> [Bool] {
    var results: [Bool] = []

    /// The 11 numbered dreaming steps, by their leading label.
    let steps = [
        "1. Inventory", "2. Full read", "3. Contradiction scan", "4. Staleness check",
        "5. Cross-reference integrity", "6. Synapse formation", "7. Orphan resolution",
        "8. Reachability check", "9. Consolidation", "10. MEMORY.md sync", "11. Log the dream",
    ]

    results.append(check("generated memoryHook contains all 11 dreaming steps") {
        for step in steps {
            try expect(HookScripts.memoryHook.contains(step), "memoryHook has \(step)")
        }
    })

    results.append(check("memoryHookDreaming contains all 11 dreaming steps") {
        for step in steps {
            try expect(HookScripts.memoryHookDreaming.contains(step), "display copy has \(step)")
        }
    })

    results.append(check("both renderings open with the shared reminder") {
        try expect(HookScripts.memoryHookDreaming.hasPrefix(HookScripts.memoryHookReminder),
                   "dreaming opens with the reminder")
        try expect(HookScripts.memoryHook.contains(HookScripts.memoryHookReminder),
                   "script embeds the reminder")
    })

    results.append(check("the display rendering uses literal placeholders, not shell expressions") {
        let d = HookScripts.memoryHookDreaming
        try expect(d.contains("≥10 writes"), "literal count")
        try expect(d.contains("\"sessionId\":\"<session-id>\""), "literal session id")
        try expect(d.contains("\"ts\":<epoch>"), "literal timestamp")
        try expect(!d.contains("${"), "no shell expansion leaked into the display copy")
        try expect(!d.contains("\\\""), "no bash escaping leaked into the display copy")
    })

    results.append(check("the script rendering substitutes and bash-escapes correctly") {
        let s = HookScripts.memoryHook
        try expect(s.contains("${WRITES_SINCE_DREAM} writes"), "count expanded")
        try expect(s.contains("\\\"sessionId\\\":\\\"${SESSION_ID}\\\""), "session id expanded + escaped")
        try expect(s.contains("\\\"ts\\\":\\$(date +%s)"), "timestamp expanded + escaped")
        try expect(!s.contains("{{"), "no template token left unreplaced")
    })

    results.append(check("no template tokens survive in either rendering") {
        for token in ["{{COUNT}}", "{{SESSION_ID}}", "{{TS}}", "{{DREAMING}}", "{{REMINDER}}"] {
            try expect(!HookScripts.memoryHook.contains(token), "memoryHook clean of \(token)")
            try expect(!HookScripts.memoryHookDreaming.contains(token), "dreaming clean of \(token)")
        }
    })

    results.append(check("memoryHook is a runnable bash script with both message branches") {
        let s = HookScripts.memoryHook
        try expect(s.hasPrefix("#!/usr/bin/env bash"), "shebang")
        try expect(s.contains("if [[ \"${WRITES_SINCE_DREAM}\" -ge 10 ]]; then"), "threshold branch")
        try expect(s.contains("MSG=\""), "message assigned")
        try expect(s.hasSuffix("\" \"$EVENT\" \"$MSG\""), "emits the hook JSON last")
    })

    results.append(check("the hook gates on the transcript before doing any memory work") {
        let s = HookScripts.memoryHook
        try expect(s.contains("transcript_path"), "reads the transcript path from the hook input")
        try expect(s.contains("TOUCHED"), "computes a touched-a-file verdict")
        // The silent exit must come before the log read, or a no-change session still pays for it.
        let gate = s.range(of: "if [[ \"${TOUCHED:-1}\" == \"0\" ]]; then")
        let logRead = s.range(of: "WRITES_SINCE_DREAM=$(")
        try expect(gate != nil && logRead != nil, "gate and log read both present")
        if let gate, let logRead {
            try expect(gate.lowerBound < logRead.lowerBound, "gate precedes the log read")
        }
        try expect(!s.contains("{\"name\":\"Edit\""), "matches tool_use blocks, not raw transcript text")
    })

    results.append(check("both the reminder and the strategy tell Claude to skip a no-change session") {
        try expect(HookScripts.memoryHookReminder.contains("skip the memory pass entirely"),
                   "reminder carries the skip clause")
        let p = HookScripts.memorySystemPrompt
        try expect(p.contains("### When to skip"), "strategy has a skip section")
        try expect(p.contains("No memory pass means no log entry"), "log section covers the skip case")
    })

    results.append(check("task command bodies are non-empty and carry their front matter") {
        for cmd in HookScripts.taskCommands {
            try expect(cmd.body.hasPrefix("---\ndescription:"), "\(cmd.filename) has front matter")
            try expect(cmd.filename.hasPrefix("claudepit-task-"), "\(cmd.filename) naming")
        }
        try expectEqual(HookScripts.taskCommands.count, 5, "five phase commands")
    })

    return results
}
