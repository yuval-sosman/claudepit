import Foundation

public actor TaskRunner {
    public static let shared = TaskRunner()
    public init() {}

    public nonisolated static func herdrAvailable() -> Bool { Herdr.available() }

    /// Phase-scoped herdr agent name. A fresh name per phase (started in a fresh pane) guarantees
    /// a new Claude session, so phases don't share one conversation.
    public static func agentName(id: String, phase: TaskPhase?) -> String {
        "task-\(id)-\(phase?.commandName ?? "start")"
    }

    /// Task ids whose phase is mid-launch: pane opening, `agent start` retrying, prompt in flight.
    /// `resolveRunning` must ignore these — an agent that is up but has not yet received its prompt
    /// reports `idle`, which would otherwise be read as "the turn finished".
    private var launching: Set<String> = []

    /// Last `state_change_seq` acted on per agent name — lets the blocked poll skip the scrollback
    /// read while an agent sits unchanged at its prompt. See `seqChanged`.
    private var lastSeenSeq: [String: Int] = [:]

    /// Actor-side re-entrancy guard for `stepAutoRun`. `AppState.driving` is MainActor state and
    /// cannot protect a step kicked off from a button while a poller tick is already in flight.
    private var autoStepping: Set<String> = []


    // MARK: - Auto-run

    /// Advance one armed task by at most one step.
    ///
    /// This is the **sole owner** of an armed task: `AppState.driveRunningTasks`/`driveBlockedTasks`
    /// skip `autoRun == true`, so exactly one code path writes an armed task's status and two stale
    /// snapshots can never clobber each other. Because it owns the task it also does the landing
    /// work those pollers would have done.
    ///
    /// Safe to call every tick — it no-ops unless the task is actually ready to move. The phase
    /// launch itself blocks for the whole phase (`runPhase` waits up to 60 min), which is what
    /// paces the chain: every intervening tick finds the id in `autoStepping` and returns.
    public func stepAutoRun(_ task: ProjectTask, allTasks: [ProjectTask],
                            projectSlug: String, projectRoot: URL) async {
        guard task.isAutoRunning else { return }
        guard !launching.contains(task.id), !autoStepping.contains(task.id) else { return }
        autoStepping.insert(task.id)
        defer { autoStepping.remove(task.id) }

        // 1. Land whatever is in flight — the driveRunning/driveBlocked work, done here instead.
        switch task.status {
        case .running: await resolveRunning(task, projectSlug: projectSlug, projectRoot: projectRoot)
        case .blocked: await resolveBlocked(task, projectSlug: projectSlug, projectRoot: projectRoot)
        default: break
        }

        // 2. Re-read: those write through TaskStore, and the caller's copy came off a MainActor
        //    snapshot that may already be a tick old.
        guard let fresh = TaskStore.shared.load(id: task.id, projectSlug: projectSlug),
              fresh.isAutoRunning else { return }

        // 3. Decide.
        switch AutoRun.nextStep(fresh, allTasks: allTasks) {
        case .wait:
            return

        case .start(let phase):
            await runPhase(fresh, phase: phase, projectSlug: projectSlug, projectRoot: projectRoot)

        case .retry(let phase):
            // A `.failed` implement usually means the 60-minute wait expired — and a timed-out wait
            // does not stop the agent, which is very likely still working. Launching a second one
            // would put two Claudes in one checkout. Only retry when nothing is live.
            let name = Self.agentName(id: fresh.id, phase: phase)
            guard !(await agentExists(name)) else { return }
            // Spend the retry BEFORE launching, so a crash mid-retry cannot buy a second one.
            try? TaskStore.shared.update(id: fresh.id, projectSlug: projectSlug) {
                $0.autoRunRetried = ($0.autoRunRetried ?? []) + [phase]
            }
            guard let again = TaskStore.shared.load(id: fresh.id, projectSlug: projectSlug) else { return }
            await runPhase(again, phase: phase, projectSlug: projectSlug, projectRoot: projectRoot)

        case .finish:
            disarmAutoRun(fresh.id, projectSlug: projectSlug, reason: nil)

        case .halt(let why):
            disarmAutoRun(fresh.id, projectSlug: projectSlug, reason: why)
        }
    }

    /// Clear the armed flag and the retry budget. `reason == nil` means it finished normally.
    public func disarmAutoRun(_ id: String, projectSlug: String, reason: String?) {
        try? TaskStore.shared.update(id: id, projectSlug: projectSlug) {
            $0.autoRun = false
            $0.autoRunRetried = nil
            $0.autoRunHaltReason = reason
        }
    }


    // MARK: - Public API

    public func start(_ task: ProjectTask, projectSlug: String, projectRoot: URL) async {
        await runPhase(task, phase: task.phase, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Re-run the task's current phase.
    public func retry(_ task: ProjectTask, projectSlug: String, projectRoot: URL) async {
        await runPhase(task, phase: task.phase, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Run a specific phase (used by the Kanban drop / "Next phase").
    public func run(_ task: ProjectTask, phase: TaskPhase, projectSlug: String, projectRoot: URL) async {
        await runPhase(task, phase: phase, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Advance to the next planned phase, or mark done if none remains.
    public func advance(_ task: ProjectTask, projectSlug: String, projectRoot: URL) async {
        if let next = TaskTransition.nextPlannedPhase(after: task.phase, in: task.plannedPhases) {
            await runPhase(task, phase: next, projectSlug: projectSlug, projectRoot: projectRoot)
        } else {
            var t = task; t.status = .done; t.phase = nil
            t.updatedAt = Date().timeIntervalSince1970
            try? TaskStore.shared.save(t, projectSlug: projectSlug)
        }
    }

    /// Move a `.running` task on when its agent stops. Hand-off phases (`openInHerdr`, no `--wait`)
    /// have no observer at all, and a `--wait` phase whose app was quit mid-run is in the same
    /// position — without this poll they sit on `.running` forever.
    ///
    /// Claude reports `idle` when it finishes a turn and returns to its prompt (`done` is in
    /// herdr's status enum but the Claude detection manifest never emits it), so `idle`/`done`
    /// both mean "turn over". `blocked` means it is asking the user something. Anything else
    /// (`working`, `unknown`) means keep waiting. Called on each watcher tick / poll by AppState.
    public func resolveRunning(_ task: ProjectTask, projectSlug: String, projectRoot: URL) async {
        guard task.status == .running, !launching.contains(task.id) else { return }
        var t = task
        let name = Self.agentName(id: t.id, phase: t.phase)
        guard let obj = await herdr(["agent", "get", name], cwd: nil) else { return }  // herdr unreachable
        guard let status = agentStatus(obj) else {
            // herdr answered but knows no such agent (pane closed, herdr restarted). The phase
            // cannot still be running: land it on its deliverable if one exists, else fail it so
            // the UI offers Retry instead of spinning on a card that will never change.
            if let a = Self.expectedArtifact(t, projectSlug: projectSlug),
               FileManager.default.fileExists(atPath: a.path) {
                await landFinishedTurn(&t, projectSlug: projectSlug, projectRoot: projectRoot)
            } else {
                fail(&t, projectSlug)
            }
            return
        }
        switch status {
        case Herdr.AgentState.blocked:
            t.status = .blocked
            saveIfChanged(t, original: task, projectSlug: projectSlug)
        case Herdr.AgentState.idle, Herdr.AgentState.done:
            await landFinishedTurn(&t, projectSlug: projectSlug, projectRoot: projectRoot)
        default:
            break   // working / unknown — still in flight
        }
    }

    /// Recover a `.blocked` task — one whose agent stopped without finishing its phase, or that is
    /// sitting on a prompt in herdr. Nothing else moves it: the user replies in the pane, not here.
    ///
    /// The DELIVERABLE is checked first and needs no subprocess at all — it also still works when
    /// the agent is gone (herdr restarted, pane closed, stored pane/tab stale). Failing that, ask
    /// the live agent, and if its turn is over re-run the full landing (which reads the scrollback
    /// marker — the only way `createPlan`/`implement` can ever report done).
    /// Called on each FileWatcher tick / poll by AppState.
    public func resolveBlocked(_ task: ProjectTask, projectSlug: String, projectRoot: URL) async {
        guard task.status == .blocked, !launching.contains(task.id) else { return }
        var t = task
        if let artifact = Self.expectedArtifact(t, projectSlug: projectSlug),
           FileManager.default.fileExists(atPath: artifact.path) {
            switch t.phase {
            case .brainstorm: t.links.brainstormPath = artifact.path
            case .writeSpec:  t.links.specPath = artifact.path
            case .codeReview: t.links.reviewPath = artifact.path
            default: break
            }
            t.status = .awaitingReview
            t.updatedAt = Date().timeIntervalSince1970
            try? TaskStore.shared.save(t, projectSlug: projectSlug)
            return
        }
        // No on-disk deliverable yet (createPlan/implement never have one). Fall back to the agent.
        let name = Self.agentName(id: t.id, phase: t.phase)
        guard let obj = await herdr(["agent", "get", name], cwd: nil) else { return }  // herdr unreachable
        guard let status = agentStatus(obj) else {
            // herdr answered but knows no such agent (pane closed, herdr restarted). There is no
            // prompt left to reply to, so "blocked" would be a state the user can never clear —
            // fail it instead and let the card offer Retry. Mirrors `resolveRunning`.
            fail(&t, projectSlug)
            return
        }
        // The user answered in the pane and the agent picked the work back up. Nothing else moved
        // the task out of `.blocked` before this, so it kept reporting "needs you" for the whole
        // run — on the board, on Home, and in the menu bar — until the agent next went idle.
        // `.running` is what the answer path (`answer`) sets for exactly this reason.
        if status == Herdr.AgentState.working {
            t.status = .running
            saveIfChanged(t, original: task, projectSlug: projectSlug)
            return
        }
        guard status == Herdr.AgentState.idle || status == Herdr.AgentState.done else { return }
        // An agent idling at its prompt with nothing to show stays idle indefinitely, and this runs
        // every few seconds — so only pay for the scrollback read when herdr says something actually
        // changed since we last looked. `state_change_seq` moves on every status transition.
        guard seqChanged(obj, for: name) else { return }
        await landFinishedTurn(&t, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// True when this agent's `state_change_seq` differs from the last one we acted on (and records
    /// the new value). Missing seq → always true, so a herdr without it degrades to polling.
    private func seqChanged(_ obj: [String: Any], for name: String) -> Bool {
        guard let agent = (obj["result"] as? [String: Any])?["agent"] as? [String: Any],
              let seq = agent["state_change_seq"] as? Int else { return true }
        guard lastSeenSeq[name] != seq else { return false }
        lastSeenSeq[name] = seq
        return true
    }

    /// The deterministic deliverable path the current phase writes. See `TaskTransition`.
    private static func expectedArtifact(_ task: ProjectTask, projectSlug: String) -> URL? {
        TaskTransition.expectedArtifact(phase: task.phase, projectSlug: projectSlug, taskID: task.id)
    }

    public func answer(_ task: ProjectTask, projectSlug: String, projectRoot: URL, text: String) async {
        guard task.worktree?.paneID != nil else { return }
        var t = task
        // `defer`, not a bare remove after the wait: an early exit added here later would
        // otherwise park the id and `resolveRunning` would skip this task for good.
        launching.insert(t.id)
        defer { launching.remove(t.id) }
        t.status = .running
        t.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(t, projectSlug: projectSlug)
        let name = Self.agentName(id: t.id, phase: t.phase)
        await herdr(["agent", "prompt", name, text], cwd: projectRoot)
        let result = await waitForTurn(name, cwd: projectRoot, timeoutMS: "600000")
        // Held through `observe` (the `defer` above), matching `runPhase`: releasing it here let a
        // poller read the agent as `idle` and land the task while this observer was still writing.
        await observe(&t, promptResult: result, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Focus the task's tab and prompt without waiting — hands the phase off to the user in herdr.
    /// If the task's agent is ALREADY running, this only focuses its tab (navigate, don't re-prompt) —
    /// mirrors the Worktrees resume-session button, so repeated clicks don't spam the live session.
    public func openInHerdr(_ task: ProjectTask, phase: TaskPhase, projectSlug: String, projectRoot: URL) async {
        var t = task
        launching.insert(t.id)
        defer { launching.remove(t.id) }
        t.phase = phase
        let commands = Self.taskCommands(for: projectRoot)
        guard Self.commandAvailable(for: phase, task: t, in: commands) else {
            fail(&t, projectSlug); return
        }
        guard await ensureWorktree(&t, projectSlug: projectSlug, projectRoot: projectRoot,
                                   commands: commands) != nil else { return }
        // If the agent for this phase is already live, just focus it — don't re-prompt.
        // Focus by AGENT NAME first: the stored tabID is a snapshot taken when the pane was made
        // and goes stale on a herdr restart, at which point `tab focus` no-ops and the click looks
        // dead. Raising the terminal window is the app layer's half (`activateHerdrHost`).
        let name = Self.agentName(id: t.id, phase: phase)
        if await agentReady(name) {
            await HerdrFocus.focus(agentName: name, tabID: t.worktree?.tabID)
            return
        }
        // Fresh tab+pane+session (closes the previous phase's tab).
        guard let pane = await openPhaseTab(&t, phase: phase, projectSlug: projectSlug) else { return }
        // Hand-off: the agent runs interactively in herdr (no --wait, so we can't observe it here).
        // It IS running, so say so — `AppState.driveRunningTasks` polls the live agent and lands the
        // task in `.awaitingReview`/`.blocked` when it stops. Marking it awaitingReview up front (as
        // this used to) made every hand-off phase read "Waiting" for its entire run.
        t.status = .running
        // No observe() runs on a hand-off, so pin the deliverable path here (deterministic, matches
        // what phasePrompt passes the agent) — else AppState's merge + the UI file-exists check,
        // which both key off links.brainstormPath, never fire and the panel stays stuck.
        if phase == .brainstorm, t.links.brainstormPath == nil {
            t.links.brainstormPath = Paths.taskBrainstormFile(projectSlug: projectSlug, id: t.id).path
        }
        t.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(t, projectSlug: projectSlug)
        await startAgent(t, phase: phase, pane: pane, projectSlug: projectSlug, projectRoot: projectRoot, wait: false)
    }

    // MARK: - Task commands

    /// This project's task-command bodies: the user's editable copies under `claudepit-config/`,
    /// filtered by the enable toggles. `projectRoot` is the project base (every caller passes
    /// `activePath`), so nothing is reconstructed from the slug — `Paths.projectPath(for:)` is
    /// lossy for paths that contain hyphens.
    static func taskCommands(for projectRoot: URL) -> [(filename: String, body: String)] {
        ManagedInstaller(appConfig: AppConfigStore(), base: projectRoot).taskCommandBodies()
    }

    /// The task-command file a phase's prompt invokes as `/claudepit-task-<name>`.
    static func commandFilename(for phase: TaskPhase) -> String {
        "claudepit-task-\(phase.commandName).md"
    }

    /// The command a phase runs *for this task*. A fix task swaps `implement` for the
    /// findings-driven `fix` body: `implement` is written around "follow the plan at planPath",
    /// and a fix task has neither plan nor spec. Swapping the body rather than adding a sixth
    /// `TaskPhase` keeps the board columns, Home's pipeline and `expectedArtifact` untouched.
    static func commandFilename(for phase: TaskPhase, task: ProjectTask) -> String {
        if phase == .implement, task.isFixTask { return "claudepit-task-fix.md" }
        return commandFilename(for: phase)
    }

    /// Whether the command this task runs for `phase` is actually installed.
    static func commandAvailable(for phase: TaskPhase, task: ProjectTask,
                                 in commands: [(filename: String, body: String)]) -> Bool {
        commands.contains { $0.filename == commandFilename(for: phase, task: task) }
    }

    /// Whether the phase's slash-command is actually among the installed commands.
    ///
    /// `phasePrompt` emits `/claudepit-task-<name>` unconditionally, so a phase whose command the
    /// user switched off in App Settings hands the agent a command that exists nowhere — it then
    /// sits waiting instead of doing the work. Checked before any agent is started so the task
    /// lands in `.failed` and the Tasks UI says so, rather than hanging on a silent no-op.
    static func commandAvailable(for phase: TaskPhase,
                                 in commands: [(filename: String, body: String)]) -> Bool {
        commands.contains { $0.filename == commandFilename(for: phase) }
    }

    // MARK: - Worktree

    /// Reuse the task's worktree if it exists + is a valid git repo, else create one.
    private func ensureWorktree(_ task: inout ProjectTask, projectSlug: String, projectRoot: URL,
                                commands: [(filename: String, body: String)]) async -> TaskWorktree? {
        if let wt = task.worktree, FileManager.default.fileExists(atPath: wt.path),
           await gitOK(wt.path) {
            Self.installCommands(inWorktree: wt.path, commands: commands)   // self-heal worktrees created before this fix
            return wt
        }
        let branch = "task/\(task.id)-\(Self.kebab(task.name))"
        let base = await trunkBranch(projectRoot) ?? "main"
        // Pin the worktree under <project>/.claude/worktrees/ (the convention WorktreeScanner
        // scans + the slug that binds sessions to this project). Herdr's default location
        // (~/.herdr/worktrees/…) has a different slug, so those sessions never surface.
        let target = projectRoot.appending(path: ".claude/worktrees/task-\(task.id)-\(Self.kebab(task.name))").path
        guard let created = await Herdr.worktreeCreate(cwd: projectRoot, branch: branch, base: base, path: target, label: "task-\(task.id)")
        else {
            task.status = .failed; task.updatedAt = Date().timeIntervalSince1970
            try? TaskStore.shared.save(task, projectSlug: projectSlug)
            return nil
        }
        // Reuse the task's worktree if it exists + is a valid git repo, else create one.
        // Tab/pane are NOT owned here — each phase opens its own (see openPhaseTab).
        let wtPath = created.path
        Self.installCommands(inWorktree: wtPath, commands: commands)
        let wt = TaskWorktree(branch: branch, path: wtPath)
        task.worktree = wt
        try? TaskStore.shared.save(task, projectSlug: projectSlug)
        return wt
    }

    /// Write the task slash-commands into the worktree's own `.claude/commands/` — Claude Code
    /// discovers project commands from the cwd, and a worktree is a separate checkout whose tree
    /// doesn't contain them. Git-exclude them so they never land in the branch.
    /// ponytail: overwrite-if-changed. `commands` is required, not defaulted, so a caller cannot
    /// silently fall back to the `HookScripts` built-ins — those ignore the user's edited copies
    /// and the per-command enable toggles. Build them with `ManagedInstaller.taskCommandBodies()`.
    static func installCommands(inWorktree wtPath: String, commands: [(filename: String, body: String)]) {
        let dir = URL(filePath: wtPath).appending(path: ".claude/commands")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for cmd in commands {
            let dest = dir.appending(path: cmd.filename)
            let data = Data(cmd.body.utf8)
            if (try? Data(contentsOf: dest)) != data { try? data.write(to: dest) }
        }
        // Retired commands (their catalog entries are gone) linger in worktrees created by
        // older builds — sweep them so the slash-command list doesn't offer dead phases.
        for f in HookScripts.retiredTaskCommandFilenames {
            try? FileManager.default.removeItem(at: dir.appending(path: f))
        }
        // Keep them out of the branch via git's exclude file. In a LINKED worktree `.git` is a
        // FILE (not a dir), so <wt>/.git/info/exclude doesn't exist — ask git for the real path
        // (it resolves to the shared <main>/.git/info/exclude).
        excludeCommands(inWorktree: wtPath)
        installGitDenyList(inWorktree: wtPath)
    }

    /// Hard-block the agent from staging/committing in the worktree. The prompt tells it not to,
    /// but the agent runs with --permission-mode auto; that mode auto-approves via a classifier
    /// and doesn't consult `permissions.deny` rules as part of its decision (nor exit-2 hook
    /// blocks). A worktree-scoped settings.local.json (discovered from the agent's cwd, never in
    /// the branch) is the only reliable enforcement.
    /// ponytail: deny-first survives auto mode too — see docs/permissions "deny-first precedence".
    private static func installGitDenyList(inWorktree wtPath: String) {
        let dir = URL(filePath: wtPath).appending(path: ".claude")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: "settings.local.json")
        // A compound `git add X && git commit …` is one Bash call whose string starts with `git add`,
        // so the `git add` rule catches it; the standalone `git commit`/`git stage`/`git push` rules
        // cover the agent invoking them directly.
        let deny = ["Bash(git add:*)", "Bash(git commit:*)", "Bash(git stage:*)",
                    "Bash(git push:*)", "Bash(git commit -a:*)"]
        let obj: [String: Any] = ["permissions": ["deny": deny]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        if (try? Data(contentsOf: dest)) != data { try? data.write(to: dest) }
        // Never let the deny file land in the branch.
        appendExclude(".claude/settings.local.json", inWorktree: wtPath)
    }

    private static func excludeCommands(inWorktree wtPath: String) {
        appendExclude(".claude/commands/claudepit-task-*.md", inWorktree: wtPath)
    }

    /// Append one ignore pattern to the worktree's shared exclude file (idempotent). In a LINKED
    /// worktree `.git` is a FILE, so <wt>/.git/info/exclude doesn't exist — ask git for the real
    /// path (resolves to <main>/.git/info/exclude).
    private static func appendExclude(_ line: String, inWorktree wtPath: String) {
        let p = Process(); p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = ["git", "-C", wtPath, "rev-parse", "--git-path", "info/exclude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return }
        // git may return a path relative to wtPath — resolve against it.
        let rel = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rel.isEmpty else { return }
        let excludeFile = rel.hasPrefix("/") ? URL(filePath: rel)
                                             : URL(filePath: wtPath).appending(path: rel)
        let current = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? ""
        guard !current.contains(line) else { return }
        try? FileManager.default.createDirectory(at: excludeFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let updated = current.isEmpty ? line + "\n" : current + (current.hasSuffix("\n") ? "" : "\n") + line + "\n"
        try? updated.write(to: excludeFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Phase loop

    private func runPhase(_ input: ProjectTask, phase: TaskPhase?, projectSlug: String, projectRoot: URL) async {
        guard Self.herdrAvailable() else { return }
        var task = input
        guard task.status != .running else { return }   // don't double-launch a phase already in flight
        guard let phase = phase ?? task.plannedPhases.first else { return }

        // Brainstorm is interactive: hand it off to herdr (no --wait) so the user converses there.
        // The YAML deliverable is picked up when the file lands (FileWatcher → loadTasks in AppState).
        if phase == .brainstorm {
            await openInHerdr(task, phase: phase, projectSlug: projectSlug, projectRoot: projectRoot)
            return
        }

        // Held for the whole phase: the task is `.running` from here on, and resolveRunning must
        // not race the launch (a not-yet-prompted agent reads as `idle`) or this very observer.
        launching.insert(task.id)
        defer { launching.remove(task.id) }

        let commands = Self.taskCommands(for: projectRoot)
        guard Self.commandAvailable(for: phase, task: task, in: commands) else {
            fail(&task, projectSlug); return
        }

        guard await ensureWorktree(&task, projectSlug: projectSlug, projectRoot: projectRoot,
                                   commands: commands) != nil else { return }

        task.phase = phase
        task.status = .running
        task.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(task, projectSlug: projectSlug)

        // Fresh tab+pane+session per phase (closes the previous phase's tab).
        guard let paneID = await openPhaseTab(&task, phase: phase, projectSlug: projectSlug,
                                              focus: !task.isAutoRunning) else {
            fail(&task, projectSlug); return
        }

        let result = await startAgent(task, phase: phase, pane: paneID,
                                      projectSlug: projectSlug, projectRoot: projectRoot, wait: true)
        await observe(&task, promptResult: result, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Close the task's previous phase tab (if any) and open a fresh tab+pane at the worktree,
    /// persisting the new tab/pane onto task.worktree. Falls back to a plain pane split if
    /// tab creation fails. Returns the new pane id.
    private func openPhaseTab(_ task: inout ProjectTask, phase: TaskPhase, projectSlug: String,
                              focus: Bool = true) async -> String? {
        guard var wt = task.worktree else { return nil }
        // Hand the phase's canonical agent name back BEFORE closing the tab that hosts it: herdr
        // has no `agent stop`, and `agent start` answers `agent_name_taken` while a stale agent
        // still holds the name — at which point `agentReady` matches the dead agent and the
        // prompt goes nowhere. Fixes the manual Retry path too, not just auto-run.
        await releaseAgentName(Self.agentName(id: task.id, phase: phase))
        if let oldTab = wt.tabID { await herdr(["tab", "close", oldTab], cwd: nil) }
        let label = "task-\(task.id)-\(phase.commandName)"
        let cwd = URL(filePath: wt.path)
        if let fresh = await Herdr.tabCreate(cwd: cwd, label: label) {
            wt.paneID = fresh.paneID; wt.tabID = fresh.tabID
            // tabCreate is --no-focus; navigate to it now — except on an unattended run, which
            // would otherwise yank the user's terminal focus once per phase for an hour.
            if focus { await herdr(["tab", "focus", fresh.tabID], cwd: nil) }
        } else if let pane = await spawnPane(cwd: cwd) {
            wt.paneID = pane; wt.tabID = nil
        } else {
            return nil
        }
        task.worktree = wt
        try? TaskStore.shared.save(task, projectSlug: projectSlug)
        return wt.paneID
    }

    /// Start the herdr agent in `pane` and send the phase's slash-command prompt.
    /// Returns the prompt --wait JSON (nil when wait == false).
    @discardableResult
    private func startAgent(_ task: ProjectTask, phase: TaskPhase, pane: String,
                            projectSlug: String, projectRoot: URL, wait: Bool) async -> [String: Any]? {
        let agentName = Self.agentName(id: task.id, phase: phase)
        let wtPath = task.worktree?.path ?? projectRoot.path
        // A freshly-created worktree pane may not be at its shell prompt yet; `agent start`
        // fails detection until it is (symptom: pane opens, nothing runs, phase → .failed on
        // first try but works on Retry). Retry start, then confirm the agent is actually up via
        // `agent list` before prompting — `agent start` returns `agent_name_taken` (an error, so
        // herdr()==nil) once the agent exists, so we can't gate on its return value alone.
        // ponytail: 5×2s ceiling; raise the count if slow shells still miss the prompt.
        // Everything after `--` goes to the claude binary (herdr: `[-- [AGENT_ARG]...]`).
        var claudeArgs = ["--permission-mode", "auto"]
        // A fix task continues the session that wrote the code under review, so the agent already
        // holds the implementation context. Only meaningful in the worktree that session ran in —
        // which is the parent's worktree, inherited when the task was created.
        if phase == .implement, let sid = task.followUp?.resumeSessionID, !sid.isEmpty {
            claudeArgs += ["--resume", sid]
        }
        // Unattended: disable the tools that would park the session waiting for a human, and tell
        // the agent to decide for itself instead. Empty for a normal hand-driven run.
        claudeArgs += AutoRun.claudeArgs(for: task)
        for attempt in 0..<5 {
            await herdr(["agent", "start", agentName, "--kind", "claude", "--pane", pane,
                         "--timeout", "120000", "--"] + claudeArgs,
                        cwd: URL(filePath: wtPath),
                        timeout: Self.ceiling(forHerdrTimeoutMS: "120000"))
            if await agentReady(agentName) { break }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        guard await agentReady(agentName) else { return nil }   // never came up → observe() fails the phase
        let prompt = Self.phasePrompt(task, phase: phase, projectSlug: projectSlug)
        let cwd = URL(filePath: wtPath)
        await herdr(["agent", "prompt", agentName, prompt], cwd: cwd)
        // Implement gets a longer window: it is always subagent-driven (one implementer per plan
        // task plus reviews), so 30 min genuinely runs out on multi-task plans (the wait still
        // returns early on idle/blocked — the timeout only caps a phase that never yields).
        let timeoutMS = phase == .implement ? "3600000" : "1800000"
        return await waitForTurn(agentName, cwd: cwd, timeoutMS: wait ? timeoutMS : nil)
    }

    /// Wait for the agent to pick the prompt up, then (when `timeoutMS` is given) for its turn to
    /// end. Returns the terminal `agent wait` JSON, or nil on a hand-off (`timeoutMS == nil`).
    ///
    /// The pick-up wait is not optional. Claude sits at `idle` whenever it is at its prompt —
    /// including the instant BEFORE our prompt reaches it — so waiting straight for `idle` would
    /// return immediately and report a phase that never ran as finished. Waiting for `working`
    /// first makes the later `idle` mean what we need it to mean, for this wait and for
    /// `resolveRunning`'s poll alike. It is bounded, so a turn that somehow completes inside the
    /// window just falls through to the real wait.
    private func waitForTurn(_ agentName: String, cwd: URL?, timeoutMS: String?) async -> [String: Any]? {
        await herdr(["agent", "wait", agentName, "--until", Herdr.AgentState.working,
                     "--timeout", "20000"], cwd: cwd, timeout: Self.ceiling(forHerdrTimeoutMS: "20000"))
        guard let timeoutMS else { return nil }
        // `done` is in herdr's status enum but its Claude manifest never emits it — `idle` is how a
        // finished turn actually reports. Waiting only on blocked/done (as this used to) meant every
        // waited phase ran out its 30-minute timeout and then landed in `.failed`.
        return await herdr(["agent", "wait", agentName,
                            "--until", Herdr.AgentState.idle,
                            "--until", Herdr.AgentState.blocked,
                            "--until", Herdr.AgentState.done,
                            "--timeout", timeoutMS], cwd: cwd,
                           timeout: Self.ceiling(forHerdrTimeoutMS: timeoutMS))
    }

    /// `Subprocess` ceiling for a herdr call that carries its own `--timeout <ms>`: herdr's own
    /// budget plus a minute of slack. Without this the 120s default would kill a legitimate
    /// 30-minute `agent wait` two minutes in, and every long phase would land in `.failed`.
    static func ceiling(forHerdrTimeoutMS ms: String) -> TimeInterval {
        (Double(ms).map { $0 / 1000 } ?? Subprocess.defaultTimeout) + 60
    }

    /// The named agent exists and is interactive-ready (source of truth = `agent list`).
    private func agentReady(_ name: String) async -> Bool {
        guard let listObj = await herdr(["agent", "list"], cwd: nil),
              let result = listObj["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return false }
        return agents.contains { ($0["name"] as? String) == name && ($0["interactive_ready"] as? Bool) == true }
    }

    /// Existence only. `agentReady` additionally requires `interactive_ready`, which a stale agent
    /// can lose while still holding its name — so the two questions are genuinely different.
    func agentExists(_ name: String) async -> Bool {
        guard let listObj = await herdr(["agent", "list"], cwd: nil),
              let result = listObj["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return false }
        return agents.contains { ($0["name"] as? String) == name }
    }

    /// Free a phase's canonical agent name so the next launch can reuse it. herdr has no
    /// `agent stop`, so renaming is the only lever. Idempotent; a no-op when no such agent exists.
    private func releaseAgentName(_ name: String) async {
        defer {
            // `lastSeenSeq` is keyed by NAME, and the name is reused across launches — without this
            // a fresh agent inherits the previous run's seq and `seqChanged` suppresses its first
            // scrollback read, losing the CLAUDEPIT_ARTIFACT: marker. Latent bug, surfaced by retry.
            lastSeenSeq[name] = nil
        }
        guard await agentExists(name) else { return }
        if await herdr(["agent", "rename", name, "--clear"], cwd: nil) == nil {
            // --clear rejected (older herdr): move it aside under a name nothing will match.
            await herdr(["agent", "rename", name, "\(name)-stale"], cwd: nil)
        }
    }

    /// Post-`--wait`: route the artifact and land the task (no chaining to the next phase).
    private func observe(_ task: inout ProjectTask, promptResult: [String: Any]?,
                         projectSlug: String, projectRoot: URL) async {
        if task.phase == .implement { await captureSessionID(into: &task, projectSlug: projectSlug) }

        guard let w = promptResult else { fail(&task, projectSlug); return }
        if statusIsBlocked(w) {
            task.status = .blocked; task.updatedAt = Date().timeIntervalSince1970
            try? TaskStore.shared.save(task, projectSlug: projectSlug); return
        }
        // Anything else (a `{"error":{"code":"timeout"}}` payload, `unknown`) is a phase that
        // never yielded — fail it so the UI offers Retry.
        guard statusIsFinished(w) else { fail(&task, projectSlug); return }

        await landFinishedTurn(&task, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// The agent's turn ended — decide where the task lands.
    ///
    /// **A finished turn is not a finished phase.** Claude reports `idle` whenever it is back at its
    /// prompt, and that includes stopping *mid-phase* to ask the user something. Observed on the
    /// writeSpec phase of task 5c0769f7: the agent paused to ask a question, we read that as "done"
    /// and parked the task in `.awaitingReview` with no `specPath` — then it worked another twelve
    /// minutes and wrote spec.md, which nothing was left watching for.
    ///
    /// So the deliverable decides, not the status: a turn that produced neither the phase's
    /// `CLAUDEPIT_ARTIFACT:` marker nor its expected file lands in `.blocked` ("go answer it in
    /// herdr"), and `resolveBlocked` promotes it to `.awaitingReview` when the artifact appears.
    private func landFinishedTurn(_ task: inout ProjectTask, projectSlug: String, projectRoot: URL) async {
        let original = task
        let produced = await routeArtifact(&task, projectSlug: projectSlug, projectRoot: projectRoot)
        task.status = produced ? .awaitingReview : .blocked
        saveIfChanged(task, original: original, projectSlug: projectSlug)
    }

    /// Persist only when something other than the timestamp actually moved. The pollers call into
    /// here every few seconds; writing unconditionally would bump `updatedAt`, wake the FileWatcher,
    /// and reload the task list on a loop forever.
    private func saveIfChanged(_ task: ProjectTask, original: ProjectTask, projectSlug: String) {
        var compare = task; compare.updatedAt = original.updatedAt
        guard compare != original else { return }
        var out = task; out.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(out, projectSlug: projectSlug)
    }

    /// Read the agent's scrollback for the current phase and route the parsed artifact into
    /// `task.links`. Returns whether the phase actually yielded its deliverable.
    @discardableResult
    private func routeArtifact(_ task: inout ProjectTask, projectSlug: String, projectRoot: URL) async -> Bool {
        let agentName = Self.agentName(id: task.id, phase: task.phase)
        let phase = task.phase
        // 1000, not 400: `createPlan` and `implement` have no deterministic artifact, so the
        // CLAUDEPIT_ARTIFACT: marker is the ONLY thing that can report them done — and an
        // unattended agent prints more (it also emits an `## Assumptions` block), pushing the
        // marker further back. A marker that scrolls out costs a full re-run of the phase.
        let out = await herdrRaw(["agent", "read", agentName, "--source", "recent-unwrapped", "--lines", "1000"],
                                 cwd: projectRoot) ?? ""
        // Marker first; then the deterministic path the prompt handed the agent, but only if that
        // file actually landed. The fallback matters when the scrollback is gone (herdr restarted,
        // pane closed) — without it the links stay empty and the detail panel has nothing to open.
        let marked = TaskTransition.parseArtifact(from: out)
        let expected: String? = {
            guard let u = Self.expectedArtifact(task, projectSlug: projectSlug),
                  FileManager.default.fileExists(atPath: u.path) else { return nil }
            return u.path
        }()
        switch phase {
        case .brainstorm:  task.links.brainstormPath = marked ?? expected ?? task.links.brainstormPath
        case .writeSpec:   task.links.specPath = marked ?? expected ?? task.links.specPath
        case .createPlan:  task.links.planPath = marked ?? task.links.planPath
        case .codeReview:
            task.links.reviewPath = marked ?? expected ?? task.links.reviewPath
            // The FILE first, scrollback only as a fallback. The block is written into review.md,
            // so the file is complete; scrollback is a 400-line window that a long review overruns
            // and that is gone entirely once herdr restarts or the pane closes.
            let fileText = task.links.reviewPath
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            var parsed = TaskTransition.parseFindings(from: fileText)
            if parsed.isEmpty { parsed = TaskTransition.parseFindings(from: out) }
            // Merge, never replace: a re-run re-parses the same findings and a bare assignment
            // would drop the spawnedTaskID links the user built in the findings sheet.
            if !parsed.isEmpty {
                task.links.reviewFindings = TaskTransition.mergeFindings(
                    existing: task.links.reviewFindings, parsed: parsed)
            }
        case .implement:   await captureSessionID(into: &task, projectSlug: projectSlug)
        case .none:        break
        }
        // Every task command ends by echoing `CLAUDEPIT_ARTIFACT:` (implement included — it echoes
        // back the planPath), so the marker is the one universal "the phase is finished" signal.
        // `expected` covers the case where the marker has scrolled away but the file is on disk.
        // `implement` writes no file of its own, so only the marker can speak for it.
        return marked != nil || expected != nil
    }

    private func fail(_ task: inout ProjectTask, _ slug: String) {
        task.status = .failed; task.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(task, projectSlug: slug)
    }

    // MARK: - herdr helpers

    private func spawnPane(cwd: URL) async -> String? {
        guard let obj = await herdr(["pane", "split", "--direction", "down", "--cwd", cwd.path], cwd: cwd)
        else { return nil }
        return Herdr.paneID(fromJSON: obj)
    }

    private func statusIsBlocked(_ obj: [String: Any]) -> Bool { agentStatus(obj) == Herdr.AgentState.blocked }
    /// The agent's turn is over. `idle` (Claude back at its prompt) is the one that actually
    /// fires — see `Herdr.AgentState` — but accept `done` too in case a manifest starts emitting it.
    private func statusIsFinished(_ obj: [String: Any]) -> Bool {
        let s = agentStatus(obj)
        return s == Herdr.AgentState.idle || s == Herdr.AgentState.done
    }
    private func agentStatus(_ obj: [String: Any]) -> String? {
        (obj["result"] as? [String: Any])
            .flatMap { $0["agent"] as? [String: Any] }
            .flatMap { $0["agent_status"] as? String }
    }

    private func captureSessionID(into task: inout ProjectTask, projectSlug: String) async {
        guard let paneID = task.worktree?.paneID else { return }
        guard let listObj = await herdr(["agent", "list"], cwd: nil),
              let result = listObj["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return }
        for agent in agents where (agent["pane_id"] as? String) == paneID {
            if let session = agent["agent_session"] as? [String: Any],
               let sid = session["value"] as? String, !sid.isEmpty,
               !task.links.sessionIDs.contains(sid) {
                task.links.sessionIDs.append(sid)
            }
            break
        }
    }

    private func gitOK(_ path: String) async -> Bool {
        await git(["-C", path, "rev-parse", "--is-inside-work-tree"]) != nil
    }
    private func currentBranch(_ root: URL) async -> String? {
        // --abbrev-ref returns the branch name (master/main/…); nil-ish "HEAD" means detached.
        let b = await git(["-C", root.path, "rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (b?.isEmpty == false && b != "HEAD") ? b : nil
    }

    /// The project's trunk — task worktrees always fork from here, never from whatever
    /// happens to be checked out, so a task never accidentally builds on top of someone's
    /// half-finished branch. Prefers origin's default branch (works whether it's named
    /// main/master/trunk/whatever); falls back to a local "main" or "master" branch when
    /// there's no remote; falls back to the checked-out branch only if neither exists, so
    /// worktree creation still succeeds somehow.
    private func trunkBranch(_ root: URL) async -> String? {
        if let ref = await git(["-C", root.path, "symbolic-ref", "refs/remotes/origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let name = ref.split(separator: "/").last, !name.isEmpty {
            return String(name)
        }
        for candidate in ["main", "master"] {
            if await git(["-C", root.path, "rev-parse", "--verify", "--quiet", candidate]) != nil {
                return candidate
            }
        }
        return await currentBranch(root)
    }

    /// The prompt a phase's agent receives.
    ///
    /// Line 1 is the phase's slash-command, alone — Claude Code hands EVERYTHING after it to the
    /// command as `$ARGUMENTS`, newlines included, so the rest is a structured markdown brief a
    /// human can read in the herdr pane instead of a one-line `key=value` blob. The `key=value`
    /// lines survive verbatim (one per line, under `## Paths`) because every task command reads
    /// its paths by name ("the absolute `specPath=` in the arguments").
    ///
    /// The second line names the command explicitly: it is the phase's only instruction set, it is
    /// the file the user can edit/disable in App Settings, and it must not be visually buried.
    static func phasePrompt(_ task: ProjectTask, phase: TaskPhase, projectSlug: String) -> String {
        let dir = Paths.taskDir(projectSlug: projectSlug, id: task.id).path
        let brainstorm = Paths.taskBrainstormFile(projectSlug: projectSlug, id: task.id).path
        let today = Self.todayString()
        // Derived from the filename, not the phase: a fix task runs /claudepit-task-fix at implement.
        let command = "/" + Self.commandFilename(for: phase, task: task)
            .replacingOccurrences(of: ".md", with: "")

        var kv: [String]
        if phase == .brainstorm {
            // Brainstorm is a PRE-SPEC step: send ONLY the task definition + brainstormPath.
            // No plansDir/specPath/planPath/reviewPath/worktreePath — those are downstream noise here.
            kv = ["taskDir=\(dir)",
                  "brainstormPath=\(task.links.brainstormPath ?? brainstorm)",
                  "today=\(today)"]
        } else if phase == .implement, task.isFixTask {
            // A fix task has no spec and no plan and never will — listing those keys would only
            // send the agent looking for files nobody is going to write. Its context is the
            // parent's review plus the findings carried in the brief below.
            kv = ["taskDir=\(dir)",
                  "worktreePath=\(task.worktree?.path ?? dir)",
                  "fixPath=\(dir)/fix.md",
                  "parentReviewPath=\(task.followUp?.parentReviewPath ?? "")",
                  "parentSpecPath=\(task.followUp?.parentSpecPath ?? "")",
                  "parentPlanPath=\(task.followUp?.parentPlanPath ?? "")",
                  "reviewPath=\(dir)/review.md",
                  "today=\(today)"]
        } else {
            let wtPath = task.worktree?.path ?? dir
            kv = ["taskDir=\(dir)", "plansDir=\(Paths.plansRoot.path)",
                  "brainstormPath=\(task.links.brainstormPath ?? brainstorm)",
                  "specPath=\(task.links.specPath ?? "\(dir)/spec.md")",
                  "planPath=\(task.links.planPath ?? "")",
                  "reviewPath=\(dir)/review.md",
                  "worktreePath=\(wtPath)", "today=\(today)"]
        }
        // Attachments live in <taskDir>/attachments/ — always point the agent at them (all phases)
        // so images/docs the user attached are usable context, mirroring the other kv fields.
        let attachDir = Paths.taskAttachmentsDir(projectSlug: projectSlug, id: task.id)
        let attachments = (try? FileManager.default.contentsOfDirectory(atPath: attachDir.path)) ?? []
        let visibleAttachments = attachments.filter { !$0.hasPrefix(".") }.sorted()
        if !visibleAttachments.isEmpty { kv.append("attachmentsDir=\(attachDir.path)") }

        var out: [String] = [command, ""]
        out.append("You are running the **\(phase.title)** phase\(Self.stepSuffix(phase, in: task.plannedPhases)) "
                   + "of Claudepit task `\(task.id)`.")
        out.append("`\(command)` (invoked on the first line) is your complete instruction set for this "
                   + "phase — follow it exactly. Everything below is its arguments.")

        out.append("")
        out.append("## Task")
        out.append(task.name.isEmpty ? "_(unnamed — see the description)_" : task.name)
        let meta = Self.metaLines(task)
        if !meta.isEmpty { out += meta }

        // Task definition is the brief for the pre-spec phases; downstream phases argue from the
        // spec/plan instead (passed as paths), so repeating it there would compete with them.
        // A fix task is the third case: it has no spec and no plan to argue from, so the findings
        // carried in its description/requirements ARE its brief.
        if phase == .brainstorm || phase == .writeSpec || (phase == .implement && task.isFixTask) {
            out.append("")
            out.append("## Description")
            let desc = task.description.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(desc.isEmpty ? "_(none given — clarify with the user)_" : desc)

            out.append("")
            out.append("## Requirements")
            out += task.requirements.isEmpty ? ["_(none recorded yet)_"] : task.requirements.map { "- \($0)" }
        }

        if !visibleAttachments.isEmpty {
            out.append("")
            out.append("## Attachments")
            out.append("User-provided context — read every file below from `attachmentsDir`:")
            out += visibleAttachments.map { "- \($0)" }
        }

        // The enforcement is the appended system prompt (AutoRun.claudeArgs); this is what a human
        // sees when they open the pane, and the fallback if that flag is ever dropped. Kept before
        // `## Paths` so the key=value block stays the last thing in the prompt.
        if task.isAutoRunning {
            out.append("")
            out.append("## Unattended run")
            out.append("Nobody is watching this pane and nobody can answer you. Do not ask — decide, "
                     + "take the option you would have recommended, and record it under "
                     + "`## Assumptions` in this phase's deliverable. Print the `CLAUDEPIT_ARTIFACT:` "
                     + "line last.")
        }

        out.append("")
        out.append("## Paths (absolute — use exactly as given)")
        // A key whose artifact doesn't exist yet is stated in words rather than emitted as a bare
        // `key=` — an empty value reads as a path and the agent resolves it against the cwd.
        out += kv.filter { !$0.hasSuffix("=") }
        let missing = kv.filter { $0.hasSuffix("=") }.map { String($0.dropLast()) }
        if !missing.isEmpty {
            out.append("")
            out.append("Not produced yet (no file exists for these): \(missing.joined(separator: ", ")).")
        }
        return out.joined(separator: "\n")
    }

    /// " (step 2 of 5)" when the phase is part of the task's pipeline, else "".
    private static func stepSuffix(_ phase: TaskPhase, in planned: [TaskPhase]) -> String {
        guard let idx = planned.firstIndex(of: phase) else { return "" }
        return " (step \(idx + 1) of \(planned.count))"
    }

    /// Optional one-line task facts — emitted only when they carry information.
    private static func metaLines(_ task: ProjectTask) -> [String] {
        var out: [String] = []
        if let topic = task.topic, !topic.isEmpty { out.append("Topic: \(topic)") }
        if task.priority != .normal { out.append("Priority: \(task.priority.label)") }
        if !task.tags.isEmpty { out.append("Tags: \(task.tags.joined(separator: ", "))") }
        return out.isEmpty ? [] : [""] + out
    }

    static func kebab(_ s: String) -> String {
        let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(lowered)
        let parts = joined.split(separator: "-").prefix(6)
        return parts.joined(separator: "-")
    }

    static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - subprocess

    @discardableResult
    /// Every herdr/git call on the drive path is bounded (`Subprocess`). This is not a nicety: an
    /// unbounded call suspends its caller forever, and the poller that awaited it never reaches the
    /// `driving.remove` that would let the task be looked at again.
    nonisolated private func herdr(_ args: [String], cwd: URL?,
                                   timeout: TimeInterval = Subprocess.defaultTimeout) async -> [String: Any]? {
        await Herdr.runJSON(args, cwd: cwd, timeout: timeout)
    }
    nonisolated private func herdrRaw(_ args: [String], cwd: URL?,
                                      timeout: TimeInterval = Subprocess.defaultTimeout) async -> String? {
        await Herdr.run(args, cwd: cwd, timeout: timeout)
    }
    nonisolated private func git(_ args: [String]) async -> String? {
        guard let r = await Subprocess.run("/usr/bin/env", ["git"] + args), r.ok else { return nil }
        return r.stdout
    }
}
