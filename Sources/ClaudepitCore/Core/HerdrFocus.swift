import Foundation

/// Bringing a herdr pane to the user's attention — the whole job, not half of it.
///
/// Two things have to happen and the app used to do only the first:
///
/// 1. **Select the pane inside herdr.** Every call site used `tab focus <stored tabID>`, which
///    addresses the tab by an id copied into `task.json` when the pane was created. That id goes
///    stale (herdr restart, tab closed and reopened) and the command then silently no-ops.
///    `agent focus <agentName>` addresses the *agent*, whose name is stable for the life of the
///    phase, so it cannot drift out of sync with what herdr actually holds.
/// 2. **Raise the window it lives in.** herdr is a TUI hosted by a terminal application (ghostty,
///    iTerm, Terminal…). Switching its tab changes nothing the user can see while Claudepit is
///    frontmost — which is exactly what "Open in Herdr does nothing" was. Only the host app's
///    pid can be resolved here; `NSRunningApplication` lives in AppKit, so the activation itself
///    is one line in the app layer (`AppState.activateHerdrHost`).
public enum HerdrFocus {

    // MARK: - Selecting the pane

    /// The herdr commands to try, in order, to put `agentName` (or failing that its tab) on screen.
    ///
    /// Pure so the ordering is assertable: the name-addressed command must come first, because the
    /// ids are the part that can be stale. An empty result means we hold nothing to focus with.
    public static func focusArgs(agentName: String?, tabID: String?) -> [[String]] {
        var out: [[String]] = []
        if let agentName, !agentName.isEmpty { out.append(["agent", "focus", agentName]) }
        if let tabID, !tabID.isEmpty { out.append(["tab", "focus", tabID]) }
        return out
    }

    /// Run `focusArgs` until one command succeeds. Returns whether anything did.
    ///
    /// herdr reports failure on stderr with an empty stdout (see `Herdr.run`), so a non-empty
    /// stdout is the success test.
    @discardableResult
    public static func focus(agentName: String?, tabID: String?, cwd: URL? = nil) async -> Bool {
        for args in focusArgs(agentName: agentName, tabID: tabID) {
            if let out = await Herdr.run(args, cwd: cwd), !out.isEmpty { return true }
        }
        return false
    }

    // MARK: - Finding the host application

    /// One row of the process table: just enough to walk parents and spot herdr.
    public struct ProcessRow: Sendable, Equatable {
        public let pid: pid_t
        public let ppid: pid_t
        public let name: String
        public init(pid: pid_t, ppid: pid_t, name: String) {
            self.pid = pid; self.ppid = ppid; self.name = name
        }
    }

    /// Ancestors of `pid`, nearest first, excluding `pid` itself and launchd.
    ///
    /// Pure, and cycle-proof: a corrupt parent map must not spin here, so a pid already seen ends
    /// the walk.
    public static func ancestry(of pid: pid_t, in parents: [pid_t: pid_t]) -> [pid_t] {
        var out: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var cursor = pid
        while let parent = parents[cursor], parent > 1, !seen.contains(parent) {
            out.append(parent)
            seen.insert(parent)
            cursor = parent
        }
        return out
    }

    /// Pids that might be the GUI application hosting herdr, best candidate first.
    ///
    /// Walks up from every running `herdr` process. Chains that pass through `ownPID` are dropped:
    /// the short-lived `herdr` commands *this app* spawns are herdr processes too, and their
    /// ancestry leads straight back to Claudepit — which is a `.regular` app and would "win",
    /// activating ourselves instead of the terminal.
    public static func hostCandidates(rows: [ProcessRow], ownPID: pid_t) -> [pid_t] {
        let parents = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var out: [pid_t] = []
        var seen: Set<pid_t> = []
        for row in rows where row.name == "herdr" {
            let chain = ancestry(of: row.pid, in: parents)
            guard !chain.contains(ownPID), row.pid != ownPID else { continue }
            for pid in chain where !seen.contains(pid) {
                seen.insert(pid)
                out.append(pid)
            }
        }
        return out
    }

    /// `hostCandidates` against the live process table.
    public static func hostCandidatePIDs() -> [pid_t] {
        hostCandidates(rows: processTable(), ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// The BSD process table via `sysctl(KERN_PROC_ALL)` — no subprocess, so this stays safe to
    /// call from anywhere (`Executable.find`'s rule).
    public static func processTable() -> [ProcessRow] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { proc in
            // `p_comm` is a fixed-size C char tuple; read it through a pointer to a local copy.
            // The capacity is captured first — evaluating it inside `withUnsafePointer` would be a
            // second access to the same variable the pointer already exclusively holds.
            var comm = proc.kp_proc.p_comm
            let width = MemoryLayout.size(ofValue: comm)
            let name = withUnsafePointer(to: &comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: width) { String(cString: $0) }
            }
            return ProcessRow(pid: proc.kp_proc.p_pid, ppid: proc.kp_eproc.e_ppid, name: name)
        }
    }
}
