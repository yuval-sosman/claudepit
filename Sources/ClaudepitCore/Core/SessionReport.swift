import Foundation

/// One session's usage report: the project card's numbers for a single session, plus what only
/// makes sense per session — how its context grew, every cache miss with its cause and what it
/// cost over a hit, the subagents it spawned and the tools it ran.
///
/// Built from the same `TranscriptDigest` as Home (parsed with `detail: true`), so its cost,
/// prompts and active time are exactly Home's for that session. The cache-miss rules:
/// - A call **re-writes** `max(0, min(previous context − cache read − input, cache write))` tokens
///   of its thread's history; above 1,000 it is a **miss**. A compaction between the two calls
///   replaces the conversation, so nothing after it counts as a re-write.
/// - A thread's cache **lifetime** is 1 hour when it wrote mostly 1-hour entries, else 5 minutes.
/// - **Idle** is from the end of the previous response to this request's start (the later of the
///   previous response's end and the last input before the call) — the cache clock runs from
///   there, not from the previous request.
/// - A miss's **extra cost** is its re-written tokens × (write price − read price): what it paid
///   over the cache hit it would otherwise have been.
public struct SessionReport: Sendable {
    public struct ContextPoint: Identifiable, Equatable, Sendable {
        /// 1-based position among the main thread's calls.
        public let id: Int
        public let time: Date
        public let context: Int
        public let rewritten: Int
        public let isMiss: Bool
        /// A compaction happened just before this call.
        public let afterCompaction: Bool
    }

    public struct Miss: Identifiable, Equatable, Sendable {
        public let id: String
        public let time: Date
        /// `main thread`, or the subagent's type.
        public let thread: String
        public let model: String
        public let rewritten: Int
        public let idleBefore: TimeInterval
        public let cacheLifetime: TimeInterval
        public let cause: String
        public let extraCost: Double
    }

    public struct CauseTotal: Identifiable, Equatable, Sendable {
        public var id: String { cause }
        public let cause: String
        public let misses: Int
        public let tokens: Int
        public let extraCost: Double
    }

    public struct Subagent: Identifiable, Equatable, Sendable {
        public let id: String
        public let type: String
        public let description: String
        public let models: [String]
        public let calls: Int
        public let cost: Double
        public let hitRate: Double?
        public let peakContext: Int
        public let misses: Int
        public let start: Date
        public let end: Date
    }

    public struct ToolTotal: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let calls: Int
        public let errors: Int
        /// Seconds from each call to its result, summed — where the session's tool time went.
        /// (A median misleads here: a few long builds hide among many sub-second greps.)
        public let totalSeconds: TimeInterval
    }

    public let sessionID: String
    /// Cost, prompts, active time, hit rate, breakdowns — the Home card's numbers for this
    /// session alone.
    public let summary: ProjectUsageSummary
    public let start: Date?
    public let end: Date?
    public let mainCalls: Int
    public let subagentCalls: Int
    public let mainHitRate: Double?
    public let subagentHitRate: Double?
    /// The main thread's cache lifetime (seconds), from the writes it made.
    public let mainCacheLifetime: TimeInterval?
    /// Cache-read tokens per output token — how much context each token of work re-sent.
    public let rereadPerOutput: Double?
    public let context: [ContextPoint]
    public let compactions: Int
    public let misses: [Miss]
    public let causes: [CauseTotal]
    public let cacheWriteTokens: Int
    public let subagents: [Subagent]
    public let tools: [ToolTotal]

    public var missTokens: Int { misses.reduce(0) { $0 + $1.rewritten } }
    public var missCost: Double { misses.reduce(0) { $0 + $1.extraCost } }
    public var baselineContext: Int? { context.first?.context }
    public var peakContext: Int? { context.map(\.context).max() }
    public var finalContext: Int? { context.last?.context }

    /// Re-written tokens above this count as a cache miss.
    public static let missThreshold = 1_000
    static let waitingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "EnterPlanMode"]

    /// What each cause means — definitions, shown as help on the report.
    public static let causeHelp: [String: String] = [
        "You came back after a break": "The pause after the previous reply outlasted the cache lifetime (1 hour on a subscription, 5 minutes on an API key).",
        "Waited on your answer/approval": "A question or plan approval waited longer than the cache lifetime.",
        "Slow tool run": "A tool (often a build) ran longer than the cache lifetime.",
        "Slow or retried API response": "The request took longer than the cache lifetime to answer (queueing or retries).",
        "Subagent resumed via SendMessage": "A finished subagent got a follow-up; its history is rebuilt, so its whole context is written again.",
        "Subagent idle until resumed": "A subagent that had finished sat longer than its cache lifetime before more work arrived.",
        "Tool list changed (MCP/tools)": "An MCP server connected or tools were added mid-session; tools sit at the front of the prompt.",
        "Model switch": "Caches are per model; switching rebuilds everything.",
        "Effort changed": "Changing effort invalidates the message cache.",
        "Cache expired": "The CLI logged that the cached prefix was gone.",
        "Earlier messages changed": "The CLI logged that earlier messages in the prompt changed.",
        "No logged reason": "The prefix changed without a recorded reason.",
    ]

    // MARK: - Loading

    /// Reads and reports one session: its main transcript and its subagents' transcripts.
    /// Filesystem work — call off the main actor.
    public static func load(sessionID: String, mainFile: URL, subagents: [SubagentSummary],
                            inWorktree: Bool) -> SessionReport? {
        guard let main = try? Data(contentsOf: mainFile, options: .mappedIfSafe) else { return nil }
        var digests = [TranscriptDigest.parse(main, isSubagent: false, inWorktree: inWorktree, detail: true)]
        for sub in subagents {
            guard let data = try? Data(contentsOf: sub.fileURL, options: .mappedIfSafe) else { continue }
            digests.append(TranscriptDigest.parse(data, isSubagent: true, inWorktree: inWorktree, detail: true))
        }
        let meta = Dictionary(subagents.map { ($0.id, (type: $0.agentType, description: $0.description)) },
                              uniquingKeysWith: { a, _ in a })
        return build(TranscriptDigest.merged(digests), sessionID: sessionID, subagents: meta)
    }

    // MARK: - Building

    public static func build(_ digest: TranscriptDigest, sessionID: String,
                             subagents meta: [String: (type: String, description: String)] = [:]) -> SessionReport {
        // A transcript can carry another session's records (a /clear continues in the same file);
        // only this session's calls belong in its report — unless none are tagged with it.
        var own = digest.calls.filter { $0.value.sessionID == sessionID }
        if own.isEmpty { own = digest.calls }
        var scoped = digest
        scoped.calls = own
        scoped.sessionTimes = digest.sessionTimes.filter { $0.key == sessionID }
        scoped.prompts = digest.prompts.filter { $0.key == sessionID }
        let times = (scoped.sessionTimes[sessionID] ?? []) + own.values.flatMap { [$0.time, $0.end] }
        let first = times.min(), last = times.max()
        let window = DayRange(start: Date(timeIntervalSince1970: (first ?? 0) - 86_400),
                              end: Date(timeIntervalSince1970: (last ?? 0) + 86_400))
        let summary = ProjectUsageSummary.build(scoped, window: window, topSessionCount: 0)

        let detail = digest.detail ?? TranscriptDetail()
        let threads = Dictionary(grouping: own.values, by: \.thread)
            .mapValues { $0.sorted { ($0.time, $0.end, $0.key) < ($1.time, $1.end, $1.key) } }

        var misses: [Miss] = []
        var points: [ContextPoint] = []
        var lifetimes: [String: TimeInterval] = [:]
        for (thread, calls) in threads {
            let w1 = calls.reduce(0) { $0 + $1.cacheWrite1h }
            let w5 = calls.reduce(0) { $0 + $1.cacheWrite - $1.cacheWrite1h }
            let ttl: TimeInterval = (w1 >= w5 && w1 > 0) ? 3600 : w5 > 0 ? 300 : (thread == "main" ? 3600 : 300)
            lifetimes[thread] = ttl
            let inputs = detail.inputs[thread] ?? []
            var prev: UsageCall?
            for (i, c) in calls.enumerated() {
                // Request start: the later of the previous response's end and the last input
                // before the call — never after the call itself.
                var start = lastAtOrBefore(inputs, c.time) ?? c.time
                if let p = prev { start = max(start, p.end) }
                start = min(start, c.time)
                let compacted = prev.map { count(detail.compactions[thread], after: $0.end, upTo: c.time) > 0 } ?? false
                var rewritten = 0
                if let p = prev, !compacted {
                    rewritten = max(0, min(p.context - c.cacheRead - c.input, c.cacheWrite))
                }
                let isMiss = rewritten > missThreshold
                if isMiss, let p = prev {
                    let idle = start - p.end
                    let label = thread == "main" ? "main thread" : (meta[thread]?.type ?? "subagent")
                    misses.append(Miss(
                        id: c.key, time: Date(timeIntervalSince1970: c.time), thread: label, model: c.model,
                        rewritten: rewritten, idleBefore: idle, cacheLifetime: ttl,
                        cause: cause(c, prev: p, idle: idle, generation: c.end - start, ttl: ttl, detail: detail),
                        extraCost: extraCost(c, rewritten: rewritten, ttl: ttl)))
                }
                if thread == "main" {
                    points.append(ContextPoint(id: i + 1, time: Date(timeIntervalSince1970: c.time),
                                               context: c.context, rewritten: rewritten, isMiss: isMiss,
                                               afterCompaction: compacted))
                }
                prev = c
            }
        }
        misses.sort { $0.rewritten != $1.rewritten ? $0.rewritten > $1.rewritten : $0.time < $1.time }

        var byCause: [String: (misses: Int, tokens: Int, cost: Double)] = [:]
        for m in misses {
            let t = byCause[m.cause] ?? (0, 0, 0)
            byCause[m.cause] = (t.misses + 1, t.tokens + m.rewritten, t.cost + m.extraCost)
        }
        var causes: [CauseTotal] = byCause.map {
            CauseTotal(cause: $0.key, misses: $0.value.misses, tokens: $0.value.tokens, extraCost: $0.value.cost)
        }
        causes.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.cause < $1.cause }

        let all = Array(own.values)
        let main = all.filter { !$0.isSubagent }
        let subs = all.filter(\.isSubagent)
        let output = all.reduce(0) { $0 + $1.output }

        let missKeys = Set(misses.map(\.id))
        var subagents: [Subagent] = []
        for (id, calls) in threads where id != "main" {
            let info = meta[id]
            let cost: Double = calls.reduce(0) { $0 + $1.cost.total }
            let ends: [TimeInterval] = calls.map(\.end)
            subagents.append(Subagent(
                id: id, type: info?.type ?? "subagent", description: info?.description ?? "",
                models: Array(Set(calls.map(\.model))).sorted(), calls: calls.count,
                cost: cost, hitRate: hitRate(calls),
                peakContext: calls.map(\.context).max() ?? 0,
                misses: calls.filter { missKeys.contains($0.key) }.count,
                start: Date(timeIntervalSince1970: calls.first?.time ?? 0),
                end: Date(timeIntervalSince1970: ends.max() ?? 0)))
        }
        subagents.sort { $0.cost != $1.cost ? $0.cost > $1.cost : $0.id < $1.id }

        let keys = Set(own.keys)
        let uses = detail.toolUses.filter { keys.contains($0.value.callKey) }
        var tools: [ToolTotal] = []
        for (name, entries) in Dictionary(grouping: uses, by: { $0.value.name }) {
            var errors = 0
            var seconds: TimeInterval = 0
            for (id, use) in entries {
                guard let result = detail.toolResults[id] else { continue }
                if result.isError { errors += 1 }
                seconds += max(0, result.time - use.time)
            }
            tools.append(ToolTotal(name: name, calls: entries.count, errors: errors, totalSeconds: seconds))
        }
        tools.sort { $0.calls != $1.calls ? $0.calls > $1.calls : $0.name < $1.name }

        return SessionReport(
            sessionID: sessionID, summary: summary,
            start: first.map { Date(timeIntervalSince1970: $0) }, end: last.map { Date(timeIntervalSince1970: $0) },
            mainCalls: main.count, subagentCalls: subs.count,
            mainHitRate: hitRate(main), subagentHitRate: hitRate(subs),
            mainCacheLifetime: main.isEmpty ? nil : lifetimes["main"],
            rereadPerOutput: output > 0 ? Double(all.reduce(0) { $0 + $1.cacheRead }) / Double(output) : nil,
            context: points.sorted { $0.id < $1.id },
            compactions: detail.compactions["main"]?.count ?? 0,
            misses: misses, causes: causes,
            cacheWriteTokens: all.reduce(0) { $0 + $1.cacheWrite },
            subagents: subagents, tools: tools)
    }

    /// Why a miss happened — the gap against the cache lifetime, what the previous call was
    /// waiting on, model/effort changes, tool-list changes and the CLI's own logged reason.
    static func cause(_ c: UsageCall, prev p: UsageCall, idle: TimeInterval, generation: TimeInterval,
                      ttl: TimeInterval, detail: TranscriptDetail) -> String {
        let reason = c.loggedMissReason
        if p.model != c.model { return "Model switch" }
        let prevTools = detail.toolUses.values.filter { $0.callKey == p.key }
        if reason == "tools_changed" || count(detail.toolListChanges[c.thread], after: p.end, upTo: c.time) > 0 {
            return "Tool list changed (MCP/tools)"
        }
        if c.isSubagent, prevTools.isEmpty, count(detail.resumes[c.thread], after: p.end, upTo: c.time) > 0 {
            return "Subagent resumed via SendMessage"
        }
        if idle > ttl {
            if prevTools.contains(where: { waitingTools.contains($0.name) }) { return "Waited on your answer/approval" }
            if c.isSubagent && p.stopReason == "end_turn" { return "Subagent idle until resumed" }
            if !c.isSubagent && (p.stopReason == "end_turn" || p.stopReason == nil) && prevTools.isEmpty {
                return "You came back after a break"
            }
            let toolIDs = detail.toolUses.filter { $0.value.callKey == p.key }
            let slowest = toolIDs.compactMap { id, use in detail.toolResults[id].map { $0.time - use.time } }.max() ?? 0
            return slowest > 0.5 * idle ? "Slow tool run" : "Slow or retried API response"
        }
        if generation > 0.9 * ttl { return "Slow or retried API response" }
        if let a = p.effort, let b = c.effort, a != b { return "Effort changed" }
        if reason == "previous_message_not_found" { return "Cache expired" }
        if reason == "messages_changed" { return "Earlier messages changed" }
        return "No logged reason"
    }

    static func extraCost(_ c: UsageCall, rewritten: Int, ttl: TimeInterval) -> Double {
        guard let rate = ModelPricing.rate(for: c.model).rate else { return 0 }
        let write = ttl >= 3600 ? rate.cacheWrite1h : rate.cacheWrite5m
        return Double(rewritten) * (write - rate.cacheRead) / 1_000_000 * c.priceMultiplier
    }

    static func hitRate(_ calls: [UsageCall]) -> Double? {
        let context = calls.reduce(0) { $0 + $1.context }
        return context > 0 ? Double(calls.reduce(0) { $0 + $1.cacheRead }) / Double(context) : nil
    }

    /// The last value ≤ `t` in a sorted list.
    static func lastAtOrBefore(_ sorted: [TimeInterval], _ t: TimeInterval) -> TimeInterval? {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? sorted[lo - 1] : nil
    }

    /// How many values fall in `(after, upTo]`.
    static func count(_ sorted: [TimeInterval]?, after: TimeInterval, upTo: TimeInterval) -> Int {
        guard let sorted, upTo > after else { return 0 }
        return sorted.filter { $0 > after && $0 <= upTo }.count
    }
}
