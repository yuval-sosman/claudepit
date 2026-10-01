import Foundation

public struct DiscoverResult: Identifiable, Sendable {
    public let id: String       // sessionID
    public let score: Int       // 1–10
    public let reason: String

    public init(id: String, score: Int, reason: String) {
        self.id = id
        self.score = score
        self.reason = reason
    }
}

public enum DiscoverError: Error {
    case claudeNotFound
    case noSummaryData
    case processFailed(Int32, String)
    case invalidJSON(String)
}

public actor DiscoverRunner {
    public static let shared = DiscoverRunner()
    /// `cwd` is the project being searched — the app's active path — so the subprocess
    /// runs scoped to it rather than to wherever the app was launched from.
    public func search(query: String, projectSlug: String, since: Date, cwd: URL? = nil) async throws -> [DiscoverResult] {
        // 1. Load summaries
        let all = SummaryStore.shared.loadAll(projectSlug: projectSlug)
        let filtered = all.summaries.filter { $0.value.updatedAt >= since }
        guard !filtered.isEmpty else { throw DiscoverError.noSummaryData }

        // 2. Build prompt
        let prompt = buildPrompt(query: query, summaries: filtered)

        // 3. Run claude -p
        let raw = try await runClaude(prompt: prompt, cwd: cwd)

        // 4. Decode JSON
        return try decode(raw)
    }

    private nonisolated func buildPrompt(query: String, summaries: [String: SessionBulletSummary]) -> String {
        let iso = ISO8601DateFormatter()
        let blocks = summaries
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map { (id, entry) -> String in
                let date = iso.string(from: entry.updatedAt)
                let bullets = entry.bullets.map { "- \($0)" }.joined(separator: "\n")
                return "<session id=\"\(id)\" updated=\"\(date)\">\n\(bullets)\n</session>"
            }
            .joined(separator: "\n")

        return """
        You are a session search engine. The user wants to find past work sessions relevant to their query.

        User query: "\(query)"

        Sessions (each block is one session):
        \(blocks)

        List the relevant sessions in `matches`:
        - Include only sessions genuinely relevant to the query.
        - score: 10 = perfect match, 1 = very loose. Omit sessions with score < 3.
        - reason: one short phrase describing why this session matches.
        """
    }

    /// What `--json-schema` holds the answer to. The root is an object (`matches`) rather than a
    /// bare array, which is the shape a JSON-schema answer takes.
    private static let schema = #"{"type":"object","properties":{"matches":{"type":"array","items":{"type":"object","properties":{"sessionID":{"type":"string"},"score":{"type":"integer"},"reason":{"type":"string"}},"required":["sessionID","score","reason"],"additionalProperties":false}}},"required":["matches"],"additionalProperties":false}"#

    private func runClaude(prompt: String, cwd: URL?) async throws -> String {
        guard let claudePath = resolveClaudePath() else {
            throw DiscoverError.claudeNotFound
        }
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = ClaudeCLI.printArgs(
                    claudePath: claudePath, extra: ClaudeCLI.structuredArgs(schema: Self.schema))
                p.environment = ClaudeCLI.environment()
                if let cwd { p.currentDirectoryURL = cwd }

                let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
                p.standardInput = stdin
                p.standardOutput = stdout
                p.standardError = stderr

                do { try p.run() } catch {
                    continuation.resume(throwing: DiscoverError.claudeNotFound)
                    return
                }

                stdin.fileHandleForWriting.write(Data(prompt.utf8))
                stdin.fileHandleForWriting.closeFile()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()

                if p.terminationStatus != 0 {
                    // `Not logged in` arrives on stdout with an empty stderr, so the
                    // message has to come from both streams or it's lost.
                    let message = ClaudeCLI.failureMessage(
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "")
                    continuation.resume(throwing: DiscoverError.processFailed(p.terminationStatus, message))
                    return
                }
                let text = (String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
        }
    }

    private func decode(_ raw: String) throws -> [DiscoverResult] {
        struct RawResult: Decodable {
            let sessionID: String
            let score: Int
            let reason: String
        }
        struct Answer: Decodable { let matches: [RawResult] }
        guard let data = ClaudeCLI.structuredOutput(fromEnvelope: raw),
              let items = try? JSONDecoder().decode(Answer.self, from: data).matches else {
            throw DiscoverError.invalidJSON(raw)
        }
        return items
            .filter { $0.score >= 3 }
            .sorted { $0.score > $1.score }
            .map { DiscoverResult(id: $0.sessionID, score: $0.score, reason: $0.reason) }
    }

    private nonisolated func resolveClaudePath() -> String? { Executable.find("claude") }
}
