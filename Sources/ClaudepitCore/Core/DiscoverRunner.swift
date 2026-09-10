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
    public func search(query: String, projectSlug: String, since: Date) async throws -> [DiscoverResult] {
        // 1. Load summaries
        let all = SummaryStore.shared.loadAll(projectSlug: projectSlug)
        let filtered = all.summaries.filter { $0.value.updatedAt >= since }
        guard !filtered.isEmpty else { throw DiscoverError.noSummaryData }

        // 2. Build prompt
        let prompt = buildPrompt(query: query, summaries: filtered)

        // 3. Run claude -p
        let raw = try await runClaude(prompt: prompt)

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

        Return ONLY a valid JSON array, no prose, no markdown fences:
        [{"sessionID":"...","score":<1-10>,"reason":"<one concise phrase>"}]

        Rules:
        - Include only sessions genuinely relevant to the query.
        - Score 10 = perfect match, 1 = very loose. Omit sessions with score < 3.
        - reason: one short phrase describing why this session matches.
        """
    }

    private func runClaude(prompt: String) async throws -> String {
        guard let claudePath = resolveClaudePath() else {
            throw DiscoverError.claudeNotFound
        }
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = [claudePath, "-p",
                               "--no-session-persistence",
                               "--bare",
                               "--output-format", "text"]

                var env = ProcessInfo.processInfo.environment
                let current = env["PATH"] ?? ""
                env["PATH"] = ([current] + Executable.searchDirs()).joined(separator: ":")
                // ponytail: use real ~/.claude so credentials are available; --bare prevents hooks from firing
                env["CLAUDE_CONFIG_DIR"] = "\(NSHomeDirectory())/.claude"
                p.environment = env

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
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: DiscoverError.processFailed(p.terminationStatus, errText))
                    return
                }
                let text = (String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
        }
    }

    private func decode(_ raw: String) throws -> [DiscoverResult] {
        // Strip any accidental markdown fences
        var text = raw
        if text.contains("```") {
            let lines = text.components(separatedBy: "\n")
            if let firstFence = lines.firstIndex(where: { $0.hasPrefix("```") }),
               let lastFence = lines.lastIndex(where: { $0.hasPrefix("```") }),
               firstFence != lastFence {
                text = lines[(firstFence+1)..<lastFence].joined(separator: "\n")
            }
        }
        guard let data = text.data(using: .utf8) else { throw DiscoverError.invalidJSON(raw) }

        struct RawResult: Decodable {
            let sessionID: String
            let score: Int
            let reason: String
        }
        do {
            let items = try JSONDecoder().decode([RawResult].self, from: data)
            return items
                .filter { $0.score >= 3 }
                .sorted { $0.score > $1.score }
                .map { DiscoverResult(id: $0.sessionID, score: $0.score, reason: $0.reason) }
        } catch {
            throw DiscoverError.invalidJSON(raw)
        }
    }

    private nonisolated func resolveClaudePath() -> String? { Executable.find("claude") }
}
