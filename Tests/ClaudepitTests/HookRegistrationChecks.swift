import Foundation
@testable import ClaudepitCore

func hookRegistrationChecks() -> [Bool] {
    var results: [Bool] = []

    let script = "claudepit-summary-hook.sh"
    let mine = "bash '/Users/me/.claude/\(script)'"
    let theirs = "bash '/Users/someone-else/.claude/\(script)'"
    func entry(_ cmd: String) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": cmd]]]
    }
    func commands(_ entries: [[String: Any]]) -> [String] {
        entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
    }

    results.append(check("isManaged matches our script under any home directory") {
        try expect(HookRegistration.isManaged(mine, scriptName: script), "own home")
        try expect(HookRegistration.isManaged(theirs, scriptName: script), "foreign home")
        try expect(!HookRegistration.isManaged("bash '/opt/other-tool.sh'", scriptName: script), "unrelated")
    })

    results.append(check("prune drops registrations from every home, keeps foreign hooks") {
        let input = [entry(theirs), entry("bash '/opt/other-tool.sh'"), entry(mine)]
        let (out, removed) = HookRegistration.prune(input, scriptName: script)
        try expectEqual(removed, 2, "removed")
        try expectEqual(commands(out), ["bash '/opt/other-tool.sh'"], "survivors")
    })

    results.append(check("prune keeps an unrelated hook sharing an entry with ours") {
        let input: [[String: Any]] = [["matcher": "*", "hooks": [
            ["type": "command", "command": theirs],
            ["type": "command", "command": "bash '/opt/other-tool.sh'"],
        ]]]
        let (out, removed) = HookRegistration.prune(input, scriptName: script)
        try expectEqual(removed, 1, "removed")
        try expectEqual(commands(out), ["bash '/opt/other-tool.sh'"], "survivor kept")
    })

    // The regression this exists for: a checkout carried to a second machine.
    results.append(check("reconcile replaces a previous machine's registration, not duplicates it") {
        let (out, changed) = HookRegistration.reconcile([entry(theirs)], scriptName: script, command: mine)
        try expect(changed, "should report changed")
        try expectEqual(commands(out), [mine], "stale entry replaced")
    })

    results.append(check("reconcile registers into empty settings") {
        let (out, changed) = HookRegistration.reconcile([], scriptName: script, command: mine)
        try expect(changed, "should report changed")
        try expectEqual(commands(out), [mine], "registered once")
    })

    results.append(check("reconcile is idempotent once correct") {
        let (once, firstChanged) = HookRegistration.reconcile([], scriptName: script, command: mine)
        try expect(firstChanged, "first run changes")
        let (twice, secondChanged) = HookRegistration.reconcile(once, scriptName: script, command: mine)
        try expect(!secondChanged, "second run must not rewrite")
        try expectEqual(commands(twice), [mine], "still registered exactly once")
    })

    results.append(check("reconcile collapses an accumulated duplicate to one") {
        let (out, changed) = HookRegistration.reconcile(
            [entry(theirs), entry(mine)], scriptName: script, command: mine)
        try expect(changed, "should report changed")
        try expectEqual(commands(out), [mine], "single registration remains")
    })

    results.append(check("reconcile leaves unrelated hooks untouched") {
        let other = "bash '/opt/other-tool.sh'"
        let (out, _) = HookRegistration.reconcile(
            [entry(other), entry(theirs)], scriptName: script, command: mine)
        try expectEqual(commands(out), [other, mine], "foreign hook preserved")
    })

    return results
}

/// The claude/herdr binary location must be discovered per-machine, never assumed.
/// Assuming Homebrew's path meant `available()` fell through to a `which`
/// subprocess run inside a SwiftUI view body, which aborted the app.
func herdrPathChecks() -> [Bool] {
    var results: [Bool] = []

    results.append(check("findExecutable locates a tool that exists on PATH") {
        let sh = Executable.find("sh")
        try expect(sh != nil, "sh should resolve")
        try expect(FileManager.default.isExecutableFile(atPath: sh!), "resolved sh is executable")
    })

    results.append(check("findExecutable returns nil for a tool that does not exist") {
        try expect(Executable.find("claudepit-definitely-not-a-real-binary") == nil, "should not resolve")
    })

    results.append(check("findExecutable does not depend on a hardcoded install prefix") {
        // `env` lives in /usr/bin on every Mac; `ls` in /bin. Both must resolve even
        // though neither is under the Homebrew prefix the app used to assume.
        try expect(Executable.find("env") != nil, "env resolves")
        try expect(Executable.find("ls") != nil, "ls resolves")
    })

    results.append(check("available() agrees with resolvedPath and never spawns a process") {
        try expectEqual(Herdr.available(), Herdr.resolvedPath != nil, "available matches resolution")
    })

    return results
}
