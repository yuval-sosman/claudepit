import Foundation

// Home's "Usage" card: what this project's Claude Code work amounted to, counted from the
// local transcripts (`~/.claude/projects/<slug>/…jsonl`) rather than the CLI's global caches.
//
// Counting rules — each one is a trap when done naively:
// - Claude Code writes **one line per content block**, each repeating `message.usage`, so an API
//   call is `message.id + requestId`; keep the line with the most `output_tokens` (intermediate
//   lines carry partial counts) and the earliest timestamp. Summing raw lines roughly doubles
//   every token total. The same subagent transcript can also be copied into two sessions, which
//   the same key dedupes.
// - Model `<synthetic>` is a client-side error message with zero usage: not an API call.
// - Dollars are never logged; they are tokens × `ModelPricing` list prices, with 5-minute and
//   1-hour cache writes priced apart (`usage.cache_creation`), fast mode and regional routing
//   applied per call.
// - A human prompt is a main-thread `user` line whose `promptSource` is `typed` or `queued` (plus
//   a human `queued_command` attachment not already logged as a queued line). Tool results,
//   slash commands, task notifications and `system` sources are not prompts.
// - Active time sums the gaps between a session's records, each capped at five minutes, so an
//   idle terminal left open overnight counts as nothing.
// - Cache hit rate is Σ cache reads ÷ Σ context, where a call's context is
//   input + cache read + cache write.

/// One deduplicated API call.
public struct UsageCall: Equatable, Sendable {
    public let key: String
    public var sessionID: String
    /// The subagent that made the call; nil on the main thread.
    public var agentID: String?
    /// Ran in a `.claude/worktrees/…` checkout — where Claudepit's task agents work.
    public var inWorktree: Bool
    /// Canonical model id (`ModelPricing.canonical`).
    public var model: String
    /// Earliest line of the call, seconds since 1970.
    public var time: TimeInterval
    /// Latest line of the call — when the response finished streaming.
    public var end: TimeInterval
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    /// `cache_creation_input_tokens` — both lifetimes.
    public var cacheWrite: Int
    /// The 1-hour share of `cacheWrite` (the rest is 5-minute).
    public var cacheWrite1h: Int
    /// What the call paid over list price (fast mode, regional routing).
    public var priceMultiplier: Double
    public var cost: TokenCost
    public var stopReason: String?
    /// `message.diagnostics.cache_miss_reason.type`, when the CLI logged one.
    public var loggedMissReason: String?
    public var effort: String?

    public var isSubagent: Bool { agentID != nil }
    /// Tokens the model read for this call.
    public var context: Int { input + cacheRead + cacheWrite }
    /// The thread the call belongs to: `main`, or the subagent's id.
    public var thread: String { agentID ?? "main" }
}

/// A call's (or a total's) list-price cost, by token type.
public struct TokenCost: Equatable, Sendable {
    public var input: Double = 0
    public var output: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite: Double = 0

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Double { input + output + cacheRead + cacheWrite }

    static func + (a: TokenCost, b: TokenCost) -> TokenCost {
        TokenCost(input: a.input + b.input, output: a.output + b.output,
                  cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// Everything usage needs from one transcript file. Window-independent, so a file that has not
/// changed never has to be read again — the scanner caches these by path, mtime and size.
public struct TranscriptDigest: Equatable, Sendable {
    public var calls: [String: UsageCall] = [:]
    /// Timestamps of every record, by session. Main transcripts only: a subagent's records share
    /// its parent's session id and would double-count the parent's active time.
    public var sessionTimes: [String: [TimeInterval]] = [:]
    /// Human prompts by session.
    public var prompts: [String: [TimeInterval]] = [:]
    /// Models not priced exactly, with how they were priced instead.
    public var priceNotes: [String: PriceMatch] = [:]
    /// Session → the CLI's own title (`ai-title`), else its first prompt, clipped.
    public var titles: [String: String] = [:]
    /// Session → the project folder (slug) its main transcript lives in.
    public var sessionProjects: [String: String] = [:]
    /// Session → the working directory its first record was written in (a readable project name,
    /// where a slug can't be turned back into a path).
    public var sessionCwds: [String: String] = [:]
    /// Per-thread timelines and tool timings, for a single session's report. Only collected
    /// when asked (`detail: true`) — a project scan has no use for them.
    public var detail: TranscriptDetail?

    public init() {}

    /// Parses one JSONL transcript. `isSubagent` is the file's location (`…/subagents/`);
    /// `inWorktree` and `project` describe its project folder.
    public static func parse(_ data: Data, isSubagent: Bool, inWorktree: Bool,
                             project: String = "", detail: Bool = false) -> TranscriptDigest {
        var parser = Parser(isSubagent: isSubagent, inWorktree: inWorktree, project: project,
                            detail: detail)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                // memchr, not a byte loop: the app runs debug builds, where a Swift loop over
                // 100 MB of transcripts takes seconds.
                var end = buffer.count
                if let hit = memchr(base + start, Int32(UInt8(ascii: "\n")), buffer.count - start) {
                    end = base.distance(to: UnsafeRawPointer(hit))
                }
                if end > start {
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                    count: end - start, deallocator: .none)
                    if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        parser.add(record)
                    }
                }
                start = end + 1
            }
        }
        return parser.finish()
    }

    /// Several files' digests as one: calls deduped by key across files, times concatenated.
    public static func merged(_ digests: [TranscriptDigest]) -> TranscriptDigest {
        var out = TranscriptDigest()
        for d in digests {
            for (key, call) in d.calls {
                out.calls[key] = out.calls[key].map { Parser.combine($0, call) } ?? call
            }
            for (sid, times) in d.sessionTimes { out.sessionTimes[sid, default: []] += times }
            for (sid, times) in d.prompts { out.prompts[sid, default: []] += times }
            out.priceNotes.merge(d.priceNotes) { a, _ in a }
            out.titles.merge(d.titles) { a, _ in a }
            out.sessionProjects.merge(d.sessionProjects) { a, _ in a }
            out.sessionCwds.merge(d.sessionCwds) { a, _ in a }
            if let detail = d.detail { out.detail = (out.detail ?? TranscriptDetail()).merging(detail) }
        }
        return out
    }

    private struct UserLine {
        let session: String
        let time: TimeInterval
        let source: String?
        let isSidechain: Bool
        let isMeta: Bool
        let excluded: Bool        // compact summary / transcript-only
        let sdk: Bool
        let text: String
    }

    private struct Parser {
        let isSubagent: Bool
        let inWorktree: Bool
        let project: String
        var digest = TranscriptDigest()
        var users: [UserLine] = []
        var queuedAttachments: [(session: String, time: TimeInterval, text: String)] = []
        var canonicalCache: [String: String] = [:]
        var aiTitles: [String: String] = [:]
        let timestamps = TimestampParser()

        init(isSubagent: Bool, inWorktree: Bool, project: String, detail: Bool) {
            self.isSubagent = isSubagent
            self.inWorktree = inWorktree
            self.project = project
            if detail { digest.detail = TranscriptDetail() }
        }

        mutating func add(_ d: [String: Any]) {
            let type = d["type"] as? String
            // Titles carry no timestamp; the last one written wins, as in the CLI.
            if type == "ai-title", let sid = d["sessionId"] as? String, let title = d["aiTitle"] as? String {
                aiTitles[sid] = title
                return
            }
            guard let t = timestamps.seconds(d["timestamp"] as? String) else { return }
            let session = d["sessionId"] as? String
            if !isSubagent, let session {
                digest.sessionTimes[session, default: []].append(t)
                if digest.sessionProjects[session] == nil { digest.sessionProjects[session] = project }
                if digest.sessionCwds[session] == nil, let cwd = d["cwd"] as? String { digest.sessionCwds[session] = cwd }
            }
            let thread = d["isSidechain"] as? Bool == true ? (d["agentId"] as? String ?? "main") : "main"
            switch type {
            case "assistant": addCall(d, time: t, session: session ?? "")
            case "user":
                guard let session else { return }
                addUser(d, time: t, session: session, thread: thread)
            case "attachment":
                guard let a = d["attachment"] as? [String: Any] else { return }
                let kind = a["type"] as? String
                digest.detail?.inputs[thread, default: []].append(t)
                if kind == "deferred_tools_delta" || kind == "mcp_instructions_delta" {
                    digest.detail?.toolListChanges[thread, default: []].append(t)
                }
                guard let session, kind == "queued_command",
                      a["commandMode"] as? String == "prompt",
                      (a["origin"] as? [String: Any])?["kind"] as? String == "human" else { return }
                queuedAttachments.append((session, t, Self.text(a["prompt"])))
            case "system":
                if d["subtype"] as? String == "compact_boundary" {
                    digest.detail?.compactions[thread, default: []].append(t)
                }
            default: break
            }
        }

        private mutating func addCall(_ d: [String: Any], time t: TimeInterval, session: String) {
            guard let message = d["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let raw = message["model"] as? String ?? ""
            if raw == "<synthetic>" { return }
            let key = "\(message["id"] as? String ?? "")|\(d["requestId"] as? String ?? "")"
            let model: String
            if let cached = canonicalCache[raw] { model = cached } else {
                model = ModelPricing.canonical(raw)
                canonicalCache[raw] = model
            }
            let (rate, match) = ModelPricing.rate(for: model)
            if match != .exact, !raw.isEmpty { digest.priceNotes[model] = match }

            let int = { (k: String) in (usage[k] as? NSNumber)?.intValue ?? 0 }
            let creation = usage["cache_creation"] as? [String: Any]
            let w5 = (creation?["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue
            let w1 = (creation?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue
            let write = int("cache_creation_input_tokens")
            // Older CLIs don't split writes by lifetime: price them all as 5-minute writes.
            let (write5m, write1h) = (w5 == nil && w1 == nil) ? (write, 0) : (w5 ?? 0, w1 ?? 0)
            let mult = ModelPricing.multiplier(rawModel: raw, canonical: model, rate: rate,
                                               inferenceGeo: usage["inference_geo"] as? String,
                                               fast: usage["speed"] as? String == "fast")
            let perToken = { (price: Double?) in (price ?? 0) / 1_000_000 * mult }
            let agent = d["isSidechain"] as? Bool == true ? d["agentId"] as? String : nil
            let reason = ((message["diagnostics"] as? [String: Any])?["cache_miss_reason"]
                          as? [String: Any])?["type"] as? String
            if digest.detail != nil, let blocks = message["content"] as? [[String: Any]] {
                for b in blocks where b["type"] as? String == "tool_use" {
                    guard let id = b["id"] as? String, digest.detail?.toolUses[id] == nil else { continue }
                    digest.detail?.toolUses[id] = ToolUseRecord(name: b["name"] as? String ?? "?",
                                                                time: t, thread: agent ?? "main", callKey: key)
                }
            }
            let call = UsageCall(
                key: key, sessionID: session, agentID: agent,
                inWorktree: inWorktree, model: model, time: t, end: t,
                input: int("input_tokens"), output: int("output_tokens"),
                cacheRead: int("cache_read_input_tokens"), cacheWrite: write, cacheWrite1h: write1h,
                priceMultiplier: mult,
                cost: TokenCost(
                    input: Double(int("input_tokens")) * perToken(rate?.input),
                    output: Double(int("output_tokens")) * perToken(rate?.output),
                    cacheRead: Double(int("cache_read_input_tokens")) * perToken(rate?.cacheRead),
                    cacheWrite: Double(write5m) * perToken(rate?.cacheWrite5m)
                              + Double(write1h) * perToken(rate?.cacheWrite1h)),
                stopReason: message["stop_reason"] as? String,
                loggedMissReason: reason, effort: d["effort"] as? String)
            digest.calls[key] = digest.calls[key].map { Self.combine($0, call) } ?? call
        }

        /// Two lines of one call: the first line's identity, the earliest time, and the usage of
        /// the line with the most output (ties go to the later line — it is the more complete one).
        static func combine(_ first: UsageCall, _ next: UsageCall) -> UsageCall {
            var out = next.output >= first.output ? next : first
            out.sessionID = first.sessionID
            out.agentID = first.agentID
            out.inWorktree = first.inWorktree
            out.model = first.model
            out.time = min(first.time, next.time)
            out.end = max(first.end, next.end)
            out.stopReason = next.stopReason ?? first.stopReason
            out.loggedMissReason = first.loggedMissReason ?? next.loggedMissReason
            out.effort = first.effort ?? next.effort
            return out
        }

        private mutating func addUser(_ d: [String: Any], time t: TimeInterval, session: String,
                                      thread: String) {
            let content = (d["message"] as? [String: Any])?["content"]
            digest.detail?.inputs[thread, default: []].append(t)
            if let blocks = content as? [[String: Any]],
               blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                for b in blocks where b["type"] as? String == "tool_result" {
                    guard let id = b["tool_use_id"] as? String else { continue }
                    digest.detail?.toolResults[id] = ToolResultRecord(time: t, isError: b["is_error"] as? Bool == true)
                }
                return
            }
            // A subagent handed new input mid-life (SendMessage) — its history is rebuilt.
            if thread != "main" { digest.detail?.resumes[thread, default: []].append(t) }
            users.append(UserLine(
                session: session, time: t, source: d["promptSource"] as? String,
                isSidechain: d["isSidechain"] as? Bool == true,
                isMeta: d["isMeta"] as? Bool == true,
                excluded: d["isCompactSummary"] as? Bool == true
                    || d["isVisibleInTranscriptOnly"] as? Bool == true,
                sdk: (d["entrypoint"] as? String)?.hasPrefix("sdk") == true,
                text: Self.text(content)))
        }

        mutating func finish() -> TranscriptDigest {
            // Sessions whose CLI logs promptSource; older ones get it inferred from the text.
            let tagged = Set(users.filter { $0.source != nil }.map(\.session))
            var queued = Set<String>()
            for u in users {
                var source = u.source
                let text = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if source == nil, !tagged.contains(u.session), !u.isSidechain, !u.isMeta,
                   !u.excluded, !text.isEmpty,
                   !text.hasPrefix("<"), !text.hasPrefix("[Request interrupted"),
                   !text.hasPrefix("Caveat:") {
                    source = u.sdk ? "sdk" : "typed"
                }
                guard source == "typed" || source == "queued", !u.isSidechain else { continue }
                digest.prompts[u.session, default: []].append(u.time)
                if source == "queued" { queued.insert(u.session + "\u{0}" + Self.clip(u.text)) }
            }
            for a in queuedAttachments where !queued.contains(a.session + "\u{0}" + Self.clip(a.text)) {
                digest.prompts[a.session, default: []].append(a.time)
            }
            if !isSubagent {
                for u in users where digest.titles[u.session] == nil && !u.isSidechain
                    && (u.source == "typed" || u.source == nil) {
                    let text = Self.clip(u.text)
                    if !text.isEmpty, !text.hasPrefix("<") { digest.titles[u.session] = text }
                }
                digest.titles.merge(aiTitles) { _, title in title }
            }
            digest.detail?.sortTimes()
            return digest
        }

        /// Text of a message's content (a string, or its text blocks joined).
        static func text(_ content: Any?) -> String {
            if let s = content as? String { return s }
            guard let blocks = content as? [[String: Any]] else { return "" }
            return blocks.filter { $0["type"] as? String == "text" }
                .map { $0["text"] as? String ?? "" }.joined(separator: "\n")
        }

        /// A prompt's identity for matching a queued line to its attachment: whitespace
        /// collapsed, first 80 characters.
        static func clip(_ s: String) -> String {
            String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
        }
    }
}

/// A `tool_use` block: what ran, when it was asked for, and by which call.
public struct ToolUseRecord: Equatable, Sendable {
    public let name: String
    public let time: TimeInterval
    public let thread: String
    public let callKey: String
}

public struct ToolResultRecord: Equatable, Sendable {
    public let time: TimeInterval
    public let isError: Bool
}

/// The per-thread timelines a session report needs to explain its cache misses. Threads are
/// `main` or a subagent id; every time list is sorted.
public struct TranscriptDetail: Equatable, Sendable {
    /// Every user/attachment record — what the next request waited on.
    public var inputs: [String: [TimeInterval]] = [:]
    public var compactions: [String: [TimeInterval]] = [:]
    /// MCP/deferred tool list changes (tools sit at the front of the prompt).
    public var toolListChanges: [String: [TimeInterval]] = [:]
    /// New input to a subagent that is not a tool result (a SendMessage resume).
    public var resumes: [String: [TimeInterval]] = [:]
    public var toolUses: [String: ToolUseRecord] = [:]
    public var toolResults: [String: ToolResultRecord] = [:]

    public init() {}

    func merging(_ o: TranscriptDetail) -> TranscriptDetail {
        var out = self
        for (k, v) in o.inputs { out.inputs[k, default: []] += v }
        for (k, v) in o.compactions { out.compactions[k, default: []] += v }
        for (k, v) in o.toolListChanges { out.toolListChanges[k, default: []] += v }
        for (k, v) in o.resumes { out.resumes[k, default: []] += v }
        out.toolUses.merge(o.toolUses) { a, _ in a }
        out.toolResults.merge(o.toolResults) { a, _ in a }
        out.sortTimes()
        return out
    }

    mutating func sortTimes() {
        for k in inputs.keys { inputs[k]?.sort() }
        for k in compactions.keys { compactions[k]?.sort() }
        for k in toolListChanges.keys { toolListChanges[k]?.sort() }
        for k in resumes.keys { resumes[k]?.sort() }
    }
}

/// Transcript timestamps (`2026-09-10T10:38:02.346Z`) as epoch seconds. The fixed UTC form is
/// parsed by hand — `ISO8601DateFormatter` costs more than the JSON decode on a large project —
/// and anything else falls back to the formatter.
struct TimestampParser {
    private let fallback = ISO8601Pair()

    func seconds(_ s: String?) -> TimeInterval? {
        guard let s else { return nil }
        let u = Array(s.utf8)
        func num(_ from: Int, _ count: Int) -> Int? {
            var v = 0
            for i in from..<(from + count) {
                let c = u[i]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        if u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u.last == 90,
           let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
           let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) {
            var fraction = 0.0
            if u.count > 20, u[19] == 46 {
                var scale = 0.1
                for c in u[20..<(u.count - 1)] {
                    guard c >= 48 && c <= 57 else { return fallback.date(s)?.timeIntervalSince1970 }
                    fraction += Double(c - 48) * scale
                    scale /= 10
                }
            } else if u.count != 20 {
                return fallback.date(s)?.timeIntervalSince1970
            }
            // Days from the civil date (Howard Hinnant's algorithm), proleptic Gregorian, UTC.
            let yy = mo <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400
            let yoe = yy - era * 400
            let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146097 + doe - 719468
            return Double(days * 86400 + h * 3600 + mi * 60 + sec) + fraction
        }
        return fallback.date(s)?.timeIntervalSince1970
    }
}

// MARK: - Summary

/// Which transcripts Home's Usage card counts.
public enum UsageScope: String, CaseIterable, Identifiable, Sendable {
    /// The open project, its task worktrees included.
    case project
    /// Every project on this machine.
    case all

    public var id: String { rawValue }
}

/// Home's period switch. The raw value is the control's label.
public enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "7D"
    case month = "30D"
    case quarter = "90D"

    public var id: String { rawValue }
    public var days: Int {
        switch self {
        case .week:    return 7
        case .month:   return 30
        case .quarter: return 90
        }
    }
    public var longLabel: String { "last \(days) days" }

    /// Local days `today − (days − 1)` through the end of today.
    public func window(now: Date, calendar: Calendar = .current) -> DayRange {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return DayRange(start: start, end: end)
    }
}

/// A half-open span of time, `[start, end)`.
public struct DayRange: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    func contains(_ t: TimeInterval) -> Bool {
        t >= start.timeIntervalSince1970 && t < end.timeIntervalSince1970
    }
}

public struct CostSlice: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let cost: Double
}

public struct DayCost: Equatable, Sendable, Identifiable {
    /// Local midnight.
    public let day: Date
    public let cost: Double
    public var id: Date { day }
}

public struct SessionCost: Equatable, Sendable, Identifiable {
    public let id: String
    public let cost: Double
    public let lastActive: Date
    /// The CLI's title, else the first prompt; nil when neither was logged.
    public let title: String?
    /// The project folder (slug) the session ran in.
    public let project: String?
    /// The directory it started in.
    public let cwd: String?
}

/// A model priced like a listed sibling (`pricedAs`), or not at all (`pricedAs == nil`, $0).
public struct UnpricedModel: Equatable, Sendable {
    public let model: String
    public let pricedAs: String?
}

/// One period of one project, ready to draw. Shares are 0…1; nil where the denominator is zero.
public struct ProjectUsageSummary: Equatable, Sendable {
    public let window: DayRange
    public let cost: Double
    public let daily: [DayCost]
    public let apiCalls: Int
    public let sessions: Int
    public let prompts: Int
    public let activeSeconds: TimeInterval
    public let cacheHitRate: Double?
    public let subagentShare: Double?
    public let worktreeShare: Double?
    /// Median over sessions of each session's largest main-thread context.
    public let medianPeakContext: Int?
    public let byModel: [CostSlice]
    public let byTokenType: [CostSlice]
    public let topSessions: [SessionCost]
    /// Models in this period not priced exactly.
    public let unpriced: [UnpricedModel]

    public var isEmpty: Bool { apiCalls == 0 && sessions == 0 }

    /// Active time: gaps between a session's records, each capped at this.
    public static let idleCap: TimeInterval = 300

    public static func build(_ data: TranscriptDigest, window: DayRange,
                             calendar: Calendar = .current, topSessionCount: Int = 3) -> ProjectUsageSummary {
        let calls = data.calls.values.filter { window.contains($0.time) }
        let costTotal = calls.reduce(TokenCost()) { $0 + $1.cost }
        let total = costTotal.total

        // Per local day, zero-filled so idle days show as gaps rather than disappearing.
        var perDay: [Date: Double] = [:]
        for c in calls {
            perDay[calendar.startOfDay(for: Date(timeIntervalSince1970: c.time)), default: 0] += c.cost.total
        }
        var daily: [DayCost] = []
        var day = calendar.startOfDay(for: window.start)
        while day < window.end {
            daily.append(DayCost(day: day, cost: perDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        var active: TimeInterval = 0
        var sessionIDs = Set<String>()
        for (sid, times) in data.sessionTimes {
            let inside = times.filter(window.contains).sorted()
            guard !inside.isEmpty else { continue }
            sessionIDs.insert(sid)
            for (a, b) in zip(inside, inside.dropFirst()) { active += min(b - a, idleCap) }
        }
        let prompts = data.prompts.values.reduce(0) { $0 + $1.filter(window.contains).count }

        let context = calls.reduce(0) { $0 + $1.context }
        let reads = calls.reduce(0) { $0 + $1.cacheRead }
        let share = { (part: Double) -> Double? in total > 0 ? part / total : nil }

        var peaks: [String: Int] = [:]
        var bySession: [String: (cost: Double, last: TimeInterval)] = [:]
        var byModel: [String: Double] = [:]
        for c in calls {
            if !c.isSubagent { peaks[c.sessionID] = max(peaks[c.sessionID] ?? 0, c.context) }
            let s = bySession[c.sessionID]
            bySession[c.sessionID] = ((s?.cost ?? 0) + c.cost.total, max(s?.last ?? 0, c.time))
            byModel[c.model, default: 0] += c.cost.total
        }

        let models: [CostSlice] = byModel
            .map { CostSlice(id: $0.key, label: ModelNames.display($0.key), cost: $0.value) }
            .filter { $0.cost > 0 }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.id < $1.id }
        let types: [CostSlice] = [
            CostSlice(id: "cacheRead", label: "Cache reads", cost: costTotal.cacheRead),
            CostSlice(id: "cacheWrite", label: "Cache writes", cost: costTotal.cacheWrite),
            CostSlice(id: "output", label: "Output", cost: costTotal.output),
            CostSlice(id: "input", label: "Input", cost: costTotal.input),
        ].filter { $0.cost > 0 }
        let top = bySession.filter { $0.value.cost > 0 }
            .sorted { $0.value.cost != $1.value.cost ? $0.value.cost > $1.value.cost : $0.key < $1.key }
            .prefix(topSessionCount)
            .map { SessionCost(id: $0.key, cost: $0.value.cost,
                               lastActive: Date(timeIntervalSince1970: $0.value.last),
                               title: data.titles[$0.key], project: data.sessionProjects[$0.key],
                               cwd: data.sessionCwds[$0.key]) }
        let usedModels = Set(calls.map(\.model))
        let unpriced = data.priceNotes.filter { usedModels.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { note -> UnpricedModel in
                if case .estimated(let from) = note.value { return UnpricedModel(model: note.key, pricedAs: from) }
                return UnpricedModel(model: note.key, pricedAs: nil)
            }

        return ProjectUsageSummary(
            window: window, cost: total, daily: daily, apiCalls: calls.count,
            sessions: sessionIDs.count, prompts: prompts, activeSeconds: active,
            cacheHitRate: context > 0 ? Double(reads) / Double(context) : nil,
            subagentShare: share(calls.filter(\.isSubagent).reduce(0) { $0 + $1.cost.total }),
            worktreeShare: share(calls.filter(\.inWorktree).reduce(0) { $0 + $1.cost.total }),
            medianPeakContext: median(peaks.values.filter { $0 > 0 }),
            byModel: models, byTokenType: types, topSessions: Array(top), unpriced: unpriced)
    }

    /// The middle value, or the mean of the two middle values.
    static func median(_ values: some Collection<Int>) -> Int? {
        let v = values.sorted()
        guard !v.isEmpty else { return nil }
        let mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : Int((Double(v[mid - 1] + v[mid]) / 2).rounded())
    }
}
