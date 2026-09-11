import Foundation

/// Shared herdr CLI wrapper. One home for the binary path, availability check,
/// subprocess invocation (raw + JSON), and response parsing — used by both
/// `TaskRunner` (task pane orchestration) and `WorktreeResumer` (resume owning
/// session). `run`/`runJSON` are nonisolated and block on a background queue
/// via `withCheckedContinuation`, so callers never stall an actor thread.
public enum Herdr {
    /// Where `herdr` actually is on *this* machine, resolved once at first use.
    ///
    /// Resolution is pure filesystem — deliberately no subprocess. `available()` is called
    /// from SwiftUI view bodies (session rows, worktree rows), and a `Process` +
    /// `waitUntilExit()` there spins the run loop, which re-enters SwiftUI's transaction
    /// flush while AttributeGraph is mid-update and aborts the app. It is also cached so
    /// per-row calls stay free.
    ///
    /// Nothing about the install location is hardcoded or persisted: a Homebrew install,
    /// a `~/.local/bin` install, or anywhere else on PATH all resolve on their own machine.
    /// Trade-off: installing herdr while the app is running needs a relaunch to be noticed.
    public static let resolvedPath: String? = Executable.find("herdr")

    /// Best-known path to the binary. Falls back to a bare name so a failed resolution
    /// surfaces as a launch error rather than silently running the wrong thing.
    public static var path: String { resolvedPath ?? "herdr" }

    public static func available() -> Bool { resolvedPath != nil }

    /// Run a herdr command, returning parsed JSON (nil on failure / non-JSON).
    @discardableResult
    public static func runJSON(_ args: [String], cwd: URL?) async -> [String: Any]? {
        guard let raw = await run(args, cwd: cwd), let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Run a herdr command, returning raw stdout (nil if the process failed to launch).
    public static func run(_ args: [String], cwd: URL?) async -> String? {
        let exec = path
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(filePath: exec)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = cwd }
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                p.waitUntilExit()
                cont.resume(returning: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
            }
        }
    }

    /// Pane id from a `herdr pane split` response: `result.pane.pane_id`.
    public static func paneID(fromJSON obj: [String: Any]) -> String? {
        (obj["result"] as? [String: Any])
            .flatMap { $0["pane"] as? [String: Any] }
            .flatMap { $0["pane_id"] as? String }
    }

    /// Tab id from a `herdr pane get` response: `result.pane.tab_id`.
    public static func tabID(fromPaneJSON obj: [String: Any]) -> String? {
        (obj["result"] as? [String: Any])
            .flatMap { $0["pane"] as? [String: Any] }
            .flatMap { $0["tab_id"] as? String }
    }

    /// Pane id from a `herdr tab create` response: `result.root_pane.pane_id`.
    public static func rootPaneID(fromJSON obj: [String: Any]) -> String? {
        (obj["result"] as? [String: Any])
            .flatMap { $0["root_pane"] as? [String: Any] }
            .flatMap { $0["pane_id"] as? String }
    }

    /// One row of `herdr agent list`.
    ///
    /// `sessionID` is **optional**: herdr only reports `agent_session` for agents it has managed
    /// to bind to a Claude session, and a task agent started into a fresh worktree pane reports
    /// none at all. Requiring one used to drop every task agent from the list, which silently
    /// disabled the Tasks board's live running/waiting indicator. `name` is the agent's herdr
    /// name (`task-<id>-<phase>` for tasks) — the stable way to find a task's agent, since pane
    /// ids get recycled.
    public struct AgentEntry: Sendable {
        public let sessionID: String?
        public let name: String?
        public let paneID: String
        public let status: String
    }

    /// Agent status vocabulary herdr reports (`AgentStatus` in its API schema).
    /// Note that the Claude detection manifest only ever emits `idle`/`working`/`blocked`/
    /// `unknown` — **never `done`** — so "the turn finished" reads as `idle`, not `done`.
    public enum AgentState {
        public static let idle = "idle", working = "working", blocked = "blocked", done = "done"
    }

    public struct WorktreeCreateResult: Sendable {
        public let path: String
        public let paneID: String?
        public let tabID: String?
    }

    /// `herdr worktree create --cwd --branch --base --path --label --no-focus --json`.
    /// `path` pins the worktree location (pass `<project>/.claude/worktrees/…` so sessions
    /// started there map to the project's slug and show up in Sessions/Worktrees).
    /// Parses defensively: path from result.worktree.path → fallback result.pane.cwd;
    /// pane id via the pane-split key path; tab id via pane.tab_id.
    public static func worktreeCreate(cwd: URL, branch: String, base: String, path: String, label: String) async -> WorktreeCreateResult? {
        guard let obj = await runJSON(
            ["worktree", "create", "--cwd", cwd.path, "--branch", branch,
             "--base", base, "--path", path, "--label", label, "--no-focus", "--json"], cwd: cwd)
        else { return nil }
        let result = obj["result"] as? [String: Any]
        let wt = result?["worktree"] as? [String: Any]
        let pane = result?["pane"] as? [String: Any]
        let path = (wt?["path"] as? String) ?? (pane?["cwd"] as? String)
        guard let path else { return nil }
        return WorktreeCreateResult(path: path,
                                    paneID: paneID(fromJSON: obj),
                                    tabID: pane?["tab_id"] as? String)
    }

    /// `herdr tab create --cwd --label --no-focus` (JSON by default) → (paneID, tabID) for a fresh tab.
    /// pane id + tab id both come from `result.root_pane`.
    public static func tabCreate(cwd: URL, label: String) async -> (paneID: String, tabID: String)? {
        guard let obj = await runJSON(["tab", "create", "--cwd", cwd.path, "--label", label, "--no-focus"], cwd: cwd),
              let result = obj["result"] as? [String: Any],
              let rootPane = result["root_pane"] as? [String: Any],
              let pane = rootPane["pane_id"] as? String,
              let tab = rootPane["tab_id"] as? String else { return nil }
        return (pane, tab)
    }

    /// Returns all open herdr agents with their session IDs, pane IDs, and statuses.
    public static func agentList() async -> [AgentEntry] {
        guard let obj = await runJSON(["agent", "list"], cwd: nil),
              let result = obj["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return [] }
        return agents.compactMap { a in
            guard let pane = a["pane_id"] as? String,
                  let status = a["agent_status"] as? String else { return nil }
            let sid = (a["agent_session"] as? [String: Any])?["value"] as? String
            return AgentEntry(sessionID: (sid?.isEmpty == false) ? sid : nil,
                              name: a["name"] as? String, paneID: pane, status: status)
        }
    }

}
