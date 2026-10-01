import SwiftUI
import ClaudepitCore
#if canImport(AppKit)
import AppKit
#endif

/// What the Worktrees page remembers between visits: the worktree you were looking at and your search.
struct WorktreesPageMemory {
    var selection: String?
    var query = ""
}

/// The Worktrees page — the active project's git worktrees as a list card (`WorktreeListView`) and
/// the selected one in a detail card (`WorktreeDetailView`), the Sessions/Plans/Memory shape. This
/// view only wires them to `AppState`: the deep links (`focusWorktreeName`,
/// `autoOpenReviewWorktree`), the Source Control sheet, the remove confirmation, herdr, and a
/// rescan every 10 s while the page shows — an agent editing in a worktree writes nothing the
/// FileWatcher sees, so without it the counts and the changes list went stale.
struct WorktreesSection: View {
    @ObservedObject var app: AppState

    @State private var selection: String?
    @State private var query = ""
    @State private var reveal: String?
    /// The worktree whose Source Control sheet is up.
    @State private var reviewTarget: WorktreeInfo?
    // ponytail: captured once on tap — keyWindow resolves to the sheet after it opens, causing shrink
    @State private var sheetSize = CGSize(width: 900, height: 560)
    @State private var pendingRemoval: WorktreeInfo?
    /// Worktree paths with an unlock/remove in flight, and the last such call's failure per path.
    @State private var busy: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var clock = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var worktrees: [WorktreeInfo] { app.worktrees }
    private var selected: WorktreeInfo? { selection.flatMap { p in worktrees.first { $0.path == p } } }

    private var context: WorktreePageContext {
        var c = WorktreePageContext()
        for wt in worktrees {
            let refs = WorktreeListing.tasks(in: wt.path, from: app.tasks).map(WorktreeTaskRef.init)
            if !refs.isEmpty { c.tasks[wt.path] = refs }
            if let agent = app.worktreeAgentName(path: wt.path) { c.liveAgents[wt.path] = agent }
        }
        c.colorSlots = app.worktreeColorSlots
        c.herdrAvailable = WorktreeResumer.available()
        c.hasProject = app.activePath != nil
        return c
    }

    var body: some View {
        let context = context
        MasterDetailLayout(listWidth: 300) {
            GlassCard {
                WorktreeListView(worktrees: worktrees, context: context, selection: $selection, query: $query,
                                 revealRequest: $reveal, actions: actions(context))
            }
        } detail: {
            detailCard(context)
        }
        .onAppear {
            selection = app.worktreesPageMemory.selection
            query = app.worktreesPageMemory.query
            app.reloadWorktrees()
            applyFocus()
            ensureSelection()
            publishTitle()
        }
        .onDisappear {
            app.worktreesPageMemory = WorktreesPageMemory(selection: selection, query: query)
            // A deep link whose worktree never turned up must not fire on some later visit.
            app.focusWorktreeName = nil
            app.autoOpenReviewWorktree = nil
        }
        .onChange(of: app.focusWorktreeName) { applyFocus() }
        .onChange(of: app.autoOpenReviewWorktree) { applyFocus() }
        .onChange(of: worktrees.map(\.path)) { applyFocus(); ensureSelection() }
        .onChange(of: app.activePath) { selection = nil; query = ""; ensureSelection() }
        // The path bar's last crumb. On the worktree list changing too: a task renamed, or the
        // selected worktree removed, changes what it should say.
        .onChange(of: selection) { publishTitle() }
        .onChange(of: worktrees) { publishTitle() }
        .onReceive(clock) { _ in
            app.refreshSessionLiveness()
            app.reloadWorktrees()
        }
        .sheet(item: $reviewTarget) { wt in
            ReviewChangesSheet(source: GitChangeSource(worktreePath: wt.path, title: context.title(wt))) {
                committed(in: wt)
            }
            .frame(width: sheetSize.width, height: sheetSize.height)
        }
        .alert(removalTitle, isPresented: removalBinding, presenting: pendingRemoval) { wt in
            Button("Cancel", role: .cancel) {}
            Button(wt.isClean ? "Remove" : "Remove and Discard", role: .destructive) { remove(wt) }
        } message: { wt in
            Text(removalMessage(wt))
        }
    }

    // MARK: Detail

    @ViewBuilder private func detailCard(_ context: WorktreePageContext) -> some View {
        if let wt = selected {
            WorktreeDetailView(wt: wt, context: context, session: session(of: wt),
                               lastCommit: app.worktreeLastCommit[wt.path],
                               isBusy: busy.contains(wt.path), cleanupError: errors[wt.path],
                               actions: actions(context),
                               onDirtyAgain: { app.worktreeLastCommit.removeValue(forKey: wt.path) }) {
                // `wt` is re-read from `app.worktrees` on every render — the freshness the
                // control's merge-state block requires.
                // The SAME live-agent guard the board pill and the task detail panel apply (§4.9):
                // merging under a working agent rewrites files it is holding in context. `lockState`
                // rather than `isActive` alone — a task agent carries no `agent_session`, so
                // `ownerSessionID` may only ever arrive via the cwd fallback, and an unlocked-but-
                // active worktree is caught by `isActive`.
                UpdateFromBaseControl(app: app, wt: wt,
                                      externallyDisabled: busy.contains(wt.path),
                                      disabledReason: (wt.isActive || wt.lockState.isLockedLive)
                                        ? UpdateFromBaseControl.liveAgentReason : nil,
                                      taskID: context.tasks[wt.path]?.first?.id)
            }
            // A different worktree is a different page: diffs, limits and folds start over.
            .id(wt.path)
        } else {
            GlassCard {
                PageListEmptyState(icon: "arrow.triangle.branch",
                                   title: worktrees.isEmpty ? "No worktrees" : "Select a worktree",
                                   detail: worktrees.isEmpty
                                       ? "A task's worktree, or one started with claude --worktree <name>, shows here."
                                       : "Pick one on the left, or move through the list with ↑ and ↓.")
            }
        }
    }

    /// The owning session's title and stored bullets — the same data the Sessions page shows
    /// (stamped onto `app.sessions` by SessionScanner).
    private func session(of wt: WorktreeInfo) -> WorktreeSessionBrief? {
        guard let sid = wt.ownerSessionID, let s = app.sessions.first(where: { $0.id == sid }) else { return nil }
        return WorktreeSessionBrief(title: s.title, bullets: s.bulletSummary?.bullets ?? [],
                                    hasHerdrPane: app.herdrSessions[sid] != nil)
    }

    // MARK: Actions

    private func actions(_ context: WorktreePageContext) -> WorktreeActions {
        var a = WorktreeActions()
        a.refresh = { app.reloadWorktrees(forceFetch: true) }
        if let base = app.activePath {
            a.openFolder = {
                let dir = base.appending(path: ".claude/worktrees")
                NSWorkspace.shared.open(FileManager.default.fileExists(atPath: dir.path) ? dir : base)
            }
        }
        a.sourceControl = { wt in openSourceControl(wt) }
        a.openSession = { wt in
            guard let sid = wt.ownerSessionID else { return }
            app.focusSessionID = wt.ownerSubagentID.map { "\(sid)/\($0)" } ?? sid
            app.selected = .sessions
        }
        if context.herdrAvailable {
            a.resumeSession = { wt in
                guard let sid = wt.ownerSessionID else { return }
                let pane = app.herdrSessions[sid]?.paneID
                Task {
                    await WorktreeResumer.resume(sessionID: sid, cwd: wt.path, label: wt.name, existingPaneID: pane)
                    // herdr is a TUI — selecting its tab changes nothing visible until its window is raised.
                    app.activateHerdrHost()
                }
            }
            a.openInHerdr = { wt in
                Task {
                    await WorktreeResumer.checkout(branch: wt.branch, cwd: wt.path)
                    app.activateHerdrHost()
                }
            }
        }
        a.openTask = { id in
            app.focusTaskID = id
            app.selected = .tasks
        }
        a.unlock = { wt in runCleanup(wt) { await WorktreeStager.unlock(worktreePath: wt.path) } }
        a.remove = { wt in pendingRemoval = wt }
        return a
    }

    private func openSourceControl(_ wt: WorktreeInfo) {
        #if canImport(AppKit)
        if let win = NSApp.keyWindow ?? NSApp.mainWindow {
            let f = win.frame
            sheetSize = CGSize(width: max(900, f.width * 0.92), height: max(560, f.height * 0.92))
        }
        #endif
        reviewTarget = wt
    }

    /// Source Control committed: remember what it made, so the Changes section can say so once the
    /// tree is clean, and rescan for the new counts.
    private func committed(in wt: WorktreeInfo) {
        Task {
            let files = await WorktreeInspector.changedFiles(at: wt.path)
            if files.isEmpty, let info = await WorktreeInspector.commitInfo(at: wt.path) {
                app.worktreeLastCommit[wt.path] = (info.shortHash, info.subject)
            }
            app.reloadWorktrees()
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var removalTitle: String {
        guard let wt = pendingRemoval else { return "Remove this worktree?" }
        return "Remove “\(wt.name)”?"
    }

    private func removalMessage(_ wt: WorktreeInfo) -> String {
        var parts: [String] = []
        parts.append(wt.isClean
            ? "Runs `git worktree remove`. The working directory is deleted; the branch \(wt.branch.isEmpty ? "" : "“\(wt.branch)” ")is kept."
            : "Force-removes it with \(wt.dirtyCount) uncommitted file\(wt.dirtyCount == 1 ? "" : "s"). The working directory and its uncommitted changes are permanently deleted; the branch \(wt.branch.isEmpty ? "" : "“\(wt.branch)” ")is kept.")
        let tasks = WorktreeListing.tasks(in: wt.path, from: app.tasks)
        if !tasks.isEmpty {
            let names = tasks.map { "“\($0.name)”" }.joined(separator: ", ")
            parts.append("\(tasks.count == 1 ? "Task" : "Tasks") \(names) work\(tasks.count == 1 ? "s" : "") here and will lose \(tasks.count == 1 ? "its" : "their") checkout.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func remove(_ wt: WorktreeInfo) {
        let order = WorktreeListing.sections(worktrees, query: query, taskNames: context.taskNames,
                                             liveAgents: context.liveAgents)
            .flatMap { $0.items.map(\.path) }
        runCleanup(wt) {
            let r = await WorktreeStager.remove(worktreePath: wt.path, force: !wt.isClean)
            // Stay in the list: the neighbour takes the removed worktree's place.
            if r.ok, selection == wt.path { selection = WorktreeListing.neighbour(of: wt.path, in: order) }
            return r
        }
    }

    /// Run a git mutation, then rescan (unlock flips the lock state; remove drops the row).
    private func runCleanup(_ wt: WorktreeInfo, _ op: @escaping () async -> (ok: Bool, message: String)) {
        busy.insert(wt.path)
        errors[wt.path] = nil
        Task {
            let r = await op()
            busy.remove(wt.path)
            if r.ok { app.reloadWorktrees() }
            else { errors[wt.path] = r.message.isEmpty ? "git command failed" : r.message }
        }
    }

    // MARK: Selection and deep links

    private func publishTitle() {
        let title = selected.map { context.title($0) }
        if app.selectedWorktreeTitle != title { app.selectedWorktreeTitle = title }
    }

    /// Keeps a worktree on screen: the remembered one if it still exists, else the first listed.
    private func ensureSelection() {
        guard selected == nil else { return }
        let order = WorktreeListing.sections(worktrees, query: query, taskNames: context.taskNames,
                                             liveAgents: context.liveAgents)
            .flatMap { $0.items.map(\.path) }
        selection = order.first ?? worktrees.first?.path
    }

    /// One-shot deep links, by worktree name: select it (clearing a search that hides it), scroll
    /// it into view, and — for `autoOpenReviewWorktree`, a task's "Review changes" — present Source
    /// Control. Held until the worktree is in the scan, which may still be running on arrival.
    private func applyFocus() {
        if let name = app.focusWorktreeName, let wt = worktrees.first(where: { $0.name == name }) {
            select(wt)
            DispatchQueue.main.async { app.focusWorktreeName = nil }
        }
        if let name = app.autoOpenReviewWorktree, let wt = worktrees.first(where: { $0.name == name }) {
            select(wt)
            openSourceControl(wt)
            DispatchQueue.main.async { app.autoOpenReviewWorktree = nil }
        }
    }

    private func select(_ wt: WorktreeInfo) {
        if !WorktreeListing.matches(wt, query: query, taskName: context.taskNames[wt.path]) { query = "" }
        selection = wt.path
        reveal = wt.path
    }
}
