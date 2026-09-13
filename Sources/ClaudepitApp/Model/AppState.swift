import Foundation
import Combine
import AppKit
import ClaudepitCore

enum Section: String, CaseIterable, Identifiable {
    case home, sessions, plans, specs, memory, claudeMd, plugins, skills, commands, agents, mcp, rules, hooks, loops, worktrees, tasks, settings, appConfig

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .mcp: return "MCP Servers"
        case .skills: return "Skills"
        case .commands: return "Commands"
        case .agents: return "Agents"
        case .rules: return "Rules"
        case .hooks: return "Hooks"
        case .loops: return "Loops"
        case .worktrees: return "Worktrees"
        case .tasks: return "Tasks"
        case .plugins: return "Plugins"
        case .settings: return "Settings"
        case .sessions: return "Sessions"
        case .plans: return "Plans"
        case .specs: return "Specs"
        case .memory: return "Memory"
        case .claudeMd: return "CLAUDE.md"
        case .appConfig: return "App Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .mcp: return "server.rack"
        case .skills: return "wand.and.stars"
        case .commands: return "terminal"
        case .agents: return "person.2"
        case .rules: return "text.badge.checkmark"
        case .hooks: return "link"
        case .loops: return "arrow.trianglehead.2.clockwise"
        case .worktrees: return "arrow.triangle.branch"
        case .tasks: return "checklist"
        case .plugins: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        case .sessions: return "clock.arrow.circlepath"
        case .plans: return "doc.text"
        case .specs: return "doc.badge.gearshape"
        case .memory: return "point.3.filled.connected.trianglepath.dotted"
        case .claudeMd: return "doc.plaintext"
        case .appConfig: return "gearshape.2"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var activePath: URL? {
        didSet { UserDefaults.standard.set(activePath?.path, forKey: "activePath") }
    }
    @Published var recentPaths: [URL] = [] {
        didSet { UserDefaults.standard.set(recentPaths.map(\.path), forKey: "recentPaths") }
    }
    @Published var selected: Section = .home {
        didSet {
            if selected != oldValue {
                selectedSessionID = nil
                selectedPlanName = nil
                selectedMemoryTitle = nil
                // Clear cross-section crumb when navigating away from plans
                if oldValue == .plans {
                    breadcrumbSessionCrumb = nil
                    breadcrumbSessionID = nil
                }
            }
        }
    }
    @Published var pendingHighlight: HighlightTarget?
    @Published var focusPluginID: String?   // set to jump the Plugins page to a specific plugin
    @Published var focusPlanPath: String?   // set to jump the Plans page to a specific plan
    @Published var plansChangeToken: Int = 0
    @Published var focusSpecPath: String?   // set to jump the Specs page to a specific spec
    @Published var returnToSpecTaskID: String? // set before a spec deep-link so SpecDetailView can offer "Back to task"
    @Published var focusClaudeMdPath: String? // set to jump the CLAUDE.md page to a specific file
    @Published var claudeMdChangeToken: Int = 0
    @Published var tasksChangeToken: Int = 0
    @Published var focusSessionID: String?  // set to jump the Sessions page to a specific session
    @Published var focusManagedConfigID: String? // set to jump App Settings to a specific managed config
    @Published var focusTaskID: String?      // set to jump the Tasks page to a specific task
    @Published var returnToTaskID: String?   // set before a plan deep-link so PlanDetailView can offer "Back to task"
    /// One-shot intents Home hands to a section along with `selected`. Same contract as the
    /// focus fields above: the consuming section clears them.
    @Published var openNewTaskPanel = false            // TasksSection → opens its New Task panel
    @Published var openDiscoverSheet = false           // SessionsSection → presents Discover
    @Published var focusTaskStatusFilter: TaskStatus?  // TasksSection → preselects Status
    @Published var focusTaskPhase: TaskPhase?          // TasksSection → preselects Phase
    @Published var herdrSessions: [String: Herdr.AgentEntry] = [:]
    /// Every live herdr agent, session-bound or not. Task agents report no `agent_session`, so
    /// `herdrSessions` (keyed by session id) never contains them — the Tasks board reads this.
    @Published var herdrAgents: [Herdr.AgentEntry] = []
    /// Cached `claude auth status`. nil until the first check finishes — views render
    /// nothing while it's nil rather than flashing a banner on every launch.
    /// Deliberately a *stored* value: resolving it needs a subprocess, and a `Process`
    /// reached from a SwiftUI view body aborts the app (see `Herdr.available()`'s note).
    @Published private(set) var claudeAuth: ClaudeAuthStatus?
    @Published private(set) var isCheckingClaudeAuth = false
    /// Set when a sign-in launch found no herdr to run it in, so the UI can fall back
    /// to handing the user the command instead.
    @Published var signInNeedsTerminal = false
    private var lastClaudeAuthCheck: Date?
    /// The Claude CLI's own cached usage numbers, read from its local caches. Stored here rather
    /// than in `HomeSection` because a section's `@State` dies on every section switch, which
    /// would re-trigger the load and orphan an in-flight refresh.
    @Published private(set) var usageSnapshot: UsageSnapshot?
    @Published private(set) var statsSnapshot: StatsSnapshot?
    /// Parsed contributing-insights from the last successful print-mode `/usage` run — loaded
    /// from the app-owned report cache on launch, since the text exists only as subprocess output.
    @Published private(set) var usageReport: UsageReport?
    /// `claude --version`, resolved once per launch. Stored for the same reason as `claudeAuth`:
    /// a subprocess must never be reachable from a view body.
    @Published private(set) var claudeVersion: String?
    @Published private(set) var isRefreshingUsage = false
    private var lastUsageRefreshAttempt: Date?
    @Published var worktrees: [WorktreeInfo] = []
    @Published var focusWorktreeName: String?   // set to jump the Worktrees page to a specific worktree
    @Published var autoOpenReviewWorktree: String?   // one-shot: auto-present a worktree's Source Control sheet after focusing
    @Published var worktreeLastCommit: [String: (hash: String, subject: String)] = [:]
    /// When the worktree scan last ran a `git fetch` for the base branch. Not published — no
    /// view reads it. The scan runs on every FileWatcher tick, so without this throttle a
    /// network call would fire every few seconds while a task agent writes its transcript.
    private var lastBaseFetch: Date?
    /// One-shot: a worktree path whose Update-from-base should auto-start when its
    /// `TaskDetailView` appears. Set by the board card's behind pill, consumed and cleared by
    /// `UpdateFromBaseControl` — the documented focus-field contract.
    @Published var pendingWorktreeUpdatePath: String?
    @Published var sessions: [SessionSummary] = []
    @Published var loops: [CronEntry] = []
    @Published var tasks: [ProjectTask] = []
    /// Task specs/plans that exist on disk, stamped with their mtime. Cached here rather than
    /// stat-ed from a view body — Home's activity feed reads it on every render.
    @Published var taskArtifacts: [TaskArtifact] = []
    /// The Plans/Specs/Memory pages' own listings, mtime-stamped for Home's activity feed —
    /// whatever those pages show appears in Recent. Cached for the same reason as above.
    @Published var planFiles: [PageFile] = []
    @Published var specFiles: [PageFile] = []
    @Published var memoryFiles: [PageFile] = []
    @Published var memoryGraph: MemoryGraph = .empty
    @Published var memoryLog: [MemoryLogEntry] = []
    @Published var selectedSessionID: String?
    @Published var selectedPlanName: String?
    @Published var selectedMemoryTitle: String?
    @Published var focusMemoryFileID: String?
    @Published var breadcrumbSessionCrumb: String?   // set when navigating to Plans from a session
    @Published var breadcrumbSessionID: String?      // session ID to restore when tapping back
    @Published var memoryEnabled: Bool = true {
        didSet {
            guard !isInitializing, memoryEnabled != oldValue, let base = activePath else { return }
            appConfig.setEnabled(base, "memory-hook", memoryEnabled)
            appConfig.setEnabled(base, "memory-system-prompt", memoryEnabled)
            syncManagedConfigs()
        }
    }
    private var isInitializing = true
    let store = ConfigStore()
    let appConfig = AppConfigStore()
    private var watcher: FileWatcher?
    private var sessionLoadTask: Task<Void, Never>?
    /// Live-agent poll, running only while some task is in flight — see `syncTaskPolling()`.
    private var taskPollTimer: Timer?

    init() {
        // Restore persisted paths before reload so sessions/memory load correctly
        if let paths = UserDefaults.standard.stringArray(forKey: "recentPaths") {
            recentPaths = paths.map { URL(filePath: $0) }
        }
        if let p = UserDefaults.standard.string(forKey: "activePath") {
            activePath = URL(filePath: p)
            appConfig.seedIfNeeded(URL(filePath: p))
            memoryEnabled = appConfig.isEnabled(URL(filePath: p), "memory-hook")
        }
        reload()
        migrateMemoryEnabledIfNeeded()
        // Installers run on setActivePath (project switch), but that never fires on cold launch —
        // so app-owned command/hook files (and, for a restored project, its memory hooks) would stay
        // stale until the user re-selects the project. Run them here too so source edits land on launch.
        installGlobalArtifacts()
        // The CLI's version can't change while the app runs, so once per launch is enough.
        Task { [weak self] in
            let version = await ClaudeVersion.fetch()
            self?.claudeVersion = version
        }
        // A `claude -p` call that comes back "Not logged in" is the authoritative
        // signal, wherever it happened. Observing a notification keeps the eight
        // scattered Q&A surfaces from each having to hold an AppState reference.
        NotificationCenter.default.addObserver(
            forName: .claudeAuthSuspect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClaudeAuth(force: true) }
        }
        isInitializing = false
    }

    /// App-owned files that must exist regardless of which project is active + this-project hooks.
    /// Called from both `init()` (cold launch) and `setActivePath` (project switch).
    private func installGlobalArtifacts() {
        ManagedInstaller.migrateSummariesIfNeeded()
        ManagedInstaller.migrateTaskCommandLocationsIfNeeded()
        if let base = activePath { appConfig.seedIfNeeded(base) }
        syncManagedConfigs()
    }

    /// Install-when-on / remove-when-off for every managed config, reading content from AppConfigStore.
    func syncManagedConfigs() {
        guard let base = activePath else { return }
        ManagedInstaller(appConfig: appConfig, base: base).sync()
    }

    // MARK: - App Settings page pass-throughs

    func setConfigEnabled(_ id: String, _ on: Bool) {
        guard let base = activePath else { return }
        appConfig.setEnabled(base, id, on)
        if id == "memory-hook" || id == "memory-system-prompt" {
            memoryEnabled = appConfig.isEnabled(base, "memory-hook")
        }
        syncManagedConfigs()
    }

    func resetConfig(_ c: ManagedConfig) {
        guard let base = activePath else { return }
        try? appConfig.resetToDefault(base, c)
        syncManagedConfigs()
    }

    func setCleanupDays(_ days: Int) {
        guard let base = activePath else { return }
        appConfig.setCleanupPeriodDays(base, days)
        syncManagedConfigs()
    }

    func setActivePath(_ url: URL) {
        activePath = url
        appConfig.seedIfNeeded(url)
        isInitializing = true
        memoryEnabled = appConfig.isEnabled(url, "memory-hook")
        isInitializing = false
        recentPaths.removeAll { $0 == url }
        recentPaths.insert(url, at: 0)
        recentPaths = Array(recentPaths.prefix(8))
        reload()
        restartWatching()
        installGlobalArtifacts()
    }

    func clearPath() {
        activePath = nil
        memoryEnabled = true
        reload()
        restartWatching()
    }

    // MARK: - claude CLI auth

    /// Refresh the cached auth state. Fire-and-forget, coalesced, and throttled so the
    /// ~260 ms subprocess runs about once per launch in the healthy case.
    ///
    /// Not called from `setActivePath`: auth is machine-global (it lives in the
    /// keychain), so re-checking on every project switch buys nothing.
    func refreshClaudeAuth(force: Bool = false) {
        guard !isCheckingClaudeAuth else { return }
        if !force, claudeAuth?.isLoggedIn == true, let last = lastClaudeAuthCheck,
           Date().timeIntervalSince(last) < 60 { return }
        isCheckingClaudeAuth = true
        Task { [weak self] in
            let status = await ClaudeAuth.status()
            await MainActor.run {
                self?.claudeAuth = status
                self?.lastClaudeAuthCheck = Date()
                self?.isCheckingClaudeAuth = false
                if status.isLoggedIn { self?.signInNeedsTerminal = false }
            }
        }
    }

    /// Open `claude auth login` in a herdr tab. Falls back to `signInNeedsTerminal`
    /// when herdr isn't installed — there is no in-app terminal to run it in.
    func signInToClaude() {
        let cwd = activePath?.path ?? NSHomeDirectory()
        Task { [weak self] in
            let launched = await ClaudeAuth.signIn(cwd: cwd)
            await MainActor.run { self?.signInNeedsTerminal = !launched }
        }
    }

    /// Fallback affordance: put the command on the clipboard and open Terminal, which
    /// needs no entitlement. Deliberately not AppleScript — typing into Terminal needs
    /// Automation access and a TCC prompt, and this app ships as a bare executable.
    func copySignInCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ClaudeAuth.signInCommand, forType: .string)
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Terminal.app"))
    }

    // MARK: - Usage & limits

    /// How old a cached snapshot may get before Home auto-refreshes it, and the floor between two
    /// auto attempts — so a CLI that fails every time still costs one subprocess per 15 minutes.
    private static let usageMaxAge: TimeInterval = 900

    /// Re-read both CLI caches (`~/.claude.json`, `stats-cache.json`) off the main actor.
    ///
    /// Deliberately not wired into the `FileWatcher`: its single debounced handler runs the full
    /// `reload()`, and the CLI rewrites `~/.claude.json` constantly — that pairing is a reload storm.
    ///
    /// `thenRefreshIfStale` chains the staleness check onto the *loaded* snapshot. Calling the two
    /// back to back instead would test the previous value — nil on a cold launch — and spawn a
    /// `/usage` subprocess on every first visit to Home even when the CLI's cache is minutes old.
    func reloadUsageCaches(thenRefreshIfStale: Bool = false) {
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                (snapshot: UsageSnapshot.load(),
                 stats: StatsCache.loadSnapshot(),
                 report: UsageReportCache.load().map { UsageReport.parse($0.text) })
            }.value
            guard let self else { return }
            self.usageSnapshot = loaded.snapshot
            self.statsSnapshot = loaded.stats
            // Keep the last good insights over a parse of nothing — the cache file only exists
            // after a successful refresh, so nil here just means "not fetched yet this machine".
            if let report = loaded.report, !report.isEmpty { self.usageReport = report }
            if thenRefreshIfStale { self.refreshUsageIfStale() }
        }
    }

    /// The menu bar panel's entry point — deliberately *not* a reload.
    ///
    /// Opening the panel must be free: it renders whatever `usageSnapshot` already holds, and the
    /// only work here is the work Home would have done anyway. The caches are read once when they
    /// have never been read at all (the panel can be opened before Home is ever visited, and on a
    /// cold launch the snapshot would otherwise be nil); after that this falls through to the same
    /// staleness guards, so opening the panel ten times in a row costs no disk read and no
    /// subprocess until the numbers are actually 15 minutes old.
    func ensureUsageLoaded() {
        if usageSnapshot == nil {
            reloadUsageCaches(thenRefreshIfStale: true)
        } else {
            refreshUsageIfStale()
        }
    }

    /// Silent auto-refresh for Home's `.onAppear`. Every guard exists to stop a `claude`
    /// subprocess firing on each visit: nothing in flight, the cache actually old, no attempt
    /// within the window, and a login to attempt it with.
    func refreshUsageIfStale() {
        guard !isRefreshingUsage, claudeAuth?.needsSignIn != true else { return }
        if let last = lastUsageRefreshAttempt,
           Date().timeIntervalSince(last) < Self.usageMaxAge { return }
        guard usageSnapshot?.isStale(maxAge: Self.usageMaxAge) ?? true else { return }
        Task { [weak self] in _ = await self?.refreshUsage() }
    }

    /// Manual refresh. Returns the raw `/usage` report so the caller can show it; a successful run
    /// is also what rewrites the two caches, hence the unconditional re-read.
    @discardableResult
    func refreshUsage() async -> UsageRunner.Result {
        isRefreshingUsage = true
        lastUsageRefreshAttempt = Date()
        let result = await UsageRunner.refresh(cwd: activePath)
        isRefreshingUsage = false
        // Core can't name an App-module notification, so the runner reports the fact and the
        // conversion happens here (same split as DiscoverRunner's signedOut flag).
        if result.signedOut { NotificationCenter.default.post(name: .claudeAuthSuspect, object: nil) }
        if !result.failed {
            let parsed = UsageReport.parse(result.text)
            if !parsed.isEmpty {
                usageReport = parsed
                let text = result.text
                Task.detached(priority: .utility) {
                    UsageReportCache.save(text: text, fetchedAt: Date())
                }
            }
        }
        reloadUsageCaches()
        return result
    }

    func reload() {
        store.reload(activePath: activePath)
        reloadSessions()
        reloadMemory()
        loadTasks()
        reloadPlanFiles()
        driveBlockedTasks()
        driveRunningTasks()
        plansChangeToken += 1
        restartWatching()
    }

    func reloadSessions() {
        let path = activePath
        sessionLoadTask?.cancel()
        sessionLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = SessionScanner().list(activePath: path)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.sessions = result
                self.reloadWorktrees()
            }
        }
        refreshHerdrAgents()
    }

    /// Re-read `herdr agent list` into both projections: `herdrSessions` (keyed by Claude session
    /// id, for the Sessions/Worktrees rows) and `herdrAgents` (every agent, including the task
    /// agents that carry no session id at all — see `Herdr.AgentEntry`).
    func refreshHerdrAgents() {
        Task { [weak self] in
            let entries = await Herdr.agentList()
            let map = Dictionary(entries.compactMap { e in e.sessionID.map { ($0, e) } },
                                 uniquingKeysWith: { a, _ in a })
            await MainActor.run {
                self?.herdrSessions = map
                self?.herdrAgents = entries
            }
        }
    }

    /// Read-only worktree scan for the active project, merged with the just-loaded sessions.
    /// Git I/O runs off the main actor (Sendable RawScan); the session merge runs on main.
    ///
    /// `forceFetch: true` is for an explicit user gesture (the Worktrees refresh button) and
    /// bypasses the 300 s throttle — the user asked for the latest base. Every other call site
    /// (the FileWatcher-driven `reloadSessions()`, `onAppear`, the worktree-cleanup refresh,
    /// `deleteTask`) keeps the default and is throttled. The timestamp is stamped HERE, on the
    /// main actor, before the scan is awaited, so two overlapping reloads never both fetch.
    func reloadWorktrees(forceFetch: Bool = false) {
        let now = Date()
        let fetch = forceFetch || GitBase.shouldFetch(last: lastBaseFetch, now: now, interval: 300)
        if fetch { lastBaseFetch = now }
        let path = activePath
        Task { [weak self] in
            // A plain `await`, no `Task.detached`: `scanRaw` is a nonisolated async method on a
            // Sendable struct and every git call inside it goes through `Subprocess`, which hops
            // to `DispatchQueue.global()` itself. Nothing blocks the main actor, and — unlike the
            // `Task.detached` this replaced — nothing occupies a cooperative-pool thread either.
            let raw = await WorktreeScanner().scanRaw(activePath: path, fetchBase: fetch)
            guard let self, let raw else { self?.worktrees = []; return }
            self.worktrees = WorktreeScanner.merge(
                parsed: raw.parsed, dirty: raw.dirty, trackedDirty: raw.trackedDirty,
                ahead: raw.ahead, behind: raw.behind,
                merging: raw.mergeInProgress, conflicted: raw.conflicted,
                baseBranch: raw.baseBranch, baseRef: raw.baseRef,
                sessions: self.sessions, cwdMap: raw.cwdMap)
            let activePaths = Set(self.worktrees.map { $0.path })
            self.worktreeLastCommit = self.worktreeLastCommit.filter { activePaths.contains($0.key) }
        }
    }

    func reloadLoops() {
        loops = CronStore.load(activePath: activePath)
    }

    func addLoop(interval: String, prompt: String) throws {
        _ = try CronRunner.create(interval: interval, prompt: prompt, cwd: activePath)
        reloadLoops()
    }

    func deleteLoop(_ entry: CronEntry) {
        try? CronStore.delete(id: entry.id, sourcePath: entry.sourcePath)
        reloadLoops()
    }

    func reloadMemory() {
        guard let base = activePath else {
            memoryGraph = .empty; memoryLog = []; memoryFiles = []; return
        }
        let slug = Paths.slug(for: base)
        memoryGraph = MemoryLoader.load(projectSlug: slug)
        memoryLog = MemoryLog.load(projectSlug: slug)
        // The Memory page shows the graph, so the feed mirrors its nodes — not a directory
        // scan. MEMORY.md (the root) is excluded: the index moves on nearly every write and
        // would pin a permanent noise row to the top of Recent.
        memoryFiles = memoryGraph.nodes.filter { !$0.isRoot }.compactMap { node in
            fileModifiedAt(node.url.path).map {
                PageFile(path: node.url.path, name: node.title, date: $0)
            }
        }
    }

    /// Every plan the Plans page lists (`~/.claude/plans/*.md` — plan mode's global output,
    /// deliberately NOT project-scoped, exactly like the page), mtime-stamped for the feed.
    func reloadPlanFiles() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Paths.plansRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        planFiles = items.filter { $0.pathExtension == "md" }.compactMap { url in
            fileModifiedAt(url.path).map {
                PageFile(path: url.path, name: url.deletingPathExtension().lastPathComponent, date: $0)
            }
        }
    }

    private func fileModifiedAt(_ path: String) -> Date? {
        (try? URL(filePath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    func loadTasks() {
        guard let base = activePath else {
            tasks = []; taskArtifacts = []; specFiles = []; return
        }
        let slug = Paths.slug(for: base)
        var loaded = TaskStore.shared.loadAll(projectSlug: slug)
        // Brainstorm hand-off: the phase runs in herdr and writes a YAML deliverable. Parse it on load
        // and merge new suggestions by id, preserving any already-accepted/dismissed decisions.
        for i in loaded.indices {
            healArtifactLinks(into: &loaded[i], projectSlug: slug)
            mergeBrainstormSuggestions(into: &loaded[i], projectSlug: slug)
        }
        tasks = loaded
        taskArtifacts = collectTaskArtifacts(tasks: loaded) { fileModifiedAt($0) }
        reloadSpecFiles(projectSlug: slug, tasks: loaded)
        tasksChangeToken += 1
        syncTaskPolling()
    }

    /// Every spec the Specs page lists (`tasks/*/spec.md` on disk — including orphaned task
    /// folders whose task.json is gone, which `links.specPath` can never reach), named like the
    /// page names them: the task's name, falling back to the folder name.
    private func reloadSpecFiles(projectSlug slug: String, tasks loaded: [ProjectTask]) {
        let nameByID = Dictionary(loaded.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let taskDirs = (try? FileManager.default.contentsOfDirectory(
            at: Paths.tasksRoot(projectSlug: slug),
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles)) ?? []
        specFiles = taskDirs.compactMap { dir in
            let spec = dir.appendingPathComponent("spec.md")
            return fileModifiedAt(spec.path).map {
                PageFile(path: spec.path,
                         name: nameByID[dir.lastPathComponent] ?? dir.lastPathComponent,
                         date: $0)
            }
        }
    }

    /// An agent working in a herdr pane produces no file-system event of its own, so the
    /// FileWatcher alone can leave a running task's card stale for minutes. Poll herdr while —
    /// and only while — some task is actually in flight; idle projects cost nothing.
    private func syncTaskPolling() {
        let active = tasks.contains { $0.status == .running || $0.status == .blocked }
        if active {
            guard taskPollTimer == nil else { return }
            taskPollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshHerdrAgents()
                    self.driveRunningTasks()
                    self.driveBlockedTasks()
                }
            }
        } else {
            taskPollTimer?.invalidate()
            taskPollTimer = nil
        }
    }

    /// Adopt any phase deliverable sitting on disk that the record never recorded — a phase the
    /// runner landed before the file was written, or one that finished while the app was closed,
    /// otherwise leaves e.g. `specPath` nil and the detail view's "Review spec" button disabled for
    /// a spec.md that plainly exists. Persists only when something was actually filled in.
    private func healArtifactLinks(into task: inout ProjectTask, projectSlug: String) {
        guard let healed = TaskTransition.healArtifactLinks(task, projectSlug: projectSlug) else { return }
        task = healed
        let links = healed.links
        try? TaskStore.shared.update(id: task.id, projectSlug: projectSlug) {
            $0.links.brainstormPath = $0.links.brainstormPath ?? links.brainstormPath
            $0.links.specPath = $0.links.specPath ?? links.specPath
            $0.links.reviewPath = $0.links.reviewPath ?? links.reviewPath
        }
    }

    /// Parse `brainstorm.yaml` (if present) and add any suggestions whose id isn't already tracked.
    /// Persists via TaskStore.update only when something new was added — no clobbering of decisions.
    private func mergeBrainstormSuggestions(into task: inout ProjectTask, projectSlug: String) {
        guard let path = task.links.brainstormPath,
              let yaml = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { return }
        let parsed = TaskTransition.parseBrainstormSuggestions(from: yaml)
        guard !parsed.isEmpty else { return }
        var existing = task.links.brainstormSuggestions
        let known = Set(existing.map { $0.id })
        let added = parsed.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        existing.append(contentsOf: added)
        task.links.brainstormSuggestions = existing
        try? TaskStore.shared.update(id: task.id, projectSlug: projectSlug) { $0.links.brainstormSuggestions = existing }
    }

    /// Accept a brainstorm suggestion: apply it to the task (requirement/description/tag) and mark accepted.
    func acceptBrainstormSuggestion(_ task: ProjectTask, _ suggestion: BrainstormSuggestion) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { t in
            switch suggestion.kind {
            case .requirement: if !t.requirements.contains(suggestion.value) { t.requirements.append(suggestion.value) }
            case .description: t.description = suggestion.value
            case .tag:         if !t.tags.contains(suggestion.value) { t.tags.append(suggestion.value) }
            }
            if let i = t.links.brainstormSuggestions.firstIndex(where: { $0.id == suggestion.id }) {
                t.links.brainstormSuggestions[i].accepted = true
            }
        }
        loadTasks()
    }

    /// Dismiss a brainstorm suggestion: mark it rejected without applying it.
    func dismissBrainstormSuggestion(_ task: ProjectTask, _ suggestion: BrainstormSuggestion) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { t in
            if let i = t.links.brainstormSuggestions.firstIndex(where: { $0.id == suggestion.id }) {
                t.links.brainstormSuggestions[i].accepted = false
            }
        }
        loadTasks()
    }

    /// Apply one field of the brainstorm compare-pane draft onto main, then mark every pending
    /// suggestion of the corresponding kind(s) as accepted (they've been folded into main).
    func acceptBrainstormField(_ task: ProjectTask, _ draft: TaskVersion, _ field: VersionField) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        let kinds = Self.kinds(for: field)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { t in
            t.applyField(field, from: draft)
            for i in t.links.brainstormSuggestions.indices where t.links.brainstormSuggestions[i].accepted == nil
                && kinds.contains(t.links.brainstormSuggestions[i].kind) {
                t.links.brainstormSuggestions[i].accepted = true
            }
        }
        loadTasks()
    }

    /// Adopt the whole brainstorm proposal: apply all edited fields to main and clear all pending.
    func acceptAllBrainstorm(_ task: ProjectTask, _ draft: TaskVersion) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { t in
            t.name = draft.name; t.topic = draft.topic; t.description = draft.description
            t.requirements = draft.requirements; t.priority = draft.priority
            t.tags = draft.tags; t.dependsOn = draft.dependsOn
            for i in t.links.brainstormSuggestions.indices where t.links.brainstormSuggestions[i].accepted == nil {
                t.links.brainstormSuggestions[i].accepted = true
            }
        }
        loadTasks()
    }

    /// Dismiss every pending brainstorm suggestion.
    func dismissAllBrainstorm(_ task: ProjectTask) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { t in
            for i in t.links.brainstormSuggestions.indices where t.links.brainstormSuggestions[i].accepted == nil {
                t.links.brainstormSuggestions[i].accepted = false
            }
        }
        loadTasks()
    }

    /// Which brainstorm kinds feed a given version field.
    private static func kinds(for field: VersionField) -> Set<BrainstormSuggestion.Kind> {
        switch field {
        case .requirements: return [.requirement]
        case .description:  return [.description]
        case .tags:         return [.tag]
        default:            return []
        }
    }

    // MARK: - Task versions (backlog-only)

    /// Save a new suggestion draft onto a backlog task.
    func saveSuggestion(_ task: ProjectTask, _ v: TaskVersion) {
        guard let base = activePath, task.status == .backlog else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) {
            $0.suggestions = ($0.suggestions ?? []) + [v]
        }
        loadTasks()
    }

    /// Replace an existing suggestion (edit-in-place) by id.
    func updateSuggestion(_ task: ProjectTask, _ v: TaskVersion) {
        guard let base = activePath, task.status == .backlog else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { t in
            guard var s = t.suggestions, let i = s.firstIndex(where: { $0.id == v.id }) else { return }
            s[i] = v; t.suggestions = s
        }
        loadTasks()
    }

    /// Copy one field from a suggestion onto the main version.
    func acceptField(_ task: ProjectTask, _ v: TaskVersion, _ field: VersionField) {
        guard let base = activePath, task.status == .backlog else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { $0.applyField(field, from: v) }
        loadTasks()
    }

    /// Promote a suggestion to the main version (old main kept as a suggestion).
    func promoteToMain(_ task: ProjectTask, _ v: TaskVersion) {
        guard let base = activePath, task.status == .backlog else { return }
        let slug = Paths.slug(for: base)
        let now = Date().timeIntervalSince1970
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { $0.promote(v, now: now) }
        loadTasks()
    }

    func deleteSuggestion(_ task: ProjectTask, id: String) {
        guard let base = activePath, task.status == .backlog else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { t in
            t.suggestions = (t.suggestions ?? []).filter { $0.id != id }
        }
        loadTasks()
    }

    func startTask(_ task: ProjectTask) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        Task { await TaskRunner.shared.start(task, projectSlug: slug, projectRoot: base) }
    }
    func retryTask(_ task: ProjectTask) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        Task { await TaskRunner.shared.retry(task, projectSlug: slug, projectRoot: base) }
    }
    func answerTask(_ task: ProjectTask, text: String) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        Task { await TaskRunner.shared.answer(task, projectSlug: slug, projectRoot: base, text: text) }
    }

    /// Poll each `.blocked` task's live herdr agent: the user replies directly in herdr, so nothing
    /// else moves the task off `.blocked`. Once the agent finishes, TaskRunner resolves it to
    /// `.awaitingReview` and rewrites task.json (the FileWatcher then reloads it). Called from `reload()`.
    private func driveBlockedTasks() {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        for task in tasks where task.status == .blocked && !driving.contains(task.id) {
            driving.insert(task.id)
            Task { [weak self] in
                await TaskRunner.shared.resolveBlocked(task, projectSlug: slug, projectRoot: base)
                await MainActor.run { _ = self?.driving.remove(task.id) }
            }
        }
    }

    /// Poll each `.running` task's live herdr agent. A hand-off phase (brainstorm) runs without
    /// `--wait`, so nothing else moves it off `.running`; neither does a `--wait` phase whose app
    /// was quit mid-run. TaskRunner lands it in `.blocked`/`.awaitingReview`/`.failed` and rewrites
    /// task.json (the FileWatcher then reloads it).
    private func driveRunningTasks() {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        for task in tasks where task.status == .running && !driving.contains(task.id) {
            driving.insert(task.id)
            Task { [weak self] in
                await TaskRunner.shared.resolveRunning(task, projectSlug: slug, projectRoot: base)
                await MainActor.run { _ = self?.driving.remove(task.id) }
            }
        }
    }

    /// Advance the task to its next planned phase (or mark done).
    func advanceTaskPhase(_ task: ProjectTask) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        Task { await TaskRunner.shared.advance(task, projectSlug: slug, projectRoot: base) }
    }

    /// Move a task onto a board column. Backlog/Done are status-only; a phase column inserts the
    /// phase into plannedPhases and runs it. Rejects when blocked by deps or already running.
    func moveTask(_ task: ProjectTask, toPhase phase: TaskPhase?) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        guard task.status != .running else { return }
        // Backlog
        guard let phase else {
            try? TaskStore.shared.update(id: task.id, projectSlug: slug) { $0.status = .backlog; $0.phase = nil }
            loadTasks(); return
        }
        guard TaskTransition.canRun(task, allTasks: tasks) else { return }
        guard !driving.contains(task.id) else { return }
        driving.insert(task.id)
        var t = task
        t.plannedPhases = TaskTransition.insertPhase(phase, into: t.plannedPhases)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { $0.plannedPhases = t.plannedPhases }
        Task {
            await TaskRunner.shared.run(t, phase: phase, projectSlug: slug, projectRoot: base)
            await MainActor.run { _ = self.driving.remove(task.id) }
        }
    }

    /// Mark a task done (Done column drop).
    func markTaskDone(_ task: ProjectTask) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        try? TaskStore.shared.update(id: task.id, projectSlug: slug) { $0.status = .done; $0.phase = nil }
        loadTasks()
    }

    func deleteTask(_ task: ProjectTask) {
        guard let base = activePath else { return }
        TaskStore.shared.delete(id: task.id, projectSlug: Paths.slug(for: base))
        loadTasks()
        if let wt = task.worktree {
            Task {
                _ = await WorktreeStager.remove(worktreePath: wt.path, force: true)
                await MainActor.run { self.reloadWorktrees() }
            }
        }
    }

    func openTaskInHerdr(_ task: ProjectTask, phase: TaskPhase) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        Task { await TaskRunner.shared.openInHerdr(task, phase: phase, projectSlug: slug, projectRoot: base) }
    }

    /// Spawn a dependent task from a review finding.
    func createTaskFromFinding(parent: ProjectTask, finding: ReviewFinding) {
        guard let base = activePath else { return }
        let slug = Paths.slug(for: base)
        let priority: Priority = {
            switch finding.severity {
            case "high": return .high
            case "med", "medium": return .normal
            default: return .low
            }
        }()
        var child = ProjectTask()
        child.name = finding.title
        child.description = finding.detail
        child.dependsOn = [parent.id]
        child.priority = priority
        child.plannedPhases = ProjectTask.defaultPhases.filter { $0 != .brainstorm }
        child.status = .backlog
        child.createdAt = Date().timeIntervalSince1970
        child.updatedAt = child.createdAt
        try? TaskStore.shared.save(child, projectSlug: slug)
        try? TaskStore.shared.update(id: parent.id, projectSlug: slug) { p in
            if let i = p.links.reviewFindings.firstIndex(where: { $0.id == finding.id }) {
                p.links.reviewFindings[i].spawnedTaskID = child.id
            }
        }
        loadTasks()
        focusTaskID = child.id
    }

    // Kanban re-run / drag guard against double-launch on watcher race.
    private var driving = Set<String>()

    func navigate(to sectionRaw: String, itemID: String) {
        guard let s = Section(rawValue: sectionRaw) else { return }
        selected = s
        pendingHighlight = HighlightTarget(sectionRaw: sectionRaw, itemID: itemID)
    }

    func handleStateFile() {
        guard let obj = try? JSONFile.readObject(Paths.stateFile) else { return }
        // Consume the state file — it's a one-shot command, not persistent config
        try? FileManager.default.removeItem(at: Paths.stateFile)
        let action = obj["action"] as? String
        if action == "set-path", let p = obj["path"] as? String {
            setActivePath(URL(filePath: p))
            return
        }
        if let action, action.hasPrefix("show-") {
            let name = String(action.dropFirst("show-".count))
            if let s = Section(rawValue: name) {
                selected = s
            }
        }
    }

    func startWatching() {
        restartWatching()
        // Honor a state file that was written before the app started
        // (e.g. /set-path run before launching, or app started after the command).
        handleStateFile()
    }

    private func restartWatching() {
        watcher?.stop()
        var paths = [Paths.globalSettings, Paths.globalLocalSettings, Paths.pluginsRoot, Paths.stateFile, Paths.projectsRoot, Paths.plansRoot, Paths.globalCommands]
        if let base = activePath {
            paths.append(Paths.projectClaude(base))
            let memDir = Paths.memoryDir(projectSlug: Paths.slug(for: base))
            if FileManager.default.fileExists(atPath: memDir.path) {
                paths.append(memDir)
            }
        }
        // Watch each project dir so new session files trigger a reload
        let projectDirs = (try? FileManager.default.contentsOfDirectory(
            at: Paths.projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        paths.append(contentsOf: projectDirs)
        // Watch subagents/ dirs so new subagent files trigger a reload immediately
        for projectDir in projectDirs {
            let sessionDirs = (try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for sessionDir in sessionDirs {
                let subagentsDir = sessionDir.appending(path: "subagents")
                if FileManager.default.fileExists(atPath: subagentsDir.path) {
                    paths.append(subagentsDir)
                }
            }
        }
        // Watch summary/ dirs so bullet summary updates trigger a live reload
        for projectDir in projectDirs {
            let summaryDir = projectDir.appending(path: "summary")
            if FileManager.default.fileExists(atPath: summaryDir.path) {
                paths.append(summaryDir)
            }
        }
        // Watch memory/ dirs so knowledge graph updates trigger a live reload
        for projectDir in projectDirs {
            let memDir = projectDir.appending(path: "memory")
            if FileManager.default.fileExists(atPath: memDir.path) {
                paths.append(memDir)
            }
        }
        // Watch tasks/ dirs and each task subdir so task.json updates trigger a live reload
        for projectDir in projectDirs {
            let tasksDir = projectDir.appending(path: "tasks")
            if FileManager.default.fileExists(atPath: tasksDir.path) {
                paths.append(tasksDir)
                let subs = (try? FileManager.default.contentsOfDirectory(
                    at: tasksDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                paths.append(contentsOf: subs)
            }
        }
        // Watch groups root so UI reacts when AI classifier writes group assignments
        if FileManager.default.fileExists(atPath: Paths.groupsRoot.path) {
            paths.append(Paths.groupsRoot)
        }
        if FileManager.default.fileExists(atPath: Paths.projectsRoot.path) {
            paths.append(Paths.projectsRoot)
        }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        watcher = FileWatcher(paths: existing) { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.handleStateFile()
            }
        }
        watcher?.start()
    }

    private func migrateMemoryEnabledIfNeeded() {
        guard let legacyValue = UserDefaults.standard.object(forKey: "memoryEnabled") as? Bool else { return }
        for path in recentPaths {
            ProjectPrefsStore.save(path, memoryEnabled: legacyValue)
        }
        // Remove global memory hooks from ~/.claude/settings.json
        let settingsURL = Paths.globalSettings
        if var settings = try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any],
           var hooks = settings["hooks"] as? [String: Any] {
            var changed = false
            for event in ["Stop", "StopFailure"] {
                guard let entries = hooks[event] as? [[String: Any]] else { continue }
                let (pruned, removed) = HookRegistration.prune(entries, scriptName: Paths.memoryHookScriptName)
                if removed > 0 {
                    hooks[event] = pruned.isEmpty ? nil : pruned
                    changed = true
                }
            }
            if changed {
                settings["hooks"] = hooks
                if let data = try? JSONSerialization.data(withJSONObject: settings,
                                                           options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: settingsURL)
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: "memoryEnabled")
    }
}

extension Notification.Name {
    /// Posted when a spawned `claude` reported a missing login, so `AppState` can
    /// re-check and surface the sign-in banner.
    static let claudeAuthSuspect = Notification.Name("claudepit.claudeAuthSuspect")
}
