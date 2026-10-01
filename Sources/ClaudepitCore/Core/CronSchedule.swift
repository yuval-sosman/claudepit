import Foundation

// Claude Code's scheduling rules, ported from the CLI (2.1.286) so the Loops page predicts what the
// scheduler will actually do rather than what a generic cron library would: the CLI's five-field
// grammar, its next-match walk, the English it prints, its deterministic jitter, the 7-day expiry,
// and the `/loop` skill's interval table. Each piece names the CLI function it mirrors; when the
// CLI changes, re-read those and update here, with the checks in `LoopChecks`.

// MARK: - Cron expression

extension Calendar {
    /// The calendar cron is read in: Gregorian, in the machine's time zone — what the CLI's JS
    /// `Date` uses whatever the person picked for their own calendar (Hebrew, Islamic, …).
    public static var cron: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }
}

/// A five-field cron expression in the CLI's dialect (`UB` + `T` in the CLI): `minute hour
/// day-of-month month day-of-week`, local time. Each field takes `*`, `*/N`, `N`, `A-B`, `A-B/N` and
/// comma lists of those. No names (`MON`, `JAN`), no `L`/`W`/`?` — the CLI rejects them, so the
/// app does too. Day-of-week is 0–6 with 7 accepted for Sunday.
public struct CronExpression: Equatable, Hashable, Sendable {
    /// The expression as given. Kept verbatim: the CLI tests the raw string against
    /// `^\*\/\d+ \* \* \* \*$` for its prompt-cache rule (`CronJitter.keepsCacheWarm`).
    public let source: String
    public let minutes: [Int]
    public let hours: [Int]
    public let daysOfMonth: [Int]
    public let months: [Int]
    public let daysOfWeek: [Int]

    public static let fieldNames = ["minute", "hour", "day of month", "month", "day of week"]
    public static let fieldRanges: [ClosedRange<Int>] = [0...59, 0...23, 1...31, 1...12, 0...6]

    public init?(_ text: String) {
        guard case .valid(let e) = Self.validate(text) else { return nil }
        self = e
    }

    private init(source: String, fields: [[Int]]) {
        self.source = source
        minutes = fields[0]; hours = fields[1]; daysOfMonth = fields[2]; months = fields[3]; daysOfWeek = fields[4]
    }

    public enum Validation: Equatable, Sendable {
        case valid(CronExpression)
        /// `field` is the 0-based field at fault; nil when the expression doesn't have five fields.
        case invalid(field: Int?, message: String)

        public var expression: CronExpression? { if case .valid(let e) = self { return e }; return nil }
        public var message: String? { if case .invalid(_, let m) = self { return m }; return nil }
    }

    public static func validate(_ text: String) -> Validation {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else {
            return .invalid(field: nil, message: "A cron expression has 5 fields — minute, hour, day of month, "
                            + "month, day of week — this has \(parts.count).")
        }
        var fields: [[Int]] = []
        for (i, part) in parts.enumerated() {
            guard let values = parseField(part, range: fieldRanges[i], isDayOfWeek: i == 4) else {
                let hi = i == 4 ? 7 : fieldRanges[i].upperBound
                return .invalid(field: i, message: "The \(fieldNames[i]) field “\(part)” isn't valid: use *, */N, N, "
                                + "A-B, A-B/N or a comma list, within \(fieldRanges[i].lowerBound)–\(hi).")
            }
            fields.append(values)
        }
        return .valid(CronExpression(source: text.trimmingCharacters(in: .whitespacesAndNewlines), fields: fields))
    }

    /// One field's values, sorted and unique — `T(field, range)` in the CLI. nil when any part of
    /// the field is malformed or out of range, or the field selects nothing.
    static func parseField(_ text: String, range: ClosedRange<Int>, isDayOfWeek: Bool) -> [Int]? {
        let lo = range.lowerBound, hi = range.upperBound
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            if part == "*" || part.hasPrefix("*/") {
                var step = 1
                if part.hasPrefix("*/") {
                    let digits = String(part.dropFirst(2))
                    guard isDigits(digits), let n = Int(digits) else { return nil }
                    step = n
                }
                guard step >= 1 else { return nil }
                for v in stride(from: lo, through: hi, by: step) { values.insert(v) }
                continue
            }
            if let dash = part.firstIndex(of: "-") {
                let a = String(part[..<dash])
                var rest = String(part[part.index(after: dash)...])
                var step = 1
                if let slash = rest.firstIndex(of: "/") {
                    let s = String(rest[rest.index(after: slash)...])
                    guard isDigits(s), let n = Int(s) else { return nil }
                    step = n
                    rest = String(rest[..<slash])
                }
                guard isDigits(a), isDigits(rest), let from = Int(a), let to = Int(rest) else { return nil }
                // Day-of-week ranges may end at 7 (Sunday again), which folds onto 0.
                let top = isDayOfWeek ? 7 : hi
                guard from <= to, step >= 1, from >= lo, to <= top else { return nil }
                for v in stride(from: from, through: to, by: step) { values.insert(isDayOfWeek && v == 7 ? 0 : v) }
                continue
            }
            guard isDigits(part), var v = Int(part) else { return nil }
            if isDayOfWeek && v == 7 { v = 0 }
            guard v >= lo && v <= hi else { return nil }
            values.insert(v)
        }
        return values.isEmpty ? nil : values.sorted()
    }

    private static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// The first matching minute strictly after `date` (seconds dropped) — the CLI's `Mdt`, and its
    /// day rule: when both day fields are restricted a date matches either (vixie cron). The CLI
    /// gives up after 527,040 steps; the 8-year horizon here bounds an impossible date (Feb 30)
    /// without missing a leap day.
    public func next(after date: Date, calendar: Calendar = .cron) -> Date? {
        let minuteSet = Set(minutes), hourSet = Set(hours), domSet = Set(daysOfMonth)
        let monthSet = Set(months), dowSet = Set(daysOfWeek)
        let domAll = daysOfMonth.count == 31, dowAll = daysOfWeek.count == 7
        // Floor the instant, not its components: in the hour a DST change repeats, components map
        // 01:15 (second pass) back onto the first, an hour in the past.
        var u = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
        let horizon = date.addingTimeInterval(8 * 366 * 86_400)
        for _ in 0..<527_040 {
            guard u <= horizon else { return nil }
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: u)
            guard let year = c.year, let month = c.month, let day = c.day, let hour = c.hour,
                  let minute = c.minute, let weekday = c.weekday else { return nil }
            if !monthSet.contains(month) {
                guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let next = calendar.date(byAdding: .month, value: 1, to: first) else { return nil }
                u = next
                continue
            }
            let dow = weekday - 1
            let dayMatches = domAll && dowAll ? true
                : domAll ? dowSet.contains(dow)
                : dowAll ? domSet.contains(day)
                : domSet.contains(day) || dowSet.contains(dow)
            if !dayMatches {
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: u)) else { return nil }
                u = next
                continue
            }
            if !hourSet.contains(hour) {
                guard let hourSpan = calendar.dateInterval(of: .hour, for: u) else { return nil }
                u = hourSpan.end
                continue
            }
            if !minuteSet.contains(minute) {
                u = u.addingTimeInterval(60)
                continue
            }
            return u
        }
        return nil
    }

    /// The next `count` matches after `date`.
    public func nextFires(after date: Date, count: Int, calendar: Calendar = .cron) -> [Date] {
        var out: [Date] = []
        var cursor = date
        while out.count < count, let n = next(after: cursor, calendar: calendar) {
            out.append(n)
            cursor = n
        }
        return out
    }

    /// The gap between the next two matches after `date` — what the jitter scales with.
    public func period(after date: Date, calendar: Calendar = .cron) -> TimeInterval? {
        guard let a = next(after: date, calendar: calendar), let b = next(after: a, calendar: calendar) else { return nil }
        return b.timeIntervalSince(a)
    }

    /// The English the CLI prints for a schedule (`rC`): "Every 5 minutes", "Every hour at :07",
    /// "Every 2 hours", "Every day at 9:03 AM", "Every Monday at 9:00 AM", "Weekdays at 9:03 AM".
    /// Anything else comes back as the expression itself, exactly as the CLI shows it.
    public static func humanize(_ text: String) -> String {
        let p = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard p.count == 5 else { return text }
        let (m, h, dom, mon, dow) = (p[0], p[1], p[2], p[3], p[4])
        let restAny = dom == "*" && mon == "*" && dow == "*"
        if h == "*" && restAny {
            if m == "*" { return "Every minute" }
            if let n = step(m) { return n == 1 ? "Every minute" : "Every \(n) minutes" }
        }
        if isDigits(m), h == "*", restAny, let mm = Int(m) {
            return mm == 0 ? "Every hour" : "Every hour at :\(pad2(mm))"
        }
        if isDigits(m), let n = step(h), restAny, let mm = Int(m) {
            let at = mm == 0 ? "" : " at :\(pad2(mm))"
            return n == 1 ? "Every hour\(at)" : "Every \(n) hours\(at)"
        }
        guard isDigits(m), isDigits(h), let mm = Int(m), let hh = Int(h) else { return text }
        let time = clock(hour: hh, minute: mm)
        if restAny { return "Every day at \(time)" }
        if dom == "*", mon == "*", dow.count == 1, let d = Int(dow) {
            return "Every \(weekdayNames[d % 7]) at \(time)"
        }
        if dom == "*", mon == "*", dow == "1-5" { return "Weekdays at \(time)" }
        return text
    }

    public static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// `*/N` → N.
    static func step(_ field: String) -> Int? {
        guard field.hasPrefix("*/") else { return nil }
        let digits = String(field.dropFirst(2))
        return isDigits(digits) ? Int(digits) : nil
    }

    static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// "9:03 AM" — the CLI's `toLocaleTimeString("en-US", {hour: "numeric", minute: "2-digit"})`,
    /// spelled by hand so it never picks up the system's narrow no-break space.
    public static func clock(hour: Int, minute: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12):\(pad2(minute)) \(hour < 12 ? "AM" : "PM")"
    }

    /// The minute field is a single minute — the case where the CLI's advice to avoid :00 and :30
    /// (and its one-shot early-fire rule) applies.
    public var fixedMinute: Int? { minutes.count == 1 ? minutes[0] : nil }
}

// MARK: - Jitter and expiry

/// The scheduler's deterministic offsets and the 7-day expiry (`nq` + `ILt` + `udn` in the CLI).
/// Every value can be overridden remotely (`tengu_kairos_cron_config`), so the effective config is
/// read from the CLI's cached flags when present (`LoopCapabilities`); these are the CLI defaults.
///
/// The offset comes from the task id, so the same task always lands at the same point in its
/// window — which is what lets the app show a task's next fire to the second.
public struct CronJitter: Equatable, Sendable {
    /// A recurring task fires up to this fraction of its period late…
    public var recurringFraction = 0.5
    /// …but never more than this.
    public var recurringCap: TimeInterval = 1800
    /// A one-shot landing on a `oneShotMinuteMod` minute fires up to this much early.
    public var oneShotMax: TimeInterval = 90
    public var oneShotFloor: TimeInterval = 0
    public var oneShotMinuteMod = 30
    /// Recurring tasks fire one final time after this age, then delete themselves (0 = never).
    public var recurringMaxAge: TimeInterval = 604_800
    /// `*/5 * * * *` fires this long before the 5-minute prompt-cache window closes instead.
    public var cacheLead: TimeInterval = 15
    /// The prompt cache's lifetime (`ldn`), the window `cacheLead` is measured against.
    public static let promptCacheWindow: TimeInterval = 300

    public init() {}
    public static let cliDefault = CronJitter()

    /// `tengu_kairos_cron_config` from the CLI's cached flags (milliseconds), each key falling back
    /// to the default. The CLI validates the whole object and uses the defaults if any key is bad;
    /// here an out-of-range key just keeps its default.
    public init(config: [String: Any]?) {
        self.init()
        guard let config else { return }
        func ms(_ key: String, max: Double) -> TimeInterval? {
            guard let v = (config[key] as? NSNumber)?.doubleValue, v >= 0, v <= max else { return nil }
            return v / 1000
        }
        if let f = (config["recurringFrac"] as? NSNumber)?.doubleValue, f >= 0, f <= 1 { recurringFraction = f }
        if let v = ms("recurringCapMs", max: 1_800_000) { recurringCap = v }
        if let v = ms("oneShotMaxMs", max: 1_800_000) { oneShotMax = v }
        if let v = ms("oneShotFloorMs", max: 1_800_000) { oneShotFloor = min(v, oneShotMax) }
        if let m = (config["oneShotMinuteMod"] as? NSNumber)?.intValue, (1...60).contains(m) { oneShotMinuteMod = m }
        if let v = ms("recurringMaxAgeMs", max: 2_592_000_000) { recurringMaxAge = v }
        if let v = ms("cacheLeadMs", max: 60_000) { cacheLead = v }
    }

    /// A task id's place in [0, 1): its first eight characters read as hex (`M` in the CLI, which
    /// is `parseInt(id.slice(0, 8), 16) / 2^32` — leading hex digits only, NaN as 0).
    public static func fraction(taskID: String) -> Double {
        var value: UInt64 = 0
        var any = false
        for c in taskID.prefix(8) {
            guard let d = c.hexDigitValue else { break }
            value = value * 16 + UInt64(d)
            any = true
        }
        return any ? Double(value) / 4_294_967_296 : 0
    }

    /// `*/N * * * *` with a 5-minute period: the CLI fires it `cacheLead` before the prompt cache
    /// would expire, counted from the last fire, instead of on the clock (`ILt`'s first branch).
    public func keepsCacheWarm(_ cron: CronExpression, period: TimeInterval) -> Bool {
        let everyNMinutes = cron.source.range(of: #"^\*\/\d+ \* \* \* \*$"#, options: .regularExpression) != nil
        return everyNMinutes && cacheLead > 0 && cacheLead < period
            && period >= Self.promptCacheWindow && period - cacheLead < Self.promptCacheWindow
    }

    /// When a recurring task fires next, counted from `from` — its last fire, else its creation
    /// (`ILt`): the next match plus `fraction × recurringFraction × period`, capped.
    public func recurringFire(_ cron: CronExpression, from: Date, taskID: String,
                              calendar: Calendar = .cron) -> Date? {
        guard let first = cron.next(after: from, calendar: calendar) else { return nil }
        guard let second = cron.next(after: first, calendar: calendar) else { return first }
        let period = second.timeIntervalSince(first)
        if keepsCacheWarm(cron, period: period) { return from.addingTimeInterval(period - cacheLead) }
        return first.addingTimeInterval(min(Self.fraction(taskID: taskID) * recurringFraction * period, recurringCap))
    }

    /// When a one-shot fires (`udn`): its match, pulled up to `oneShotMax` early when it lands on a
    /// :00/:30 minute — never before `from`.
    public func oneShotFire(_ cron: CronExpression, from: Date, taskID: String,
                            calendar: Calendar = .cron) -> Date? {
        guard let at = cron.next(after: from, calendar: calendar) else { return nil }
        guard calendar.component(.minute, from: at) % oneShotMinuteMod == 0 else { return at }
        let early = oneShotFloor + Self.fraction(taskID: taskID) * (oneShotMax - oneShotFloor)
        return max(at.addingTimeInterval(-early), from)
    }

    /// The most a recurring schedule can be held back — before a task id exists to fix the exact
    /// offset (the creation dialog's "may run up to … late").
    public func maxRecurringDelay(_ cron: CronExpression, from: Date, calendar: Calendar = .cron) -> TimeInterval? {
        guard let period = cron.period(after: from, calendar: calendar) else { return nil }
        if keepsCacheWarm(cron, period: period) { return 0 }
        return min(recurringFraction * period, recurringCap)
    }

    /// When a recurring task created at `createdAt` ages out: it fires one final time at or after
    /// this, then deletes itself. nil when expiry is switched off.
    public func expiry(createdAt: Date) -> Date? {
        recurringMaxAge > 0 ? createdAt.addingTimeInterval(recurringMaxAge) : nil
    }
}

// MARK: - /loop arguments

/// An interval as `/loop` takes it: `30s`, `5m`, `2h`, `1d`.
public struct LoopInterval: Equatable, Hashable, Sendable {
    public enum Unit: String, CaseIterable, Sendable {
        case s, m, h, d
        public var word: String {
            switch self { case .s: "second"; case .m: "minute"; case .h: "hour"; case .d: "day" }
        }
    }
    public var value: Int
    public var unit: Unit

    public init(_ value: Int, _ unit: Unit) { self.value = value; self.unit = unit }

    /// `^\d+[smhd]$`, the skill's leading-token rule.
    public init?(token: String) {
        guard let last = token.last, let unit = Unit(rawValue: String(last)) else { return nil }
        let digits = token.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(digits) else { return nil }
        self.init(v, unit)
    }

    public var token: String { "\(value)\(unit.rawValue)" }

    public var spoken: String { "\(value) \(unit.word)\(value == 1 ? "" : "s")" }

    /// Seconds rounded up to whole minutes, as the skill does ("cron minimum granularity").
    /// Saturating: whatever is typed into the dialog's field must not trap.
    public var minutes: Int {
        func times(_ factor: Int) -> Int {
            let (r, overflow) = value.multipliedReportingOverflow(by: factor)
            return overflow ? Int.max / 4 : r
        }
        switch unit {
        case .s: return max(1, value / 60 + (value % 60 == 0 ? 0 : 1))
        case .m: return value
        case .h: return times(60)
        case .d: return times(1440)
        }
    }

    /// The interval after the skill's seconds rounding: `90s` → `2m`.
    public var normalized: LoopInterval {
        unit == .s ? LoopInterval(minutes, .m) : self
    }

    /// The cron the `/loop` skill's conversion table gives (`Nm` → `*/N * * * *`, `Nm` ≥ 60 →
    /// `0 */H * * *`, `Nh` → `0 */N * * *`, `Nd` → `0 0 */N * *`), or nil when cron can't say it
    /// evenly — the skill then picks the nearest clean interval (`cleanAlternatives`). Literal, N = 1
    /// included: a real `/loop 1m` scheduled `*/1 * * * *`.
    public var cron: String? {
        let n = normalized
        guard n.value >= 1 else { return nil }
        switch n.unit {
        case .s: return nil
        case .m:
            if n.value <= 59 { return "*/\(n.value) * * * *" }
            guard n.value % 60 == 0 else { return nil }
            return LoopInterval(n.value / 60, .h).cron
        case .h:
            if n.value <= 23 { return "0 */\(n.value) * * *" }
            guard n.value % 24 == 0 else { return nil }
            return LoopInterval(n.value / 24, .d).cron
        case .d:
            return "0 0 */\(n.value) * *"
        }
    }

    /// Whether the interval divides its unit, so every gap is the same — `7m` fires at :56 and
    /// then :00 (a 4-minute gap), `90m` is 1.5 h which cron can't express. Day steps restart on
    /// the 1st of each month whatever N is; the skill doesn't round those, so neither does this.
    public var isClean: Bool {
        let n = normalized
        switch n.unit {
        case .s: return false
        case .m:
            if n.value <= 59 { return 60 % n.value == 0 }
            return n.value % 60 == 0 && LoopInterval(n.value / 60, .h).isClean
        case .h:
            if n.value <= 23 { return 24 % n.value == 0 }
            return n.value % 24 == 0
        case .d: return n.value >= 1
        }
    }

    static let cleanMinutes = [1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30]
    static let cleanHours = [1, 2, 3, 4, 6, 8, 12]

    /// The clean intervals either side of an unclean one, nearest first — what the skill rounds
    /// to, offered as one-click fixes.
    public var cleanAlternatives: [LoopInterval] {
        guard !isClean else { return [] }
        let total = minutes
        var candidates = Self.cleanMinutes.map { LoopInterval($0, .m) }
        candidates += Self.cleanHours.map { LoopInterval($0, .h) }
        candidates += (1...28).map { LoopInterval($0, .d) }
        let below = candidates.filter { $0.minutes < total }.max { $0.minutes < $1.minutes }
        let above = candidates.filter { $0.minutes > total }.min { $0.minutes < $1.minutes }
        return [below, above].compactMap { $0 }
            .sorted { (abs($0.minutes - total), $0.minutes) < (abs($1.minutes - total), $1.minutes) }
    }
}

/// `/loop`'s arguments split the way its skill does: a leading interval token (`5m check …`), else
/// a trailing "every …" clause (`check … every 20 minutes`), else no interval at all — the loop
/// then paces itself. Shared by the transcript reader (to explain a recorded `/loop`) and the
/// creation dialog (to warn when a self-paced prompt would be read as having an interval).
public struct LoopArguments: Equatable, Sendable {
    public var interval: LoopInterval?
    public var prompt: String
    /// Which rule found the interval: 1 (leading token), 2 (trailing "every"), nil (none).
    public var rule: Int?

    public init(interval: LoopInterval?, prompt: String, rule: Int?) {
        self.interval = interval; self.prompt = prompt; self.rule = rule
    }

    public static func parse(_ raw: String) -> LoopArguments {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSplit = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if let first = firstSplit.first, let interval = LoopInterval(token: String(first)) {
            let rest = firstSplit.count > 1 ? String(firstSplit[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return LoopArguments(interval: interval, prompt: rest, rule: 1)
        }
        let pattern = #"(?i)(?:^|\s)every\s+(\d+)\s*(seconds|second|secs|sec|s|minutes|minute|mins|min|m|hours|hour|hrs|hr|h|days|day|d)\s*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let numRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
           let value = Int(text[numRange]), let whole = Range(match.range, in: text) {
            let word = text[unitRange].lowercased()
            let unit: LoopInterval.Unit = word.hasPrefix("s") ? .s : word.hasPrefix("h") ? .h : word.hasPrefix("d") ? .d : .m
            let prompt = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return LoopArguments(interval: LoopInterval(value, unit), prompt: prompt, rule: 2)
        }
        return LoopArguments(interval: nil, prompt: text, rule: nil)
    }
}

// MARK: - What a loop runs

/// The prompt a scheduled task enqueues, classified. `/loop` without a prompt schedules a sentinel
/// the CLI expands at fire time: the built-in maintenance instructions, or the tasks in `loop.md`.
public enum LoopPromptKind: Equatable, Sendable {
    case custom(String)
    /// A slash command or skill, e.g. `/review-pr 1234`.
    case command(name: String, args: String)
    /// `<<autonomous-loop>>` (fixed interval) / `<<autonomous-loop-dynamic>>` (self-paced).
    case maintenance(dynamic: Bool)
    /// `<<loop.md>>` / `<<loop.md-dynamic>>`.
    case loopFile(dynamic: Bool)
    /// Each fire hands the work to a subagent: "Use the x subagent to …" (`AgentDelegation`), or
    /// an `@agent-x` mention (`mentioned`), which a fire leaves as plain text.
    case agent(name: String, task: String, mentioned: Bool)

    public static let maintenanceSentinel = "<<autonomous-loop>>"
    public static let maintenanceDynamicSentinel = "<<autonomous-loop-dynamic>>"
    public static let loopFileSentinel = "<<loop.md>>"
    public static let loopFileDynamicSentinel = "<<loop.md-dynamic>>"

    public init(prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch p {
        case Self.maintenanceSentinel: self = .maintenance(dynamic: false)
        case Self.maintenanceDynamicSentinel: self = .maintenance(dynamic: true)
        case Self.loopFileSentinel: self = .loopFile(dynamic: false)
        case Self.loopFileDynamicSentinel: self = .loopFile(dynamic: true)
        default:
            if p.hasPrefix("/"), let name = p.split(whereSeparator: \.isWhitespace).first, name.count > 1 {
                let args = p.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
                // Claude sometimes schedules the whole `/loop 1m <prompt>` as the task's prompt (a real
                // Haiku run did); each fire then takes it as the task, so what it asks for is the inner prompt.
                let inner = name == "/loop" ? LoopArguments.parse(args).prompt : ""
                if !inner.isEmpty, !inner.hasPrefix("/loop") {
                    self = LoopPromptKind(prompt: inner)
                    return
                }
                self = .command(name: String(name), args: args)
            } else if let d = AgentDelegation.parse(p) {
                self = .agent(name: d.agent, task: d.task, mentioned: false)
            } else if p.hasPrefix("@"), let m = AgentDelegation.mention(in: p) {
                self = .agent(name: m.agent, task: m.rest, mentioned: true)
            } else {
                self = .custom(p)
            }
        }
    }

    /// A one-line name for lists.
    public var title: String {
        switch self {
        case .custom(let p):
            let line = p.split(whereSeparator: \.isNewline).first.map(String.init) ?? p
            return line.isEmpty ? "(empty prompt)" : line
        case .command(let name, let args): return args.isEmpty ? name : "\(name) \(args)"
        case .maintenance: return "Built-in maintenance"
        case .loopFile: return "loop.md tasks"
        case .agent(let name, let task, _):
            let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
            return line.isEmpty ? name : "\(name): \(line)"
        }
    }

    public var isSentinel: Bool {
        switch self { case .maintenance, .loopFile: return true; default: return false }
    }
}

// MARK: - Labels

/// Short and long names for a schedule, beyond what the CLI itself prints.
public enum LoopCadence {
    /// The list badge: `5m`, `2h`, `1d`, `daily`, `wkdays`, `Mon`, `once`, else `cron`.
    public static func badge(cron: String, recurring: Bool) -> String {
        guard recurring else { return "once" }
        let p = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard p.count == 5 else { return "cron" }
        let digits: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        let restAny = p[2] == "*" && p[3] == "*" && p[4] == "*"
        if p[0] == "*", p[1] == "*", restAny { return "1m" }
        if let n = CronExpression.step(p[0]), p[1] == "*", restAny { return "\(n)m" }
        if digits(p[0]), p[1] == "*", restAny { return "1h" }
        if digits(p[0]), let n = CronExpression.step(p[1]), restAny { return "\(n)h" }
        if digits(p[0]), digits(p[1]), let n = CronExpression.step(p[2]), p[3] == "*", p[4] == "*" { return "\(n)d" }
        if digits(p[0]), digits(p[1]), restAny { return "daily" }
        if digits(p[0]), digits(p[1]), p[2] == "*", p[3] == "*", p[4] == "1-5" { return "wkdays" }
        if digits(p[0]), digits(p[1]), p[2] == "*", p[3] == "*", p[4].count == 1, let d = Int(p[4]) {
            return String(CronExpression.weekdayNames[d % 7].prefix(3))
        }
        return "cron"
    }

    /// The CLI's English (`CronExpression.humanize`), plus what it leaves as a bare expression for a
    /// pinned one-shot: "Once, Oct 1 at 2:30 PM".
    public static func describe(cron: String, recurring: Bool) -> String {
        let human = CronExpression.humanize(cron)
        guard !recurring else { return human }
        let p = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        if p.count == 5, let m = Int(p[0]), let h = Int(p[1]), let d = Int(p[2]), let mo = Int(p[3]),
           (1...12).contains(mo), p[4] == "*" {
            let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][mo - 1]
            return "Once, \(month) \(d) at \(CronExpression.clock(hour: h, minute: m))"
        }
        return human == cron ? "Once, at the next match of \(cron)" : "Once — \(human.prefix(1).lowercased())\(human.dropFirst())"
    }

    /// "4m 45s", "30m", "1h 30m", "2d".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        if s < 86_400 { return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m" }
        return s % 86_400 / 3600 == 0 ? "\(s / 86_400)d" : "\(s / 86_400)d \(s % 86_400 / 3600)h"
    }
}
