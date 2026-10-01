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
    public static func runJSON(_ args: [String], cwd: URL?,
                               timeout: TimeInterval = Subprocess.defaultTimeout) async -> [String: Any]? {
        guard let raw = await run(args, cwd: cwd, timeout: timeout), let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Run a herdr command, returning raw **stdout** (nil if the process failed to launch).
    ///
    /// Stdout only, deliberately: herdr writes its `{"error":{"code":…}}` payloads to **stderr**
    /// and leaves stdout empty, so a failed command yields "" here and therefore nil from
    /// `runJSON`. `TaskRunner` reads that nil as "the command failed" — `agent start` answering
    /// `agent_name_taken` is the load-bearing case. Folding stderr into the return value would
    /// turn every error into a successfully-parsed object.
    ///
    /// Bounded by `Subprocess`: both pipes are drained while the child runs and `timeout` kills a
    /// child that never exits. A hang here suspends its caller forever and, on the task-drive
    /// path, wedges the task's `AppState.driving` entry for the life of the app.
    public static func run(_ args: [String], cwd: URL?,
                           timeout: TimeInterval = Subprocess.defaultTimeout) async -> String? {
        await Subprocess.run(path, args, cwd: cwd, timeout: timeout)?.stdout
    }

    /// herdr's agent-name rule (0.8.2): start with a lowercase letter; only lowercase letters,
    /// digits, `-` or `_`; 1–32 characters. Anything else fails `agent start` with
    /// `invalid_agent_name` — after the tab is already open, so the click looks like "herdr opened
    /// a pane and nothing ran". Brainstorm's `brainstorm-plan-<long slug>` hit exactly that.
    public static let maxAgentNameLength = 32

    /// `raw` made into a name herdr accepts. A valid name comes back unchanged; anything else is
    /// lowercased, its other characters turned into `-`, and — when too long — cut and closed with
    /// a stable 6-hex hash of `raw`, so two long names sharing a prefix stay distinct and the same
    /// `raw` always maps to the same name (a second click must find the first click's agent).
    public static func agentName(_ raw: String) -> String {
        var chars: [Character] = raw.lowercased().map { c in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "_" ? c : "-"
        }
        if chars.first.map({ !($0.isASCII && $0.isLetter) }) ?? true { chars.insert(contentsOf: "a-", at: 0) }
        guard chars.count > maxAgentNameLength else { return String(chars) }
        var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a: stable across launches, unlike hashValue
        for byte in raw.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let suffix = String(String(hash, radix: 16).suffix(6))
        var head = String(chars.prefix(maxAgentNameLength - suffix.count - 1))
        while head.hasSuffix("-") || head.hasSuffix("_") { head.removeLast() }
        return head + "-" + suffix
    }

    /// Whether the command exited 0. For commands that print nothing either way — `pane send-text`
    /// writes no stdout on success or failure (herdr 0.8.2), so only the exit code tells them apart.
    public static func succeeds(_ args: [String], cwd: URL?,
                                timeout: TimeInterval = Subprocess.defaultTimeout) async -> Bool {
        await Subprocess.run(path, args, cwd: cwd, timeout: timeout)?.ok ?? false
    }

    /// Submit `text` to a running agent — by name or pane id — as if typed and sent. herdr refuses
    /// (`agent_blocked`) while the agent is waiting on a question, and says so only on stderr, so
    /// the exit code is the answer.
    public static func prompt(agent target: String, text: String) async -> Bool {
        await succeeds(["agent", "prompt", target, text], cwd: nil)
    }

    /// Press keys in an agent's terminal (`esc`, `enter`, …).
    public static func sendKeys(agent target: String, keys: [String]) async -> Bool {
        await succeeds(["agent", "send-keys", target] + keys, cwd: nil)
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
        /// `terminal_title_stripped` — Claude Code's own terminal title (its running session's
        /// topic, e.g. "fix-worktree-project-slug"), minus the spinner glyph. The only
        /// human-readable name herdr has for an unnamed agent.
        public let title: String?
        public let cwd: String?
        /// Which agent it is (`claude`, `codex`, …) — only a Claude session can be sent `/loop`.
        public let kind: String?

        public init(sessionID: String?, name: String?, paneID: String, status: String,
                    title: String? = nil, cwd: String? = nil, kind: String? = nil) {
            self.sessionID = sessionID; self.name = name; self.paneID = paneID
            self.status = status; self.title = title; self.cwd = cwd; self.kind = kind
        }
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
            let title = a["terminal_title_stripped"] as? String
            return AgentEntry(sessionID: (sid?.isEmpty == false) ? sid : nil,
                              name: a["name"] as? String, paneID: pane, status: status,
                              title: (title?.isEmpty == false) ? title : nil,
                              cwd: a["cwd"] as? String, kind: a["agent"] as? String)
        }
    }

}
