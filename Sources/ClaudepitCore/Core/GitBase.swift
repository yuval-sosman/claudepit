import Foundation

/// The single source of truth for "what is this repo's base branch, and which ref do we
/// compare and merge against". Extracted from `TaskRunner` so the worktree scan's base and a
/// task worktree's fork point cannot drift apart — one implementation, one answer.
///
/// Every function here that spawns a subprocess is `async` and goes through `Subprocess.run`,
/// which hops to `DispatchQueue.global()` before it touches a `Process`. A caller therefore just
/// `await`s: no thread is blocked — not the main actor (where a `waitUntilExit()` spins the run
/// loop, re-enters SwiftUI's transaction flush and aborts the app) and not a cooperative-pool
/// thread either.
///
/// `Task.detached` is NOT a way off the cooperative pool — it starts an *unstructured* task on
/// the same pool, so a blocking wait inside one occupies a pool thread just as a plain `Task`
/// would, and the pool is only as wide as the core count. An earlier version of this file
/// claimed its callers "hopped off" that way; they did not, and the worktree scan (which runs on
/// every FileWatcher tick, with up to 15 s of `fetchBase` plus 3-4 subprocesses per worktree)
/// could starve the task pollers and every herdr call with no error surfaced anywhere. Do not
/// reintroduce a `Task.detached` wrapper around these calls.
public enum GitBase {

    /// The project's trunk — task worktrees fork from here and the worktree scan compares
    /// against it. Prefers origin's default branch (works whether it's named
    /// main/master/trunk/whatever); falls back to a local "main" or "master" when there's no
    /// remote; falls back to the checked-out branch only if neither exists.
    /// Returns a BARE name ("main"), never a remote-qualified ref. nil on a detached HEAD with
    /// no main/master — a legitimate repo shape in which every base-dependent affordance hides.
    public static func trunkBranch(repoRoot: String) async -> String? {
        // `--short` prints "origin/<branch>"; strip that prefix rather than taking the last path
        // segment — a default branch named "release/main" must not resolve to "main", which is a
        // DIFFERENT branch we would then display and `git merge` into the user's worktree.
        if let ref = await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], dir: repoRoot) {
            let name = ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
            if !name.isEmpty { return name }
        }
        for candidate in ["main", "master"] {
            if await git(["rev-parse", "--verify", "--quiet", candidate], dir: repoRoot) != nil {
                return candidate
            }
        }
        // --abbrev-ref returns the branch name; "HEAD" means detached.
        let b = await git(["rev-parse", "--abbrev-ref", "HEAD"], dir: repoRoot)
        return (b?.isEmpty == false && b != "HEAD") ? b : nil
    }

    /// The ref to compare and merge against: "origin/<base>" when the remote-tracking ref
    /// exists on disk, else the local "<base>".
    public static func baseRef(repoRoot: String, base: String) async -> String {
        await git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(base)"], dir: repoRoot) != nil
            ? "origin/\(base)" : base
    }

    /// True when the repo has an `origin` remote. Gates `fetchBase`: without a remote
    /// `git fetch origin` exits 128, and there is nothing to be out of date with.
    public static func hasOrigin(repoRoot: String) async -> Bool {
        await git(["remote", "get-url", "origin"], dir: repoRoot) != nil
    }

    /// `git fetch --quiet origin <base>` at `repoRoot`. Returns false on ANY failure: no
    /// origin, offline, credentials refused, timed out. Never throws.
    ///
    /// This is the only network call in the app and it runs INSIDE the worktree scan, which
    /// runs unattended every few minutes — a stalled fetch would freeze dirty counts, merge
    /// state and the whole worktree list for its duration. A null stdin stops an interactive
    /// prompt but not an unreachable host, so this additionally:
    ///   - refuses up front when there is no `origin`;
    ///   - disables every credential/host-key prompt path via the environment;
    ///   - inherits `Subprocess`'s hard ceiling, which SIGTERMs at `timeout` and SIGKILLs a
    ///     child that ignores it — the old hand-rolled watchdog sent SIGTERM only and then fell
    ///     back into `waitUntilExit()`, so a git that trapped the signal blocked forever.
    /// Both streams are drained concurrently rather than pointed at /dev/null: only the exit
    /// code matters here, and a *drained* pipe is what makes the call deadlock-free (an
    /// undrained one deadlocks the child once its ~64KB buffer fills).
    @discardableResult
    public static func fetchBase(repoRoot: String, base: String, timeout: TimeInterval = 15) async -> Bool {
        guard await hasOrigin(repoRoot: repoRoot) else { return false }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oConnectTimeout=5"
        let r = await Subprocess.run("/usr/bin/env",
                                    ["git", "-C", repoRoot, "fetch", "--quiet", "origin", base],
                                    environment: env, timeout: timeout)
        return r?.ok == true
    }

    /// Parse `git rev-list --left-right --count <base>...HEAD`. Git emits a TAB-separated pair
    /// ("3\t5"); the LEFT side is reachable-from-base-but-not-HEAD (behind) and the RIGHT side
    /// is reachable-from-HEAD-but-not-base (ahead). Pure. nil unless both fields are integers.
    public static func parseLeftRight(_ output: String) -> (behind: Int, ahead: Int)? {
        let parts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else { return nil }
        return (behind, ahead)
    }

    /// Throttle predicate for the scan's fetch. Pure — `now` is injected, never read inside,
    /// so it is testable and the caller can stamp its timestamp before dispatching.
    public static func shouldFetch(last: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    // MARK: - subprocess

    /// The module's one read-only git call: trimmed stdout, or nil on a non-zero exit, a timeout
    /// or a launch failure. On `Subprocess`, so both pipes are drained while git runs and a stuck
    /// child dies at the ceiling instead of blocking the caller (see `Subprocess`'s type comment).
    /// Internal, not private: `WorktreeScanner` uses it too rather than hand-rolling a second one.
    static func git(_ args: [String], dir: String,
                    timeout: TimeInterval = Subprocess.defaultTimeout) async -> String? {
        guard let r = await Subprocess.run("/usr/bin/env", ["git", "-C", dir] + args, timeout: timeout),
              r.ok else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
