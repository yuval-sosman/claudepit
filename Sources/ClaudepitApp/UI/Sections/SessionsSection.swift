import SwiftUI
import ClaudepitCore
import AppKit

/// The Sessions page: the list (`SessionListView`, which owns Recent/Groups, search, selection
/// and group editing) beside the selected session's detail — or, with several selected, what
/// can be done to all of them.
struct SessionsSection: View {
    @ObservedObject var app: AppState
    @StateObject private var state = SessionListState()
    @AppStorage("sessionsListPrefs") private var prefs = SessionListPrefs()

    @State private var now = Date()
    @State private var showDiscover = false
    @State private var discoverQuery = ""
    @State private var appWindowWidth: CGFloat = 1100
    @State private var appWindowHeight: CGFloat = 800

    /// Liveness: dates, the live dot and herdr's states drift between FileWatcher rescans
    /// (see `AppState.refreshSessionLiveness`), so the page re-reads them while it shows.
    /// `@State`, not `let`: this struct is rebuilt on every AppState publish, and a fresh
    /// publisher each time restarts the countdown — under steady publishing it would never fire.
    @State private var tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            GlassCard {
                SessionListView(sessions: app.sessions, context: context, prefs: $prefs,
                                state: state, actions: actions)
            }
        } detail: {
            detailCard
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverSheet(app: app, projectSlug: currentProjectSlug, initialQuery: discoverQuery)
                .frame(width: appWindowWidth * 0.65, height: appWindowHeight * 0.75)
        }
        .onAppear {
            restoreMemory()
            app.reloadSessions()
            // After the transcript being opened has had the CPU (throttled; see reloadSessionStats).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { app.reloadSessionStats() }
            applyDiscoverIntent()
            applyFocusIntent()
        }
        .onDisappear { saveMemory() }
        .onReceive(tick) { _ in
            now = Date()
            app.refreshSessionLiveness()
        }
        .onChange(of: app.openDiscoverSheet) { applyDiscoverIntent() }
        .onChange(of: app.focusSessionID) { applyFocusIntent() }
        .onChange(of: app.activePath) {
            // Another project: its own sessions, its own place.
            state.selection = []; state.primaryID = nil; state.expanded = []
            state.query = ""; state.newGroup = nil; state.renamingGroupID = nil
            app.sessionsPageMemory = SessionsPageMemory()
        }
        .onChange(of: state.primaryID) { _, id in
            reloadBullets(for: id)
            app.selectedSessionID = id
        }
        .textSelection(.disabled)
    }

    // MARK: - Wiring

    private var projectKey: String? {
        app.activePath.map { SessionScanner.storageKey(forPath: ProjectFolders.normalizedPath($0)) }
    }

    private var currentProjectSlug: String {
        projectKey ?? app.sessions.first?.projectSlug ?? ""
    }

    private var context: SessionListContext {
        var c = SessionListContext()
        c.now = now
        c.projectKey = projectKey
        c.groups = app.sessionGroups
        c.herdrStatus = app.herdrSessions.mapValues(\.status)
        c.stats = app.sessionStats
        c.taskNames = Dictionary(app.tasks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        c.boundWorktrees = Dictionary(app.worktrees.compactMap { wt in wt.ownerSessionID.map { ($0, wt.name) } },
                                      uniquingKeysWith: { a, _ in a })
        c.worktreeSlots = app.worktreeColorSlots
        c.herdrAvailable = Herdr.available()
        return c
    }

    private var actions: SessionListActions {
        var a = SessionListActions()
        if WorktreeResumer.available() { a.resume = { resume($0) } }
        a.openTask = { id in app.focusTaskID = id; app.selected = .tasks }
        a.createGroup = { name, key, ids in app.createSessionGroup(named: name, key: key, assigning: ids) }
        a.renameGroup = { id, name, key in app.renameSessionGroup(id, to: name, key: key) }
        a.recolorGroup = { id, color, key in app.recolorSessionGroup(id, color, key: key) }
        a.deleteGroup = { id, key in app.deleteSessionGroup(id, key: key) }
        a.moveGroup = { id, offset, key in app.moveSessionGroup(id, by: offset, key: key) }
        a.setGroupCollapsed = { id, collapsed, key in app.setSessionGroupCollapsed(id, collapsed, key: key) }
        a.assign = { ids, gid, key in app.assignSessions(ids, to: gid, key: key) }
        a.unassign = { ids in app.unassignSessions(ids) }
        a.trash = { app.trashSessions($0) }
        a.discover = { openDiscover(query: $0) }
        return a
    }

    /// Resume in the session's own directory — a worktree session's checkout, not the project
    /// root, or `claude --resume` can't find it — or focus the herdr pane it is already open in.
    private func resume(_ s: SessionSummary) {
        let pane = app.herdrSessions[s.id]?.paneID
        let candidates = [s.cwd, app.worktrees.first { $0.ownerSessionID == s.id }?.path, app.activePath?.path]
        guard let cwd = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) })
        else { return }
        let label = context.title(of: s)
        Task { await WorktreeResumer.resume(sessionID: s.id, cwd: cwd, label: label, existingPaneID: pane) }
        app.activateHerdrHost()
    }

    private func openDiscover(query: String) {
        // The sheet's frame is sized from the window it covers.
        appWindowWidth = NSApp.keyWindow?.frame.width ?? 1100
        appWindowHeight = NSApp.keyWindow?.frame.height ?? 800
        discoverQuery = query
        showDiscover = true
    }

    /// Home's one-shot "open Discover" intent (documented focus pattern — the consumer clears it).
    private func applyDiscoverIntent() {
        guard app.openDiscoverSheet else { return }
        app.openDiscoverSheet = false
        openDiscover(query: "")
    }

    /// A deep link to a session (or "parent/subagent"): reveal it whatever hides it.
    private func applyFocusIntent() {
        guard let id = app.focusSessionID else { return }
        app.focusSessionID = nil
        state.revealRequest = id
    }

    private func reloadBullets(for sessionID: String?) {
        guard let id = sessionID,
              let idx = app.sessions.firstIndex(where: { $0.id == id }) else { return }
        let slug = app.sessions[idx].projectSlug
        let fresh = SummaryStore.shared.load(projectSlug: slug, sessionID: id)
        if fresh?.bullets != app.sessions[idx].bulletSummary?.bullets {
            app.sessions[idx].bulletSummary = fresh
        }
    }

    // MARK: - Memory across visits

    private func restoreMemory() {
        let m = app.sessionsPageMemory
        guard m.projectPath == app.activePath else { return }
        state.selection = m.selection
        state.primaryID = m.primaryID
        state.anchorID = m.primaryID
        state.expanded = m.expanded
        state.query = m.search
        state.timeFilter = m.timeFilter
        state.worktreeFilter = m.worktreeFilter
        if let id = m.primaryID, app.focusSessionID == nil {
            DispatchQueue.main.async { state.scrollRequest = .init(id: id, center: true) }
        }
    }

    private func saveMemory() {
        app.sessionsPageMemory = SessionsPageMemory(
            projectPath: app.activePath, selection: state.selection, primaryID: state.primaryID,
            expanded: state.expanded, search: state.query, timeFilter: state.timeFilter,
            worktreeFilter: state.worktreeFilter)
    }

    // MARK: - Detail card (right, wide)

    @ViewBuilder private var detailCard: some View {
        GlassCard {
            let selected = app.sessions.filter { state.selection.contains($0.id) }
            if selected.count > 1 {
                SessionSelectionPanel(
                    sessions: selected, context: context,
                    onAssign: { gid, key in app.assignSessions(selected.map(\.id), to: gid, key: key) },
                    onNewGroup: {
                        prefs.tab = .groups
                        state.newGroup = .init(key: selected[0].groupKey, sessionIDs: selected.map(\.id))
                    },
                    onUngroup: { app.unassignSessions(selected.map(\.id)) },
                    onTrash: { state.pendingTrash = selected.filter { !context.status(of: $0).isLive } },
                    onOpen: { s in state.select(s.id); state.scrollRequest = .init(id: s.id, center: false) },
                    onClear: { if let p = state.primaryID { state.select(p) } }
                )
                .padding(20)
            } else if let id = state.primaryID {
                if let (parent, sub) = resolveSubagent(id) {
                    SessionDetailView(
                        app: app,
                        summary: subagentAsSummary(sub),
                        parentSummary: parent,
                        onOpenSubagent: { tapped in
                            state.expanded.insert(parent.id)
                            state.select(SessionListModel.subagentID(parent: parent.id, sub: tapped.id))
                        },
                        onBack: { state.select(parent.id) }
                    )
                    .id(id)
                    .padding(16)
                } else if let s = app.sessions.first(where: { $0.id == id }) {
                    SessionDetailView(
                        app: app,
                        summary: s,
                        onOpenSubagent: { sub in
                            state.expanded.insert(s.id)
                            state.select(SessionListModel.subagentID(parent: s.id, sub: sub.id))
                        }
                    )
                    .id(s.id)
                    .padding(16)
                } else {
                    EmptyState("Select a session")
                }
            } else {
                EmptyState(app.sessions.isEmpty ? "No sessions yet" : "Select a session")
            }
        }
    }

    // MARK: Helpers

    private func resolveSubagent(_ selectionID: String) -> (SessionSummary, SubagentSummary)? {
        guard selectionID.contains("/") else { return nil }
        let parts = selectionID.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let parentID = String(parts[0])
        let subID = String(parts[1])
        guard let parent = app.sessions.first(where: { $0.id == parentID }),
              let sub = parent.subagents.first(where: { $0.id == subID }) else { return nil }
        return (parent, sub)
    }

    private func subagentAsSummary(_ sub: SubagentSummary) -> SessionSummary {
        SessionSummary(
            id: sub.id,
            fileURL: sub.fileURL,
            projectSlug: "",
            title: sub.description.isEmpty ? sub.agentType : sub.description,
            modifiedAt: Date(timeIntervalSince1970: 0),
            turnCount: 0,
            isActive: false,
            subagents: []
        )
    }
}
