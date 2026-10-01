import Foundation

/// What one transcript records about scheduling, in file order: every `CronCreate`, `CronDelete`
/// and `ScheduleWakeup` call with its result, every scheduled fire, every `/loop` invocation and
/// every `/goal` verdict. Session-scoped loops exist only in their process's memory, and the
/// transcript is the one durable account of them — it is also what the CLI itself rebuilds them
/// from on `--resume` (its `Di`), so reading it the same way says exactly what a resume brings back.
///
/// How the CLI writes these (2.1.281–2.1.286, verified on real transcripts):
/// - a call is an `assistant` record's `tool_use` block; its result is a later `user` record's
///   `tool_result` with a structured `toolUseResult` (CronCreate: `{id, recurring, durable}`;
///   ScheduleWakeup: `{scheduledFor, clampedDelaySeconds, wasClamped}`);
/// - a fire is a `system` record (`subtype: scheduled_task_fire`, with `taskId`, `cron`, `prompt`,
///   `taskKind`) followed by the prompt itself as a meta `user` record carrying
///   `turnOrigin: "scheduled"` and `scheduledTaskId`;
/// - a self-paced wakeup is scheduled internally as a pinned one-shot (`2 11 * * *`, kind `loop`),
///   a new task id each time.
public struct LoopLog: Equatable, Sendable {
    public struct Create: Equatable, Sendable {
        public var toolUseID: String
        public var time: Date
        public var offset: Int
        public var cron: String
        public var prompt: String
        public var recurring: Bool?
        public var durable: Bool?
        public var result: CreateResult?
    }
    public struct CreateResult: Equatable, Sendable {
        public var jobID: String?
        public var recurring: Bool?
        public var durable: Bool?
        public var isError: Bool
        public var text: String
    }
    public struct Delete: Equatable, Sendable {
        public var toolUseID: String
        public var time: Date
        public var offset: Int
        public var jobID: String?
        /// nil until the result is read.
        public var ok: Bool?
    }
    public struct Wakeup: Equatable, Sendable {
        public var toolUseID: String
        public var time: Date
        public var offset: Int
        public var delaySeconds: Int?
        public var reason: String?
        public var prompt: String?
        public var stop: Bool
        public var scheduledFor: Date?
        public var clampedDelaySeconds: Int?
        public var wasClamped: Bool?
        public var isError: Bool?
        public var resultText: String?

        public init(toolUseID: String, time: Date, offset: Int, delaySeconds: Int?, reason: String?, prompt: String?,
                    stop: Bool, scheduledFor: Date? = nil, clampedDelaySeconds: Int? = nil, wasClamped: Bool? = nil,
                    isError: Bool? = nil, resultText: String? = nil) {
            self.toolUseID = toolUseID; self.time = time; self.offset = offset; self.delaySeconds = delaySeconds
            self.reason = reason; self.prompt = prompt; self.stop = stop; self.scheduledFor = scheduledFor
            self.clampedDelaySeconds = clampedDelaySeconds; self.wasClamped = wasClamped
            self.isError = isError; self.resultText = resultText
        }
    }
    public struct Fire: Equatable, Sendable {
        /// When it fired — its `scheduled_task_fire` record.
        public var time: Date
        public var offset: Int
        public var taskID: String
        public var cron: String?
        /// The full prompt once its prompt record is read; until then the fire record's copy,
        /// which the CLI cuts to 200 characters and squashes whitespace in.
        public var prompt: String?
        /// `loop` for a self-paced wakeup — the CLI sets it on nothing else.
        public var taskKind: String?
        /// The CLI's own line for it ("Claude resuming /loop wakeup (Oct 1 11:57am)").
        public var label: String?
        /// When its prompt record landed — the turn it starts begins there. A fire that comes due
        /// as a turn ends is written *before* that turn's last records; its prompt record after.
        public var deliveredAt: Date?
        public var promptOffset: Int?
    }
    public struct Invocation: Equatable, Sendable {
        public var time: Date
        public var offset: Int
        public var args: String
        /// Claude invoked the loop skill itself (Skill tool), not the person typing `/loop`.
        public var viaSkill: Bool
    }
    public struct GoalEvent: Equatable, Sendable {
        public var time: Date
        public var condition: String
        public var met: Bool?
        public var reason: String?
        public var iterations: Int?
        public var durationMs: Int?
        /// The marker the CLI writes when a goal is set (`sentinel: true`).
        public var isStart: Bool
        /// `/goal clear` (or an alias).
        public var isClear: Bool
    }

    public var creates: [Create] = []
    public var deletes: [Delete] = []
    public var wakeups: [Wakeup] = []
    public var fires: [Fire] = []
    public var invocations: [Invocation] = []
    public var goals: [GoalEvent] = []
    /// The newest permission mode a prompt or fire ran under — whether a fire can run unattended.
    public var permissionMode: String?
    /// When the newest turn that isn't a fire began: a typed prompt or command, a task
    /// notification — with the fires' deliveries, when the latest turn started.
    public var lastTurnStartAt: Date?
    /// When each turn ended (`turn_duration`), in file order — where a fire's iteration ends.
    public var turnEnds: [Date] = []
    /// The session's name as last set (`claude -n`, `/rename`) — every session the Loops page
    /// starts carries one.
    public var customTitle: String?
    /// The agent the whole session runs as (`claude --agent`, or the `agent` setting): its
    /// `agent-setting` record. Its tools are all the session's fires have.
    public var agentSetting: String?

    enum Pending: Equatable, Sendable { case create, delete, wakeup }
    /// Calls whose results haven't been read yet, by tool-use id.
    var pending: [String: Pending] = [:]

    public init() {}

    public var isEmpty: Bool {
        creates.isEmpty && deletes.isEmpty && wakeups.isEmpty && fires.isEmpty && invocations.isEmpty && goals.isEmpty
    }

    /// One transcript record at byte `offset`.
    mutating func ingest(_ o: [String: Any], offset: Int, timestamps: TimestampParser) {
        let type = o["type"] as? String
        // Untimed bookkeeping record; the newest name wins.
        if type == "custom-title", let title = o["customTitle"] as? String, !title.isEmpty {
            customTitle = title
            return
        }
        if type == "agent-setting" {
            agentSetting = (o["agentSetting"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        guard let time = timestamps.seconds(o["timestamp"] as? String).map(Date.init(timeIntervalSince1970:)) else { return }
        if type == "user" || type == "system", let mode = o["permissionMode"] as? String { permissionMode = mode }
        let message = o["message"] as? [String: Any]
        switch type {
        case "assistant":
            for b in message?["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_use" {
                guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                let input = b["input"] as? [String: Any] ?? [:]
                switch name {
                case "CronCreate":
                    guard let cron = input["cron"] as? String, let prompt = input["prompt"] as? String else { continue }
                    creates.append(Create(toolUseID: id, time: time, offset: offset, cron: cron, prompt: prompt,
                                          recurring: input["recurring"] as? Bool, durable: input["durable"] as? Bool))
                    pending[id] = .create
                case "CronDelete":
                    deletes.append(Delete(toolUseID: id, time: time, offset: offset, jobID: input["id"] as? String))
                    pending[id] = .delete
                case "ScheduleWakeup":
                    wakeups.append(Wakeup(toolUseID: id, time: time, offset: offset,
                                          delaySeconds: (input["delaySeconds"] as? NSNumber)?.intValue,
                                          reason: input["reason"] as? String, prompt: input["prompt"] as? String,
                                          stop: input["stop"] as? Bool == true))
                    pending[id] = .wakeup
                case "Skill" where (input["skill"] as? String).map(Self.isLoopSkill) == true:
                    invocations.append(Invocation(time: time, offset: offset, args: input["args"] as? String ?? "",
                                                  viaSkill: true))
                default: break
                }
            }
        case "user":
            let detail = o["toolUseResult"] as? [String: Any]
            if let blocks = message?["content"] as? [[String: Any]] {
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                for b in results { resolve(b, detail: results.count == 1 ? detail : nil) }
            }
            let origin = o["turnOrigin"] as? String
            let source = o["promptSource"] as? String
            if let task = o["scheduledTaskId"] as? String {
                deliver(taskID: task, at: time, offset: offset, prompt: message?["content"] as? String)
            } else if (origin != nil && origin != "scheduled") || source == "typed" || source == "queued" {
                lastTurnStartAt = max(lastTurnStartAt ?? .distantPast, time)
            }
            if let text = message?["content"] as? String { commands(in: text, time: time, offset: offset) }
        case "system":
            if o["subtype"] as? String == "scheduled_task_fire", let task = o["taskId"] as? String {
                addFire(Fire(time: time, offset: offset, taskID: task, cron: o["cron"] as? String,
                             prompt: o["prompt"] as? String, taskKind: o["taskKind"] as? String,
                             label: o["content"] as? String))
            } else if o["subtype"] as? String == "local_command", let text = o["content"] as? String {
                commands(in: text, time: time, offset: offset)
            } else if o["subtype"] as? String == "turn_duration" {
                turnEnds.append(time)
            }
        case "attachment":
            guard let a = o["attachment"] as? [String: Any], a["type"] as? String == "goal_status",
                  let condition = a["condition"] as? String else { return }
            goals.append(GoalEvent(time: time, condition: condition, met: a["met"] as? Bool,
                                   reason: a["reason"] as? String,
                                   iterations: (a["iterations"] as? NSNumber)?.intValue,
                                   durationMs: (a["durationMs"] as? NSNumber)?.intValue,
                                   isStart: a["sentinel"] as? Bool == true, isClear: false))
        default: break
        }
    }

    /// `loop`, or a plugin-qualified `…:loop`.
    static func isLoopSkill(_ name: String) -> Bool { name == "loop" || name.hasSuffix(":loop") }

    /// A typed `/loop …` or `/goal …` (a user record, or a newer CLI's `local_command` record).
    private mutating func commands(in text: String, time: Date, offset: Int) {
        guard let name = xmlTag(text, "command-name") else { return }
        let args = (xmlTag(text, "command-args") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "/loop" {
            invocations.append(Invocation(time: time, offset: offset, args: args, viaSkill: false))
        } else if name == "/goal", ["clear", "stop", "off", "reset", "none", "cancel"].contains(args.lowercased()) {
            goals.append(GoalEvent(time: time, condition: "", isStart: false, isClear: true))
        }
    }

    /// A fire is written twice — the `system` record, then (maybe after the previous turn's last
    /// records) the prompt itself.
    private mutating func addFire(_ fire: Fire) {
        fires.append(fire)
    }

    /// The prompt record of a fire: it belongs to the newest undelivered fire of its task (the next
    /// fire of a recurring task can't come before this one's turn ends). An older CLI that wrote no
    /// fire record gets one made from it.
    private mutating func deliver(taskID: String, at time: Date, offset: Int, prompt: String?) {
        if let i = fires.lastIndex(where: { $0.taskID == taskID && $0.deliveredAt == nil && $0.time <= time.addingTimeInterval(1) }) {
            fires[i].deliveredAt = time
            fires[i].promptOffset = offset
            if let prompt, !prompt.isEmpty { fires[i].prompt = prompt }   // the full one
            return
        }
        fires.append(Fire(time: time, offset: offset, taskID: taskID, prompt: prompt, deliveredAt: time, promptOffset: offset))
    }

    private mutating func resolve(_ block: [String: Any], detail: [String: Any]?) {
        guard let id = block["tool_use_id"] as? String, let kind = pending.removeValue(forKey: id) else { return }
        let isError = block["is_error"] as? Bool == true
        let text: String = {
            if let s = block["content"] as? String { return s }
            return (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }()
        switch kind {
        case .create:
            guard let i = creates.lastIndex(where: { $0.toolUseID == id }) else { return }
            creates[i].result = CreateResult(jobID: isError ? nil : (detail?["id"] as? String ?? Self.jobID(in: text)),
                                             recurring: detail?["recurring"] as? Bool,
                                             durable: detail?["durable"] as? Bool, isError: isError, text: text)
        case .delete:
            guard let i = deletes.lastIndex(where: { $0.toolUseID == id }) else { return }
            deletes[i].ok = !isError
        case .wakeup:
            guard let i = wakeups.lastIndex(where: { $0.toolUseID == id }) else { return }
            wakeups[i].isError = isError
            wakeups[i].resultText = text
            if let ms = (detail?["scheduledFor"] as? NSNumber)?.doubleValue {
                wakeups[i].scheduledFor = Date(timeIntervalSince1970: ms / 1000)
            }
            wakeups[i].clampedDelaySeconds = (detail?["clampedDelaySeconds"] as? NSNumber)?.intValue
            wakeups[i].wasClamped = detail?["wasClamped"] as? Bool
        }
    }

    /// A job id spelled in a result's text, when the structured result is missing: the one
    /// 8-hex-character word in it.
    static func jobID(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b[0-9a-f]{8}\b"#) else { return nil }
        let hits = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { !$0.allSatisfy(\.isNumber) }
        return Set(hits).count == 1 ? hits[0] : nil
    }

    private func xmlTag(_ text: String, _ tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}

// MARK: - Reading

/// Finds the scheduling records in transcript bytes without parsing the rest: a byte search for
/// markers only those records contain, then a JSON parse of just the lines they sit on. A
/// transcript runs to tens of MB, almost none of it about loops.
public enum LoopLogReader {
    /// Each is how the CLI's compact JSON spells it — a quoted mention inside a message is
    /// escaped (`\"name\":\"CronCreate\"`) and so never matches. Kept few and broad (each is a
    /// pass over the file): `"scheduled` alone finds fire records, fired prompts and wakeup
    /// results; `<command-name>/` every slash command. The parse decides the rest.
    static let markers: [String] = [
        #""name":"Cron"#, #""name":"ScheduleWakeup""#, #""scheduled"#, "<command-name>/",
        #""skill":"loop""#, #""type":"goal_status""#, #""promptSource":""#, #""type":"custom-title""#,
        #""turnOrigin":""#, #""subtype":"turn_duration""#, #""type":"agent-setting""#,
    ]

    /// Read the whole lines in `bytes` into `log`; `baseOffset` is where `bytes` begin in the file.
    public static func ingest(_ bytes: Data, baseOffset: Int, into log: inout LoopLog) {
        let timestamps = TimestampParser()
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var done = Set<Int>()
            func parse(_ starts: [Int: Int]) {
                for (start, end) in starts.sorted(by: { $0.key < $1.key }) where !done.contains(start) {
                    done.insert(start)
                    let line = Data(bytes: base + start, count: end - start)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    log.ingest(obj, offset: baseOffset + start, timestamps: timestamps)
                }
            }
            var lines: [Int: Int] = [:]
            for marker in markers { collectLines(base, raw.count, needle: Array(marker.utf8), into: &lines) }
            parse(lines)
            // Results come after their calls — in this chunk or a later one — so they are looked
            // for by tool-use id, once the calls that want them are known.
            var results: [Int: Int] = [:]
            for id in log.pending.keys {
                collectLines(base, raw.count, needle: Array(#""tool_use_id":"\#(id)""#.utf8), into: &results)
            }
            parse(results)
        }
    }

    /// Every line (start → end, newline excluded) containing `needle`.
    static func collectLines(_ base: UnsafeRawPointer, _ count: Int, needle: [UInt8], into lines: inout [Int: Int]) {
        guard !needle.isEmpty else { return }
        let end = base + count
        var cursor = base
        while cursor < end, let hit = memmem(cursor, end - cursor, needle, needle.count) {
            let hitAt = UnsafeRawPointer(hit) - base
            var start = hitAt
            while start > 0, base.load(fromByteOffset: start - 1, as: UInt8.self) != 0x0A { start -= 1 }
            var stop = hitAt + needle.count
            while stop < count, base.load(fromByteOffset: stop, as: UInt8.self) != 0x0A { stop += 1 }
            lines[start] = stop
            cursor = base + min(count, stop + 1)
        }
    }

    /// A whole transcript, read once.
    public static func read(_ file: URL) -> LoopLog {
        var log = LoopLog()
        if let data = try? Data(contentsOf: file, options: .alwaysMapped) { ingest(data, baseOffset: 0, into: &log) }
        return log
    }
}

/// Per transcript: the log so far and how far the file has been read — `WorktreeScanner`'s
/// `MentionCache` shape. An unchanged file costs a stat; a live session's growing transcript is
/// read only from where the last read stopped; a file rewritten shorter is read again from the top.
public final class LoopLogCache: @unchecked Sendable {
    struct Entry {
        /// Always just past a newline, so a half-written line is read once it is whole.
        var offset: Int
        var size: Int
        var modified: Date
        var log: LoopLog
    }
    private var map: [String: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    public func log(for file: URL) -> LoopLog {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int, let modified = attrs[.modificationDate] as? Date else { return LoopLog() }
        lock.lock()
        let cached = map[file.path]
        lock.unlock()
        if let cached, cached.size == size, cached.modified == modified { return cached.log }
        var entry = cached ?? Entry(offset: 0, size: 0, modified: .distantPast, log: LoopLog())
        if size < entry.offset { entry = Entry(offset: 0, size: 0, modified: .distantPast, log: LoopLog()) }
        if size > entry.offset, let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count > entry.offset {
            let tail = data[(data.startIndex + entry.offset)...]
            if let lastNewline = tail.lastIndex(of: 0x0A) {
                // A slice of the mapped file, not a copy: a first read of a 60 MB transcript
                // would otherwise allocate all of it.
                let whole = tail[tail.startIndex...lastNewline]
                LoopLogReader.ingest(whole, baseOffset: entry.offset, into: &entry.log)
                entry.offset += whole.count
            }
        }
        entry.size = size
        entry.modified = modified
        lock.lock()
        map[file.path] = entry
        lock.unlock()
        return entry.log
    }

    /// Forget transcripts no longer scanned, so the cache can't grow without bound.
    public func prune(keeping live: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        map = map.filter { live.contains($0.key) }
    }
}

// MARK: - One iteration

/// What one fire's turn did — read on demand from the fire's offset, for the iterations the
/// detail card shows. The list never needs it.
public struct LoopIteration: Equatable, Sendable {
    public struct ToolCount: Equatable, Sendable { public let name: String; public let count: Int }
    /// Claude's last words in the turn — usually its report.
    public var lastText: String?
    public var toolCalls = 0
    public var tools: [ToolCount] = []
    /// Tool results that came back as errors.
    public var errors = 0
    public var outputTokens = 0
    /// From the CLI's own `turn_duration` record.
    public var durationMs: Int?
    public var endedAt: Date?
    /// The turn's end was found (not cut off by the read budget or still running).
    public var complete = false
    public var models: [String] = []
    /// Subagents the turn started. An interactive session runs them in the background, so the
    /// turn ends at the launch and the agent's report arrives later, as a turn of its own — the
    /// reader follows each one there.
    public var delegations: [Delegation] = []
    /// A subagent it started in the background hasn't reported back yet.
    public var awaitingReports: Bool { delegations.contains { $0.background && !$0.reported } }

    public struct Delegation: Equatable, Sendable {
        public var toolUseID: String
        /// `subagent_type` — the agent file's name, or `general-purpose` when the call named none.
        public var agent: String
        public var description: String?
        /// The call came back "Async agent launched": its report is a later turn.
        public var background = false
        /// From the report: `completed`, `failed`, `killed`… — nil while it hasn't come back.
        public var status: String?
        /// What the agent reported (its last words), cut to `LoopIterationReader.reportLimit`.
        public var result: String?
        public var reportedAt: Date?
        /// The agent's own run time, from the report's `<usage>`.
        public var durationMs: Int?

        public init(toolUseID: String, agent: String, description: String? = nil) {
            self.toolUseID = toolUseID; self.agent = agent; self.description = description
        }
        public var reported: Bool { status != nil }
    }

    public init() {}
}

public enum LoopIterationReader {
    /// Read the turn a fire started: from its **prompt record** at `offset` (`LoopFire.promptOffset`
    /// — not the fire record, which can sit before the previous turn's last records) until the CLI
    /// records the turn's end (`turn_duration`) or another turn begins — at most `budget` bytes.
    /// A subagent the turn started in the background is then followed past the turn's end to its
    /// report (`<task-notification>` naming the call), within the same budget.
    public static func read(file: URL, from offset: Int, budget: Int = 8 << 20) -> LoopIteration? {
        var it = LoopIteration()
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), offset >= 0, offset < data.count else { return nil }
        let timestamps = TimestampParser()
        let end = data.startIndex + min(data.count, offset + budget)
        var cursor = data.startIndex + offset
        var outputByMessage: [String: Int] = [:]
        var toolCounts: [String: Int] = [:]
        var first = true
        func date(_ o: [String: Any]) -> Date? {
            timestamps.seconds(o["timestamp"] as? String).map(Date.init(timeIntervalSince1970:))
        }
        while cursor < end {
            let lineStart = cursor
            let lineEnd = data[cursor..<end].firstIndex(of: 0x0A) ?? end
            let line = data[cursor..<lineEnd]
            cursor = lineEnd + 1
            if first { first = false; continue }   // the fire's prompt record itself
            guard !line.isEmpty else { continue }
            func has(_ s: String) -> Bool { contains(line, s) }
            if has(#""subtype":"turn_duration""#) {
                if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    it.durationMs = (o["durationMs"] as? NSNumber)?.intValue
                    it.endedAt = date(o)
                }
                it.complete = true
                break
            }
            // Any prompt — typed, a command, a notification, another fire — starts the next turn
            // (tool results carry neither key).
            let startsTurn = has(#""turnOrigin":""#) || has(#""promptSource":"typed""#) || has(#""promptSource":"queued""#)
            if startsTurn && has(#""type":"user""#) {
                it.complete = true   // the next turn began without a duration record (older CLIs)
                cursor = lineStart   // …and it may be a report the delegations below wait for
                break
            }
            if has(#""tool_result""#) {
                if has(#""is_error":true"#) { it.errors += 1 }
                if !it.delegations.isEmpty, it.delegations.contains(where: { has($0.toolUseID) }),
                   let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    settleLaunches(o, in: &it, at: date(o))
                }
                continue
            }
            guard has(#""type":"assistant""#),
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["type"] as? String == "assistant", let message = o["message"] as? [String: Any] else { continue }
            if let model = message["model"] as? String, model != "<synthetic>", !it.models.contains(model) {
                it.models.append(model)
            }
            if let id = message["id"] as? String, let usage = message["usage"] as? [String: Any],
               let out = (usage["output_tokens"] as? NSNumber)?.intValue {
                outputByMessage[id] = max(outputByMessage[id] ?? 0, out)
            }
            for b in message["content"] as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text":
                    if let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { it.lastText = t }
                case "tool_use":
                    it.toolCalls += 1
                    let name = b["name"] as? String
                    if let name { toolCounts[name, default: 0] += 1 }
                    // `Task` is the Agent tool's old name.
                    if name == "Agent" || name == "Task", let id = b["id"] as? String {
                        let input = b["input"] as? [String: Any] ?? [:]
                        it.delegations.append(.init(toolUseID: id, agent: input["subagent_type"] as? String ?? "general-purpose",
                                                    description: input["description"] as? String))
                    }
                default: break
                }
            }
        }
        it.outputTokens = outputByMessage.values.reduce(0, +)
        it.tools = toolCounts.map { LoopIteration.ToolCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }

        // The reports, past the turn's end: whatever comes first — every one found, or the budget.
        while cursor < end, it.delegations.contains(where: { $0.background && !$0.reported }) {
            let lineEnd = data[cursor..<end].firstIndex(of: 0x0A) ?? end
            let line = data[cursor..<lineEnd]
            cursor = lineEnd + 1
            // `<tool-use-id>id<` — not the closing tag, which a JSON writer may spell `<\/tool-use-id>`;
            // the parsed notification confirms the id.
            guard contains(line, "<task-notification>"),
                  let i = it.delegations.firstIndex(where: { !$0.reported && contains(line, "<tool-use-id>\($0.toolUseID)<") }),
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["type"] as? String == "user",
                  let text = text(of: o), let note = TaskNotification.parse(text), note.toolUseID == it.delegations[i].toolUseID
            else { continue }
            it.delegations[i].status = note.status.isEmpty ? "completed" : note.status
            it.delegations[i].result = note.result.map(cut) ?? (note.summary.isEmpty ? nil : note.summary)
            it.delegations[i].reportedAt = date(o)
            it.delegations[i].durationMs = tag("duration_ms", in: text).flatMap { Int($0) }
        }
        return it
    }

    /// A report's text is kept to this many characters — enough for a summary line and a glance.
    public static let reportLimit = 4000

    /// A launch's tool result: "Async agent launched" means the report is a later turn; anything
    /// else is the agent's report itself, returned in the turn (a foreground run).
    private static func settleLaunches(_ o: [String: Any], in it: inout LoopIteration, at time: Date?) {
        let message = o["message"] as? [String: Any]
        for b in message?["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_result" {
            guard let id = b["tool_use_id"] as? String,
                  let i = it.delegations.firstIndex(where: { $0.toolUseID == id }) else { continue }
            let body: String
            if let s = b["content"] as? String { body = s }
            else { body = (b["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Async agent launched") {
                it.delegations[i].background = true
            } else {
                it.delegations[i].status = (b["is_error"] as? Bool) == true ? "failed" : "completed"
                it.delegations[i].result = trimmed.isEmpty ? nil : cut(trimmed)
                it.delegations[i].reportedAt = time
            }
        }
    }

    private static func text(of o: [String: Any]) -> String? {
        let content = (o["message"] as? [String: Any])?["content"]
        if let s = content as? String { return s }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let a = text.range(of: "<\(name)>"), let b = text.range(of: "</\(name)>", range: a.upperBound..<text.endIndex) else { return nil }
        return String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cut(_ s: String) -> String {
        s.count > reportLimit ? String(s.prefix(reportLimit - 1)) + "…" : s
    }

    /// memmem, not `Data.range(of:)`: a turn can run to megabytes of tool output.
    private static func contains(_ line: Data, _ s: String) -> Bool {
        let needle = Array(s.utf8)
        return line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return memmem(base, raw.count, needle, needle.count) != nil
        }
    }
}
