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

    /// Recover a `.blocked` task by its DELIVERABLE, not agent status. The user answers the blocked
    /// agent directly in herdr; agent status is unreliable (Claude Code rests at "blocked" whenever it's
    /// awaiting input — even after finishing — and the task's stored pane/tab may no longer match a live
    /// agent). So: if the phase's expected artifact FILE now exists, route it and land `.awaitingReview`.
    /// Phases without a deterministic on-disk deliverable (createPlan/implement) can't self-heal
    /// here — the user advances them manually. Called on each FileWatcher tick by AppState.
    public func resolveBlocked(_ task: ProjectTask, projectSlug: String, projectRoot: URL) async {
        guard task.status == .blocked else { return }
        guard let artifact = Self.expectedArtifact(task, projectSlug: projectSlug),
              FileManager.default.fileExists(atPath: artifact.path) else { return }
        var t = task
        switch t.phase {
        case .brainstorm: t.links.brainstormPath = artifact.path
        case .writeSpec:  t.links.specPath = artifact.path
        case .codeReview: t.links.reviewPath = artifact.path
        default: break
        }
        t.status = .awaitingReview
        t.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(t, projectSlug: projectSlug)
    }

    /// The deterministic deliverable path a phase writes (matches `phasePrompt`'s kv defaults).
    /// nil for phases with no fixed on-disk file (createPlan picks its own plans filename; implement
    /// produces no artifact file).
    private static func expectedArtifact(_ task: ProjectTask, projectSlug: String) -> URL? {
        switch task.phase {
        case .brainstorm: return Paths.taskBrainstormFile(projectSlug: projectSlug, id: task.id)
        case .writeSpec:  return Paths.taskDir(projectSlug: projectSlug, id: task.id).appending(path: "spec.md")
        case .codeReview: return Paths.taskDir(projectSlug: projectSlug, id: task.id).appending(path: "review.md")
        default: return nil
        }
    }

    public func answer(_ task: ProjectTask, projectSlug: String, projectRoot: URL, text: String) async {
        guard task.worktree?.paneID != nil else { return }
        var t = task
        let result = await herdr(["agent", "prompt", Self.agentName(id: t.id, phase: t.phase), text,
                                  "--wait", "--until", "blocked", "--until", "done",
                                  "--timeout", "600000"], cwd: projectRoot)
        t.status = .running
        t.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(t, projectSlug: projectSlug)
        await observe(&t, promptResult: result, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Focus the task's tab and prompt without waiting — hands the phase off to the user in herdr.
    /// If the task's agent is ALREADY running, this only focuses its tab (navigate, don't re-prompt) —
    /// mirrors the Worktrees resume-session button, so repeated clicks don't spam the live session.
    public func openInHerdr(_ task: ProjectTask, phase: TaskPhase, projectSlug: String, projectRoot: URL) async {
        var t = task
        t.phase = phase
        let commands = Self.taskCommands(for: projectRoot)
        guard Self.commandAvailable(for: phase, in: commands) else {
            fail(&t, projectSlug); return
        }
        guard await ensureWorktree(&t, projectSlug: projectSlug, projectRoot: projectRoot,
                                   commands: commands) != nil else { return }
        // If the agent for this phase is already live, just focus its tab — don't re-prompt.
        let name = Self.agentName(id: t.id, phase: phase)
        if await agentReady(name), let tabID = t.worktree?.tabID {
            await herdr(["tab", "focus", tabID], cwd: nil)
            return
        }
        // Fresh tab+pane+session (closes the previous phase's tab).
        guard let pane = await openPhaseTab(&t, phase: phase, projectSlug: projectSlug) else { return }
        // Hand-off: the agent runs interactively in herdr (no --wait, so we can't observe it).
        // Leave the record in awaitingReview so the user keeps control (Next/Retry re-drive it).
        t.status = .awaitingReview
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

        let commands = Self.taskCommands(for: projectRoot)
        guard Self.commandAvailable(for: phase, in: commands) else {
            fail(&task, projectSlug); return
        }

        guard await ensureWorktree(&task, projectSlug: projectSlug, projectRoot: projectRoot,
                                   commands: commands) != nil else { return }

        task.phase = phase
        task.status = .running
        task.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(task, projectSlug: projectSlug)

        // Fresh tab+pane+session per phase (closes the previous phase's tab).
        guard let paneID = await openPhaseTab(&task, phase: phase, projectSlug: projectSlug) else {
            fail(&task, projectSlug); return
        }

        let result = await startAgent(task, phase: phase, pane: paneID,
                                      projectSlug: projectSlug, projectRoot: projectRoot, wait: true)
        await observe(&task, promptResult: result, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Close the task's previous phase tab (if any) and open a fresh tab+pane at the worktree,
    /// persisting the new tab/pane onto task.worktree. Falls back to a plain pane split if
    /// tab creation fails. Returns the new pane id.
    private func openPhaseTab(_ task: inout ProjectTask, phase: TaskPhase, projectSlug: String) async -> String? {
        guard var wt = task.worktree else { return nil }
        if let oldTab = wt.tabID { await herdr(["tab", "close", oldTab], cwd: nil) }
        let label = "task-\(task.id)-\(phase.commandName)"
        let cwd = URL(filePath: wt.path)
        if let fresh = await Herdr.tabCreate(cwd: cwd, label: label) {
            wt.paneID = fresh.paneID; wt.tabID = fresh.tabID
            await herdr(["tab", "focus", fresh.tabID], cwd: nil)   // tabCreate is --no-focus; navigate to it now
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
        for attempt in 0..<5 {
            await herdr(["agent", "start", agentName, "--kind", "claude", "--pane", pane,
                         "--timeout", "120000", "--", "--permission-mode", "auto"],
                        cwd: URL(filePath: wtPath))
            if await agentReady(agentName) { break }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        guard await agentReady(agentName) else { return nil }   // never came up → observe() fails the phase
        let prompt = Self.phasePrompt(task, phase: phase, projectSlug: projectSlug)
        var args = ["agent", "prompt", agentName, prompt]
        // Implement gets a longer window: it is always subagent-driven (one implementer per plan
        // task plus reviews), so 30 min genuinely runs out on multi-task plans (the wait still
        // returns early on blocked/done — the timeout only caps a phase that never yields).
        let timeoutMS = phase == .implement ? "3600000" : "1800000"
        if wait { args += ["--wait", "--until", "blocked", "--until", "done", "--timeout", timeoutMS] }
        return await herdr(args, cwd: URL(filePath: wtPath))
    }

    /// The named agent exists and is interactive-ready (source of truth = `agent list`).
    private func agentReady(_ name: String) async -> Bool {
        guard let listObj = await herdr(["agent", "list"], cwd: nil),
              let result = listObj["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return false }
        return agents.contains { ($0["name"] as? String) == name && ($0["interactive_ready"] as? Bool) == true }
    }

    /// Post-prompt: route artifact by phase, always land in `.awaitingReview` (no chaining).
    private func observe(_ task: inout ProjectTask, promptResult: [String: Any]?,
                         projectSlug: String, projectRoot: URL) async {
        if task.phase == .implement { await captureSessionID(into: &task, projectSlug: projectSlug) }

        guard let w = promptResult else { fail(&task, projectSlug); return }
        if statusIsBlocked(w) {
            task.status = .blocked; task.updatedAt = Date().timeIntervalSince1970
            try? TaskStore.shared.save(task, projectSlug: projectSlug); return
        }
        guard statusIsDone(w) else { fail(&task, projectSlug); return }

        await resolvePhaseArtifact(&task, projectSlug: projectSlug, projectRoot: projectRoot)
    }

    /// Read the agent's scrollback for the current phase, route the parsed artifact into `task.links`,
    /// and land the task in `.awaitingReview`. Shared by `observe` (post-`--wait`) and `resolveBlocked`
    /// (FileWatcher poll of a blocked task the user answered in herdr).
    private func resolvePhaseArtifact(_ task: inout ProjectTask, projectSlug: String, projectRoot: URL) async {
        let agentName = Self.agentName(id: task.id, phase: task.phase)
        let phase = task.phase
        let out = await herdrRaw(["agent", "read", agentName, "--source", "recent-unwrapped", "--lines", "400"],
                                 cwd: projectRoot) ?? ""
        switch phase {
        case .brainstorm:  task.links.brainstormPath = TaskTransition.parseArtifact(from: out) ?? task.links.brainstormPath
        case .writeSpec:   task.links.specPath = TaskTransition.parseArtifact(from: out) ?? task.links.specPath
        case .createPlan:  task.links.planPath = TaskTransition.parseArtifact(from: out) ?? task.links.planPath
        case .codeReview:
            task.links.reviewPath = TaskTransition.parseArtifact(from: out) ?? task.links.reviewPath
            let parsed = TaskTransition.parseFindings(from: out)
            if !parsed.isEmpty { task.links.reviewFindings = parsed }
        case .implement:   await captureSessionID(into: &task, projectSlug: projectSlug)
        case .none:        break
        }

        task.status = .awaitingReview
        task.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.shared.save(task, projectSlug: projectSlug)
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

    private func statusIsBlocked(_ obj: [String: Any]) -> Bool { agentStatus(obj) == "blocked" }
    private func statusIsDone(_ obj: [String: Any]) -> Bool { agentStatus(obj) == "done" }
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

    private static func phasePrompt(_ task: ProjectTask, phase: TaskPhase, projectSlug: String) -> String {
        let dir = Paths.taskDir(projectSlug: projectSlug, id: task.id).path
        let brainstorm = Paths.taskBrainstormFile(projectSlug: projectSlug, id: task.id).path
        let today = Self.todayString()
        var kv: [String]
        if phase == .brainstorm {
            // Brainstorm is a PRE-SPEC step: send ONLY the task definition + brainstormPath.
            // No plansDir/specPath/planPath/reviewPath/worktreePath — those are downstream noise here.
            kv = ["taskDir=\(dir)",
                  "brainstormPath=\(task.links.brainstormPath ?? brainstorm)",
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
        if !task.name.isEmpty { kv.append("name=\(task.name)") }
        // Attachments live in <taskDir>/attachments/ — always point the agent at them (all phases)
        // so images/docs the user attached are usable context, mirroring the other kv fields.
        let attachDir = Paths.taskAttachmentsDir(projectSlug: projectSlug, id: task.id)
        let attachments = (try? FileManager.default.contentsOfDirectory(atPath: attachDir.path)) ?? []
        let visibleAttachments = attachments.filter { !$0.hasPrefix(".") }.sorted()
        if !visibleAttachments.isEmpty {
            kv.append("attachmentsDir=\(attachDir.path)")
        }
        let reqs = task.requirements.map { "- \($0)" }.joined(separator: "\n")
        var extra = ""
        if phase == .brainstorm || phase == .writeSpec {
            extra = "\nTask: \(task.name)\n\(task.description)\nRequirements:\n\(reqs)"
        }
        if !visibleAttachments.isEmpty {
            extra += "\nAttachments (in attachmentsDir):\n" + visibleAttachments.map { "- \($0)" }.joined(separator: "\n")
        }
        return "/claudepit-task-\(phase.commandName) \(kv.joined(separator: " "))\(extra)"
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
    nonisolated private func herdr(_ args: [String], cwd: URL?) async -> [String: Any]? {
        await Herdr.runJSON(args, cwd: cwd)
    }
    nonisolated private func herdrRaw(_ args: [String], cwd: URL?) async -> String? {
        await Herdr.run(args, cwd: cwd)
    }
    nonisolated private func git(_ args: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(filePath: "/usr/bin/env")
                p.arguments = ["git"] + args
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { cont.resume(returning: nil); return }
                cont.resume(returning: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
            }
        }
    }
}
