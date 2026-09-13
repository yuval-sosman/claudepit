import Foundation
@testable import ClaudepitCore

/// `HerdrFocus` — the pure halves of "put a herdr pane in front of the user".
func herdrFocusChecks() -> [Bool] {
    var results: [Bool] = []

    // MARK: - focusArgs: the ordering IS the fix, so it is what gets asserted.

    results.append(check("focusArgs tries the agent name before the tab id") {
        // The agent name is stable for the life of the phase; the tab id is a snapshot taken when
        // the pane was created and goes stale on a herdr restart. Name first, or the stale id wins
        // and the command silently no-ops — which is what "Open in Herdr does nothing" looked like.
        try expectEqual(HerdrFocus.focusArgs(agentName: "task-56cf65b6-brainstorm", tabID: "w3:tQ"),
                        [["agent", "focus", "task-56cf65b6-brainstorm"], ["tab", "focus", "w3:tQ"]],
                        "agent focus first, tab focus as fallback")
    })

    results.append(check("focusArgs degrades to whichever handle it has") {
        try expectEqual(HerdrFocus.focusArgs(agentName: nil, tabID: "w3:tQ"),
                        [["tab", "focus", "w3:tQ"]], "no agent name")
        try expectEqual(HerdrFocus.focusArgs(agentName: "a", tabID: nil),
                        [["agent", "focus", "a"]], "no tab recorded")
        try expect(HerdrFocus.focusArgs(agentName: "", tabID: "").isEmpty,
                   "empty strings are not handles")
        try expect(HerdrFocus.focusArgs(agentName: nil, tabID: nil).isEmpty,
                   "nothing to focus → no commands")
    })

    // MARK: - ancestry

    results.append(check("ancestry walks to the GUI app, nearest first, stopping before launchd") {
        // 700 herdr → 600 shell → 500 login → 400 terminal app → 1 launchd.
        let parents: [pid_t: pid_t] = [700: 600, 600: 500, 500: 400, 400: 1]
        try expectEqual(HerdrFocus.ancestry(of: 700, in: parents), [600, 500, 400], "chain")
        try expect(HerdrFocus.ancestry(of: 999, in: parents).isEmpty, "unknown pid → empty")
    })

    results.append(check("ancestry terminates on a parent cycle") {
        // A corrupt table must not spin the caller.
        try expectEqual(HerdrFocus.ancestry(of: 10, in: [10: 11, 11: 12, 12: 10]), [11, 12], "cycle")
    })

    // MARK: - hostCandidates

    let rows: [HerdrFocus.ProcessRow] = [
        .init(pid: 400, ppid: 1, name: "ghostty"),
        .init(pid: 500, ppid: 400, name: "login"),
        .init(pid: 600, ppid: 500, name: "zsh"),
        .init(pid: 700, ppid: 600, name: "herdr"),       // the server, under the terminal
        .init(pid: 900, ppid: 1, name: "ClaudepitApp"),
        .init(pid: 901, ppid: 900, name: "herdr"),       // a short-lived command WE spawned
    ]

    results.append(check("hostCandidates walks up from herdr to the terminal application") {
        try expectEqual(HerdrFocus.hostCandidates(rows: rows, ownPID: 900), [600, 500, 400], "chain")
    })

    results.append(check("hostCandidates drops chains that pass through our own pid") {
        // The decisive case: the `herdr` commands this app spawns are herdr processes too, and
        // their ancestry leads back to Claudepit — itself a `.regular` app, which would "win" and
        // activate ourselves instead of the terminal.
        try expect(!HerdrFocus.hostCandidates(rows: rows, ownPID: 900).contains(900),
                   "never offer our own app as the host")
    })

    results.append(check("hostCandidates is empty when no herdr is running") {
        try expect(HerdrFocus.hostCandidates(rows: rows.filter { $0.name != "herdr" },
                                             ownPID: 900).isEmpty,
                   "nothing to raise")
    })

    results.append(check("hostCandidates offers every host once, in discovery order") {
        let two = rows + [.init(pid: 410, ppid: 1, name: "iTerm2"),
                          .init(pid: 710, ppid: 410, name: "herdr")]
        try expectEqual(HerdrFocus.hostCandidates(rows: two, ownPID: 900),
                        [600, 500, 400, 410], "two terminals, no repeats")
    })

    results.append(check("processTable reads the live process list") {
        let live = HerdrFocus.processTable()
        try expect(live.count > 1, "more than one process on this machine")
        try expect(live.contains { $0.pid == ProcessInfo.processInfo.processIdentifier },
                   "finds this very process")
    })

    // MARK: - Subprocess ceiling for a herdr call carrying its own --timeout

    results.append(check("a herdr --timeout gets a subprocess ceiling above it") {
        // The 120s default would kill a legitimate 30-minute `agent wait` two minutes in, and
        // every long phase would land in `.failed`.
        try expectEqual(TaskRunner.ceiling(forHerdrTimeoutMS: "1800000"), 1860, "30 min + slack")
        try expectEqual(TaskRunner.ceiling(forHerdrTimeoutMS: "20000"), 80, "20 s + slack")
        try expectEqual(TaskRunner.ceiling(forHerdrTimeoutMS: "nope"),
                        Subprocess.defaultTimeout + 60, "garbled → default + slack")
    })

    return results
}
