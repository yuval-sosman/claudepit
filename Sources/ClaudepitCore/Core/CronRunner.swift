import Foundation

public struct CronEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let cron: String
    public let createdAt: Date
    public let recurring: Bool
    public let sourcePath: URL

    public var intervalLabel: String { parseCronLabel(cron) }

    public init(id: String, prompt: String, cron: String, createdAt: Date, recurring: Bool, sourcePath: URL) {
        self.id = id
        self.prompt = prompt
        self.cron = cron
        self.createdAt = createdAt
        self.recurring = recurring
        self.sourcePath = sourcePath
    }

    private func parseCronLabel(_ expr: String) -> String {
        let parts = expr.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return expr }
        let min = parts[0]; let hr = parts[1]
        // */N * * * *  → Nm
        if min.hasPrefix("*/"), hr == "*" {
            return min.dropFirst(2) + "m"
        }
        // * */N * * *  → Nh  (but min == * means every minute within the hour — skip)
        if min == "0", hr.hasPrefix("*/") {
            return hr.dropFirst(2) + "h"
        }
        // 0 0 */N * *  → Nd
        if min == "0", hr == "0", parts[2].hasPrefix("*/") {
            return parts[2].dropFirst(2) + "d"
        }
        return expr
    }
}

public struct CronStore {
    private struct RawTask: Decodable {
        let id: String
        let cron: String
        let prompt: String
        let createdAt: Double   // milliseconds epoch
        let recurring: Bool?
    }

    private struct TaskFile: Decodable {
        let tasks: [RawTask]
    }

    /// Load from project-scoped .claude/scheduled_tasks.json, falling back to global ~/.claude/scheduled_tasks.json.
    /// `activePath` is the current project root (may be nil).
    public static func load(activePath: URL?) -> [CronEntry] {
        var candidates: [URL] = []
        if let proj = activePath {
            candidates.append(proj.appending(path: ".claude/scheduled_tasks.json"))
        }
        candidates.append(URL(filePath: NSHomeDirectory()).appending(path: ".claude/scheduled_tasks.json"))

        var seen = Set<String>()
        var entries: [CronEntry] = []

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(TaskFile.self, from: data)
            else { continue }

            for t in file.tasks where !seen.contains(t.id) {
                seen.insert(t.id)
                let date = Date(timeIntervalSince1970: t.createdAt / 1000)
                entries.append(CronEntry(
                    id: t.id,
                    prompt: t.prompt,
                    cron: t.cron,
                    createdAt: date,
                    recurring: t.recurring ?? true,
                    sourcePath: url
                ))
            }
        }

        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Remove a task by ID from whichever scheduled_tasks.json file contains it.
    public static func delete(id: String, sourcePath: URL) throws {
        guard let data = try? Data(contentsOf: sourcePath),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tasks = obj["tasks"] as? [[String: Any]]
        else { return }

        tasks.removeAll { ($0["id"] as? String) == id }
        obj["tasks"] = tasks
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: sourcePath, options: .atomic)
    }
}

public enum CronError: Error {
    case invalidInterval(String)
    case writeFailure(String)
}

public struct CronRunner {
    /// Write a new durable loop directly to scheduled_tasks.json.
    /// `intervalOrCron` is either a shorthand like "10m" or a 5-field cron expression.
    public static func create(interval: String, prompt: String, cwd: URL?) throws -> String {
        let cronExpr = try toCron(interval)
        let id = String(UUID().uuidString.prefix(8).lowercased())
        let now = Date().timeIntervalSince1970 * 1000  // ms epoch

        let task: [String: Any] = [
            "id": id,
            "cron": cronExpr,
            "prompt": prompt,
            "createdAt": now,
            "recurring": true
        ]

        let dest = tasksFile(cwd: cwd)
        try appendTask(task, to: dest)
        return id
    }

    // MARK: - Interval → cron

    private static func toCron(_ input: String) throws -> String {
        // Already a 5-field cron expression
        let parts = input.split(separator: " ")
        if parts.count == 5 { return input }

        // Shorthand: Ns / Nm / Nh / Nd
        let pattern = #"^(\d+)([smhd])$"#
        guard let match = input.range(of: pattern, options: .regularExpression),
              match == input.startIndex..<input.endIndex,
              let n = Int(input.dropLast())
        else { throw CronError.invalidInterval(input) }

        let unit = input.last!
        switch unit {
        case "s":
            let mins = max(1, Int(ceil(Double(n) / 60)))
            return mins == 1 ? "* * * * *" : "*/\(mins) * * * *"
        case "m":
            if n <= 59 { return "*/\(n) * * * *" }
            let h = n / 60
            return "0 */\(h) * * *"
        case "h":
            return n <= 23 ? "0 */\(n) * * *" : "0 0 */\(n / 24) * *"
        case "d":
            return "0 0 */\(n) * *"
        default:
            throw CronError.invalidInterval(input)
        }
    }

    // MARK: - File write

    private static func tasksFile(cwd: URL?) -> URL {
        if let cwd {
            return cwd.appending(path: ".claude/scheduled_tasks.json")
        }
        return URL(filePath: NSHomeDirectory()).appending(path: ".claude/scheduled_tasks.json")
    }

    private static func appendTask(_ task: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var tasks: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = obj["tasks"] as? [[String: Any]] {
            tasks = existing
        }
        tasks.append(task)

        let file: [String: Any] = ["tasks": tasks]
        let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
