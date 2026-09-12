import Foundation

/// Turns a raw model id into the name the CLI's own Stats tab shows:
/// `claude-opus-5` → `Opus 5`, `claude-haiku-4-5-20251001` → `Haiku 4.5`.
/// There is no dynamic model listing anywhere — ids arrive verbatim from `stats-cache.json`.
public enum ModelNames {
    public static func display(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Trailing date stamp ("20251001") is a release date, not a version.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        let family = parts.filter { !$0.allSatisfy(\.isNumber) }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }
        guard !family.isEmpty else { return id }
        let name = family.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }
}

/// The CLI's compact count spelling: `617.9m`, `9.6k`, `162`. Lowercase suffix and exactly one
/// decimal, matching the Stats tab ("154.0k", "342.0m") so the card's numbers read as the
/// same report.
public enum CompactCount {
    public static func tokens(_ n: Int) -> String {
        let value = Double(n)
        func one(_ v: Double) -> String { String(format: "%.1f", v) }
        switch n {
        case ..<1_000:             return "\(n)"
        case ..<1_000_000:         return "\(one(value / 1_000))k"
        case ..<1_000_000_000:     return "\(one(value / 1_000_000))m"
        default:                   return "\(one(value / 1_000_000_000))b"
        }
    }
}
