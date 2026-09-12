import Foundation

/// Read-only "resume owning session" launcher: opens a new herdr tab at the
/// worktree and starts `claude --resume <sessionID>` in it. Fire-and-forget.
/// All herdr subprocess plumbing lives in the shared `Herdr` lib (same one
/// `TaskRunner` uses).
public enum WorktreeResumer {
    public static func available() -> Bool { Herdr.available() }

    /// Open a new herdr tab at `cwd` and run `git checkout <branch>` in it.
    public static func checkout(branch: String, cwd: String) async {
        let dir = URL(filePath: cwd)
        guard let obj = await Herdr.runJSON(["tab", "create", "--cwd", cwd, "--label", branch, "--focus"], cwd: dir),
              let pane = Herdr.rootPaneID(fromJSON: obj) else { return }
        _ = await Herdr.run(["pane", "run", pane, "git", "checkout", branch], cwd: dir)
    }

    /// Focus the herdr tab hosting `paneID`. Returns false when the pane no longer exists —
    /// callers can fall back to launching something new. Shared by "Focus in Herdr" everywhere
    /// (session rows, Home's Live Agents, the resume path below).
    @discardableResult
    public static func focusPane(paneID: String, cwd: String) async -> Bool {
        let dir = URL(filePath: cwd)
        guard let obj = await Herdr.runJSON(["pane", "get", paneID], cwd: dir),
              let tabID = Herdr.tabID(fromPaneJSON: obj) else { return false }
        _ = await Herdr.run(["tab", "focus", tabID], cwd: dir)
        return true
    }

    /// Resume a Claude session. If `existingPaneID` is provided (session already open in herdr),
    /// focuses that pane's tab instead of launching a new one.
    public static func resume(sessionID: String, cwd: String, label: String, existingPaneID: String? = nil) async {
        if let paneID = existingPaneID, await focusPane(paneID: paneID, cwd: cwd) { return }
        let dir = URL(filePath: cwd)
        guard let obj = await Herdr.runJSON(["tab", "create", "--cwd", cwd, "--label", label, "--focus"], cwd: dir),
              let pane = Herdr.rootPaneID(fromJSON: obj) else { return }
        _ = await Herdr.run(["pane", "run", pane, "claude", "--resume", sessionID], cwd: dir)
    }
}
