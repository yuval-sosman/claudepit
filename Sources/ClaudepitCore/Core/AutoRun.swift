import Foundation

/// Unattended execution policy: which phase an armed task runs next, and what the `claude` agent
/// is invoked with so it never stops to ask a question.
///
/// Everything here is pure — no herdr, no subprocess, no filesystem — so the whole state machine
/// is testable. `TaskRunner.stepAutoRun` is the thin actor-side dispatcher over `nextStep`.
public enum AutoRun {

    /// Phases auto-run never executes. `brainstorm` is built end-to-end on `AskUserQuestion`, and
    /// its YAML suggestions need in-app accept/dismiss triage before anything downstream is right —
    /// there is nothing useful an unattended agent can do with it.
    public static let skipped: Set<TaskPhase> = [.brainstorm]

    /// Where an auto-run stops. It never marks a task `.done`: `Step` has no case that means done,
    /// and the dispatcher calls `runPhase` directly rather than `TaskRunner.advance` — the one
    /// function in the codebase that sets `.done`.
    public static let terminal: TaskPhase = .codeReview

    /// Why a chain ended without anything going wrong.
    public enum Finish: String, Equatable, Sendable {
        case reviewLanded        // the terminal phase produced its deliverable
        case pipelineExhausted   // plannedPhases ran out before the terminal phase
    }

    public enum Step: Equatable, Sendable {
        case wait                       // something is in flight — do nothing this tick
        case start(TaskPhase)
        case retry(TaskPhase)           // the single allowed re-run of a phase
        case finish(Finish)             // disarm; the task is where the user wants it
        case halt(reason: String)       // disarm and record why; the task needs a human
    }

    // MARK: - Decision

    /// The one step an armed task should take right now. Total: safe to call with any task.
    public static func nextStep(_ task: ProjectTask, allTasks: [ProjectTask]) -> Step {
        guard task.isAutoRunning else { return .wait }

        // A live phase owns the task; the runner lands it before the next step is asked for.
        if task.status == .running { return .wait }

        // Transient co-tenancy — a fix task sharing its parent's checkout. This clears on its own,
        // so wait rather than halt. (Contrast with dependencies, immediately below.)
        if TaskTransition.worktreeBusy(task, allTasks: allTasks) != nil { return .wait }

        // An unmet dependency can only be satisfied by another task reaching `.done`, which may
        // never happen. Say so instead of spinning forever.
        let unmet = TaskTransition.unmetDependencies(task, allTasks: allTasks)
        if !unmet.isEmpty {
            return .halt(reason: "waiting on \(unmet.joined(separator: ", "))")
        }

        switch task.status {
        case .running:
            return .wait                                    // unreachable — handled above

        case .done:
            return .finish(.pipelineExhausted)              // defensive: disarm, never re-enter

        case .backlog:
            return startFirst(task)

        case .failed, .blocked:
            // "Failed" and "stalled without a deliverable" get the same single retry.
            guard let phase = task.phase else { return startFirst(task) }
            if (task.autoRunRetried ?? []).contains(phase) {
                let what = task.status == .failed ? "failed" : "stalled"
                return .halt(reason: "\(phase.title) \(what) twice")
            }
            return .retry(phase)

        case .awaitingReview:
            guard let phase = task.phase else { return startFirst(task) }

            // The stop line. A human reads the review before anything is called done.
            if phase == terminal { return .finish(.reviewLanded) }

            // A landed phase that still wants something from the user is not one auto-run can step
            // past. In practice this is only brainstorm with undecided suggestions — every other
            // phase reaches `.awaitingReview` with its deliverable already recorded.
            if task.phaseNeedsReview {
                return .halt(reason: "\(phase.title) needs your input before the next phase")
            }

            guard let next = nextRunnablePhase(after: phase, in: task.plannedPhases) else {
                // Pipeline ran out before the terminal phase. Auto-run does not invent phases and
                // does not close the task out.
                return .finish(.pipelineExhausted)
            }
            return .start(next)
        }
    }

    private static func startFirst(_ task: ProjectTask) -> Step {
        guard let first = firstRunnablePhase(in: task.plannedPhases) else {
            return .halt(reason: "no runnable phase in the pipeline")
        }
        return .start(first)
    }

    // MARK: - Skip-aware phase walk

    public static func firstRunnablePhase(in planned: [TaskPhase]) -> TaskPhase? {
        planned.first { !skipped.contains($0) }
    }

    /// `TaskTransition.nextPlannedPhase`, stepped forward over every skipped phase.
    public static func nextRunnablePhase(after current: TaskPhase?, in planned: [TaskPhase]) -> TaskPhase? {
        var cursor = current
        while let next = TaskTransition.nextPlannedPhase(after: cursor, in: planned) {
            if !skipped.contains(next) { return next }
            cursor = next
        }
        return nil
    }

    // MARK: - Worktree de-duplication

    /// At most one armed task per worktree checkout.
    ///
    /// `TaskTransition.worktreeBusy` only sees a co-tenant that is already `.running`/`.blocked`,
    /// so two armed tasks both parked at `.awaitingReview` on one checkout (a fix task and its
    /// parent) would both launch in the same tick and trample each other's paneID/tabID. Keep the
    /// highest priority, then the least recently updated, so the choice is stable across ticks.
    public static func selectStartable(_ candidates: [ProjectTask]) -> [ProjectTask] {
        var chosen: [String: ProjectTask] = [:]   // worktree path → winner
        var free: [ProjectTask] = []              // no worktree yet: nothing to contend for
        for task in candidates {
            guard let path = task.worktree?.path else { free.append(task); continue }
            let key = URL(filePath: path).standardizedFileURL.path
            guard let held = chosen[key] else { chosen[key] = task; continue }
            if beats(task, held) { chosen[key] = task }
        }
        return free + chosen.values.sorted { $0.id < $1.id }
    }

    private static func beats(_ lhs: ProjectTask, _ rhs: ProjectTask) -> Bool {
        if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank > rhs.priority.rank }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id < rhs.id
    }

    // MARK: - Agent invocation

    /// Tools that would park an unattended agent forever. `AskUserQuestion` is the obvious one;
    /// both plan-mode tools go too, because denying only `ExitPlanMode` would trap the plan phase
    /// inside plan mode with no way out.
    public static let disallowedTools = ["AskUserQuestion", "EnterPlanMode", "ExitPlanMode"]

    /// Extra `claude` args for an unattended phase — empty when the task is not armed, so a normal
    /// hand-driven run is byte-for-byte what it is today.
    ///
    /// Delivered as argv rather than as an edit to the command bodies in `HookScripts`: those reach
    /// the agent through the project's *editable copy* under `claudepit-config/`
    /// (`ManagedInstaller.taskCommandBodies()`), so a user who has edited theirs would never see a
    /// change made there. This reaches every run regardless.
    ///
    /// `--permission-mode` is deliberately not set here. It is `auto` for armed and unarmed runs
    /// alike: what actually parks an unattended session is the *tools* above, which no permission
    /// mode gates, and `dontAsk` would silently deny the things `implement` needs to do its job.
    public static func claudeArgs(for task: ProjectTask) -> [String] {
        guard task.isAutoRunning else { return [] }
        // One comma-joined argument, not three space-separated ones: `--disallowedTools` is
        // declared variadic (`<tools...>`), so space-separating would rely on the parser stopping
        // at the next flag.
        return ["--disallowedTools", disallowedTools.joined(separator: ","),
                "--append-system-prompt", unattendedSystemPrompt]
    }

    /// Appended to the default system prompt for every unattended phase.
    ///
    /// The "decide instead" sentence is load-bearing and must not be softened: `claudepit-task-spec.md`
    /// makes `AskUserQuestion` *mandatory* ("never a plain-text question, never a silent guess"), so
    /// the agent is otherwise following an instruction it cannot execute. This has to override it,
    /// not merely forbid it.
    ///
    /// **Single line, deliberately.** This travels as an argument to `herdr agent start`, which runs
    /// the agent by typing its command into the pane's interactive shell ("the pane must be at its
    /// interactive shell prompt"). An embedded newline would submit the line early and the launch
    /// would fail. `agent prompt` is the opposite case — it types into a running agent's input box,
    /// which is why `phasePrompt` can be multi-line and this cannot.
    public static let unattendedSystemPrompt = [
        "UNATTENDED RUN — nobody is watching this session.",
        "Never ask the user anything: AskUserQuestion, EnterPlanMode and ExitPlanMode are disabled"
            + " for this run, and printing a question and waiting is no better — there is no one to"
            + " answer it.",
        "Where your instructions tell you to ask, decide instead: take the option you would have"
            + " labelled \"(Recommended)\", say plainly which one you took, and keep going. A"
            + " decision you make and record beats a stall.",
        "Record every such decision under an \"## Assumptions\" heading in this phase's deliverable"
            + " — one line each: what you decided, what you rejected, and what would have to be true"
            + " for the rejected option to win. If this phase writes no file, print the same block"
            + " in the transcript.",
        "Do not stop part-way to report progress and wait for approval; run the phase to its end.",
        "Finish by printing the CLAUDEPIT_ARTIFACT: <absolute path> line your command specifies. It"
            + " is the only signal that this phase completed, and it must be the LAST thing you"
            + " print.",
    ].joined(separator: " ")
}
