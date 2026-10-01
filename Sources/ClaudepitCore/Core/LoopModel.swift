import Foundation

// The Loops page's model: every loop the app can see — session loops rebuilt from transcripts,
// durable tasks in `.claude/scheduled_tasks.json`, the Desktop app's scheduled tasks — each with a
// state that answers "is this running right now, and if not, why not". Pure: `LoopBuilder` takes
// what was read and the clock, so every rule is testable (`LoopChecks`).

/// Where a loop stands.
public enum LoopState: String, Equatable, Sendable, CaseIterable {
    /// Its session is open and its next fire is ahead.
    case scheduled
    /// Its time has come; it fires as soon as the session is idle.
    case due
    /// One of its iterations is the turn running now.
    case running
    /// Its session stopped on a permission prompt or a question: nothing fires until it's answered.
    case blocked
    /// Its session closed. A cron task comes back when the session is resumed.
    case paused
    /// A one-shot that fired.
    case completed
    /// Removed with CronDelete (or from the task file).
    case cancelled
    /// A self-paced loop that Claude ended (ScheduleWakeup `stop: true`).
    case stopped
    /// A self-paced loop that ended without stopping — no re-arm, or its session closed (those
    /// are not restored on resume).
    case lapsed
    /// A one-shot whose time passed while nothing could fire it.
    case missed
    /// Reached the 7-day limit.
    case expired
    /// The CronCreate call itself failed.
    case failed
    /// A durable task nothing will run as things stand (see its note).
    case notRunning
    /// The Desktop app's — it keeps the schedule, so the state isn't visible from here.
    case external

    public var isActive: Bool { self == .scheduled || self == .due || self == .running || self == .blocked }

    public var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .due: "Due"
        case .running: "Running now"
        case .blocked: "Needs you"
        case .paused: "Paused"
        case .completed: "Done"
        case .cancelled: "Cancelled"
        case .stopped: "Stopped by Claude"
        case .lapsed: "Ended"
        case .missed: "Missed"
        case .expired: "Expired"
        case .failed: "Failed"
        case .notRunning: "Not running"
        case .external: "Desktop app"
        }
    }
}

/// The list's sections, in order.
public enum LoopGroup: Int, CaseIterable, Sendable, Comparable {
    case running, paused, saved, desktop, ended

    public static func < (a: LoopGroup, b: LoopGroup) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused — session closed"
        case .saved: "Saved in scheduled_tasks.json"
        case .desktop: "Desktop app"
        case .ended: "Ended"
        }
    }

    public var help: String {
        switch self {
        case .running: "Loops in an open session — they fire whenever the session is idle"
        case .paused: "Their session closed. Resuming it (claude --resume) brings these back unless they expired"
        case .saved: "Durable tasks in this project's .claude/scheduled_tasks.json"
        case .desktop: "Scheduled tasks of the Claude Desktop app (~/.claude/scheduled-tasks) — managed there"
        case .ended: "Finished, cancelled, stopped or expired loops from the last two weeks"
        }
    }
}

/// One time a loop fired.
public struct LoopFire: Equatable, Sendable, Identifiable {
    public var time: Date
    public var taskID: String
    /// When the scheduler meant it to fire. nil for a fallback wakeup, whose time isn't recorded.
    public var dueAt: Date?
    /// The fire record's byte offset in the transcript — where its turn starts.
    public var offset: Int
    /// The CLI's fallback wakeup: the previous iteration ended without re-arming the loop.
    public var isFallback: Bool
    public var label: String?
    /// When its prompt reached the session — its turn starts there. nil while it waits for the
    /// session's current turn to end.
    public var deliveredAt: Date?
    /// Its prompt record's byte offset — where `LoopIterationReader` starts.
    public var promptOffset: Int?
    /// When its turn ended (`turn_duration`).
    public var endedAt: Date?

    public init(time: Date, taskID: String, dueAt: Date?, offset: Int, isFallback: Bool, label: String?,
                deliveredAt: Date? = nil, promptOffset: Int? = nil, endedAt: Date? = nil) {
        self.time = time; self.taskID = taskID; self.dueAt = dueAt; self.offset = offset
        self.isFallback = isFallback; self.label = label
        self.deliveredAt = deliveredAt; self.promptOffset = promptOffset; self.endedAt = endedAt
    }

    /// Unique even when two fires share a task id (a recurring task) or an offset (a durable task's
    /// only recorded fire).
    public var id: String { "\(taskID)@\(offset)@\(Int(time.timeIntervalSince1970 * 1000))" }
    /// When its turn started: its delivery, else its fire.
    public var startedAt: Date { deliveredAt ?? time }
    /// How long it waited past its time — it can only run while the session is idle.
    public var delay: TimeInterval? { dueAt.map { startedAt.timeIntervalSince($0) } }
}

/// The session's `/goal`, the other way Claude Code keeps a session working on its own.
public struct GoalSummary: Equatable, Sendable {
    public enum State: String, Sendable { case active, achieved, cleared }
    public var condition: String
    public var state: State
    public var lastReason: String?
    public var iterations: Int?
    public var since: Date

    public init(condition: String, state: State, lastReason: String?, iterations: Int?, since: Date) {
        self.condition = condition; self.state = state; self.lastReason = lastReason
        self.iterations = iterations; self.since = since
    }
}

public struct LoopRecord: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// CronCreate, recurring — a fixed `/loop <interval>` or a cron schedule.
        case recurring
        /// CronCreate, `recurring: false` — a reminder.
        case oneShot
        /// `/loop` without an interval: Claude picks each delay (ScheduleWakeup).
        case selfPaced
        /// `.claude/scheduled_tasks.json`.
        case durable
        /// `~/.claude/scheduled-tasks/<name>/SKILL.md`.
        case desktop

        public var label: String {
            switch self {
            case .recurring: "Recurring"
            case .oneShot: "One-time"
            case .selfPaced: "Self-paced"
            case .durable: "Durable task"
            case .desktop: "Desktop task"
            }
        }
    }

    public enum Origin: Equatable, Sendable {
        /// `/loop <args>` — typed, or invoked by Claude through the Skill tool.
        case loopCommand(args: String, viaSkill: Bool)
        /// Claude scheduled it from a plain request ("remind me at 3pm…").
        case conversation
        case durableFile
        case desktopApp
    }

    public var id: String
    public var kind: Kind
    public var origin: Origin
    /// What fires, verbatim — a sentinel for the built-in prompt or `loop.md`.
    public var prompt: String
    public var cron: String?
    public var recurring: Bool
    /// The scheduler's job id (cron and durable tasks).
    public var taskID: String?
    /// Every scheduler id it has had — a self-paced loop gets a new one per wakeup.
    public var taskIDs: [String] = []
    public var sessionID: String?
    public var sessionTitle: String?
    public var transcript: URL?
    public var cwd: String?
    public var createdAt: Date
    public var createOffset: Int?
    public var fires: [LoopFire] = []
    /// A self-paced loop's decisions: each delay Claude chose and why.
    public var wakeups: [LoopLog.Wakeup] = []
    public var state: LoopState
    public var nextFire: Date?
    /// `nextFire` is an estimate (the CLI's ~20-minute fallback), not a recorded time.
    public var nextFireIsEstimate = false
    public var expiresAt: Date?
    public var endedAt: Date?
    /// One line on why it is in its state.
    public var note: String?
    public var permissionMode: String?
    /// The agent its session runs as (`claude --agent`) — that agent's tools are all a fire has.
    public var sessionAgent: String?
    public var durable: DurableTask?
    public var desktop: DesktopScheduledTask?

    public init(id: String, kind: Kind, origin: Origin, prompt: String, cron: String?, recurring: Bool,
                createdAt: Date, state: LoopState) {
        self.id = id; self.kind = kind; self.origin = origin; self.prompt = prompt; self.cron = cron
        self.recurring = recurring; self.createdAt = createdAt; self.state = state
    }

    public var promptKind: LoopPromptKind { LoopPromptKind(prompt: prompt) }

    public var title: String {
        if let desktop { return desktop.name }
        return promptKind.title
    }

    public var group: LoopGroup {
        switch kind {
        case .desktop: return .desktop
        case .durable: return state == .cancelled ? .ended : .saved
        default:
            if state.isActive { return .running }
            return state == .paused ? .paused : .ended
        }
    }

    /// "Every 5 minutes", "Claude decides", "Once, Oct 1 at 2:30 PM".
    public var cadence: String {
        if kind == .selfPaced { return "Self-paced — Claude picks each delay" }
        if kind == .desktop { return "Set in the Desktop app" }
        guard let cron else { return "—" }
        return LoopCadence.describe(cron: cron, recurring: recurring)
    }

    /// The list's short badge: "5m", "auto", "once", "daily", …
    public var badge: String {
        if kind == .selfPaced { return "auto" }
        if kind == .desktop { return "app" }
        guard let cron else { return "?" }
        return LoopCadence.badge(cron: cron, recurring: recurring)
    }

    public var lastFire: LoopFire? { fires.last }

    /// When it last changed: its last fire, its end, or its creation.
    public var lastActivity: Date { [endedAt, fires.last?.time, wakeups.last?.time, createdAt].compactMap { $0 }.max() ?? createdAt }

    /// The fires it should make in `window`, each assumed on time — the overview's timeline. Only
    /// a loop that can fire projects anything; a self-paced loop only knows its next wakeup.
    public func projectedFires(in window: DateInterval, jitter: CronJitter = .cliDefault,
                               calendar: Calendar = .cron, limit: Int = 1_500) -> [Date] {
        guard state.isActive || (kind == .durable && state != .notRunning && state != .cancelled),
              let first = nextFire else { return [] }
        var out: [Date] = []
        if window.contains(first) { out.append(first) }
        guard recurring, kind != .selfPaced, let cron, let expr = CronExpression(cron), let id = taskID else { return out }
        var cursor = first
        while out.count < limit, cursor < window.end {
            if let expiresAt, cursor >= expiresAt { break }   // that was the final fire
            guard let next = jitter.recurringFire(expr, from: cursor, taskID: id, calendar: calendar), next > cursor else { break }
            if window.contains(next) { out.append(next) }
            cursor = next
        }
        return out
    }

    /// Search: the prompt, the schedule, the session, the ids, how it was made.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        var hay = [prompt, title, cadence, cron ?? "", taskID ?? "", sessionTitle ?? "", sessionID ?? "",
                   kind.label, state.label, note ?? ""]
        hay += taskIDs
        if case .loopCommand(let args, _) = origin { hay.append("/loop \(args)") }
        if let desktop { hay += [desktop.name, desktop.description] }
        return hay.contains { $0.lowercased().contains(q) }
    }
}

// MARK: - Building

public enum LoopBuilder {
    /// A transcript the scan reads, with what the page names it by.
    public struct SessionRef: Sendable, Equatable {
        public let id: String
        public let transcript: URL
        public let title: String
        public let cwd: String?
        public let modifiedAt: Date
        public init(id: String, transcript: URL, title: String, cwd: String?, modifiedAt: Date) {
            self.id = id; self.transcript = transcript; self.title = title; self.cwd = cwd; self.modifiedAt = modifiedAt
        }
    }

    /// The CLI's fallback when a self-paced iteration ends without re-arming: one wakeup "about
    /// 20 minutes later" (docs: Stop a loop).
    public static let fallbackDelay: TimeInterval = 20 * 60
    /// How far back a `/loop` invocation can be and still have made a cron task created after it —
    /// the skill calls CronCreate first thing.
    static let invocationWindow: TimeInterval = 15 * 60
    /// …and a self-paced loop, whose first wakeup is armed only at the end of its first iteration.
    static let selfPacedInvocationWindow: TimeInterval = 6 * 3600

    /// Every loop one session's transcript records, its state judged against `now` and whether the
    /// session's process is alive (`live`).
    public static func records(from log: LoopLog, session: SessionRef, live: LiveSession?, now: Date,
                               jitter: CronJitter = .cliDefault, calendar: Calendar = .cron) -> [LoopRecord] {
        var out: [LoopRecord] = []
        var claimed = Set<Int>()
        // When the newest turn began: a prompt, a command or a notification (`lastTurnStartAt`), a
        // typed /loop, or a fire's delivery. A busy session whose newest turn is one of a loop's
        // fires is running that loop.
        let latestTurnStart = ([log.lastTurnStartAt].compactMap { $0 } + log.fires.compactMap(\.deliveredAt)
                               + log.invocations.filter { !$0.viaSkill }.map(\.time)).max()
        // The process was started after this instant: what was armed before it went through a
        // `--resume`, which restores only unexpired cron tasks and one-shots still ahead.
        let restartedAfter: (Date) -> Bool = { t in (live?.startedAt).map { $0 > t.addingTimeInterval(1) } ?? false }

        /// The `/loop` that made something created at `t`: the newest unclaimed one shortly before.
        func origin(at t: Date, within window: TimeInterval = invocationWindow) -> LoopRecord.Origin {
            if let i = log.invocations.indices.last(where: { i in
                let inv = log.invocations[i]
                return !claimed.contains(i) && inv.time <= t.addingTimeInterval(1)
                    && t.timeIntervalSince(inv.time) <= window
            }) {
                claimed.insert(i)
                return .loopCommand(args: log.invocations[i].args, viaSkill: log.invocations[i].viaSkill)
            }
            return .conversation
        }

        func base(_ id: String, kind: LoopRecord.Kind, prompt: String, cron: String?, recurring: Bool,
                  createdAt: Date, origin: LoopRecord.Origin) -> LoopRecord {
            var r = LoopRecord(id: "\(session.id)#\(id)", kind: kind, origin: origin, prompt: prompt, cron: cron,
                               recurring: recurring, createdAt: createdAt, state: .scheduled)
            r.sessionID = session.id
            r.sessionTitle = log.customTitle ?? session.title
            r.transcript = session.transcript
            r.cwd = session.cwd
            r.permissionMode = log.permissionMode
            r.sessionAgent = log.agentSetting
            return r
        }

        /// The end of the turn a fire started: the first `turn_duration` after its delivery.
        func turnEnd(after start: Date?) -> Date? {
            guard let start else { return nil }
            return log.turnEnds.first { $0 > start }
        }

        func fire(_ f: LoopLog.Fire, due: Date?, isFallback: Bool = false) -> LoopFire {
            LoopFire(time: f.time, taskID: f.taskID, dueAt: due, offset: f.offset, isFallback: isFallback, label: f.label,
                     deliveredAt: f.deliveredAt, promptOffset: f.promptOffset, endedAt: turnEnd(after: f.deliveredAt))
        }

        /// A fire written but not yet delivered waits for the session's current turn to end.
        func pendingNote(_ last: LoopFire?) -> String? {
            guard let last, last.deliveredAt == nil else { return nil }
            return "It fired at \(CronExpression.clock(hour: calendar.component(.hour, from: last.time), minute: calendar.component(.minute, from: last.time)))"
                + " — its prompt waits for the session's current turn to end"
        }

        // Cron tasks: one per CronCreate the CLI accepted.
        let cronJobIDs = Set(log.creates.compactMap { $0.result?.jobID })
        for c in log.creates {
            guard let result = c.result else { continue }   // its result isn't written yet
            if result.durable == true { continue }           // it lives in scheduled_tasks.json
            let recurring = result.recurring ?? c.recurring ?? true
            var r = base(result.jobID ?? c.toolUseID, kind: recurring ? .recurring : .oneShot, prompt: c.prompt,
                         cron: c.cron, recurring: recurring, createdAt: c.time, origin: origin(at: c.time))
            r.createOffset = c.offset
            guard !result.isError, let id = result.jobID, let expr = CronExpression(c.cron) else {
                r.state = .failed
                r.endedAt = c.time
                r.note = result.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "CronCreate failed"
                out.append(r)
                continue
            }
            r.taskID = id
            r.taskIDs = [id]
            var prev = c.time
            for f in log.fires where f.taskID == id {
                let due = recurring ? jitter.recurringFire(expr, from: prev, taskID: id, calendar: calendar)
                                    : jitter.oneShotFire(expr, from: c.time, taskID: id, calendar: calendar)
                r.fires.append(fire(f, due: due))
                prev = f.time
            }
            if recurring { r.expiresAt = jitter.expiry(createdAt: c.time) }
            let oneShotAt = recurring ? nil : jitter.oneShotFire(expr, from: c.time, taskID: id, calendar: calendar)
            let deletion = log.deletes.first { $0.jobID == id && $0.time >= c.time && $0.ok != false }
            if let d = deletion {
                r.state = .cancelled
                r.endedAt = d.time
                r.note = "Cancelled with CronDelete"
            } else if !recurring, let f = r.fires.first {
                r.state = f.deliveredAt == nil && live != nil ? .due : .completed
                r.endedAt = f.time
                r.note = r.state == .due ? pendingNote(f) : "Fired once and deleted itself"
            } else if recurring, let exp = r.expiresAt, let final = r.fires.first(where: { $0.time >= exp }) {
                r.state = .expired
                r.endedAt = final.time
                r.note = "Reached the 7-day limit: fired one last time and deleted itself"
            } else if let live, recurring, restartedAfter(c.time), let exp = r.expiresAt, let started = live.startedAt, started >= exp {
                r.state = .expired
                r.endedAt = exp
                r.note = "It had passed the 7-day limit when its session was resumed, so it wasn't restored"
            } else if live != nil, !recurring, restartedAfter(c.time), let at = oneShotAt, let started = live?.startedAt, at < started {
                r.state = .missed
                r.endedAt = at
                r.note = "Its time passed while its session was closed, so the resume didn't bring it back"
            } else if let live {
                let next = recurring ? jitter.recurringFire(expr, from: r.fires.last?.time ?? c.time, taskID: id, calendar: calendar)
                                     : oneShotAt
                r.nextFire = next
                if let note = pendingNote(r.fires.last) {
                    r.state = .due
                    r.note = note
                } else if live.isBusy, let last = r.fires.last, last.endedAt == nil, last.startedAt == latestTurnStart {
                    r.state = .running
                    if let next, next <= now { r.note = "Its next fire is already due — it waits for this iteration to end" }
                } else if let next, next <= now {
                    r.state = .due
                    r.note = live.isBusy ? "Waiting for the session's current turn to end" : "Firing as soon as the session is idle"
                } else {
                    r.state = .scheduled
                }
                if recurring, let exp = r.expiresAt, let next, next >= exp {
                    r.note = "Its next fire is the last — the 7-day limit is reached"
                }
            } else if recurring {
                if let exp = r.expiresAt, now >= exp {
                    r.state = .expired
                    r.endedAt = exp
                    r.note = "Passed the 7-day limit while its session was closed"
                } else {
                    r.state = .paused
                    r.note = "Comes back when the session is resumed"
                }
            } else if let at = oneShotAt, at > now {
                r.state = .paused
                r.nextFire = at
                r.note = "Comes back when the session is resumed — if that's before its time"
            } else {
                r.state = .missed
                r.endedAt = oneShotAt
                r.note = "Its time passed while its session was closed"
            }
            out.append(r)
        }

        // Self-paced loops: ScheduleWakeup calls with one prompt, each answered by a fire (taskKind
        // "loop" — the CLI marks nothing else so). A fire joins the chain whose wakeup it answers;
        // only a fire answering none (the CLI's fallback) is matched by prompt, and a fire record
        // carries the prompt cut to 200 characters with its whitespace squashed, so compare that way.
        struct Chain {
            var prompt: String
            var wakeups: [LoopLog.Wakeup] = []
            var fires: [LoopLog.Fire] = []
            var stop: LoopLog.Wakeup?
            var start: Date
            /// Wakeups armed and not yet answered by a fire.
            var pending = 0
            func open(at t: Date) -> Bool { stop.map { $0.time > t } ?? true }
        }
        enum Item { case wake(LoopLog.Wakeup), fire(LoopLog.Fire) }
        let items: [Item] = (log.wakeups.map { Item.wake($0) }
                             + log.fires.filter { $0.taskKind == "loop" && !cronJobIDs.contains($0.taskID) }.map { Item.fire($0) })
            .enumerated()
            .sorted { a, b in
                func t(_ i: Item) -> Date { switch i { case .wake(let w): w.time; case .fire(let f): f.time } }
                return t(a.element) != t(b.element) ? t(a.element) < t(b.element) : a.offset < b.offset
            }
            .map(\.element)
        var chains: [Chain] = []
        for item in items {
            switch item {
            case .wake(let w) where w.stop:
                if let i = chains.lastIndex(where: { $0.stop == nil }) { chains[i].stop = w }
            case .wake(let w):
                guard w.isError != true else { continue }   // a rejected call schedules nothing
                if let i = chains.lastIndex(where: { $0.stop == nil && Self.samePrompt($0.prompt, w.prompt ?? "") }) {
                    chains[i].wakeups.append(w)
                    chains[i].pending += 1
                } else {
                    chains.append(Chain(prompt: w.prompt ?? "", wakeups: [w], start: w.time, pending: 1))
                }
            case .fire(let f):
                if let i = chains.lastIndex(where: { $0.open(at: f.time) && $0.pending > 0 }) {
                    chains[i].fires.append(f)
                    chains[i].pending -= 1
                } else if let i = chains.lastIndex(where: { $0.open(at: f.time) && Self.samePrompt($0.prompt, f.prompt ?? "") }) {
                    chains[i].fires.append(f)
                } else {
                    chains.append(Chain(prompt: f.prompt ?? "", fires: [f], start: f.time))
                }
            }
        }
        for chain in chains {
            var r = base("auto-\(Int(chain.start.timeIntervalSince1970))", kind: .selfPaced, prompt: chain.prompt,
                         cron: nil, recurring: true, createdAt: chain.start,
                         origin: origin(at: chain.start, within: selfPacedInvocationWindow))
            r.wakeups = chain.wakeups + (chain.stop.map { [$0] } ?? [])
            r.createOffset = chain.wakeups.first?.offset ?? chain.fires.first?.offset
            // Each fire answers the newest wakeup armed before it; a fire with none to answer is
            // the CLI's fallback.
            var used = Set<String>()
            for f in chain.fires {
                let w = chain.wakeups.last { $0.time < f.time && !used.contains($0.toolUseID) }
                if let w { used.insert(w.toolUseID) }
                let due = w.flatMap { wake in
                    wake.scheduledFor ?? wake.delaySeconds.map { wake.time.addingTimeInterval(TimeInterval($0)) }
                }
                r.fires.append(fire(f, due: due, isFallback: w == nil))
            }
            r.taskIDs = r.fires.map(\.taskID)
            r.taskID = r.taskIDs.last
            r.expiresAt = jitter.expiry(createdAt: chain.start)
            let lastEvent = [chain.wakeups.last?.time, chain.fires.last?.time, chain.stop?.time].compactMap { $0 }.max() ?? chain.start
            if let stop = chain.stop {
                r.state = .stopped
                r.endedAt = stop.time
                r.note = "Claude ended the loop (ScheduleWakeup stop)"
            } else if let exp = r.expiresAt, now >= exp {
                r.state = .expired
                r.endedAt = exp
                r.note = "Reached the 7-day limit"
            } else if live == nil {
                r.state = .lapsed
                r.endedAt = lastEvent
                r.note = "Its session closed — self-paced loops aren't restored on resume; run /loop again"
            } else if restartedAfter(lastEvent) {
                r.state = .lapsed
                r.endedAt = lastEvent
                r.note = "Its session was restarted since — self-paced wakeups aren't restored on resume; run /loop again"
            } else if let live {
                let lastWake = chain.wakeups.last, lastFire = r.fires.last
                if let note = pendingNote(lastFire) {
                    r.state = .due
                    r.note = note
                } else if let w = lastWake, lastFire.map({ $0.time < w.time }) ?? true {
                    let next = w.scheduledFor ?? w.time.addingTimeInterval(TimeInterval(w.clampedDelaySeconds ?? w.delaySeconds ?? 0))
                    r.nextFire = next
                    r.state = next > now ? .scheduled : .due
                    if r.state == .due {
                        r.note = live.isBusy ? "Waiting for the session's current turn to end" : "Firing as soon as the session is idle"
                    }
                } else if let f = lastFire {
                    if live.isBusy, f.endedAt == nil, f.startedAt == latestTurnStart {
                        r.state = .running
                    } else if f.isFallback {
                        r.state = .lapsed
                        r.endedAt = f.endedAt ?? f.time
                        r.note = "Claude didn't re-arm the loop, even after the fallback wakeup — it ended"
                    } else {
                        // The CLI arms its fallback 20 minutes after the iteration *ends*, at the next
                        // whole minute (cron's granularity).
                        let end = f.endedAt ?? f.startedAt
                        let estimate = Date(timeIntervalSince1970: ((end.timeIntervalSince1970 + fallbackDelay) / 60).rounded(.up) * 60)
                        if now.timeIntervalSince(estimate) > 20 * 60 {
                            r.state = .lapsed
                            r.endedAt = end
                            r.note = "Claude didn't re-arm after its last iteration, and no fallback fire came"
                        } else {
                            r.nextFire = estimate
                            r.nextFireIsEstimate = f.endedAt == nil
                            r.state = estimate > now ? .scheduled : .due
                            r.note = "Claude didn't re-arm after the last iteration — the CLI's fallback wakeup fires "
                                + "20 minutes after it ended; the loop ends if that one doesn't re-arm either"
                        }
                    }
                }
            }
            out.append(r)
        }

        // A session stopped on a permission prompt or a question fires nothing until it's answered —
        // the commonest way an unattended loop silently stops, so it outranks every active state.
        if let live, live.isWaiting {
            for i in out.indices where out[i].state.isActive {
                out[i].state = .blocked
                out[i].note = "Its session is waiting for you (\(live.waitingFor ?? "a question or a permission prompt"))"
                    + " — nothing fires until it's answered"
            }
        }

        // A `/loop` whose first iteration is still running has made nothing yet — show it starting.
        if let live, live.isBusy {
            for (i, inv) in log.invocations.enumerated() where !claimed.contains(i) {
                guard inv.time == log.invocations.last?.time, inv.time >= (latestTurnStart ?? .distantPast),
                      now.timeIntervalSince(inv.time) < 3600, !restartedAfter(inv.time) else { continue }
                let parsed = LoopArguments.parse(inv.args)
                var r = base("start-\(Int(inv.time.timeIntervalSince1970))",
                             kind: parsed.interval == nil ? .selfPaced : .recurring,
                             prompt: parsed.prompt.isEmpty
                                ? (parsed.interval == nil ? LoopPromptKind.maintenanceDynamicSentinel : LoopPromptKind.maintenanceSentinel)
                                : parsed.prompt,
                             cron: parsed.interval?.cron, recurring: true, createdAt: inv.time,
                             origin: .loopCommand(args: inv.args, viaSkill: inv.viaSkill))
                r.state = .running
                r.createOffset = inv.offset
                r.note = "Setting up — Claude is running the first iteration"
                out.append(r)
            }
        }
        return out
    }

    /// Whether two prompts are the same one, allowing for the copy a fire record keeps (whitespace
    /// squashed, control characters dropped, cut at 200 characters).
    static func samePrompt(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }
                .map(String.init).joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            while t.hasSuffix("…") || t.hasSuffix("...") { t = String(t.dropLast(t.hasSuffix("…") ? 1 : 3)) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        let x = norm(a), y = norm(b)
        if x == y { return true }
        let n = min(x.count, y.count, 180)
        return n >= 40 && x.prefix(n) == y.prefix(n)
    }

    /// The tasks in `.claude/scheduled_tasks.json`, judged the way the CLI decides whether to run
    /// them: durable tasks switched on, the scheduler not disabled, a session open in the folder
    /// to hold the scheduler lock, and the task not made by a session from another checkout.
    public static func durableRecords(_ tasks: [DurableTask], file: URL, capabilities: LoopCapabilities,
                                      liveInProject: [LiveSession], lock: SchedulerLock?, lockHolderAlive: Bool,
                                      knownSessionIDs: Set<String>, now: Date, calendar: Calendar = .cron) -> [LoopRecord] {
        let jitter = capabilities.jitter
        return tasks.map { t in
            var r = LoopRecord(id: "durable#\(t.id)", kind: .durable, origin: .durableFile, prompt: t.prompt, cron: t.cron,
                               recurring: t.recurring, createdAt: t.createdAt, state: .scheduled)
            r.taskID = t.id
            r.taskIDs = [t.id]
            r.durable = t
            r.transcript = nil
            r.sessionID = t.createdBySessionID
            if t.recurring && !t.permanent { r.expiresAt = jitter.expiry(createdAt: t.createdAt) }
            if let last = t.lastFiredAt {
                r.fires = [LoopFire(time: last, taskID: t.id, dueAt: nil, offset: -1, isFallback: false, label: "Last fired")]
            }
            guard let expr = CronExpression(t.cron) else {
                r.state = .failed
                r.note = "Its cron expression is invalid, so the CLI skips it"
                return r
            }
            let next = t.recurring ? jitter.recurringFire(expr, from: t.lastFiredAt ?? t.createdAt, taskID: t.id, calendar: calendar)
                                   : jitter.oneShotFire(expr, from: t.createdAt, taskID: t.id, calendar: calendar)
            r.nextFire = next
            if capabilities.durable.isKnownOff {
                r.state = .notRunning
                r.note = "Durable tasks are switched off in this Claude Code — it never reads this file"
            } else if !capabilities.schedulerOn {
                r.state = .notRunning
                r.note = "Scheduled tasks are disabled (CLAUDE_CODE_DISABLE_CRON)"
            } else if let creator = t.createdBySessionID, !knownSessionIDs.contains(creator) {
                r.state = .notRunning
                r.note = "Made by a session from another checkout — Claude Code won't run it here"
            } else if liveInProject.isEmpty {
                if !t.recurring, let next, next <= now {
                    r.state = .missed
                    r.note = "Missed — the next session opened in this folder will ask whether to run it"
                } else {
                    r.state = .notRunning
                    r.note = "Runs only while a Claude Code session is open in this folder"
                }
            } else {
                r.state = (next ?? .distantFuture) <= now ? .due : .scheduled
                if let lock, lockHolderAlive {
                    r.note = "Run by session \(lock.sessionID.prefix(8)) (pid \(lock.pid)), which holds the scheduler lock"
                } else {
                    r.note = "The first session idle in this folder takes the scheduler lock and runs it"
                }
            }
            return r
        }
    }

    public static func desktopRecords(_ tasks: [DesktopScheduledTask]) -> [LoopRecord] {
        tasks.map { t in
            var r = LoopRecord(id: "desktop#\(t.url.deletingLastPathComponent().lastPathComponent)", kind: .desktop, origin: .desktopApp, prompt: t.prompt, cron: nil,
                               recurring: true, createdAt: t.modifiedAt ?? .distantPast, state: .external)
            r.desktop = t
            r.note = t.description.isEmpty ? nil : t.description
            return r
        }
    }

    /// The session's `/goal` as its transcript last left it.
    public static func goal(from log: LoopLog) -> GoalSummary? {
        guard let last = log.goals.last else { return nil }
        if last.isClear {
            let condition = log.goals.last { !$0.isClear }?.condition ?? ""
            return GoalSummary(condition: condition, state: .cleared, lastReason: nil, iterations: nil, since: last.time)
        }
        let start = log.goals.last { $0.isStart && $0.condition == last.condition }?.time ?? last.time
        let iterations = log.goals.filter { $0.condition == last.condition && !$0.isStart && $0.time >= start }.count
        return GoalSummary(condition: last.condition, state: last.met == true ? .achieved : .active,
                           lastReason: log.goals.last { $0.reason != nil && $0.condition == last.condition }?.reason,
                           iterations: last.iterations ?? iterations, since: start)
    }
}

// MARK: - Listing

public enum LoopListing {
    public struct Section: Identifiable, Equatable, Sendable {
        public let group: LoopGroup
        public let items: [LoopRecord]
        public var id: Int { group.rawValue }
    }

    /// The list: groups in order, empty ones dropped. Running loops by their next fire (due ones
    /// first), the rest newest first.
    public static func sections(_ records: [LoopRecord], query: String = "") -> [Section] {
        let shown = records.filter { $0.matches(query) }
        return LoopGroup.allCases.compactMap { group in
            let items = shown.filter { $0.group == group }.sorted { a, b in
                if group == .running || group == .saved {
                    let x = a.nextFire ?? .distantFuture, y = b.nextFire ?? .distantFuture
                    if x != y { return x < y }
                }
                if group == .desktop { return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
                if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
                return a.id < b.id
            }
            return items.isEmpty ? nil : Section(group: group, items: items)
        }
    }

    /// The loop a transcript's fire belongs to, by session and scheduler task id.
    public static func record(sessionID: String, taskID: String, in records: [LoopRecord]) -> LoopRecord? {
        records.first { $0.sessionID == sessionID && ($0.taskID == taskID || $0.taskIDs.contains(taskID)) }
    }
}
