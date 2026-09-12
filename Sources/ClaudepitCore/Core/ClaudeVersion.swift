import Foundation

/// Resolves the installed CLI's version — the one useful fact on `/usage`'s Status tab.
/// `claude --version` prints `2.1.236 (Claude Code)`; no cache file records it, so this is
/// a subprocess like the other runners: detached, never reachable from a view body.
public enum ClaudeVersion {
    /// "2.1.236 (Claude Code)" → "2.1.236". nil when the output doesn't lead with a semver-ish
    /// token, so an error message is never displayed as a version.
    public static func parse(_ output: String) -> String? {
        guard let first = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first else { return nil }
        let token = String(first)
        guard token.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil
        else { return nil }
        return token
    }

    public static func fetch() async -> String? {
        guard let claudePath = Executable.find("claude") else { return nil }
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = [claudePath, "--version"]
                p.environment = ClaudeCLI.environment()

                let stdout = Pipe()
                p.standardOutput = stdout
                p.standardError = Pipe()

                do { try p.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: parse(String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
