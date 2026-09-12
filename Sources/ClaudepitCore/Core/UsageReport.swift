import Foundation

/// The "What's contributing to your limits usage?" half of the print-mode `/usage` report.
///
/// This data exists **only** in the report text — the CLI computes it from local transcripts on
/// the fly and caches none of it in `~/.claude.json` or `stats-cache.json` — so Claudepit parses
/// the text it already captures on refresh. Sample (verified against a real run):
///
///     You are currently using your subscription to power your Claude Code usage
///
///     Current session: 15% used · resets Sep 12 at 2:30pm (Asia/Jerusalem)
///     …
///     Last 24h · 1459 requests · 25 sessions
///       70% of your usage came from subagent-heavy sessions
///       Top skills: /rerun 6%, /claudepit-task-plan 2%
///       Top subagents: general-purpose 18%, Explore 3%
///
/// The parser is tolerant by construction: any line it doesn't recognize is skipped, and
/// malformed input yields an empty report rather than an error — the section simply hides.
public struct UsageReport: Equatable, Sendable {
    public struct RankedItem: Equatable, Sendable {
        public let name: String
        public let percent: Int

        public init(name: String, percent: Int) {
            self.name = name
            self.percent = percent
        }
    }

    /// One "Last 24h · N requests · M sessions" block with its indented detail lines.
    public struct InsightWindow: Equatable, Sendable, Identifiable {
        public let label: String        // "Last 24h", "Last 7d"
        public let requests: Int?
        public let sessions: Int?
        /// The free-text behavior lines ("70% of your usage came from subagent-heavy sessions").
        public let behaviors: [String]
        public let topSkills: [RankedItem]
        public let topSubagents: [RankedItem]

        public var id: String { label }

        public init(label: String, requests: Int?, sessions: Int?, behaviors: [String],
                    topSkills: [RankedItem], topSubagents: [RankedItem]) {
            self.label = label
            self.requests = requests
            self.sessions = sessions
            self.behaviors = behaviors
            self.topSkills = topSkills
            self.topSubagents = topSubagents
        }
    }

    /// "You are currently using your subscription…" — the report's first line.
    public let headline: String?
    public let windows: [InsightWindow]

    public init(headline: String?, windows: [InsightWindow]) {
        self.headline = headline
        self.windows = windows
    }

    public var isEmpty: Bool { headline == nil && windows.isEmpty }

    public static func parse(_ text: String) -> UsageReport {
        var headline: String?
        var windows: [InsightWindow] = []

        var label: String?
        var requests: Int?, sessions: Int?
        var behaviors: [String] = []
        var skills: [RankedItem] = [], subagents: [RankedItem] = []

        func closeWindow() {
            if let label {
                windows.append(InsightWindow(label: label, requests: requests, sessions: sessions,
                                             behaviors: behaviors, topSkills: skills,
                                             topSubagents: subagents))
            }
            label = nil; requests = nil; sessions = nil
            behaviors = []; skills = []; subagents = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indented = rawLine.first?.isWhitespace == true

            if !indented && trimmed.hasPrefix("Last ") && trimmed.contains("·") {
                closeWindow()
                let parts = trimmed.components(separatedBy: "·")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                label = parts[0]
                for part in parts.dropFirst() {
                    let leading = Int(part.prefix { $0.isNumber })
                    if part.hasSuffix("requests") { requests = leading }
                    if part.hasSuffix("sessions") { sessions = leading }
                }
                continue
            }

            if indented, label != nil {
                if let list = rankedList(trimmed, prefix: "Top skills:") {
                    skills = list
                } else if let list = rankedList(trimmed, prefix: "Top subagents:") {
                    subagents = list
                } else {
                    behaviors.append(trimmed)
                }
                continue
            }

            // A non-indented line that isn't a window header ends any open window — the report
            // puts nothing after the last block today, but a future footer must not leak in.
            closeWindow()
            if headline == nil && !trimmed.hasPrefix("Current ") && !trimmed.hasPrefix("What's ") {
                headline = trimmed
            }
        }
        closeWindow()
        return UsageReport(headline: headline, windows: windows)
    }

    /// "Top skills: /rerun 6%, /claudepit-task-plan 2%" → [(name, percent)]. An entry whose
    /// trailing token isn't `N%` is dropped rather than guessed at.
    private static func rankedList(_ line: String, prefix: String) -> [RankedItem]? {
        guard line.hasPrefix(prefix) else { return nil }
        let list = line.dropFirst(prefix.count)
        return list.components(separatedBy: ",").compactMap { entry in
            let words = entry.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ").filter { !$0.isEmpty }
            guard words.count >= 2, let last = words.last, last.hasSuffix("%"),
                  let percent = Int(last.dropLast()) else { return nil }
            return RankedItem(name: words.dropLast().joined(separator: " "), percent: percent)
        }
    }
}

/// Persists the last successful report text so insights survive an app relaunch — without it
/// the section is blank for up to 15 minutes (until the next stale-triggered refresh), since
/// the text exists only as subprocess output.
public enum UsageReportCache {
    public static func save(text: String, fetchedAt: Date, url: URL = Paths.usageReportCache) {
        let obj: [String: Any] = [
            "version": 1,
            "text": text,
            "fetchedAtMs": Int(fetchedAt.timeIntervalSince1970 * 1000),
        ]
        try? JSONFile.writeObject(obj, to: url)
    }

    public static func load(url: URL = Paths.usageReportCache) -> (text: String, fetchedAt: Date)? {
        guard let root = try? JSONFile.readObject(url),
              let text = root["text"] as? String,
              let ms = (root["fetchedAtMs"] as? NSNumber)?.doubleValue else { return nil }
        return (text, Date(timeIntervalSince1970: ms / 1000))
    }
}
