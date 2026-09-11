import Foundation

public struct QAMessage: Equatable {
    public let role: String   // "user" or "assistant"
    public let text: String
    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public enum PlanQAError: Error {
    case claudeNotFound
    case processFailed(Int32, String)
}

public struct PlanQARunner {
    public static func buildImprovementPrompt(planContent: String, suggestion: String) -> String {
        return """
        You are rewriting an implementation plan based on a suggested improvement.
        Return ONLY the full rewritten plan in markdown — no preamble, no explanation, no code fences.

        <original_plan>
        \(planContent)
        </original_plan>

        <suggested_improvement>
        \(suggestion)
        </suggested_improvement>
        """
    }

    public static func improve(_ prompt: String, cwd: URL? = nil) async throws -> String {
        return try await ask(prompt, cwd: cwd)
    }

    public static func buildPrompt(
        planContent: String,
        history: [QAMessage],
        question: String,
        contentLabel: String = "plan"
    ) -> String {
        var parts = [
            "You are a helpful assistant. Answer questions about the following \(contentLabel) concisely.",
        ]
        if contentLabel == "plan" {
            parts.append("If your response includes a concrete suggestion that would improve the plan, append the exact token [[SUGGEST_IMPROVEMENT]] on its own line at the very end of your response. Do not include it otherwise.")
        }
        parts += [
            "",
            "<\(contentLabel)>",
            planContent,
            "</\(contentLabel)>",
        ]
        if !history.isEmpty {
            parts += ["", "Previous conversation:"]
            for msg in history {
                let label = msg.role == "user" ? "User" : "Assistant"
                parts.append("\(label): \(msg.text)")
            }
        }
        parts += ["", "Question: \(question)"]
        return parts.joined(separator: "\n")
    }

    /// `cwd` is the project the answer is about — the app's active path. It lets the
    /// model read the repo it's being asked about; without it the subprocess inherits
    /// wherever the app happened to be launched from. Writes are auto-denied in `-p`
    /// mode, so this grants reads only.
    public static func ask(_ prompt: String, cwd: URL? = nil) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                guard let claudePath = resolveClaudePath() else {
                    continuation.resume(throwing: PlanQAError.claudeNotFound)
                    return
                }
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = ClaudeCLI.printArgs(
                    claudePath: claudePath, extra: ["--output-format", "text"])
                p.environment = ClaudeCLI.environment()
                if let cwd { p.currentDirectoryURL = cwd }

                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                p.standardInput = stdin
                p.standardOutput = stdout
                p.standardError = stderr

                do { try p.run() } catch {
                    continuation.resume(throwing: PlanQAError.claudeNotFound)
                    return
                }

                // Write prompt to stdin then close so claude sees EOF
                let data = Data(prompt.utf8)
                stdin.fileHandleForWriting.write(data)
                stdin.fileHandleForWriting.closeFile()

                // Read both stdout and stderr before waitUntilExit to avoid deadlock
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()

                let status = p.terminationStatus
                if status != 0 {
                    // `Not logged in` arrives on stdout with an empty stderr, so the
                    // message has to come from both streams or it's lost.
                    let message = ClaudeCLI.failureMessage(
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "")
                    continuation.resume(throwing: PlanQAError.processFailed(status, message))
                    return
                }
                let result = (String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: result)
            }
        }
    }

    private static func resolveClaudePath() -> String? { Executable.find("claude") }
}
