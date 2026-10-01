import SwiftUI
import ClaudepitCore
#if canImport(AppKit)
import AppKit
#endif

/// The New Loop dialog's request: what to fill it with, and what it knows when it opens.
struct NewLoopRequest: Identifiable {
    let id = UUID()
    let seed: LoopDraft?
    let context: NewLoopContext
}

/// The Loops page — every loop the app can see as a list card (`LoopListView`) and the selected one,
/// or the overview, in a detail card (`LoopDetailView` / `LoopOverviewView`): the Sessions/Worktrees
/// shape. Session loops exist only inside a running Claude Code process, so this page reads them
/// from where the CLI leaves them — transcripts, the live-session registry, the task file — and
/// rescans every 5 s while it shows (`AppState.reloadLoops`). This view only wires it all to
/// `AppState`: deep links, the New Loop dialog, the stop confirmation and the notice toast.
struct LoopsSection: View {
    @ObservedObject var app: AppState

    @State private var selection: LoopSelection = .overview
    @State private var query = ""
    @State private var reveal: String?
    @State private var sheet: NewLoopRequest?
    @State private var pendingStop: LoopRecord?
    /// A background session the person asked to stop (`claude stop`), awaiting confirmation.
    @State private var pendingSessionStop: LoopRecord?
    /// A loop.md the person asked to move to the Trash, awaiting confirmation.
    @State private var pendingTrash: LoopFile?
    /// One-shot: the overview scrolls to its loop.md card (a loop's card linked there).
    @State private var revealLoopFile = false
    /// A session the dialog just started: selected as soon as its loop appears.
    @State private var awaitingSession: String?
    @State private var sheetSize = CGSize(width: 980, height: 660)
    @State private var now = Date()
    @State private var clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var context: LoopPageContext {
        var c = LoopPageContext()
        c.snapshot = app.loopSnapshot
        c.launches = app.loopLaunches
        c.herdrAvailable = Herdr.available()
        for id in Set(app.loopSnapshot.records.compactMap(\.sessionID)) + app.loopSnapshot.liveSessions.map(\.sessionID) {
            if let t = app.loopHerdrTarget(sessionID: id) { c.herdrTargets[id] = t }
        }
        c.hasProject = app.activePath != nil
        c.projectName = app.activePath?.lastPathComponent
        c.projectPath = app.activePath
        c.cliVersion = app.claudeVersion
        c.commandInfo = app.loopCommandAvailability()
        c.agents = app.loopAgents()
        return c
    }

    var body: some View {
        let context = context
        MasterDetailLayout(listWidth: 320) {
            GlassCard {
                LoopListView(context: context, selection: $selection, query: $query, revealRequest: $reveal,
                             now: now, actions: actions(context))
            }
        } detail: {
            detail(context)
                .overlay(alignment: .bottom) { toast }
                .alert("Move \(pendingTrash?.scope == .user ? "your" : "this project's") loop.md to the Trash?",
                       isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                       presenting: pendingTrash) { file in
                    Button("Cancel", role: .cancel) {}
                    Button("Move to Trash", role: .destructive) { app.trashLoopFile(file) }
                } message: { file in
                    Text(trashMessage(file))
                }
        }
        .onAppear {
            selection = app.loopsPageMemory.selection
            query = app.loopsPageMemory.query
            app.refreshHerdrAgents()
            app.reloadLoops()
            applyFocus()
            publishTitle()
        }
        .onDisappear {
            app.loopsPageMemory = LoopsPageMemory(selection: selection, query: query)
            app.focusLoop = nil
            app.focusLoopID = nil
        }
        .onReceive(clock) { date in
            now = date
            app.refreshHerdrAgents()
            app.reloadLoops()
        }
        .onChange(of: app.focusLoop) { applyFocus() }
        .onChange(of: app.focusLoopID) { applyFocus() }
        .onChange(of: app.loopSnapshot) {
            applyFocus()
            selectAwaitedLaunch()
            keepSelection()
            publishTitle()
        }
        .onChange(of: selection) { publishTitle() }
        .onChange(of: app.activePath) { selection = .overview; query = "" }
        .sheet(item: $sheet) { req in
            NewLoopSheet(context: req.context, seed: req.seed,
                         onSubmit: { draft in
                             let before = Set(app.loopLaunches.map(\.sessionID))
                             let ok = await app.startLoop(draft)
                             if ok, let launched = app.loopLaunches.first(where: { !before.contains($0.sessionID) }) {
                                 awaitingSession = launched.sessionID
                             }
                             return ok
                         },
                         onOpenLoopFile: { app.openLoopFile($0) },
                         onClose: { sheet = nil })
                .frame(width: sheetSize.width, height: sheetSize.height)
        }
        .alert(stopTitle, isPresented: stopBinding, presenting: pendingStop) { r in
            Button("Cancel", role: .cancel) {}
            Button(r.kind == .durable ? "Remove" : "Stop", role: .destructive) { Task { await app.stopLoop(r) } }
        } message: { r in
            Text(stopMessage(r))
        }
        .alert("Stop this background session?", isPresented: Binding(get: { pendingSessionStop != nil },
                                                                      set: { if !$0 { pendingSessionStop = nil } }),
               presenting: pendingSessionStop) { r in
            Button("Cancel", role: .cancel) {}
            Button("Stop Session", role: .destructive) { Task { await app.stopBackgroundSession(r) } }
        } message: { r in
            let others = app.loopSnapshot.records.filter { $0.sessionID == r.sessionID && $0.state.isActive }.count - 1
            Text("claude stop ends the whole session" + (others > 0 ? ", with its \(others) other loop\(others == 1 ? "" : "s")" : "")
                 + ". Its conversation is kept: resuming it brings back cron loops that haven't expired; a self-paced loop needs /loop again.")
        }
    }

    // MARK: Detail

    @ViewBuilder private func detail(_ context: LoopPageContext) -> some View {
        switch selection {
        case .overview:
            LoopOverviewView(context: context, actions: actions(context), select: { select($0) },
                             revealLoopFile: $revealLoopFile)
        case .loop(let id):
            if let r = context.record(id) {
                LoopDetailView(record: r, context: context, actions: actions(context), select: { select($0) })
                    // A different loop is a different page: outcomes and folds start over.
                    .id(r.id)
            } else {
                LoopOverviewView(context: context, actions: actions(context), select: { select($0) })
            }
        }
    }

    @ViewBuilder private var toast: some View {
        if let notice = app.loopNotice {
            HStack(spacing: 8) {
                Image(systemName: notice.level == .error ? "xmark.octagon.fill"
                      : notice.level == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.level == .error ? Color.red : notice.level == .warning ? .orange : .green)
                Text(notice.text).font(.callout).lineLimit(3)
                Button { app.loopNotice = nil } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                if app.loopNotice?.id == notice.id { withAnimation { app.loopNotice = nil } }
            }
        }
    }

    // MARK: Actions

    private func actions(_ context: LoopPageContext) -> LoopActions {
        var a = LoopActions()
        a.newLoop = { seed in openNewLoop(seed) }
        a.refresh = {
            app.refreshHerdrAgents()
            app.reloadLoops()
        }
        a.openSession = { r in
            guard let sid = r.sessionID, r.transcript != nil else { return }
            app.focusSessionID = sid
            app.selected = .sessions
        }
        a.focus = { r in app.focusLoopSession(r) }
        if context.herdrAvailable {
            a.resume = { r in app.resumeLoopSession(r) }
            a.attach = { r in app.attachBackgroundSession(r) }
        }
        a.stop = { r in pendingStop = r }
        a.stopSession = { r in pendingSessionStop = r }
        a.openLoopFile = { scope in app.openLoopFile(scope) }
        a.saveLoopFile = { scope, text, base, force in try app.saveLoopFile(scope, text: text, base: base, force: force) }
        a.trashLoopFile = { file in pendingTrash = file }
        a.manageLoopFile = {
            selection = .overview
            revealLoopFile = true
        }
        return a
    }

    private func openNewLoop(_ seed: LoopDraft?) {
        #if canImport(AppKit)
        if let win = NSApp.keyWindow ?? NSApp.mainWindow {
            let f = win.frame
            sheetSize = CGSize(width: min(max(900, f.width * 0.86), 1180), height: min(max(600, f.height * 0.86), 820))
        }
        #endif
        let snap = app.loopSnapshot
        let ctx = NewLoopContext(capabilities: snap.capabilities, loopFile: snap.activeLoopFile,
                                 herdrAvailable: Herdr.available(), commands: app.loopCommandAvailability(),
                                 agents: app.loopAgents(), claudeAvailable: Executable.find("claude") != nil,
                                 scheduleUnavailable: app.loopScheduleUnavailable,
                                 targets: app.loopSessionTargets(), hasProject: app.activePath != nil,
                                 projectName: app.activePath?.lastPathComponent)
        sheet = NewLoopRequest(seed: seed, context: ctx)
    }

    /// What a bare /loop runs once this file is gone.
    private func trashMessage(_ file: LoopFile) -> String {
        let snap = app.loopSnapshot
        let after: String
        if file.scope == .project {
            after = snap.userLoopFile != nil ? "A bare /loop here runs your loop.md from its next iteration."
                                             : "A bare /loop here runs the built-in maintenance prompt from its next iteration."
        } else {
            after = "Projects without their own loop.md run the built-in maintenance prompt"
                + (snap.projectLoopFile != nil ? " — this one keeps its own." : ".")
        }
        return after + " You can put it back from the Trash."
    }

    private var stopBinding: Binding<Bool> {
        Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } })
    }

    private var stopTitle: String {
        guard let r = pendingStop else { return "Stop this loop?" }
        return r.kind == .durable ? "Remove this task?" : "Stop “\(r.title.prefix(40))”?"
    }

    private func stopMessage(_ r: LoopRecord) -> String {
        switch r.kind {
        case .durable:
            return "Removes task \(r.taskID ?? "") from .claude/scheduled_tasks.json. A session holding the scheduler lock stops running it."
        case .selfPaced:
            if app.loopSnapshot.liveSession(r.sessionID)?.isIdle == true && r.state == .scheduled {
                return "Presses Esc in its session, which clears the pending wakeup — the documented way to stop a self-paced loop."
            }
            return "Its session is busy, so Esc would interrupt the turn. Instead this asks it to stop the loop (ScheduleWakeup stop) when the turn ends."
        default:
            return "Asks its session to cancel task \(r.taskID ?? "") with CronDelete. It acts when it's idle."
        }
    }

    // MARK: Selection and deep links

    private func select(_ id: String) {
        selection = .loop(id)
        if let r = app.loopSnapshot.records.first(where: { $0.id == id }), !r.matches(query) { query = "" }
        reveal = id
    }

    private func publishTitle() {
        let title: String? = {
            switch selection {
            case .overview: return "Overview"
            case .loop(let id): return app.loopSnapshot.records.first { $0.id == id }?.title
            }
        }()
        if app.selectedLoopTitle != title { app.selectedLoopTitle = title }
    }

    /// A transcript fire's "Loop" link, or Home's "needs you" row: select the loop once the scan has it.
    private func applyFocus() {
        if let id = app.focusLoopID, app.loopSnapshot.records.contains(where: { $0.id == id }) {
            select(id)
            DispatchQueue.main.async { app.focusLoopID = nil }
        }
        guard let focus = app.focusLoop,
              let r = LoopListing.record(sessionID: focus.sessionID, taskID: focus.taskID, in: app.loopSnapshot.records)
        else { return }
        select(r.id)
        DispatchQueue.main.async { app.focusLoop = nil }
    }

    /// The loop a session started from the dialog: select it when its transcript first records it.
    private func selectAwaitedLaunch() {
        guard let sid = awaitingSession,
              let r = app.loopSnapshot.records.filter({ $0.sessionID?.hasPrefix(sid) == true }).max(by: { $0.createdAt < $1.createdAt })
        else { return }
        select(r.id)
        awaitingSession = nil
    }

    /// A selected loop that's gone (its session's history aged out) falls back to the overview.
    private func keepSelection() {
        if case .loop(let id) = selection, app.loopSnapshot.scannedAt != nil,
           !app.loopSnapshot.records.contains(where: { $0.id == id }) {
            selection = .overview
        }
    }
}
