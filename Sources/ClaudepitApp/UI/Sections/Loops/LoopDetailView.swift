import SwiftUI
import AppKit
import ClaudepitCore

/// One loop, read top to bottom: where it stands and what to do about it, when it fires (with a
/// live countdown and its jitter window), exactly what fires, every iteration and what each one
/// did, how it was made, and the session it lives in. Plain data and closures.
struct LoopDetailView: View {
    let record: LoopRecord
    let context: LoopPageContext
    var actions = LoopActions()
    /// Select another loop (the session's other loops link here).
    var select: (String) -> Void = { _ in }

    /// What each fire's turn did, read on demand from the transcript (`LoopIterationReader`); a
    /// fire whose transcript can't be read maps to nil.
    @State private var outcomes: [String: LoopIteration?] = [:]
    @State private var expandedFire: String?
    @State private var showAllFires = false

    private static let firstFires = 12

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    header(now: tick.date)
                }
                Divider().opacity(0.15)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        callout
                        TimelineView(.periodic(from: .now, by: 1)) { tick in scheduleSection(now: tick.date) }
                        promptSection
                        iterationsSection
                        originSection
                        if record.sessionID != nil && record.kind != .durable { sessionSection }
                    }
                    .frame(maxWidth: 900, alignment: .topLeading)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .task(id: record.fires.map(\.id).joined(separator: ",")) { await loadOutcomes() }
    }

    // MARK: Header

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    titleLabel.frame(minWidth: 120, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
                    headerActions(compact: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleLabel
                    headerActions(compact: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleLabel
                    headerActions(compact: true).fixedSize()
                }
            }
            FlowLayout(spacing: 10) {
                HeaderFact(icon: record.state.icon, text: record.state.label, help: record.state.explanation,
                           color: record.state.color)
                HeaderFact(icon: record.kind.icon, text: record.kind.label, help: record.cadence)
                if let next = record.nextFire, record.state.isActive || record.kind == .durable || record.state == .paused {
                    HeaderFact(icon: "timer", text: next <= now ? "due \(LoopTime.ago(next, now: now))"
                                                                : (record.nextFireIsEstimate ? "~" : "") + LoopTime.until(next, now: now),
                               help: "Next fire: \(LoopTime.clock(next, now: now))", color: next <= now ? .orange : .primary)
                }
                let fires = record.fires.filter { $0.offset >= 0 }.count
                if fires > 0 {
                    HeaderFact(icon: "flame", text: "\(fires) fire\(fires == 1 ? "" : "s")",
                               help: "Times it fired; the last \(LoopTime.ago(record.fires.last!.time, now: now))")
                }
                if let expires = record.expiresAt, record.state.isActive || record.state == .paused {
                    HeaderFact(icon: "calendar.badge.clock", text: "expires \(LoopTime.until(expires, now: now))",
                               help: "Recurring loops last 7 days: \(LoopTime.clock(expires, now: now)). It fires once more after that, then deletes itself.",
                               color: expires.timeIntervalSince(now) < 86_400 ? .orange : .secondary)
                }
                if let id = record.taskID {
                    HeaderFact(icon: "number", text: id, help: "The scheduler's task id — CronDelete takes it")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var titleLabel: some View {
        HStack(spacing: 8) {
            Circle().fill(record.state.color).frame(width: 9, height: 9)
                .help(record.state.explanation)
            Text(record.title).font(.headline).lineLimit(1).truncationMode(.tail).help(record.prompt)
        }
    }

    private func headerActions(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if record.transcript != nil {
                HeaderButton(title: "Session", icon: Icon.jump, help: "Show the session this loop lives in", compact: compact) {
                    actions.openSession(record)
                }
                .debugFrame("loop-open-session")
            }
            if context.herdrTarget(record) != nil {
                HeaderButton(title: "Focus", icon: "terminal", help: "Focus the herdr pane its session is open in", compact: compact) {
                    actions.focus(record)
                }
            } else if let bg = context.background(record), let attach = actions.attach {
                HeaderButton(title: "Attach", icon: "terminal",
                             help: "Open this background session in a herdr tab (claude attach \(bg.jobID ?? ""))", compact: compact) {
                    attach(record)
                }
                .debugFrame("loop-attach")
            } else if record.state == .paused, let resume = actions.resume {
                HeaderButton(title: "Resume", icon: "play.circle",
                             help: "claude --resume this session in herdr — its cron loops come back with it", compact: compact) {
                    resume(record)
                }
                .debugFrame("loop-resume")
            }
            if context.canStop(record) {
                HeaderButton(title: record.kind == .durable ? "Remove" : "Stop", icon: "stop.circle",
                             help: stopHelp, compact: compact) {
                    actions.stop(record)
                }
                .debugFrame("loop-stop")
            } else if context.background(record) != nil, let stopSession = actions.stopSession {
                HeaderButton(title: "Stop Session", icon: "stop.circle",
                             help: "claude stop — ends the background session and every loop in it; resuming it brings cron loops back",
                             compact: compact) {
                    stopSession(record)
                }
                .debugFrame("loop-stop-session")
            }
            HeaderButton(title: record.state.isActive ? "Duplicate" : "Run Again", icon: "plus.square.on.square",
                         help: "Open New Loop filled in from this one", compact: compact) {
                actions.newLoop(LoopDraft(record: record))
            }
            .debugFrame("loop-run-again")
            HeaderMenu { LoopMenuItems(record: record, context: context, actions: actions, includePrimary: false) }
        }
    }

    private var stopHelp: String {
        switch record.kind {
        case .durable: return "Remove it from .claude/scheduled_tasks.json"
        case .selfPaced: return "Press Esc in its session (or ask it to stop, if a turn is running)"
        default: return "Ask its session to cancel it with CronDelete"
        }
    }

    // MARK: Where it stands

    @ViewBuilder private var callout: some View {
        let r = record
        switch r.state {
        case .running:
            LoopCallout(icon: "play.circle.fill", color: .blue, title: "An iteration is running",
                        text: r.note ?? "Its session is busy with this loop's turn. The next fire waits until the turn ends.") {
                if context.herdrTarget(r) != nil { Button("Watch it in herdr") { actions.focus(r) }.buttonStyle(.link).font(.caption) }
            }
        case .blocked:
            LoopCallout(icon: "hand.raised.fill", color: .red, title: "Its session needs you",
                        text: (r.note ?? "") + ". Loops fire only from an idle session, so this one — and every loop in the "
                            + "session — waits until you answer. Pick Auto or Accept edits when you start a loop to avoid permission stops.") {
                if context.herdrTarget(r) != nil {
                    Button("Answer it in herdr") { actions.focus(r) }.buttonStyle(.link).font(.caption)
                } else if r.transcript != nil {
                    Button("Show the session") { actions.openSession(r) }.buttonStyle(.link).font(.caption)
                }
            }
        case .due:
            LoopCallout(icon: "hourglass", color: .orange, title: "Due — waiting for the session",
                        text: (r.note ?? "") + ". Loops fire only between turns; a time that passes during a turn fires once, when it ends.")
        case .paused:
            LoopCallout(icon: "pause.circle", color: .yellow, title: "Paused — its session is closed",
                        text: "Session loops live in their Claude Code process. Resuming the session (claude --resume) "
                            + "restores this loop\(r.expiresAt.map { " until it expires \(LoopTime.clock($0))" } ?? "")." ) {
                if let resume = actions.resume { Button("Resume the session in herdr") { resume(r) }.buttonStyle(.link).font(.caption) }
            }
        case .missed:
            LoopCallout(icon: "exclamationmark.circle", color: .orange, title: "Missed", text: r.note) {
                Button("Schedule it again…") { actions.newLoop(LoopDraft(record: r)) }.buttonStyle(.link).font(.caption)
            }
        case .failed:
            LoopCallout(icon: "exclamationmark.triangle", color: .red, title: "Claude Code didn't schedule it", text: r.note)
        case .notRunning:
            LoopCallout(icon: "pause.rectangle", color: .orange, title: "Not running", text: r.note)
        case .lapsed, .stopped, .expired, .cancelled, .completed:
            LoopCallout(icon: r.state.icon, color: .secondary, title: r.state.label,
                        text: [r.note, r.endedAt.map { "Ended \(LoopTime.clock($0))." }].compactMap { $0 }.joined(separator: " — ")) {
                Button("Run it again in a new session…") { actions.newLoop(LoopDraft(record: r)) }
                    .buttonStyle(.link).font(.caption)
            }
        case .external:
            LoopCallout(icon: "desktopcomputer", color: .purple, title: "A Claude Desktop scheduled task",
                        text: "Its schedule, folder, model, permission mode and on/off switch live in the Desktop app (Routines); "
                            + "only its prompt is in this file — edits apply at its next run. It runs in a fresh session while the "
                            + "app is open and the Mac awake, a few minutes after its time. After sleep it catches up once, for "
                            + "the latest missed time in the last 7 days. In Manual mode a run waits on each new permission "
                            + "until you answer it in the app.") {
                if let d = r.desktop { Button("Open SKILL.md") { actions.open(d.url) }.buttonStyle(.link).font(.caption) }
            }
        case .scheduled:
            EmptyView()
        }
    }

    // MARK: Schedule

    @ViewBuilder private func scheduleSection(now: Date) -> some View {
        let r = record
        DetailSection(title: "Schedule", icon: "calendar") {
            Spacer(minLength: 0)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if r.kind != .desktop {
                    LoopTimeline(lanes: [lane(now: now)], window: timelineWindow(now: now), now: now)
                        .padding(.bottom, 2)
                }
                LoopFactRow(label: "Cadence", detail: cadenceDetail) {
                    HStack(spacing: 6) {
                        Text(r.cadence).font(.callout)
                        if let cron = r.cron {
                            Text(cron).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                                .help("The cron expression the scheduler holds (local time)")
                        }
                    }
                }
                if let next = r.nextFire, r.state.isActive || r.kind == .durable || r.state == .paused {
                    LoopFactRow(label: "Next fire", detail: nextDetail(next)) {
                        Text("\(LoopTime.clock(next, now: now)) — \(next <= now ? "due \(LoopTime.ago(next, now: now))" : LoopTime.until(next, now: now))")
                            .font(.callout.monospacedDigit())
                    }
                }
                if let expires = r.expiresAt, r.kind != .oneShot {
                    LoopFactRow(label: "Lasts until",
                                detail: "Recurring loops expire 7 days after they're made: at the first fire after this "
                                    + "they run one last time, then delete themselves. Make a new one to keep going.") {
                        Text("\(LoopTime.clock(expires, now: now)) (\(expires > now ? LoopTime.until(expires, now: now) : "passed"))")
                            .font(.callout.monospacedDigit())
                    }
                }
                if r.kind != .durable && r.kind != .desktop {
                    LoopFactRow(label: "Runs while") {
                        Text("its session is open and idle — a time that passes mid-turn fires once, when the turn "
                             + "ends; missed times don't catch up")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var cadenceDetail: String? {
        guard let cron = record.cron, let expr = CronExpression(cron) else {
            return record.kind == .selfPaced
                ? "After each iteration Claude picks the next delay, 1 minute to 1 hour, and says why (below)."
                : nil
        }
        let jitter = context.snapshot.capabilities.jitter
        if let period = expr.period(after: Date()), jitter.keepsCacheWarm(expr, period: period) {
            return "Every 5 minutes fires \(LoopCadence.duration(period - jitter.cacheLead)) after the previous fire, "
                + "to stay inside the 5-minute prompt cache."
        }
        return nil
    }

    private func nextDetail(_ next: Date) -> String? {
        let r = record
        if r.nextFireIsEstimate {
            return "An estimate: Claude didn't re-arm after its last iteration, so the CLI's fallback wakeup fires about "
                + "20 minutes after it. If that iteration doesn't re-arm either, the loop ends."
        }
        if r.kind == .selfPaced, let w = r.wakeups.last(where: { !$0.stop }) {
            let chose = (w.clampedDelaySeconds ?? w.delaySeconds).map { "Claude chose \(LoopCadence.duration(TimeInterval($0)))" } ?? "Claude chose it"
            return [chose + (w.reason.map { ": “\($0)”" } ?? ""), w.wasClamped == true ? "(clamped to 1 min – 1 h)" : nil]
                .compactMap { $0 }.joined(separator: " ")
        }
        if r.recurring, let cron = r.cron, let expr = CronExpression(cron),
           let period = expr.period(after: r.fires.last?.time ?? r.createdAt),
           context.snapshot.capabilities.jitter.keepsCacheWarm(expr, period: period) {
            let from = r.fires.last?.time ?? r.createdAt
            return "\(LoopCadence.duration(period - context.snapshot.capabilities.jitter.cacheLead)) after its "
                + "\(r.fires.isEmpty ? "creation" : "last fire") at \(LoopTime.clock(from)) — an every-5-minutes loop keeps "
                + "the 5-minute prompt cache warm instead of following the clock."
        }
        guard r.recurring, let cron = r.cron, let expr = CronExpression(cron) else {
            if !r.recurring, let cron = r.cron, let m = CronExpression(cron)?.fixedMinute, m % 30 == 0 {
                return "A one-time task on the hour or half hour fires up to 90 s early, by a fixed offset."
            }
            return nil
        }
        let from = r.fires.last?.time ?? r.createdAt
        guard let planned = expr.next(after: from) else { return nil }
        let offset = next.timeIntervalSince(planned)
        if offset > 1, offset <= context.snapshot.capabilities.jitter.recurringCap + 1 {
            return "Its time is \(LoopTime.clock(planned)); this task always starts \(LoopCadence.duration(offset)) after it "
                + "(the scheduler's fixed offset from its id, so loops don't all fire at once)."
        }
        return nil
    }

    private func timelineWindow(now: Date) -> DateInterval {
        let r = record
        if r.state.isActive || r.state == .paused || r.kind == .durable {
            let period = r.cron.flatMap { CronExpression($0) }.flatMap { $0.period(after: now) } ?? 1200
            let back = min(max(3 * period, 1800), 12 * 3600)
            var ahead = min(max(5 * period, 3600), 24 * 3600)
            if let next = r.nextFire, next.timeIntervalSince(now) + 600 > ahead {
                ahead = min(next.timeIntervalSince(now) + 600, 7 * 86_400)
            }
            return DateInterval(start: now.addingTimeInterval(-back), end: now.addingTimeInterval(ahead))
        }
        let start = r.fires.first?.time ?? r.createdAt
        let end = max(r.endedAt ?? r.lastActivity, start.addingTimeInterval(1800))
        let pad = end.timeIntervalSince(start) * 0.08
        return DateInterval(start: start.addingTimeInterval(-pad), end: end.addingTimeInterval(pad))
    }

    private func lane(now: Date) -> LoopTimelineLane {
        let r = record
        let window = timelineWindow(now: now)
        let jitter = context.snapshot.capabilities.jitter
        var lane = LoopTimelineLane(id: r.id, title: r.title, color: r.state.isActive ? r.state.color : .secondary)
        lane.past = r.fires.map(\.time)
        lane.future = r.projectedFires(in: window, jitter: jitter)
        lane.estimate = r.nextFireIsEstimate
        if r.recurring, r.state.isActive, let cron = r.cron, let expr = CronExpression(cron),
           let delay = jitter.maxRecurringDelay(expr, from: now), delay > 0,
           let planned = expr.next(after: r.fires.last?.time ?? r.createdAt) {
            lane.windows = [DateInterval(start: planned, duration: delay)]
        }
        return lane
    }

    // MARK: Prompt

    private var promptSection: some View {
        DetailSection(title: "What fires", icon: "text.bubble") {
            Spacer(minLength: 0)
            Button("Copy") { actions.copy(record.prompt) }.buttonStyle(.link).font(.caption)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                switch record.promptKind {
                case .maintenance:
                    promptText(record.prompt, caption: "The built-in maintenance prompt — the CLI expands this marker at each fire.")
                    VStack(alignment: .leading, spacing: 3) {
                        bullet("continue any unfinished work from the conversation")
                        bullet("tend the current branch's PR: review comments, failed CI runs, merge conflicts")
                        bullet("run cleanup passes (bug hunts, simplification) when nothing else is pending")
                        Text("It starts nothing new, and pushes or deletes only to continue what the conversation already authorized. A loop.md replaces it.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    loopFileLine
                case .loopFile:
                    promptText(record.prompt, caption: "The tasks in loop.md — re-read at every fire, so edits apply from the next iteration.")
                    loopFileLine
                case .command(let name, _):
                    promptText(record.prompt, caption: nil)
                    commandLine(name)
                case .agent(let name, _, let mentioned):
                    promptText(record.prompt, caption: nil)
                    agentLine(name, mentioned: mentioned)
                case .custom:
                    promptText(record.prompt, caption: nil)
                }
                if let agent = record.sessionAgent {
                    sessionAgentLine(agent)
                }
            }
        }
    }

    @ViewBuilder private func agentLine(_ name: String, mentioned: Bool) -> some View {
        if mentioned {
            Text("“@agent-\(name)” is a mention, and a fire leaves it as plain text — Claude may answer it some other way than starting \(name). Duplicate this loop to hand each fire to \(name) by name instead.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.2").font(.caption2).foregroundStyle(TranscriptStyle.agent)
                Text("Each fire starts a fresh \(name)" + (context.agent(name).map { " — \(agentFacts($0))" } ?? "")
                     + ". It runs in the background, and its report arrives as a turn of its own: the iterations below show it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sessionAgentLine(_ agent: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "person.crop.square").font(.caption2).foregroundStyle(.secondary)
            Text("Its session runs as \(agent) (claude --agent): \(agent)'s instructions and tools are all a fire has"
                 + (context.agent(agent).map { " — \(agentFacts($0))" } ?? "") + ".")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func agentFacts(_ a: LoopAgent) -> String {
        if a.isBuiltIn { return "built into Claude Code" }
        return [a.model, "tools: \(a.toolSummary)"].compactMap { $0 }.joined(separator: ", ")
    }

    private func promptText(_ text: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.callout.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.tertiary)
            Text(s).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var loopFileLine: some View {
        let snap = context.snapshot
        if let file = snap.activeLoopFile {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
                Text("\(file.scope == .project ? "This project's" : "Your") loop.md · "
                     + ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                if file.isTruncated {
                    Text("over 25,000 bytes — cut there").font(.caption).foregroundStyle(.orange)
                }
                Button("Manage") { actions.manageLoopFile() }.buttonStyle(.link).font(.caption)
                    .help("Show, edit or ask about it on the overview")
                    .debugFrame("loop-manage-loopfile")
            }
        } else {
            HStack(spacing: 8) {
                Text("No loop.md here — the built-in prompt runs.").font(.caption).foregroundStyle(.secondary)
                if context.hasProject {
                    Button("Write one…") { actions.manageLoopFile() }.buttonStyle(.link).font(.caption)
                        .help("Write a loop.md on the overview")
                        .debugFrame("loop-manage-loopfile")
                }
            }
        }
    }

    @ViewBuilder private func commandLine(_ name: String) -> some View {
        if CommandAvailability.builtIns.contains(name) || name.hasPrefix("/mcp__") {
            Text("\(name) is \(name.hasPrefix("/mcp__") ? "an MCP prompt" : "a built-in command") — each fire hands it to Claude as plain text instead of running it.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if let info = context.commandInfo[name] {
            if info.modelInvocable {
                Text("Each fire runs \(name)\(info.description.isEmpty ? "" : " — \(info.description)")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("\(name) can't be run by Claude on its own (\(info.reason ?? "not model-invocable")) — each fire arrives as plain text.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Iterations

    @ViewBuilder private var iterationsSection: some View {
        let fires = record.fires.filter { $0.offset >= 0 }
        let wakeups = record.wakeups
        if !fires.isEmpty || !wakeups.isEmpty || record.kind == .durable {
            DetailSection(title: "Iterations", icon: "list.bullet.rectangle", count: fires.isEmpty ? nil : fires.count) {
                Spacer(minLength: 0)
                if fires.count > Self.firstFires {
                    Button(showAllFires ? "Show recent" : "Show all \(fires.count)") { showAllFires.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    if record.kind == .durable {
                        Text(record.durable?.lastFiredAt.map { "Last fired \(LoopTime.clock($0)) — durable tasks record only their last fire." }
                             ?? "Hasn't fired yet. Durable tasks record only their last fire.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if fires.isEmpty {
                        Text(record.kind == .selfPaced ? "No fire yet — /loop ran the first iteration when it started; the rest come at the times Claude picks."
                                                       : "No fire yet — /loop ran the task once when it was made; scheduled fires follow.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(timeline(fires: fires, wakeups: wakeups)) { item in
                        switch item {
                        case .fire(let f): fireRow(f)
                        case .wakeup(let w): wakeupRow(w)
                        }
                    }
                }
            }
        }
    }

    private enum IterationItem: Identifiable {
        case fire(LoopFire), wakeup(LoopLog.Wakeup)
        var id: String { switch self { case .fire(let f): f.id; case .wakeup(let w): w.toolUseID } }
        var time: Date { switch self { case .fire(let f): f.time; case .wakeup(let w): w.time } }
    }

    /// Fires and Claude's decisions between them, newest first.
    private func timeline(fires: [LoopFire], wakeups: [LoopLog.Wakeup]) -> [IterationItem] {
        let shown = showAllFires ? fires : Array(fires.suffix(Self.firstFires))
        let since = shown.first?.time ?? .distantPast
        let items = shown.map(IterationItem.fire) + wakeups.filter { $0.time >= since.addingTimeInterval(-1) || shown.isEmpty }.map(IterationItem.wakeup)
        return items.sorted { $0.time > $1.time }
    }

    private func fireRow(_ f: LoopFire) -> some View {
        let loaded = outcomes[f.id] != nil
        let outcome = outcomes[f.id] ?? nil
        let open = expandedFire == f.id
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                expandedFire = open ? nil : f.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: f.isFallback ? "alarm.waves.left.and.right" : "flame.fill")
                        .font(.system(size: 10)).foregroundStyle(f.isFallback ? Color.orange : record.state.color.opacity(0.9))
                        .frame(width: 14)
                    Text(LoopTime.clock(f.time)).font(.caption.monospacedDigit().weight(.semibold))
                    Text(fireNote(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    if f.promptOffset == nil {
                        Text("queued — its turn hasn't started").font(.caption2).foregroundStyle(.tertiary)
                    } else if let o = outcome {
                        Text(outcomeSummary(o)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                    } else if loaded {
                        Text("transcript unavailable").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: open ? Icon.chevronExpanded : Icon.chevronCollapsed)
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(f.isFallback ? "The CLI's fallback wakeup: Claude ended the previous iteration without re-arming the loop"
                               : "Fired \(LoopTime.clock(f.time))" + (f.dueAt.map { ", due \(LoopTime.clock($0))" } ?? ""))
            if let text = outcome?.lastText {
                Text(text).font(.caption).foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(open ? nil : 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
            if let o = outcome, !o.delegations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(o.delegations, id: \.toolUseID) { d in delegationRow(d, open: open) }
                }
                .padding(.leading, 26)
            }
            if open, let o = outcome {
                VStack(alignment: .leading, spacing: 3) {
                    if !o.tools.isEmpty {
                        Text("Tools: " + o.tools.prefix(6).map { "\($0.name) \($0.count)" }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !o.models.isEmpty {
                        Text("Model: " + o.models.map(ModelNames.display).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !o.complete { Text("Still running, or longer than the part read here.").font(.caption2).foregroundStyle(.tertiary) }
                    if record.transcript != nil {
                        Button("Open the session at this point") { actions.openSession(record) }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
                .padding(.leading, 26)
            }
        }
    }

    /// A subagent the fire's turn started, and its report once it came back.
    private func delegationRow(_ d: LoopIteration.Delegation, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.2").font(.system(size: 9)).foregroundStyle(TranscriptStyle.agent)
                Text(d.agent).font(.caption.weight(.semibold))
                Text(delegationStatus(d)).font(.caption2)
                    .foregroundStyle(d.status == nil || d.status == "completed" ? Color.secondary : .orange)
            }
            .help(d.description ?? d.agent)
            if let result = d.result {
                Text(result).font(.caption).foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(open ? 14 : 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15)
            }
        }
    }

    private func delegationStatus(_ d: LoopIteration.Delegation) -> String {
        guard let status = d.status else {
            return d.background ? "running in the background — no report yet" : "started"
        }
        var parts = [status == "completed" ? (d.background ? "reported back" : "returned") : status]
        if let at = d.reportedAt { parts.append("at \(LoopTime.clock(at))") }
        if let ms = d.durationMs { parts.append("after \(LoopCadence.duration(TimeInterval(ms) / 1000))") }
        return parts.joined(separator: " ")
    }

    private func fireNote(_ f: LoopFire) -> String {
        if f.isFallback { return "fallback wakeup — Claude hadn't re-armed" }
        if f.deliveredAt == nil { return "fired — waiting for the session's current turn to end" }
        guard let due = f.dueAt, let delay = f.delay else { return "fired" }
        if delay > 60 { return "due \(LoopTime.clock(due)) — waited \(LoopCadence.duration(delay)) for the session to finish a turn" }
        if delay < -1 { return "\(LoopCadence.duration(-delay)) early (one-time jitter)" }
        return "on time"
    }

    private func outcomeSummary(_ o: LoopIteration) -> String {
        var parts: [String] = []
        if let ms = o.durationMs { parts.append(LoopCadence.duration(TimeInterval(ms) / 1000)) }
        if o.toolCalls > 0 { parts.append("\(o.toolCalls) tool\(o.toolCalls == 1 ? "" : "s")") }
        if o.errors > 0 { parts.append("\(o.errors) error\(o.errors == 1 ? "" : "s")") }
        if o.outputTokens > 0 { parts.append("\(CompactCount.tokens(o.outputTokens)) out") }
        return parts.isEmpty ? (o.complete ? "no tools" : "running…") : parts.joined(separator: " · ")
    }

    private func wakeupRow(_ w: LoopLog.Wakeup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: w.stop ? "stop.circle" : "arrow.uturn.right.circle")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(LoopTime.clock(w.time)).font(.caption.monospacedDigit())
            if w.stop {
                Text("Claude stopped the loop").font(.caption).foregroundStyle(.secondary)
            } else {
                let delay = (w.clampedDelaySeconds ?? w.delaySeconds).map { LoopCadence.duration(TimeInterval($0)) } ?? "?"
                Text("Claude re-armed: next in \(delay)").font(.caption).foregroundStyle(.secondary)
                if let reason = w.reason {
                    Text("— \(reason)").font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
                }
                if w.isError == true { Text("(rejected)").font(.caption).foregroundStyle(.red) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .help(w.stop ? "ScheduleWakeup(stop: true)" : "ScheduleWakeup(delaySeconds: \(w.delaySeconds ?? 0))"
              + (w.scheduledFor.map { " → \(LoopTime.clock($0))" } ?? ""))
    }

    /// Read what each shown fire's turn did — from its prompt record, where its turn begins — and
    /// keep re-reading one that was still running, every 10 s while the card is up.
    private func loadOutcomes() async {
        guard let file = record.transcript else { return }
        while !Task.isCancelled {
            let wanted = record.fires.filter { $0.promptOffset != nil }.suffix(showAllFires ? 200 : Self.firstFires)
                .filter { f in
                    guard let known = outcomes[f.id] else { return true }   // never read
                    // Still running when read — or its agent hadn't reported back, while the loop lives.
                    return known?.complete == false || (known?.awaitingReports == true && record.state.isActive)
                }
            if wanted.isEmpty { return }
            for f in wanted.reversed() {
                guard let offset = f.promptOffset else { continue }
                let it = await Task.detached(priority: .utility) { LoopIterationReader.read(file: file, from: offset) }.value
                outcomes[f.id] = it
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    // MARK: Origin

    private var originSection: some View {
        DetailSection(title: "How it was made", icon: "wand.and.stars") {
            Spacer(minLength: 0)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                switch record.origin {
                case .loopCommand(let args, let viaSkill):
                    let parsed = LoopArguments.parse(args)
                    LoopFactRow(label: viaSkill ? "Claude ran" : "You typed",
                                detail: interpretation(parsed)) {
                        HStack(spacing: 6) {
                            Text(args.isEmpty ? "/loop" : "/loop \(args)").font(.callout.monospaced()).textSelection(.enabled)
                            Button { actions.copy(args.isEmpty ? "/loop" : "/loop \(args)") } label: {
                                Image(systemName: Icon.copyPath).font(.system(size: 10))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy the command")
                        }
                    }
                case .conversation:
                    LoopFactRow(label: "Asked for", detail: "Claude scheduled it with CronCreate from a request in the "
                                + "conversation (\"remind me…\", \"every morning…\") rather than /loop.") {
                        Text("In the conversation").font(.callout)
                    }
                case .durableFile:
                    LoopFactRow(label: "Saved in", detail: durableDetail) {
                        Text(".claude/scheduled_tasks.json").font(.callout.monospaced())
                    }
                case .desktopApp:
                    LoopFactRow(label: "Saved in", detail: "The Desktop app runs it in a new session at its time, while the app is open and the Mac awake; after a sleep it runs once to catch up.") {
                        Text(record.desktop.map { "~/.claude/scheduled-tasks/\($0.url.deletingLastPathComponent().lastPathComponent)/SKILL.md" } ?? "")
                            .font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                if record.kind != .desktop {
                    LoopFactRow(label: "Scheduler") {
                        Text(schedulerCall).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LoopFactRow(label: "Made") { Text(LoopTime.clock(record.createdAt)).font(.callout.monospacedDigit()) }
                }
            }
        }
    }

    private func interpretation(_ a: LoopArguments) -> String {
        let what = a.prompt.isEmpty ? "the default prompt (loop.md, else the built-in maintenance prompt)" : "“\(a.prompt)”"
        guard let i = a.interval else { return "No interval, so Claude paces it: \(what)." }
        let cron = i.cron.map { "\($0) — \(CronExpression.humanize($0))" } ?? "rounded to a clean interval"
        return "Interval \(i.token)\(a.rule == 2 ? " (from the trailing “every …”)" : "") → \(cron); runs \(what), once right away and then on schedule."
    }

    private var schedulerCall: String {
        let r = record
        switch r.kind {
        case .selfPaced:
            return "ScheduleWakeup × \(r.wakeups.filter { !$0.stop }.count) — a one-time wakeup per iteration (task ids \(r.taskIDs.prefix(4).joined(separator: ", "))\(r.taskIDs.count > 4 ? "…" : ""))"
        case .durable:
            return "{ id: \(r.taskID ?? "?"), cron: \"\(r.cron ?? "")\", recurring: \(r.recurring)\(r.durable?.permanent == true ? ", permanent: true" : "") }"
        default:
            return "CronCreate(cron: \"\(r.cron ?? "")\", recurring: \(r.recurring)) → job \(r.taskID ?? "?")"
        }
    }

    private var durableDetail: String {
        guard let t = record.durable else { return "" }
        var parts = ["Runs while a Claude Code session is open in this folder; the one holding .claude/scheduled_tasks.lock fires it."]
        if let sid = t.createdBySessionID { parts.append("Made by session \(sid.prefix(8)).") }
        if t.permanent { parts.append("Permanent: no 7-day expiry.") }
        return parts.joined(separator: " ")
    }

    // MARK: Session

    private var sessionSection: some View {
        let r = record
        let live = context.live(r)
        let goal = r.sessionID.flatMap { context.snapshot.goals[$0] }
        let siblings = context.records.filter { $0.sessionID == r.sessionID && $0.id != r.id }
        return DetailSection(title: "Session", icon: "bubble.left.and.text.bubble.right") {
            Text(r.sessionTitle ?? "").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            if r.transcript != nil {
                Button("Show") { actions.openSession(r) }.buttonStyle(.link).font(.caption)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                LoopFactRow(label: "Process", detail: live == nil ? "Its loops can't fire until the session is resumed." : nil) {
                    if let live {
                        HStack(spacing: 6) {
                            Circle().fill(live.isWaiting ? Color.red : live.isBusy ? .orange : .green).frame(width: 7, height: 7)
                            Text("Open · \(live.isWaiting ? "waiting for you: \(live.waitingFor ?? "an answer")" : live.isBusy ? "busy with a turn" : "idle at the prompt") · pid \(String(live.pid))"
                                 + (live.version.map { " · Claude Code \($0)" } ?? ""))
                                .font(.callout)
                        }
                    } else {
                        Text("Closed").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let sid = r.sessionID {
                    LoopFactRow(label: context.background(r) != nil ? "Where" : "In herdr") {
                        if context.herdrTarget(r) != nil {
                            Button("Focus its pane") { actions.focus(r) }.buttonStyle(.link).font(.callout)
                        } else if let bg = context.background(r) {
                            HStack(spacing: 6) {
                                Text("A background session — no terminal; it keeps running after Terminal or Claudepit closes.")
                                    .font(.callout).foregroundStyle(.secondary)
                                if let id = bg.jobID {
                                    Button { actions.copy(BackgroundSession.attachCommand(id)) } label: {
                                        Text(BackgroundSession.attachCommand(id)).font(.caption.monospaced())
                                    }
                                    .buttonStyle(.link).help("Copy")
                                }
                            }
                        } else if live != nil {
                            Text("Not in herdr — it runs in another terminal").font(.callout).foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 6) {
                                Text("claude --resume \(sid)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Button { actions.copy("claude --resume \(sid)") } label: { Image(systemName: Icon.copyPath).font(.system(size: 10)) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
                            }
                        }
                    }
                }
                if let mode = r.permissionMode {
                    LoopFactRow(label: "Permissions", detail: permissionDetail(mode)) {
                        Text(mode).font(.callout.monospaced())
                    }
                }
                if let goal {
                    LoopFactRow(label: "/goal", detail: goal.lastReason.map { "Last check: \($0)" }) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(goal.state.rawValue.capitalized).font(.caption.weight(.semibold))
                                .foregroundStyle(goal.state == .active ? Color.blue : goal.state == .achieved ? .green : .secondary)
                            Text(goal.condition).font(.callout).lineLimit(2)
                        }
                    }
                }
                if !siblings.isEmpty {
                    LoopFactRow(label: "Other loops") {
                        FlowLayout(spacing: 8) {
                            ForEach(siblings) { s in
                                Button { select(s.id) } label: {
                                    HStack(spacing: 4) {
                                        Circle().fill(s.state.isActive ? s.state.color : .secondary).frame(width: 6, height: 6)
                                        Text("\(s.badge) · \(s.title)").font(.caption).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
        }
    }

    private func permissionDetail(_ mode: String) -> String {
        switch mode {
        case "auto": return "Most fires run unattended — but a command Claude Code's safety checks flag still stops for you."
        case "bypassPermissions": return "Fires never stop for permission: every tool runs."
        case "dontAsk": return "Fires never stop for permission: a call that would ask fails instead."
        case "acceptEdits": return "File edits run unattended; a fire that needs another permission waits for you."
        case "plan": return "Plan mode: fires research and propose, but change nothing."
        default: return "A fire that needs a permission stops there until you answer it."
        }
    }
}
