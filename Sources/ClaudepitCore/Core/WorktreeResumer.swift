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

    /// Resume a Claude session. If `existingPaneID` is provided (session already open in herdr),
    /// focuses that pane's tab instead of launching a new one.
    public static func resume(sessionID: String, cwd: String, label: String, existingPaneID: String? = nil) async {
        let dir = URL(filePath: cwd)
        if let paneID = existingPaneID,
           let obj = await Herdr.runJSON(["pane", "get", paneID], cwd: dir),
           let tabID = Herdr.tabID(fromPaneJSON: obj) {
            _ = await Herdr.run(["tab", "focus", tabID], cwd: dir)
            return
        }
        guard let obj = await Herdr.runJSON(["tab", "create", "--cwd", cwd, "--label", label, "--focus"], cwd: dir),
              let pane = Herdr.rootPaneID(fromJSON: obj) else { return }
        _ = await Herdr.run(["pane", "run", pane, "claude", "--resume", sessionID], cwd: dir)
    }
}
