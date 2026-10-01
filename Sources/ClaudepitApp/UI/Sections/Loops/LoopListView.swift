import SwiftUI
import AppKit
import ClaudepitCore

/// What the Loops list and detail know beyond the snapshot. Plain data, so both render without
/// `AppState` (the DEBUG `--snapshot-pages loops` tool draws them offscreen).
struct LoopPageContext {
    var snapshot: LoopSnapshot = .empty
    /// Loops just started in a new session, not yet in a transcript.
    var launches: [LoopLaunch] = []
    var herdrAvailable = false
    /// Session id → the herdr pane hosting it.
    var herdrTargets: [String: String] = [:]
    var hasProject = true
    var projectName: String?
    /// The active project — the working directory for Ask's `claude -p` calls.
    var projectPath: URL?
    var cliVersion: String?
    /// `/name` → whether Claude may run it on its own.
    var commandInfo: [String: CommandAvailability] = [:]
    /// The project's and the user's agent files.
    var agents: [LoopAgent] = []

    var records: [LoopRecord] { snapshot.records }
    func record(_ id: String) -> LoopRecord? { records.first { $0.id == id } }
    func herdrTarget(_ r: LoopRecord) -> String? { r.sessionID.flatMap { herdrTargets[$0] } }
    func live(_ r: LoopRecord) -> LiveSession? { snapshot.liveSession(r.sessionID) }
    func agent(_ name: String) -> LoopAgent? { agents.first { $0.name == name } ?? LoopAgent.builtIns.first { $0.name == name } }
    /// The loop's session, when it runs in the background (`claude --bg`): no terminal, no pane.
    func background(_ r: LoopRecord) -> LiveSession? { live(r).flatMap { $0.isBackground ? $0 : nil } }

    /// The loop can be stopped from here: a durable task (edit the file), or a live session the
    /// app can reach in herdr.
    func canStop(_ r: LoopRecord) -> Bool {
        if r.kind == .durable { return r.state != .cancelled }
        return r.state.isActive && herdrTarget(r) != nil
    }
}

/// Everything the page can do. Shared by the list's menus and the detail card's header, so the two
/// always offer the same actions.
struct LoopActions {
    /// Open the New Loop dialog, optionally filled in from an existing loop.
    var newLoop: (LoopDraft?) -> Void = { _ in }
    var refresh: () -> Void = {}
    /// Show the loop's session on the Sessions page.
    var openSession: (LoopRecord) -> Void = { _ in }
    /// Focus the herdr pane hosting the loop's session.
    var focus: (LoopRecord) -> Void = { _ in }
    /// `claude --resume` the loop's closed session in herdr.
    var resume: ((LoopRecord) -> Void)? = nil
    /// Cancel / stop it (the page confirms first).
    var stop: (LoopRecord) -> Void = { _ in }
    /// Open its background session in a herdr tab (`claude attach <id>`).
    var attach: ((LoopRecord) -> Void)? = nil
    /// Stop its background session (`claude stop <id>`) — the page confirms first.
    var stopSession: ((LoopRecord) -> Void)? = nil
    /// Open (creating from the template) the project's or the user's loop.md.
    var openLoopFile: (LoopFile.Scope) -> Void = { _ in }
    /// Write a loop.md from the overview's editor. `base` is the text the edit started from (nil
    /// creates the file); throws `LoopFile.SaveError` when the file moved on, unless `force`.
    var saveLoopFile: (LoopFile.Scope, _ text: String, _ base: String?, _ force: Bool) throws -> Void = { _, _, _, _ in }
    /// Move a loop.md to the Trash (the page confirms first).
    var trashLoopFile: (LoopFile) -> Void = { _ in }
    /// Show the overview's loop.md card — a loop's card links there.
    var manageLoopFile: () -> Void = {}
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var copy: (String) -> Void = { s in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// The Loops page's left card: an Overview entry, loops just being started, then every loop under
/// Running / Paused / Saved / Desktop app / Ended, with search and ↑/↓ — the same list family as
/// Sessions, Plans, Memory and Worktrees (`PageList.swift`).
struct LoopListView: View {
    let context: LoopPageContext
    @Binding var selection: LoopSelection
    @Binding var query: String
    /// One-shot from a deep link: scroll this loop into view, then cleared.
    @Binding var revealRequest: String?
    var now = Date()
    var actions = LoopActions()

    @FocusState private var listFocused: Bool
    @State private var hovered: String?
    @State private var searchFocusToken = 0
    @State private var keyScroll: String?

    private static let overviewID = "overview"

    var body: some View {
        let sections = LoopListing.sections(context.records, query: query)
        VStack(spacing: 0) {
            header
            if !context.snapshot.capabilities.schedulerOn { schedulerOff }
            if !context.records.isEmpty { searchRow(sections) }
            if context.records.isEmpty && context.launches.isEmpty {
                overviewRow.padding(.bottom, 4)
                PageListEmptyState(icon: "arrow.trianglehead.2.clockwise", title: "No loops yet",
                                   detail: "A loop re-runs a prompt in a Claude Code session — on an interval, or at a pace "
                                         + "Claude picks. Start one here, or type /loop in any session.") {
                    Button("New Loop…") { actions.newLoop(nil) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            } else if sections.isEmpty && !query.isEmpty {
                PageListEmptyState(icon: Icon.search, title: "No loops match “\(query)”",
                                   detail: "Search reads prompts, schedules, sessions and task ids.") {
                    Button("Clear Search") { query = "" }.buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                list(sections)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Loops").font(.headline)
            let active = context.snapshot.activeCount
            if active > 0 {
                Text("\(active) running").font(.caption.monospacedDigit()).foregroundStyle(.green)
            }
            Spacer()
            iconButton(Icon.addCircle, help: "New loop (⌘N)") { actions.newLoop(nil) }
                .debugFrame("loop-new")
                .background {
                    Button("") { actions.newLoop(nil) }
                        .keyboardShortcut("n", modifiers: .command).opacity(0).frame(width: 0, height: 0)
                }
            iconButton(Icon.refresh, help: "Rescan sessions and the task file", action: actions.refresh)
                .debugFrame("loop-refresh")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.top, 12).padding(.bottom, 8)
    }

    private var schedulerOff: some View {
        let caps = context.snapshot.capabilities
        let why = caps.disabledBy.first.map { "CLAUDE_CODE_DISABLE_CRON in \($0.lastPathComponent)" }
            ?? "its scheduler flag is off in this Claude Code"
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            Text("Loops are switched off — \(why).").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func searchRow(_ sections: [LoopListing.Section]) -> some View {
        PageListSearchField(text: $query, placeholder: "Search loops",
                            help: "Searches prompts, schedules, sessions and task ids (⌥⌘F)",
                            focusToken: searchFocusToken,
                            onArrowDown: {
                                listFocused = true
                                if let first = sections.first?.items.first {
                                    selection = .loop(first.id)
                                    keyScroll = first.id
                                }
                            },
                            onLeave: { listFocused = true })
            .debugFrame("loop-search")
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .background {
                Button("") { searchFocusToken += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .opacity(0).frame(width: 0, height: 0)
            }
    }

    // MARK: List

    private func order(_ sections: [LoopListing.Section]) -> [String] {
        [Self.overviewID] + sections.flatMap { $0.items.map(\.id) }
    }

    private func list(_ sections: [LoopListing.Section]) -> some View {
        let order = order(sections)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    overviewRow.id(Self.overviewID)
                    ForEach(context.launches) { launch in launchRow(launch) }
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.items) { r in row(r) }
                        } header: {
                            PageListSectionHeader(title: section.group.title, count: section.items.count,
                                                  help: section.group.help)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                let delta: Int
                switch press.key {
                case .upArrow: delta = -1
                case .downArrow: delta = 1
                default: return .ignored
                }
                let current: String? = {
                    if case .loop(let id) = selection { return id }
                    return Self.overviewID
                }()
                if let next = PageListKeys.step(current, by: delta, in: order) {
                    selection = next == Self.overviewID ? .overview : .loop(next)
                    keyScroll = next
                }
                return .handled
            }
            .onAppear { reveal(proxy) }
            .onChange(of: revealRequest) { reveal(proxy) }
            .onChange(of: keyScroll) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
                keyScroll = nil
            }
        }
    }

    private var overviewRow: some View {
        let snap = context.snapshot
        let subtitle: String = {
            if let next = snap.nextFire {
                return "\(snap.activeCount) running · next \(LoopTime.until(next.at, now: now))"
            }
            return snap.activeCount > 0 ? "\(snap.activeCount) running" : "Nothing scheduled"
        }()
        return PageListRow(
            title: "Overview",
            subtitle: subtitle,
            meta: Text((snap.blocked.isEmpty ? "" : "\(snap.blocked.count) waiting for you · ")
                       + "\(snap.fireCount(within: 86_400, now: now)) fires in 24h"),
            isSelected: selection == .overview,
            isFocused: listFocused,
            isHovered: hovered == Self.overviewID,
            help: "Loops waiting for you, the next hours across all loops, recent fires, loop.md and what this Claude Code supports",
            onTap: { selection = .overview; listFocused = true }
        ) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 44)
        } markers: {
            EmptyView()
        } menuItems: {
            Button { actions.newLoop(nil) } label: { Label("New Loop…", systemImage: Icon.add) }
            Button { actions.refresh() } label: { Label("Rescan", systemImage: Icon.refresh) }
        }
        .debugFrame("loop-row-overview")
        .onHover { inside in
            if inside { hovered = Self.overviewID } else if hovered == Self.overviewID { hovered = nil }
        }
    }

    private func launchRow(_ launch: LoopLaunch) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ProgressView().controlSize(.small).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Starting a session…").font(.subheadline.weight(.semibold))
                Text(launch.message).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                Text("Appears here once Claude schedules it · \(LoopTime.ago(launch.startedAt, now: now))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .padding(.horizontal, 6)
        .help("A new Claude Code session in herdr was sent this; the loop is listed once its transcript records it")
    }

    private func row(_ r: LoopRecord) -> some View {
        PageListRow(
            title: r.title,
            titleLines: 2,
            subtitle: subtitle(r),
            meta: meta(r),
            isSelected: selection == .loop(r.id),
            isFocused: listFocused,
            isHovered: hovered == r.id,
            help: "\(r.kind.label) · \(r.cadence)\n\(r.state.label): \(r.note ?? r.state.explanation)",
            edgeColor: r.state.isActive ? r.state.color : nil,
            onTap: { selection = .loop(r.id); listFocused = true }
        ) {
            LoopBadge(record: r)
        } markers: {
            if context.herdrTarget(r) != nil {
                Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Its session is open in herdr")
            }
            if case .agent(let name, _, let mentioned) = r.promptKind {
                Image(systemName: "person.2").font(.system(size: 9)).foregroundStyle(mentioned ? .orange : .secondary)
                    .help(mentioned ? "Mentions @agent-\(name) — a fire leaves that as plain text"
                                    : "Hands each fire to the \(name) subagent")
            } else if let agent = r.sessionAgent {
                Image(systemName: "person.2").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Its session runs as \(agent)")
            }
            if context.background(r) != nil {
                Image(systemName: "server.rack").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Runs in a background session (claude --bg) — no terminal")
            }
            if r.state == .blocked {
                Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.red)
                    .help(r.note ?? r.state.explanation)
            }
            if r.state == .missed || r.state == .failed || r.state == .notRunning || r.state == .due {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    .help(r.note ?? r.state.explanation)
            }
        } menuItems: {
            LoopMenuItems(record: r, context: context, actions: actions)
        }
        .id(r.id)
        .debugFrame("loop-row-\(r.id)")
        .onHover { inside in
            if inside { hovered = r.id } else if hovered == r.id { hovered = nil }
        }
    }

    private func subtitle(_ r: LoopRecord) -> String? {
        switch r.kind {
        case .durable: return ".claude/scheduled_tasks.json · \(r.cadence)"
        case .desktop: return r.desktop?.description
        default:
            let session = r.sessionTitle ?? r.sessionID.map { String($0.prefix(8)) } ?? ""
            return "\(r.cadence) · \(session)"
        }
    }

    /// "Scheduled · in 4m 12s · 6 fires": the state in its colour, then when, then how often it ran.
    private func meta(_ r: LoopRecord) -> Text {
        var text = Text(r.state.label).foregroundColor(r.state.isActive || r.state == .paused ? r.state.color : nil)
        text = text + Text(" · \(LoopTime.phrase(r, now: now))")
        let fires = r.fires.filter { $0.offset >= 0 }.count
        if fires > 0 { text = text + Text(" · \(fires) fire\(fires == 1 ? "" : "s")") }
        return text
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = revealRequest else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            revealRequest = nil
        }
    }
}

/// The actions one loop offers, as menu items — the row's "…" and right-click menus and the detail
/// card's "…" capsule all draw this.
struct LoopMenuItems: View {
    let record: LoopRecord
    let context: LoopPageContext
    let actions: LoopActions
    /// The detail header has buttons for these already.
    var includePrimary = true

    var body: some View {
        let r = record
        if includePrimary {
            if r.transcript != nil {
                Button { actions.openSession(r) } label: { Label("Show Session", systemImage: Icon.jump) }
            }
            if context.herdrTarget(r) != nil {
                Button { actions.focus(r) } label: { Label("Focus Session in herdr", systemImage: "terminal") }
            } else if context.background(r) != nil, let attach = actions.attach {
                Button { attach(r) } label: { Label("Attach in herdr", systemImage: "terminal") }
            } else if r.state == .paused, let resume = actions.resume {
                Button { resume(r) } label: { Label("Resume Session in herdr", systemImage: "play.circle") }
            }
            Divider()
        }
        if let bg = context.background(r), let id = bg.jobID {
            Button { actions.copy(BackgroundSession.attachCommand(id)) } label: {
                Label("Copy “\(BackgroundSession.attachCommand(id))”", systemImage: Icon.copyPath)
            }
        }
        Button { actions.newLoop(LoopDraft(record: r)) } label: {
            Label(r.state.isActive ? "Duplicate…" : "Run Again…", systemImage: "plus.square.on.square")
        }
        if let command = r.loopCommand {
            Button { actions.copy(command) } label: { Label("Copy “\(command.prefix(30))\(command.count > 30 ? "…" : "")”", systemImage: Icon.copyPath) }
        }
        Button { actions.copy(r.prompt) } label: { Label("Copy Prompt", systemImage: Icon.copyPath) }
        if let id = r.taskID {
            Button { actions.copy(id) } label: { Label("Copy Task ID \(id)", systemImage: "number") }
        }
        if let url = r.transcript {
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("Reveal Transcript in Finder", systemImage: Icon.revealInFinder)
            }
        }
        if let url = r.durable.map({ _ in context.snapshot.durableFile }) ?? nil {
            Button { actions.open(url) } label: { Label("Open scheduled_tasks.json", systemImage: Icon.openFile) }
        }
        if let desktop = r.desktop {
            Button { actions.open(desktop.url) } label: { Label("Open SKILL.md", systemImage: Icon.openFile) }
        }
        if r.state.isActive, context.herdrTarget(r) == nil, r.kind != .durable {
            Button { actions.copy(r.stopRequest) } label: {
                Label("Copy Stop Request", systemImage: "stop.circle")
            }
            .help("Its session isn't in herdr — paste this into it (or press Esc there, for a waiting self-paced loop)")
        }
        if context.canStop(r) {
            Divider()
            Button(role: .destructive) { actions.stop(r) } label: {
                Label(r.kind == .durable ? "Remove Task…" : r.kind == .selfPaced ? "Stop Loop…" : "Cancel Loop…",
                      systemImage: "stop.circle")
            }
        }
    }
}

extension LoopRecord {
    /// What to tell a session to stop this loop — for one the app can't reach in herdr.
    var stopRequest: String {
        if kind == .selfPaced { return "Stop the /loop: call ScheduleWakeup with stop: true and don't schedule another iteration." }
        return "Cancel the scheduled task \(taskID ?? "") with CronDelete."
    }

    /// The `/loop` command that would start this loop again, when it was one.
    var loopCommand: String? {
        if case .loopCommand(let args, _) = origin { return args.isEmpty ? "/loop" : "/loop \(args)" }
        return nil
    }
}

extension LoopDraft {
    /// A draft that recreates `record` — "Run Again…" and "Duplicate…".
    init(record r: LoopRecord) {
        self.init()
        switch r.promptKind {
        case .maintenance, .loopFile: task = .defaultPrompt
        case .command(let name, let args): task = .command(name: name, args: args)
        case .custom(let text): task = .prompt(text)
        case .agent:
            // A mention stays as typed — the dialog then offers to turn it into a delegation.
            if let d = AgentDelegation.parse(r.prompt) {
                task = .agent(name: d.agent, task: d.task, skipWhileRunning: d.skipWhileRunning)
            } else {
                task = .prompt(r.prompt)
            }
        }
        sessionAgent = r.sessionAgent
        if r.kind == .selfPaced {
            cadence = .selfPaced
        } else if case .loopCommand(let args, _) = r.origin, let i = LoopArguments.parse(args).interval {
            cadence = .interval(i)
        } else if let cron = r.cron {
            cadence = r.recurring ? .cron(cron) : .once(Date().addingTimeInterval(3600))
        }
        if r.kind == .durable { destination = .durableFile }
        // The transcript spells the ask-every-time mode `default`; the flag calls it `manual`. A mode
        // the dialog doesn't offer leaves the person's own default (and the dialog warns about it).
        switch r.permissionMode {
        case "default"?: permissionMode = "manual"
        case let m? where LoopDraft.permissionModes.contains(where: { $0.id == m }): permissionMode = m
        case nil: permissionMode = "auto"
        default: permissionMode = nil
        }
    }
}
