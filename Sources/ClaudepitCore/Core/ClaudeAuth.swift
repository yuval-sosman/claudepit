import Foundation

/// Whether the `claude` CLI on this machine has a usable login, and what to do if not.
public struct ClaudeAuthStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case loggedIn
        case loggedOut
        /// `claude` isn't installed anywhere we look, or failed to launch.
        case cliNotFound
        /// The check itself didn't work — non-zero exit, or output we can't parse.
        /// Distinct from `.loggedOut` on purpose: a CLI too old to have `auth status`
        /// lands here, and must not be reported to the user as "signed out".
        case checkFailed(String)
    }

    public let state: State
    public let authMethod: String?
    public let email: String?
    public let orgName: String?
    public let subscriptionType: String?

    public init(state: State, authMethod: String? = nil, email: String? = nil,
                orgName: String? = nil, subscriptionType: String? = nil) {
        self.state = state
        self.authMethod = authMethod
        self.email = email
        self.orgName = orgName
        self.subscriptionType = subscriptionType
    }

    public var isLoggedIn: Bool { state == .loggedIn }
    /// The only state that should surface a "sign in" prompt to the user.
    public var needsSignIn: Bool { state == .loggedOut }
}

public enum ClaudeAuth {

    public static let signInCommand = "claude auth login"

    /// What `claude auth status --json` prints. Every field but `loggedIn` is optional:
    /// a logged-out payload carries only `loggedIn`/`authMethod`/`apiProvider`, and an
    /// `ANTHROPIC_API_KEY` login reports `loggedIn: true` with null email/org.
    private struct Payload: Decodable {
        let loggedIn: Bool
        let authMethod: String?
        let email: String?
        let orgName: String?
        let subscriptionType: String?
    }

    /// Parse the CLI's stdout. nil when it isn't the shape we expect — which is the
    /// signal for `.checkFailed`, never for `.loggedOut`.
    public static func decode(stdout: String) -> ClaudeAuthStatus? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return ClaudeAuthStatus(
            state: p.loggedIn ? .loggedIn : .loggedOut,
            authMethod: p.authMethod, email: p.email,
            orgName: p.orgName, subscriptionType: p.subscriptionType)
    }

    /// True when a failed `claude -p` message means "no usable login" rather than
    /// some other error. Matched against the *merged* streams — the message arrives on
    /// stdout, not stderr (see `ClaudeCLI.failureMessage`).
    public static func isNotLoggedIn(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("not logged in")
            || m.contains("please run /login")
            || m.contains("oauth token has expired")
            || m.contains("invalid api key")
    }

    /// Runs `claude auth status --json` off the main actor (~260 ms). Never throws.
    ///
    /// Do **not** call this from a SwiftUI view body. `Herdr.available()` is body-safe
    /// only because it is a pure-filesystem `static let`; a `Process` + `waitUntilExit()`
    /// reached from `body` re-enters SwiftUI's transaction flush mid-update and aborts
    /// the app. Cache the result and read the cached value from views.
    public static func status() async -> ClaudeAuthStatus {
        guard let exec = Executable.find("claude") else {
            return ClaudeAuthStatus(state: .cliNotFound)
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(filePath: exec)
                p.arguments = ["auth", "status", "--json"]
                p.environment = ClaudeCLI.environment()
                // No cwd: auth is machine-global, and a project's settings shouldn't skew it.

                // Without this the child inherits the GUI app's stdin, which never
                // delivers EOF, and the process hangs forever.
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err

                do { try p.run() } catch {
                    cont.resume(returning: ClaudeAuthStatus(state: .cliNotFound)); return
                }
                // A wedged child would otherwise pin the caller's "checking" flag on
                // forever. terminate() unblocks waitUntilExit, so we still resume once.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    if p.isRunning { p.terminate() }
                }

                // Drain both pipes before waiting, or a full buffer deadlocks the child.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()

                let stdout = String(data: outData, encoding: .utf8) ?? ""
                // `auth status` exits 1 when logged out but still prints valid JSON, so
                // the payload — not the exit code — decides. Only unparseable output is
                // a failed check.
                if let status = decode(stdout: stdout) {
                    cont.resume(returning: status); return
                }
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                let why = ClaudeCLI.failureMessage(stdout: stdout, stderr: stderr)
                cont.resume(returning: ClaudeAuthStatus(
                    state: .checkFailed(why.isEmpty ? "no output" : String(why.prefix(200)))))
            }
        }
    }

    /// Open a focused herdr tab running `claude auth login`. false when herdr is absent —
    /// the caller falls back to showing the command, since there is no in-app terminal.
    /// `--focus` (unlike `Herdr.tabCreate`) so the browser prompt is seen immediately.
    @discardableResult
    public static func signIn(cwd: String) async -> Bool {
        guard Herdr.available() else { return false }
        let dir = URL(filePath: cwd)
        guard let obj = await Herdr.runJSON(
                ["tab", "create", "--cwd", cwd, "--label", "claude login", "--focus"], cwd: dir),
              let pane = Herdr.rootPaneID(fromJSON: obj) else { return false }
        _ = await Herdr.run(["pane", "run", pane, "claude", "auth", "login"], cwd: dir)
        return true
    }
}
