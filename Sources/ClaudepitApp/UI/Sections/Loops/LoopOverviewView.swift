import SwiftUI
import AppKit
import ClaudepitCore

/// The Loops page's overview: the loops waiting on you, what fires in the next hours across every
/// loop and the numbers behind it, the `loop.md` a bare `/loop` runs (managed in place —
/// `LoopFileSection`), what fired lately, and what this Claude Code supports.
struct LoopOverviewView: View {
    let context: LoopPageContext
    var actions = LoopActions()
    var select: (String) -> Void = { _ in }
    /// One-shot: scroll to the loop.md card (a loop's card linked here), then cleared.
    var revealLoopFile: Binding<Bool> = .constant(false)
    /// The snapshot tool: open the loop.md card in this mode.
    var loopFileMode: LoopFileSection.Mode = .show

    @State private var hours = 6.0

    private static let docs = URL(string: "https://code.claude.com/docs/en/scheduled-tasks")!
    private static let loopFileAnchor = "loop-md"

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.15)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            attention
                            TimelineView(.periodic(from: .now, by: 5)) { tick in
                                VStack(alignment: .leading, spacing: 14) {
                                    upcoming(now: tick.date)
                                    tiles(now: tick.date)
                                }
                            }
                            LoopFileSection(project: context.snapshot.projectLoopFile, user: context.snapshot.userLoopFile,
                                            hasProject: context.hasProject, projectName: context.projectName,
                                            cwd: context.projectPath, actions: actions, initialMode: loopFileMode)
                                .id(Self.loopFileAnchor)
                            TimelineView(.periodic(from: .now, by: 5)) { tick in
                                HStack(alignment: .top, spacing: 14) {
                                    recent(now: tick.date).frame(maxWidth: .infinity)
                                    capabilities.frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .frame(maxWidth: 980, alignment: .topLeading)
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .onChange(of: revealLoopFile.wrappedValue, initial: true) {
                        guard revealLoopFile.wrappedValue else { return }
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(Self.loopFileAnchor, anchor: .top) }
                            revealLoopFile.wrappedValue = false
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.secondary)
            Text("Loops overview").font(.headline)
            if let project = context.projectName {
                Text(project).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            HeaderButton(title: "New Loop", icon: Icon.add, help: "Start a loop in a session, or schedule it elsewhere") {
                actions.newLoop(nil)
            }
            .debugFrame("loop-overview-new")
            HeaderButton(title: "Docs", icon: Icon.externalLink, help: "Claude Code docs: Run prompts on a schedule") {
                actions.open(Self.docs)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Waiting on you

    /// Loops whose session stopped on a permission prompt or a question — the commonest silent
    /// death of an unattended loop — with the way to answer each.
    @ViewBuilder private var attention: some View {
        let blocked = context.snapshot.blocked
        if !blocked.isEmpty {
            LoopCallout(icon: "hand.raised.fill", color: .red,
                        title: blocked.count == 1 ? "A loop is waiting for you" : "\(blocked.count) loops are waiting for you",
                        text: "Its session stopped on a permission prompt or a question — nothing fires until it's answered.") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(blocked) { r in
                        HStack(spacing: 8) {
                            LoopBadge(record: r)
                            Button(r.title) { select(r.id) }
                                .buttonStyle(.link).font(.caption).lineLimit(1)
                                .help("Show this loop")
                            Text([r.sessionTitle, context.live(r)?.waitingFor.map { "waiting: \($0)" }].compactMap { $0 }
                                    .joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 6)
                            if context.background(r) != nil, let attach = actions.attach {
                                Button("Attach") { attach(r) }.buttonStyle(.bordered).controlSize(.mini)
                                    .help("Open its background session in a herdr tab to answer it")
                            } else if context.herdrTarget(r) != nil {
                                Button("Answer in herdr") { actions.focus(r) }.buttonStyle(.bordered).controlSize(.mini)
                                    .help("Bring its session's herdr pane forward")
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Next hours

    private func upcoming(now: Date) -> some View {
        let window = DateInterval(start: now.addingTimeInterval(-hours * 600), end: now.addingTimeInterval(hours * 3600))
        let jitter = context.snapshot.capabilities.jitter
        let active = context.records.filter { $0.state.isActive || ($0.kind == .durable && $0.state != .notRunning && $0.state != .cancelled) }
            .sorted { ($0.nextFire ?? .distantFuture) < ($1.nextFire ?? .distantFuture) }
        let lanes = active.map { r in
            LoopTimelineLane(id: r.id, title: "\(r.badge) · \(r.title)", color: r.state.color,
                             past: r.fires.map(\.time), future: r.projectedFires(in: window, jitter: jitter),
                             estimate: r.nextFireIsEstimate)
        }
        return DetailSection(title: "Next \(Int(hours)) hours", icon: "timeline.selection", count: lanes.isEmpty ? nil : lanes.count) {
            Spacer(minLength: 0)
            Picker("", selection: $hours) {
                Text("1h").tag(1.0); Text("6h").tag(6.0); Text("24h").tag(24.0)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130).controlSize(.small)
        } content: {
            if lanes.isEmpty {
                HStack(spacing: 10) {
                    Text("Nothing will fire — no loop is running in an open session.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("New Loop…") { actions.newLoop(nil) }.buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    LoopTimeline(lanes: lanes, window: window, now: now, laneHeight: 22, labelWidth: 210,
                                 onSelect: select)
                    Text("● fired · ○ expected — a fire due while its session is mid-turn waits for the turn to end · dashed: an estimate")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func tiles(now: Date) -> some View {
        let snap = context.snapshot
        let sessions = Set(context.records.filter(\.state.isActive).compactMap(\.sessionID)).count
        let next = snap.nextFire
        // The 7-day expiry: the running loop that dies first.
        let expiring = context.records.filter { $0.state.isActive && $0.expiresAt.map { $0 > now } == true }
            .min { $0.expiresAt! < $1.expiresAt! }
        return HStack(spacing: 10) {
            tile("Running", "\(snap.activeCount)",
                 sessions == 0 ? "no session hosts one" : "in \(sessions) session\(sessions == 1 ? "" : "s")", .green)
            tile("Next fire", next.map { $0.at <= now ? "due now" : LoopTime.until($0.at, now: now) } ?? "—",
                 next?.record.title ?? "nothing scheduled", .primary, open: next?.record.id)
            tile("Fired", "\(snap.fireCount(within: 86_400, now: now))", "in the last 24 hours", .primary)
            tile("Expires next", expiring?.expiresAt.map { LoopTime.until($0, now: now) } ?? "—",
                 expiring?.title ?? "no recurring loop running",
                 expiring?.expiresAt.map { $0.timeIntervalSince(now) < 86_400 } == true ? .orange : .primary,
                 open: expiring?.id, help: "Recurring loops delete themselves after 7 days — recreate one to keep it going")
        }
    }

    /// A number with its label; with `id`, a click shows that loop.
    @ViewBuilder private func tile(_ label: String, _ value: String, _ detail: String, _ color: Color,
                                   open id: String? = nil, help: String? = nil) -> some View {
        let body = VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        if let id {
            Button { select(id) } label: { body }
                .buttonStyle(.plain)
                .help(help.map { "\($0). Click to show the loop." } ?? "Show this loop")
        } else {
            body.help(help ?? "")
        }
    }

    // MARK: Recent fires

    private func recent(now: Date) -> some View {
        let fires = context.snapshot.recentFires(limit: 8, within: 86_400, now: now)
        return DetailSection(title: "Recent fires", icon: "clock.arrow.circlepath") {
            Spacer(minLength: 0)
            Text("last 24 hours").font(.caption2).foregroundStyle(.tertiary)
        } content: {
            if fires.isEmpty {
                Text("No loop fired in the last 24 hours.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(fires, id: \.fire.id) { item in
                        Button { select(item.record.id) } label: {
                            HStack(spacing: 8) {
                                Text(LoopTime.clock(item.fire.time, now: now))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .leading)
                                Circle().fill(item.record.state.isActive ? item.record.state.color : .secondary)
                                    .frame(width: 6, height: 6)
                                Text(item.record.title).font(.caption).lineLimit(1)
                                Spacer(minLength: 6)
                                lateness(item.fire)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(item.record.cadence)\(item.record.sessionTitle.map { " · \($0)" } ?? "") — show this loop")
                    }
                }
            }
        }
    }

    /// How a fire landed against its due time: a fire late by more than a minute met a busy session.
    @ViewBuilder private func lateness(_ fire: LoopFire) -> some View {
        if fire.isFallback {
            Text("fallback").font(.caption2).foregroundStyle(.orange)
                .help("The iteration before didn't re-arm the loop; the CLI's fallback wakeup fired")
        } else if let due = fire.dueAt, fire.time.timeIntervalSince(due) > 60 {
            Text(LoopCadence.duration(fire.time.timeIntervalSince(due)) + " late").font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Due \(LoopTime.clock(due)) — its session was busy, so it waited for the turn to end")
        } else {
            Text("on time").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: This Claude Code

    private var capabilities: some View {
        let caps = context.snapshot.capabilities
        return DetailSection(title: "This Claude Code", icon: "cpu") {
            Spacer(minLength: 0)
            if let v = context.cliVersion { Text(v).font(.caption.monospaced()).foregroundStyle(.tertiary) }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6) {
                    chip("Scheduler", caps.schedulerOn ? .on : .off, critical: true,
                         help: "/loop and CronCreate. CLAUDE_CODE_DISABLE_CRON=1 turns it off.")
                    chip("Self-paced loops", caps.selfPaced, help: "/loop with no interval: Claude picks each delay, 1 minute to 1 hour")
                    chip("Maintenance prompt", caps.maintenancePrompt,
                         help: "What a bare /loop runs when there's no loop.md")
                    chip("Durable tasks", caps.durable,
                         help: caps.durable.isKnownOff
                             ? "Off for this account: the CLI never reads .claude/scheduled_tasks.json, so the page doesn't offer it"
                             : "Tasks saved in .claude/scheduled_tasks.json, run by one session per folder")
                }
                if let file = caps.disabledBy.first {
                    Text("The scheduler is off: CLAUDE_CODE_DISABLE_CRON in \(file.path(percentEncoded: false)) — no loop fires.")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if caps.jitter != .cliDefault {
                    Text("Jitter settings differ from the defaults (remote config).").font(.caption2).foregroundStyle(.orange)
                }
                Text(caps.flagsFetchedAt.map { "From the CLI's cached feature flags (fetched \(LoopTime.clock($0)))." }
                     ?? "No cached feature flags found — the CLI's defaults are shown.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One capability: on (green), off (grey — red when nothing works without it), with "(default)"
    /// when the CLI's flag cache didn't say.
    private func chip(_ name: String, _ f: LoopCapabilities.Flag, critical: Bool = false, help: String) -> some View {
        let color: Color = f.isOn ? .green : critical ? .red : .secondary
        return HStack(spacing: 4) {
            Image(systemName: f.isOn ? "checkmark.circle.fill" : "minus.circle.fill").font(.system(size: 10))
                .foregroundStyle(color)
            Text(name).font(.caption)
            if case .unknown = f { Text("(default)").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize()
        .help(help)
    }
}
