import Foundation

public enum TaskDraftError: Error {
    case claudeNotFound
    case processFailed(Int32, String)
    case invalidJSON(String)
}

/// Turns a free-text idea into a filled-in task draft via one-shot `claude -p`.
/// Stateless — statics only, like PlanQARunner. Prompt-building and decoding are
/// pure so the checks can exercise them without spawning a process.
public struct TaskDraftRunner {

    /// One existing task offered to the model as a dependsOn candidate.
    public struct Candidate: Sendable {
        public let id: String
        public let name: String
        public let topic: String?
        public init(id: String, name: String, topic: String? = nil) {
            self.id = id
            self.name = name
            self.topic = topic
        }
    }

    public static func buildPrompt(idea: String, topics: [String], candidates: [Candidate]) -> String {
        let topicBlock = topics.isEmpty
            ? "(none yet — propose a concise topic, or leave it empty)"
            : topics.map { "- \($0)" }.joined(separator: "\n")

        var parts = [
            """
            You are helping fill out a new task form for a software project. The user describes
            an idea in free text; you turn it into a structured task draft. You may read the
            repository in the current directory for context (naming, existing features).

            User's idea:
            \"\"\"
            \(idea)
            \"\"\"

            Known topics — prefer one of these if it fits, otherwise propose a concise new one:
            \(topicBlock)
            """
        ]

        if !candidates.isEmpty {
            let lines = candidates.map { c -> String in
                let topic = (c.topic ?? "").isEmpty ? "" : " (\(c.topic!))"
                return "- \(c.id) — \(c.name)\(topic)"
            }.joined(separator: "\n")
            parts.append("""
            Existing tasks — usable as dependencies; refer to them by the id before the dash:
            \(lines)
            """)
        }

        parts.append("""
        Fill in the draft:
        - name: one short imperative sentence, no trailing period.
        - topic: reuse a known topic when one fits; otherwise a concise new one, or empty.
        - description: markdown, 1-3 paragraphs.
        - requirements: one concrete, verifiable requirement per item — only those that follow
          from the idea; do not pad the list.
        - priority: "normal" unless the idea clearly signals urgency or low importance.
        - tags: 0-3 short labels.
        - dependsOn: only ids that appear in the existing-tasks list, and only when the idea
          genuinely depends on that task. Usually empty; when unsure, leave it empty.
        """)

        return parts.joined(separator: "\n\n")
    }

    /// What `--json-schema` holds the answer to. Every key required, so the model always fills
    /// the whole form; `decode` still tolerates a missing key rather than trusting that.
    static let schema = #"{"type":"object","properties":{"name":{"type":"string"},"topic":{"type":"string"},"description":{"type":"string"},"requirements":{"type":"array","items":{"type":"string"}},"priority":{"type":"string","enum":["low","normal","high","urgent"]},"tags":{"type":"array","items":{"type":"string"}},"dependsOn":{"type":"array","items":{"type":"string"}}},"required":["name","topic","description","requirements","priority","tags","dependsOn"],"additionalProperties":false}"#

    /// Every field Optional: the model's JSON has none of TaskVersion's id/label/createdAt
    /// and may drop keys, so a direct TaskVersion decode would throw on any omission.
    private struct RawDraft: Decodable {
        let name: String?
        let topic: String?
        let description: String?
        let requirements: [String]?
        let priority: String?
        let tags: [String]?
        let dependsOn: [String]?
    }

    /// `json` is the object from the result envelope's `structured_output`.
    public static func decode(_ json: String, validTaskIDs: Set<String>) throws -> TaskVersion {
        let draft = json.data(using: .utf8).flatMap { try? JSONDecoder().decode(RawDraft.self, from: $0) }
        // Tolerate missing keys, but not the wrong object entirely ({} or {"error": …}).
        guard let d = draft, d.name != nil || d.description != nil else {
            throw TaskDraftError.invalidJSON(json)
        }

        let cleanList: ([String]?) -> [String] = { items in
            (items ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let priorityRaw = (d.priority ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TaskVersion(
            name: (d.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            topic: (d.topic ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            description: (d.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            requirements: cleanList(d.requirements),
            priority: Priority(rawValue: priorityRaw) ?? .normal,
            tags: cleanList(d.tags),
            dependsOn: (d.dependsOn ?? []).filter { validTaskIDs.contains($0) })
    }

    public static func generate(idea: String, topics: [String], candidates: [Candidate],
                                validTaskIDs: Set<String>, cwd: URL? = nil) async throws -> TaskVersion {
        let prompt = buildPrompt(idea: idea, topics: topics, candidates: candidates)
        let raw: String
        do {
            raw = try await PlanQARunner.ask(prompt, cwd: cwd,
                                             output: ClaudeCLI.structuredArgs(schema: schema))
        } catch PlanQAError.claudeNotFound {
            throw TaskDraftError.claudeNotFound
        } catch let PlanQAError.processFailed(code, message) {
            throw TaskDraftError.processFailed(code, message)
        }
        guard let data = ClaudeCLI.structuredOutput(fromEnvelope: raw),
              let json = String(data: data, encoding: .utf8) else {
            throw TaskDraftError.invalidJSON(raw)
        }
        return try decode(json, validTaskIDs: validTaskIDs)
    }
}
