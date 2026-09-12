import Foundation

/// Runs the CLI's own `/usage` command non-interactively. Two things come back: the printed
/// report (plain aligned text, not markdown), and — as a side effect on success — freshly
/// rewritten `~/.claude.json` and `~/.claude/stats-cache.json`, which `UsageSnapshot`/`StatsCache`
/// then re-read. There is no `claude usage` subcommand; `-p "/usage"` is the whole interface.
public enum UsageRunner {
    public struct Result: Sendable {
        /// The report on success, the diagnostic on failure.
        public let text: String
        /// The caller (App module) turns this into a `.claudeAuthSuspect` notification — Core
        /// cannot name it, so the flag crosses the boundary instead (same shape as DiscoverRunner).
        public let signedOut: Bool
        public let failed: Bool

        public init(text: String, signedOut: Bool, failed: Bool) {
            self.text = text; self.signedOut = signedOut; self.failed = failed
        }
    }

    /// `cwd` is the active project, so the run is scoped the way the user's own `claude` would be.
    public static func refresh(cwd: URL?) async -> Result {
        guard let claudePath = Executable.find("claude") else {
            return Result(text: "claude not found on PATH.", signedOut: false, failed: true)
        }
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = ClaudeCLI.printArgs(
                    claudePath: claudePath, extra: ["--output-format", "text"])
                p.environment = ClaudeCLI.environment()
                if let cwd { p.currentDirectoryURL = cwd }

                let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
                p.standardInput = stdin
                p.standardOutput = stdout
                p.standardError = stderr

                do { try p.run() } catch {
                    continuation.resume(returning: Result(
                        text: "Could not launch claude.", signedOut: false, failed: true))
                    return
                }

                // The prompt goes over stdin — `printArgs` carries no prompt argument.
                stdin.fileHandleForWriting.write(Data("/usage".utf8))
                stdin.fileHandleForWriting.closeFile()

                // Drain both pipes before waiting or a full buffer deadlocks the child.
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 {
                    // `Not logged in` arrives on stdout with an empty stderr — reading stderr
                    // alone would discard exactly the diagnostic that matters.
                    let message = ClaudeCLI.failureMessage(stdout: out, stderr: err)
                    continuation.resume(returning: Result(
                        text: message.isEmpty ? "claude exited \(p.terminationStatus)." : message,
                        signedOut: ClaudeAuth.isNotLoggedIn(message),
                        failed: true))
                    return
                }
                continuation.resume(returning: Result(
                    text: out.trimmingCharacters(in: .whitespacesAndNewlines),
                    signedOut: false, failed: false))
            }
        }
    }
}
