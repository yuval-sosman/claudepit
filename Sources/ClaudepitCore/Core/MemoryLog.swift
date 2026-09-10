import Foundation

/// Reader for `memory/log.json` — the append-only activity log Claude maintains
/// (via the memory hook instructions). Tolerates BOTH the current rich shape
/// (title/summary/changes[]) and older thin entries ({type,file,note,ts}).
/// No writer: Claude owns the file.
public struct MemoryLogEntry: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, Equatable { case write, dream }

    public struct Change: Codable, Sendable {
        public enum Action: String, Codable, Sendable, Equatable {
            case create, update, delete

            /// Single source of truth for the A/M/D badge letter + color,
            /// matching ReviewChangesSheet's git-status convention.
            public var letter: String {
                switch self { case .create: "A"; case .update: "M"; case .delete: "D" }
            }
        }
        public let action: Action
        public let file: String

        public init(action: Action, file: String) {
            self.action = action; self.file = file
        }
    }

    public let type: Kind
    public let ts: Int
    public let sessionId: String?
    public let title: String?
    public let summary: String?      // new; falls back to legacy `note`
    public let changes: [Change]?    // new; falls back to legacy single `file`
    public let file: String?         // legacy single-file entry
    public let note: String?         // legacy free-text

    public var id: String { "\(ts)-\(type.rawValue)-\(file ?? title ?? "")" }

    // MARK: - Normalized accessors the UI reads

    /// Every file touched, with its action. Falls back to the legacy single
    /// `file` (treated as an update) when `changes` is absent.
    public var displayChanges: [Change] {
        if let changes, !changes.isEmpty { return changes }
        if let file { return [Change(action: .update, file: file)] }
        return []
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let file, !file.isEmpty { return file }
        return type == .dream ? "Consolidation" : "Memory write"
    }

    public var displaySummary: String? {
        let s = summary ?? note
        return (s?.isEmpty == true) ? nil : s
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

public enum MemoryLog {
    /// Loads log.json newest-first. Returns [] on any failure (missing file,
    /// malformed JSON) — the log is best-effort display, never load-bearing.
    public static func load(projectSlug: String) -> [MemoryLogEntry] {
        let url = Paths.memoryLogFile(projectSlug: projectSlug)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MemoryLogEntry].self, from: data)
        else { return [] }
        return entries.sorted { $0.ts > $1.ts }
    }
}
