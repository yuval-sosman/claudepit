import Foundation

/// One place that decides how Claudepit invokes the `claude` CLI as a subprocess.
///
/// Scripted calls have to be isolated from the user's own configuration — above all from
/// Claudepit's own `UserPromptSubmit` summary hook, which injects `additionalContext` and
/// would otherwise contaminate every answer we show. The flag that used to buy that
/// isolation was `--bare`, and it silently broke every call: `--bare` skips keychain reads
/// and accepts only `ANTHROPIC_API_KEY` or an `apiKeyHelper`, so a subscription login can
/// never authenticate under it. `--safe-mode` suppresses the same customizations —
/// hooks (user *and* project scope), CLAUDE.md, skills, plugins, MCP servers, auto-memory —
/// while leaving auth, model selection and permissions working normally.
///
/// The other half of that bug was `CLAUDE_CONFIG_DIR`. Setting it *at all* — even to the
/// default `~/.claude` — makes the CLI look up a keychain service name suffixed with a hash
/// of the path (`Claude Code-credentials-<hash>`), which holds no credentials. So we never
/// set it. We do not strip an inherited one either: a user who exports it globally has
/// their credentials under that hashed entry, and passing it through is what makes our
/// subprocess behave like their own `claude`.
public enum ClaudeCLI {

    /// Suppresses hooks/CLAUDE.md/plugins/MCP/auto-memory without disabling auth.
    /// Never replace this with `--bare` — see the type doc.
    public static let isolationFlag = "--safe-mode"

    /// Argv for a one-shot `claude -p` call. The prompt itself goes in over stdin.
    public static func printArgs(claudePath: String, extra: [String] = []) -> [String] {
        [claudePath, "-p", "--no-session-persistence", isolationFlag] + extra
    }

    /// Argv for resuming a session to run a built-in slash command (e.g. `/context`).
    /// No `--no-session-persistence` decision here: callers pass it in `extra` if the
    /// report should leave no trace.
    public static func resumeArgs(
        claudePath: String, sessionID: String, command: String, extra: [String] = []
    ) -> [String] {
        [claudePath, "-r", sessionID, "-p", isolationFlag] + extra + [command]
    }

    /// Environment for a spawned `claude`: the inherited one with PATH widened to the
    /// places a Finder-launched app can't see. `CLAUDE_CONFIG_DIR` is deliberately never
    /// added. `USER` is deliberately never removed — the keychain account name is derived
    /// from it, and a subprocess without it fails exactly like a logged-out one.
    public static func environment(
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = parent
        env["PATH"] = Executable.augmentedPATH()
        return env
    }

    /// The line worth showing a user when `claude` exits non-zero.
    ///
    /// Which stream carries the reason depends on the failure: an unknown flag goes to
    /// stderr with an empty stdout, while `Not logged in · Please run /login` goes to
    /// **stdout** with an empty stderr. Reading stderr alone — which is what both runners
    /// used to do — throws away the diagnostic in the case that matters most.
    public static func failureMessage(stdout: String, stderr: String) -> String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
