import Foundation

/// One rate-limit window as the Claude CLI caches it in `~/.claude.json`.
public struct UsageWindow: Equatable, Sendable {
    /// Percent of the window consumed (0–100), verbatim from the CLI.
    public let percent: Int
    /// When the window rolls over. Null in the payload for windows that never reset.
    public let resetsAt: Date?

    public enum Level: Sendable { case normal, warning, critical }

    public init(percent: Int, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    public var level: Level {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    /// Clamped 0…1 for a `ProgressView`. The CLI has been seen to report >100 on an
    /// exhausted window, which would push the gauge past its track.
    public var fraction: Double { min(1, max(0, Double(percent) / 100)) }
}

/// One row of `utilization.limits[]` — the per-scope breakdown behind the two headline windows.
public struct UsageLimit: Equatable, Sendable, Identifiable {
    public let kind: String              // "session" | "weekly_all" | "weekly_scoped"
    public let percent: Int
    public let severity: String          // "normal" | "warning" | … (CLI's own vocabulary)
    public let resetsAt: Date?
    public let isActive: Bool
    /// `scope.model.display_name` — nil for the unscoped rows, which the headline windows cover.
    public let modelDisplayName: String?

    /// kind alone is not unique: `weekly_scoped` appears once per model.
    public var id: String { "\(kind)|\(modelDisplayName ?? "")" }

    public init(kind: String, percent: Int, severity: String,
                resetsAt: Date?, isActive: Bool, modelDisplayName: String?) {
        self.kind = kind; self.percent = percent; self.severity = severity
        self.resetsAt = resetsAt; self.isActive = isActive
        self.modelDisplayName = modelDisplayName
    }
}

/// The `extra_usage` subtree — the CLI's usage-credits state ("Usage credits are off ·
/// /usage-credits to turn them on" in the `/usage` panel). Credits are off for most
/// subscriptions, so every numeric field is Optional and the common render is just the flag.
public struct ExtraUsage: Equatable, Sendable {
    public let isEnabled: Bool
    public let usedCredits: Double?
    public let monthlyLimit: Double?
    /// Percent of the monthly credit budget consumed, when the CLI reports one.
    public let utilization: Int?

    public init(isEnabled: Bool, usedCredits: Double?, monthlyLimit: Double?, utilization: Int?) {
        self.isEnabled = isEnabled
        self.usedCredits = usedCredits
        self.monthlyLimit = monthlyLimit
        self.utilization = utilization
    }
}

/// The `cachedUsageUtilization` subtree of `~/.claude.json`, which the CLI refreshes whenever it
/// talks to the API (and always on `/usage`). Read-only: Claudepit never writes this file.
public struct UsageSnapshot: Equatable, Sendable {
    public let fetchedAt: Date
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let limits: [UsageLimit]
    public let extraUsage: ExtraUsage?

    public init(fetchedAt: Date, fiveHour: UsageWindow?, sevenDay: UsageWindow?,
                limits: [UsageLimit], extraUsage: ExtraUsage? = nil) {
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
        self.extraUsage = extraUsage
    }

    /// 15 minutes by default — the auto-refresh threshold on Home.
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 900) -> Bool {
        now.timeIntervalSince(fetchedAt) >= maxAge
    }

    /// The scoped weekly rows, which the headline windows don't cover.
    public var scopedWeekly: [UsageLimit] {
        limits.filter { $0.kind == "weekly_scoped" }
    }

    /// Parses the WHOLE `~/.claude.json` object. nil when the cache subtree is absent —
    /// a fresh install, or a CLI that has never reached the usage endpoint.
    public static func parse(root: [String: Any]) -> UsageSnapshot? {
        guard let cached = root["cachedUsageUtilization"] as? [String: Any] else { return nil }
        // JSONSerialization hands numbers back as NSNumber; `as? Double` covers Int and Double
        // spellings alike, which matters because the CLI writes this one as a plain integer.
        guard let fetchedMs = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue else { return nil }
        let utilization = cached["utilization"] as? [String: Any] ?? [:]

        let dates = ISO8601Pair()
        func window(_ key: String) -> UsageWindow? {
            guard let obj = utilization[key] as? [String: Any],
                  let percent = (obj["utilization"] as? NSNumber)?.intValue else { return nil }
            return UsageWindow(percent: percent, resetsAt: dates.date(obj["resets_at"] as? String))
        }

        let rawLimits = utilization["limits"] as? [[String: Any]] ?? []
        let limits: [UsageLimit] = rawLimits.compactMap { row in
            guard let kind = row["kind"] as? String else { return nil }
            let scopeModel = (row["scope"] as? [String: Any])
                .flatMap { $0["model"] as? [String: Any] }
                .flatMap { $0["display_name"] as? String }
            return UsageLimit(
                kind: kind,
                percent: (row["percent"] as? NSNumber)?.intValue ?? 0,
                severity: row["severity"] as? String ?? "normal",
                resetsAt: dates.date(row["resets_at"] as? String),
                isActive: (row["is_active"] as? NSNumber)?.boolValue ?? false,
                modelDisplayName: scopeModel)
        }

        var extra: ExtraUsage?
        if let raw = utilization["extra_usage"] as? [String: Any] {
            extra = ExtraUsage(
                isEnabled: (raw["is_enabled"] as? NSNumber)?.boolValue ?? false,
                usedCredits: (raw["used_credits"] as? NSNumber)?.doubleValue,
                monthlyLimit: (raw["monthly_limit"] as? NSNumber)?.doubleValue,
                utilization: (raw["utilization"] as? NSNumber)?.intValue)
        }

        return UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: fetchedMs / 1000),
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            limits: limits,
            extraUsage: extra)
    }

    /// nil on any failure — a missing file, unreadable JSON, or no cache subtree. The card
    /// treats all three identically ("No usage data yet").
    public static func load(url: URL = Paths.globalClaudeJson) -> UsageSnapshot? {
        guard let root = try? JSONFile.readObject(url) else { return nil }
        return parse(root: root)
    }
}

/// `resets_at` carries fractional seconds (`…:00.373961+00:00`), which the plain ISO8601 parser
/// rejects outright — so both spellings get a formatter and the fractional one is tried first.
/// Instantiated per parse rather than cached: `ISO8601DateFormatter` is a non-Sendable class.
struct ISO8601Pair {
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
