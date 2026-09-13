# Claudepit

macOS SwiftUI app that provides a GUI over Claude Code — sessions, agents, skills, MCP servers, plugins, hooks, and settings.

## Session Summary Hook

On every app launch, `ManagedInstaller.sync()` writes `~/.claude/claudepit-summary-hook.sh` (the script stays global — it resolves the project slug from `cwd` at runtime) and registers it under `UserPromptSubmit` in **`<project>/.claude/settings.json`** (project-scoped, Claudepit-managed projects only — mirrors the Stop/StopFailure memory hooks). `migrateGlobalSummaryHook()` strips any stale global `SessionStart`/`UserPromptSubmit` registration left by older builds, pruning by script filename so another machine's registration is caught too.

**Do not edit the hook script or the settings.json entry directly** — both are overwritten on each launch.

To change the hook's behavior, edit the source:
- **Script content**: `Sources/ClaudepitCore/Core/HookScripts.swift` — the `summaryHook` string literal
- **Registration logic** (event, scope, migration): `Sources/ClaudepitCore/Core/ManagedInstaller.swift` — `installSummaryHook()`

The hook fires on `UserPromptSubmit`, reads `session_id` and `cwd` from stdin JSON, looks up existing bullets from `~/.claude/projects/<project-slug>/summary/<session-id>.json`, and injects a summary instruction into Claude's context via `additionalContext`.

## Memory System Prompt

On every `setActivePath` (when `memoryEnabled` is `true`), `ManagedInstaller.installMemorySystemPrompt()` writes a `systemPrompt.append` key into `<project>/.claude/settings.json` (project-scoped, not global).

**Do not edit this key directly** — it is overwritten on each launch when enabled.

To change the memory instructions, edit:
- **Instruction content**: `Sources/ClaudepitCore/Core/HookScripts.swift` — `memorySystemPrompt`
- **Registration logic**: `Sources/ClaudepitCore/Core/ManagedInstaller.swift` — `installMemorySystemPrompt()`

The injected instructions tell Claude to:
- Use a feature-oriented memory strategy (ignore default auto-memory behavior)
- Save one topic file per feature domain under `~/.claude/projects/<slug>/memory/`, accumulating all contributing session IDs
- Read per-session bullet summaries from `~/.claude/projects/<slug>/summary/<session-id>.json`
- Self-maintain `MEMORY.md` (cap at 20 lines, merge related topics)

## Memory End-of-Session Hooks

On every `setActivePath` (when `memoryEnabled` is `true`), `ManagedInstaller.installMemoryHooks()` writes `~/.claude/claudepit-memory-hook.sh` and registers it under both `Stop` and `StopFailure` in `<project>/.claude/settings.json`.

**Do not edit the hook script or the settings.json entries directly** — both are overwritten on each launch when enabled.

To change the hook's behavior, edit:
- **Script content**: `Sources/ClaudepitCore/Core/HookScripts.swift` — `memoryHook`
- **Registration logic**: `Sources/ClaudepitCore/Core/ManagedInstaller.swift` — `installMemoryHooks()`

The hook fires on `Stop` and `StopFailure`, injecting an `additionalContext` reminder for Claude to apply the Custom Memory Strategy before the session ends.

**Fast path — no changes, no work.** Before anything else the script scans `transcript_path` for a
file-mutating **tool call** (`Edit`/`Write`/`MultiEdit`/`NotebookEdit`, or a `Bash` command matching
the shell-write patterns) and, finding none, emits a bare `{"continue": true}` — no reminder, no
dreaming, so a purely conversational session triggers no memory pass at all. The scan deliberately
inspects `tool_use` blocks rather than grepping the raw transcript: every transcript embeds a system
prompt mentioning `git commit` and similar, so a plain text grep matches on *every* session. It
reads the whole hook input in one `python3` pass and short-circuits before the `log.json` read
(~0.08s on a 3MB transcript). A false positive costs only the normal reminder, which the strategy's
own "When to skip" rule then short-circuits on the model side.

## Memory Toggle

`AppState.memoryEnabled: Bool` controls both the system prompt injection and the Stop/StopFailure hooks together. It is **per-project, not global**: the value is read from and written to `appConfig.isEnabled(base, "memory-hook")`, which lives in `<project>/.claude/claudepit-config/config.json`, and toggling it sets both the `memory-hook` and `memory-system-prompt` entries. (An older build kept a global `memoryEnabled` key in `UserDefaults`; `AppState.migrateMemoryEnabledIfNeeded()` writes it into each recent project's `ProjectPrefs` and deletes the key, and `AppConfigStore.seedIfNeeded` folds that legacy value into the two memory entries on the project's first seed.) A `PillToggle` in `MemorySection` (left sidebar header) lets the user enable/disable the entire memory system:
- **On**: installs `systemPrompt.append` + registers the Stop/StopFailure hooks, both in this project's `.claude/settings.json`.
- **Off**: removes `systemPrompt.append` + prunes the Stop/StopFailure hooks from this project's `.claude/settings.json`.

## Managed Configs (installer + artifact index)

Everything Claudepit writes into a project's Claude config is one entry in `ManagedConfig.catalog`
(`Sources/ClaudepitCore/Core/AppConfigStore.swift`). Two Core types act on that catalog:

- **`ManagedInstaller`** (`Core/ManagedInstaller.swift`) — makes disk match the catalog plus the
  project's enable/edit state. `sync()` installs-when-on / removes-when-off every entry, reading
  bodies from the project's editable copies via `AppConfigStore`. All paths derive from its
  injected `globalClaudeDir` and `base` (never `Paths.home`, which is a `static let`), so it is
  testable against temp dirs. Settings writes go through one `mutateSettings` helper on
  `JSONFile.readObject`/`writeObject` — validated and atomic, and **no backup files**: these are
  app-driven writes, not user edits. Every installer keeps a churn guard so an unchanged relaunch
  writes nothing.
- **`ManagedArtifacts`** (`Core/ManagedArtifacts.swift`) — the read-side index: which settings keys
  and hook events each entry owns, which script it installs, every file it writes. Hook ownership
  is matched by **value** (`HookRegistration.isManaged` on the script filename, so a foreign home
  path still resolves); settings-key ownership is matched by **key plus layer** (claimed only in
  the active project's `settings.json`).

`AppState.syncManagedConfigs()` is a thin delegation to `ManagedInstaller.sync()`; the one-time
migrations are `static` on `ManagedInstaller` because they are project-independent.

**Auto-update status.** `AppConfigStore.status(base:_:)` returns `ManagedCopyStatus`
(`.untouched` / `.edited` / `.missing`) for an entry's editable copy. It and `seedIfNeeded` share
one `copyStatus(current:seededHash:builtin:)` helper, so the badge in App Settings and the
auto-update decision can never disagree about what counts as a user edit. App Settings renders it
as "Default (auto-updates)" / "Modified — auto-update paused" / "Not installed", and pairs the
Modified state with the existing Reset button.

**Transparency in the UI.** `ManagedBadge` (`UI/ManagedBadge.swift`) is the teal "Claudepit" marker
shown wherever a managed entry surfaces; clicking it deep-links to the owning App Settings card.
`SettingsTreeView` computes ownership per node (`SettingsTreeNode.managedOwner`) and **suppresses
the hover pencil and click-to-edit** on owned nodes — an edit there would be overwritten on the
next launch. Ownership deliberately stops at shared containers: the `hooks` key and each
per-event array are never claimed (they hold foreign hooks too), so a hook reads as a badge on its
entry plus one on its `command` leaf — and an entry is claimed only when **every** command beneath
it is ours, since `prune` preserves a foreign hook sharing an entry with ours. Tapping a managed
*leaf* row deep-links to App Settings rather than no-oping; container rows keep toggling expansion.
`HookCard` swaps its Delete action for "Manage in App Settings" on a managed hook, for the same
reason.

**File map.** `AppConfigSection` lists each entry's real, openable paths from
`ManagedArtifacts.writtenFiles(for:base:)` rather than describing them in prose, so the list cannot
drift from what the installer writes and is correct on whatever machine it runs on.

## Session Groups

Session groups are stored at `~/.claude/claudepit-groups/<project-slug>.json` — one file per project. Each file contains:
- **`groups`** — array of group objects (id, name, color, createdAt)
- **`assignments`** — map of `sessionID → groupID`

To change group logic, edit `Sources/ClaudepitCore/Core/GroupStore.swift` and `Sources/ClaudepitCore/Model/SessionGroup.swift`.

## Session Summaries

Per-session bullet summaries are stored at `~/.claude/projects/<project-slug>/summary/<session-id>.json` — one file per session, sibling to `memory/`. On first launch after an upgrade, `ManagedInstaller.migrateSummariesIfNeeded()` automatically moves any existing data from the old `~/.claude/claudepit-summaries/<slug>.json` format to the new location.

To change summary behavior, edit `Sources/ClaudepitCore/Core/HookScripts.swift` — `summaryHook`.

## Tasks

Project-scoped task tracker. Each task moves through a fixed pipeline: **created → writeSpec → createPlan → implement → codeReview → done**, executed by interactive `claude` agents in **herdr** panes.

**Storage** — one folder per task under `~/.claude/projects/<slug>/tasks/<task-id>/`, sibling to `summary/` and `memory/` (so the existing `FileWatcher` picks up changes):
- `task.json` — the record (`ProjectTask`: name, description, `phase`, `status`, `requirements`, `links`, and the `autoRun`/`autoRunRetried`/`autoRunHaltReason` trio below).
- `attachments/` — copied-in images (storage designed; drag-in UI is a follow-up).

Key files: `Sources/ClaudepitCore/Model/Task.swift` (model), `Core/TaskStore.swift` (per-task-folder atomic load/save/delete), `Core/TaskTransition.swift` (pure phase-advance + `CLAUDEPIT_ARTIFACT:` parsing), `Core/TaskRunner.swift` (herdr orchestration actor), `UI/Sections/TasksSection.swift` + `TaskDetailView.swift`.

**Execution** — `TaskRunner` (an actor, `.shared`) runs **only while the app is open** (like `CronRunner`). One phase per `start()`: it spawns/reuses a herdr pane (`herdr pane split` → `agent start --kind claude`), prompts the matching subagent, waits for the turn to end, reads scrollback, and greps a `CLAUDEPIT_ARTIFACT: <path>` marker line to populate `links` (falling back to the deterministic `expectedArtifact` path when that file exists but the scrollback is gone). Subprocess calls run off-actor (`nonisolated` + `withCheckedContinuation`) so long phases don't block the actor. If herdr isn't on PATH, execution is disabled and the UI shows a notice.

**Agent status vocabulary** — herdr's enum is `idle|working|blocked|done|unknown` (`Herdr.AgentState`), but its **Claude detection manifest never emits `done`** — a finished turn reports **`idle`**, because Claude is back at its prompt. Waiting on `blocked`/`done` alone therefore never fires, and every waited phase ran out its 30-minute timeout and landed in `.failed`. Two consequences baked into `TaskRunner`:

- `waitForTurn` waits for **`working` first** (bounded, 20s) and only then for `idle`/`blocked`/`done`. Without the pick-up wait, `idle` would match the instant *before* the prompt reaches the agent and a phase that never ran would be reported as finished.
- A `launching: Set<String>` guard on the actor holds a task id for the whole launch (`runPhase`/`openInHerdr`/`answer`), so the pollers below can't race a not-yet-prompted agent.

**A finished turn is not a finished phase.** `idle` only means Claude is back at its prompt, which includes stopping *mid-phase* to ask the user something — so the **deliverable decides**, not the status. `TaskRunner.routeArtifact` returns whether the phase yielded one (its `CLAUDEPIT_ARTIFACT:` marker, which every task command echoes — `implement` included — or `TaskTransition.expectedArtifact`'s file on disk); `landFinishedTurn` maps that to `.awaitingReview` when true and **`.blocked`** when false, and `resolveBlocked` promotes it once the artifact appears. Getting this wrong parked task `5c0769f7`'s writeSpec phase in `.awaitingReview` with a nil `specPath` twelve minutes before the agent actually wrote spec.md. All poller writes go through `saveIfChanged` (a save on every tick would bump `updatedAt` → wake the FileWatcher → reload, forever), and the blocked poll skips its scrollback read while herdr's `state_change_seq` is unchanged.

**Link healing** — `TaskTransition.healArtifactLinks` adopts any deterministic deliverable that exists on disk but was never recorded, for **every** phase rather than just the current one. `AppState.loadTasks()` runs it beside `mergeBrainstormSuggestions`. Without it a phase that finished unobserved leaves `specPath`/`reviewPath` nil and the detail view's "Review spec" button disabled for a file that plainly exists.

**Heal must converge.** `AppState.healArtifactLinks`'s write-back has to persist *everything*
`TaskTransition.healArtifactLinks` derived — paths **and** `reviewFindings`. It once wrote only the
three paths, so the findings upgrade was re-derived on every load, `TaskStore.update` bumped
`updatedAt`, the FileWatcher fired, `reload()` ran `loadTasks()`, and the app re-entered the same
write several times a second forever (sessions rescanned, watcher rebuilt, a `grep` child alive
~50% of the time). `TaskStore.update` now **refuses a mutation that changes nothing**, which retires
the whole class rather than the one instance — but anything heal learns to fill in next still
belongs in that write-back.

**Status progression** — a phase goes `.running` → (`.blocked` | `.awaitingReview` | `.failed`). A phase never chains on its own: `landFinishedTurn` lands the task and stops, and the user advances with "Next phase" (`AppState.advanceTaskPhase`) or by dragging on the board. The **one** exception is an armed auto-run (see below), which is opt-in per task and drives the chain from outside the runner's completion path rather than from inside it. Hand-off phases (brainstorm) run **without** `--wait`, so nothing observes them in-line — two pollers on `AppState` close the loop, both guarded by the `driving` set:

- `driveRunningTasks()` → `TaskRunner.resolveRunning` — polls a `.running` task's live agent: `blocked` → `.blocked`, `idle`/`done` → `landFinishedTurn`, agent missing entirely → land on its deliverable or `.failed` (never spin forever).
- `driveBlockedTasks()` → `TaskRunner.resolveBlocked` — deliverable file first (no subprocess, and still works when the agent is gone), then the live agent, then `landFinishedTurn` so `createPlan`/`implement` can report done via their marker.
- `driveAutoRunTasks()` → `TaskRunner.stepAutoRun` — the third poller, added with auto-run. It is the **sole owner** of an armed task, so the two above skip `isAutoRunning` and exactly one code path writes an armed task's status.

**The `driving` guard has deadlines, not just entries.** It is `[String: Date]`, claimed through
`beginDriving(_:ttl:)` — `resolveDriveTTL` (300s) for a poll, `launchDriveTTL` (4200s) for a launch,
which must clear `runPhase`'s 60-minute `implement` wait or the guard would expire mid-phase and a
second agent could be launched into the same checkout. As a plain `Set` whose entry was removed
only *after* the `await` returned, a drive call that never returned parked its id for the life of
the process: the task sat on "Running" with an idle agent and its deliverable already on disk, and
"Open in Herdr" (same actor) looked dead too. `TaskRunner.launching` is the actor-side twin — every
holder now releases it with `defer`, and `answer` holds it through `observe` like `runPhase` does.

All three run on every watcher tick **and** on `AppState.syncTaskPolling()`'s 4s timer, whose predicate is `.running`/`.blocked` **or `isAutoRunning`** — an armed task spends most of its life at `.awaitingReview` between phases, and without that third clause the timer invalidates the moment a phase lands and the chain dies silently — a working agent writes nothing the FileWatcher can see, so without it a running card goes stale for minutes.

**Auto-run ("Run to review").** A task can be armed to run unattended from its current phase
through to `codeReview`, then stop. Three Optional fields carry it (Optional because a new
non-Optional field fails the decode of every existing `task.json` and drops it through the lossy
`remapV1`): `autoRun`, `autoRunRetried` (the per-phase retry budget, on disk so a restart cannot
grant a second free retry) and `autoRunHaltReason`.

`Core/AutoRun.swift` holds the whole policy as pure functions — `nextStep` returns
`wait`/`start`/`retry`/`finish`/`halt`, so the state machine is testable with no herdr at all
(`Tests/ClaudepitTests/AutoRunChecks.swift`). Three rules are structural rather than checked at
runtime: **brainstorm is never run** (`AutoRun.skipped` — its command is built on
`AskUserQuestion` and its suggestions need in-app triage), the chain **never marks a task `.done`**
(`Step` has no case that means done, and the dispatcher calls `runPhase` rather than
`TaskRunner.advance`, the only function that sets it), and a failed/stalled phase gets **exactly
one** retry before halting.

The agent is made non-interactive at the **invocation**, not in the command bodies:
`AutoRun.claudeArgs` appends `--disallowedTools AskUserQuestion,EnterPlanMode,ExitPlanMode` plus an
`--append-system-prompt`. Editing `HookScripts` would not reach a user who has edited their copy
under `claudepit-config/`, since `ManagedInstaller.taskCommandBodies()` prefers that copy. The
appended prompt must **override** rather than merely forbid — `claudepit-task-spec.md` makes
`AskUserQuestion` mandatory, so "where your instructions tell you to ask, decide instead" is
load-bearing. `--permission-mode` stays `auto` in both modes: what parks an unattended session is
the tools, which no permission mode gates. Both plan-mode tools are denied together — denying only
`ExitPlanMode` would trap the plan phase inside plan mode.

Sharp edges the implementation handles: a `.failed` implement usually means the 60-minute wait
expired, and a timed-out wait does **not** stop the agent — so `stepAutoRun` refuses to retry while
`agentExists` still finds one, or two Claudes would share a checkout. `releaseAgentName` renames the
stale agent aside before `openPhaseTab` closes its tab (herdr has no `agent stop`, and
`agent start` answers `agent_name_taken` while the name is held, at which point `agentReady` matches
the dead agent and the prompt goes nowhere) and clears `lastSeenSeq[name]`, since that map is keyed
by a reused name and would otherwise suppress a fresh agent's first scrollback read. The scrollback
window is **1000** lines, not 400: `createPlan`/`implement` have no deterministic artifact, so the
`CLAUDEPIT_ARTIFACT:` marker is the only thing that can report them done, and an unattended agent
prints more. `AutoRun.selectStartable` keeps two armed tasks that share one checkout (a fix task and
its parent) from both launching in the same tick — `worktreeBusy` only sees `.running`/`.blocked`
co-tenants. And `openPhaseTab(focus:)` skips `tab focus` for an armed run, which would otherwise
steal the user's terminal focus once per phase.

**Card state** — `CardState` (`UI/Sections/TaskCardView.swift`) is the one status a card shows: `waiting` / `running` / `failed` / `phaseDone` / `notStarted` / `done` (raw value = sort rank). Terminal statuses (backlog/failed/done) decide on their own; for an in-flight task the **live agent wins** (`working` → Running, `blocked` → Waiting) and `idle`/no-agent defer to the persisted status.

`.awaitingReview` splits in two via `ProjectTask.phaseNeedsReview`: it means "the agent stopped", not "you still owe it something". The test is **"does it still need you"**, not "have you looked at it" — a phase whose deliverable link is set reads **Phase done**, and does *not* stay Waiting until the user opens the file (that made Waiting mean everything, and so nothing). Only two things keep it Waiting: brainstorm suggestions left `accepted == nil` (the one phase with an in-app accept/dismiss flow), and a phase parked here with its artifact link still nil. A non-nil link is the artifact test, since every writer of those paths sets one only for a file that exists — which keeps the property pure enough for a view body. `buildAttention` uses the same property, so finished phases drop off Home's Needs Attention too.

`AppState.liveState(of:)` matches the agent by **name** (`TaskRunner.agentName`) and only then by pane id, and reads `herdrAgents` — *not* `herdrSessions`. Task agents carry no `agent_session`, so `Herdr.AgentEntry.sessionID` is Optional and the session-keyed map never contains them; requiring one used to drop every task agent from `agent list` and left the board's live state permanently dead.

**Phase commands** — `ManagedInstaller.sync()` writes six `<project>/.claude/commands/claudepit-task-{brainstorm,spec,plan,implement,review,fix}.md` slash-commands on launch (**project-scoped**, Claudepit-managed projects only), **overwrite-if-changed**, and sweeps retired ones (`HookScripts.retiredTaskCommandFilenames` — currently the removed `verify` phase's command; `TaskRunner.installCommands` runs the same sweep in worktrees). Tasks that still carry `verify` in `task.json` are healed on load by `TaskStore.remapRemovedPhases` (phase `verify` falls forward to `codeReview`). Task **worktrees** get the same bodies: `TaskRunner.installCommands(inWorktree:commands:)` requires the caller to pass them, and `ensureWorktree` builds them with `ManagedInstaller.taskCommandBodies()` from the `projectRoot` it is already given — so a worktree receives the user's edited copies and honors the enable toggles instead of the `HookScripts` built-ins. `ManagedInstaller.migrateTaskCommandLocationsIfNeeded()` removes any stale global copies under `~/.claude/commands/` and the 4 pre-slash-command subagents under `~/.claude/agents/` — once per machine, recorded in the `completedMigrations` `UserDefaults` key. **Do not edit these files by hand** — edit the source in `HookScripts.swift` (`taskCommands` / `taskCommand*` strings).

**Review findings → tasks.** A `codeReview` phase writes a `CLAUDEPIT_FINDINGS_BEGIN … END` block
**into `review.md`**, and `routeArtifact` parses **the file** first (scrollback is only a fallback —
it is a 400-line window a long review overruns, and it is gone once the pane closes). The block is a
**JSON array**, one object per finding: `ruleId`, `severity`, `category`, `title`, `locations`
(`"path:line"` strings), and the narrative triad `what` / `why` / `fix`. Field names follow **SARIF**
— the industry standard for static-analysis results — wherever SARIF has an equivalent, so it
converts to a SARIF run mechanically; the triad is what SARIF has no first-class home for.
`TaskTransition.parseFindings` still accepts the legacy `severity | title | detail` lines, so reviews
already on disk keep working, and `healArtifactLinks` **upgrades** a task holding legacy findings the
next time it loads — no re-review needed. Finding ids hash `title + first location`, not the
narrative, so rewording a review does not orphan the `spawnedTaskID` links.
`ReviewFinding.isStructured` drives the card layout: What / Why / Fix as separate blocks plus
clickable `file:line` chips, falling back to the single blob for a legacy finding. Triage happens in `ReviewFindingsSheet` (reached from a banner in
`TaskDetailView.codeReviewPanel`, sized by `reviewSheetSize` like the brainstorm sheet), **not** in
the detail panel — ten findings as ten rows in a 250pt column truncated every title and let only one
expand at a time. Several findings can be selected and become **one** task; `FindingTaskDraft`
(Core, pure) is the single builder for its name/description/requirements/priority, so the one-click
create and the pre-filled `NewTaskSheet` (`createSeed`) cannot produce differently-shaped tasks.
`routeArtifact` folds a re-review through `TaskTransition.mergeFindings` — a bare assignment used to
discard every `spawnedTaskID`.

**Fix tasks.** A findings task created with "Fix now" plans `[.implement, .codeReview]`, carries
**no `dependsOn`** — `TaskTransition.canRun` gates on the parent reaching `.done`, which never
happens while it sits in Review, so a dependency would make it permanently un-runnable — and records
the parent in `ProjectTask.followUp` instead. It keeps `phase == nil` at creation: `HomeTaskPipeline`
counts the ends by status and the middle by phase, so a task carrying both is counted twice in the
strip, and `runPhase`'s `phase ?? plannedPhases.first` starts it at `.implement` anyway.

It **inherits the parent's `TaskWorktree`** (branch + path; pane/tab deliberately not copied) because
the implementation under review is *uncommitted* there — a fresh worktree off trunk would not contain
the code the findings point at. `ensureWorktree` reuses it with no code change. Two consequences:
`AppState.deleteTask` refuses to remove a worktree another task still points at, and
`TaskTransition.worktreeBusy` blocks Run/Retry/drag while a co-tenant's agent holds the checkout.

Its implement phase runs **`claudepit-task-fix.md`**, selected by
`TaskRunner.commandFilename(for:task:)` on `ProjectTask.isFixTask` (`followUp != nil` *and* no
`createPlan` phase — adding Plan back in the edit form opts back into the plan-centric command).
Swapping the body rather than adding a sixth `TaskPhase` keeps `TaskBoardView.columns`,
`HomeTaskPipeline`, `expectedArtifact` and `CardState` untouched. `phasePrompt` gives it the
findings as its brief (implement otherwise gets `## Description`/`## Requirements` for no phase but
brainstorm/writeSpec) and points it at the parent's review/spec/plan instead of its own empty
`specPath`/`planPath`. `startAgent` appends `--resume <followUp.resumeSessionID>` after `herdr agent
start`'s `--`, so the agent picks up the parent's implement session — which only resolves in that
session's cwd, i.e. the inherited worktree, so the two settings fall together in the form.

**Phase prompt** — `TaskRunner.phasePrompt` builds what the agent actually receives: the phase's
`/claudepit-task-<name>` slash-command **alone on line 1** (Claude Code hands everything after it to
the command as `$ARGUMENTS`, newlines included — verified), then a line naming that command as the
phase's only instruction set, then a markdown brief (`## Task` / `## Description` / `## Requirements`
/ `## Attachments`) and a `## Paths` block of one `key=value` per line. The `key=value` form is
contractual — every command body reads its paths by name ("the absolute `specPath=` in the
arguments") — so keep each pair on its own line and never pack them back onto line 1. Description
and requirements go only to `brainstorm`/`writeSpec`; downstream phases argue from the spec/plan they
are given paths to. A path whose artifact doesn't exist yet is listed in the "Not produced yet" line
instead of being emitted as a bare `key=`, which the agent would resolve against the cwd. Covered by
`Tests/ClaudepitTests/TaskPromptChecks.swift`.

**Deep links** — from a task's detail view, buttons jump to the produced artifact using the app's focus pattern (there is no `navHistory`/`NavEntry` — that was removed): `app.focusPlanPath = path; app.selected = .plans` and `app.focusSessionID = sid; app.selected = .sessions`. `PlansSection`/`SessionsSection` consume the focus fields via `.onChange`.

**Versions** — a task keeps a **main version** (its top-level `name`/`topic`/`description`/`requirements`/`priority`/`tags`/`dependsOn` fields — TaskRunner and all views read these directly) plus optional **suggestion versions** in `ProjectTask.suggestions: [TaskVersion]?` (both `topic` and `suggestions` are Optional for Codable back-compat — missing keys decode to `nil`). Suggestions are alternate proposals compared against main. Pure mutations live on `ProjectTask`: `applyField(_:from:)` (per-field Accept) and `promote(_:now:)` (Make main — keeps old main as a suggestion). **Suggestion** editing is **backlog-only**: once `status != .backlog` the versions UI and the New Draft button are locked (`TaskVersionsSheet` shows its lock banner, and the five suggestion mutators on `AppState` guard on `status == .backlog`). The **Edit** button — which edits main in place, writing straight through `TaskStore.update` with no `AppState` guard — is wider: `ProjectTask.allowsMainEdit` keeps it available in the **Backlog** and **Brainstorm** columns (`phase == nil || phase == .brainstorm`, excluding `.done`), minus `.running`/`.blocked`, because brainstorm is the phase whose job *is* refining the request, but a live herdr agent already holds the old description in its prompt and would never see the edit. UI: `NewTaskSheet` doubles as the create/edit/draft form (`editing`/`taskID`/`draftMode` params); `TaskVersionsSheet` is the two-pane compare/edit/accept/promote view (reuses `planDiffLines`/`PlanDiffView`). Per-project free-text **topics** persist in `TopicStore` at `~/.claude/claudepit-task-topics/<slug>.json` (seeds the New Task Topic combo box).

## claude -p Subprocess Calls

Every `claude` subprocess the app spawns goes through **`ClaudeCLI`**
(`Sources/ClaudepitCore/Core/ClaudeCLI.swift`), which owns the argv and the environment.
Do not hand-roll a `Process()` for `claude` — use `ClaudeCLI.printArgs` /
`ClaudeCLI.resumeArgs` / `ClaudeCLI.environment()`.

**Isolation is `--safe-mode`, never `--bare`.** Scripted calls must not pick up the user's
hooks — above all Claudepit's own `UserPromptSubmit` summary hook, which injects
`additionalContext` and would contaminate every answer. `--safe-mode` suppresses hooks
(user *and* project scope), CLAUDE.md, skills, plugins, MCP servers and auto-memory while
leaving auth working. `--bare` suppresses the same things but **disables OAuth/keychain
auth** — it accepts only `ANTHROPIC_API_KEY` or an `apiKeyHelper`, so on a subscription
login every call fails with `Not logged in · Please run /login`. It was the cause of a
total outage of Q&A, Discover and `/context`.

**Never set `CLAUDE_CONFIG_DIR`.** Setting it *at all* — even to the default `~/.claude` —
makes the CLI look up a keychain service name suffixed with a hash of the path
(`Claude Code-credentials-<hash>`), which holds no credentials. `ClaudeCLI.environment()`
never adds it, and deliberately does not strip an inherited one (a user who exports it
globally has their credentials under that hashed entry). It also never removes `USER` —
the keychain *account* name is derived from it.

**Read failures from both streams.** `ClaudeCLI.failureMessage(stdout:stderr:)` prefers
stderr and falls back to stdout, because an unknown flag reports on stderr while
`Not logged in` arrives on **stdout** with an empty stderr and exit 1. Reading stderr alone
silently discards the diagnostic that matters most.

**Run in the active project.** User-facing calls take a `cwd` — the app's `activePath` (or
the session's worktree, where one applies). Without it the subprocess inherits wherever the
app was launched from. `--no-session-persistence` keeps these runs out of the project's
session list.

| File | Purpose | Flags |
|------|---------|-------|
| `Sources/ClaudepitCore/Core/PlanQARunner.swift` | Plan & Memory Q&A, improvement generation | `ClaudeCLI.printArgs` + `cwd` |
| `Sources/ClaudepitCore/Core/DiscoverRunner.swift` | Semantic session search | `ClaudeCLI.printArgs` + `cwd` |
| `Sources/ClaudepitCore/Core/UsageRunner.swift` | `/usage` report for Home's Usage card (also rewrites the CLI's own caches) | `ClaudeCLI.printArgs` + `cwd` |
| `Sources/ClaudepitCore/Core/TaskDraftRunner.swift` | New Task "Create with AI" — fills the form from a free-text idea | via `PlanQARunner.ask` + `cwd` |
| `Sources/ClaudepitApp/UI/Sections/SessionDetailView.swift` | `/context` report (shown in popover) | `ClaudeCLI.resumeArgs` + `cwd` |
| `Sources/ClaudepitApp/UI/Sections/PluginsSection.swift` | `claude plugin …`, `/reload-plugins` | **none** — `--safe-mode` would disable the very plugins being managed |

## Every other subprocess: `Subprocess`

`Sources/ClaudepitCore/Core/Subprocess.swift` is the one bounded way to run a child process.
`Herdr.run` and `TaskRunner.git` go through it; do not hand-roll `Process` + `waitUntilExit()`
again. Two hangs it exists to prevent, both of which suspend the awaiting Swift task **forever**
(a `withCheckedContinuation` that never resumes cannot be cancelled from outside):

- **Pipe-buffer deadlock.** A pipe holds ~64KB. Reading *after* `waitUntilExit()` — the shape every
  call site used — hangs on any child that writes more: it blocks in `write()`, so it never exits,
  so the wait never returns. An undrained `standardError` is the same trap with no reader at all.
  Both pipes are drained concurrently while the child runs.
- **A child that never exits.** `waitUntilExit()` is not interruptible, so the only lever is
  killing it: a `timeout` ceiling (SIGTERM, then SIGKILL after a grace).

`Herdr.run` returns **stdout only**, deliberately: herdr writes `{"error":{"code":…}}` to *stderr*
and leaves stdout empty, so a failed command still yields nil from `runJSON` — which is what
`TaskRunner` reads as failure (`agent start` answering `agent_name_taken` is the load-bearing case).
A herdr call carrying its own `--timeout <ms>` must pass `TaskRunner.ceiling(forHerdrTimeoutMS:)`,
or the 120s default kills a legitimate 30-minute `agent wait` and lands the phase in `.failed`.

## Focusing a herdr pane

`HerdrFocus` (`Core/HerdrFocus.swift`) owns both halves of "show me that pane", because doing only
the first half is indistinguishable from the button being broken:

1. **Select it inside herdr** — `agent focus <agentName>` first, `tab focus <tabID>` only as
   fallback. The agent name is stable for the life of the phase; the tab id is a snapshot written
   into `task.json` when the pane was created and goes stale on a herdr restart, at which point
   `tab focus` silently no-ops.
2. **Raise the window** — herdr is a TUI inside a terminal application, so switching its tab changes
   nothing visible while Claudepit is frontmost. `HerdrFocus.hostCandidatePIDs()` walks up from
   every live `herdr` process via `sysctl(KERN_PROC_ALL)` (no subprocess — `Executable.find`'s rule)
   and `AppState.activateHerdrHost()` activates the first `.regular` app among them. Chains passing
   through our own pid are dropped: the short-lived `herdr` commands *this app* spawns are herdr
   processes too, and their ancestry leads back to Claudepit, which would "win" and activate
   ourselves. Every call site pairs the focus with `activateHerdrHost()`.

## Detecting a signed-out CLI

`ClaudeAuth` (`Sources/ClaudepitCore/Core/ClaudeAuth.swift`) wraps
`claude auth status --json`. Two behaviours to know: it **exits 1 when logged out** but
still prints valid JSON, so the payload — not the exit code — decides; and a CLI too old to
have the subcommand must land in `.checkFailed`, never `.loggedOut`, so an old install is
never reported to the user as "signed out".

`AppState.claudeAuth` caches the result. It is a **stored** `@Published` value on purpose:
resolving it needs a subprocess, and a `Process` + `waitUntilExit()` reached from a SwiftUI
view body aborts the app (same hazard documented on `Herdr.available()`). Never add a
synchronous `claudeLoggedIn()` for views to call. It refreshes on launch, on
`NSApplication.didBecomeActiveNotification` (only while signed out — the login flow
finishes in a browser), on the banner's Recheck button, and whenever a failed call posts
`.claudeAuthSuspect`. Not on `setActivePath`: auth is machine-global, not per-project.

## Cross-Section Deep Links (Focus Pattern)

There is **no** `navHistory`/`NavEntry`/breadcrumb system — it was removed (commit `69b1f29`). Cross-section navigation uses simple one-shot "focus" fields on `AppState`:

```swift
// Jump to a specific plan / session / managed config, then switch section:
app.focusPlanPath = path;         app.selected = .plans
app.focusSessionID = sid;         app.selected = .sessions
app.focusManagedConfigID = id;    app.selected = .appConfig
```

The destination section consumes the field via `.onChange` and clears it: `PlansSection` reads `focusPlanPath` (`applyFocusPlanPath()`), `SessionsSection` reads `focusSessionID`, `AppConfigSection` reads `focusManagedConfigID` (`applyFocusManagedConfigID()`, which expands the matching card). To add a new deep link, set the relevant focus field and set `app.selected` — no history to push.

Key fields: `AppState.focusPlanPath`, `AppState.focusSessionID`, `AppState.focusManagedConfigID`. Consumers: `PlansSection.swift`, `SessionsSection.swift`, `AppConfigSection.swift`.

Home's quick actions and drill-downs use the same one-shot contract for *intents* rather than
identities: `openNewTaskPanel` / `focusTaskStatusFilter` / `focusTaskPhase` (consumed by
`TasksSection.applyPendingIntents()`) and `openDiscoverSheet` (consumed by
`SessionsSection.applyDiscoverIntent()`). They are kept apart from `TasksSection.applyFocus()`,
which deliberately clears every filter for `focusTaskID` — the opposite of what a filter intent wants.

## Machine Portability (no hardcoded prefixes)

The checkout must run on any Mac, for any user, with no per-machine setup. Two rules:

**1. Never hardcode a binary's install prefix.** Resolve external CLIs through
`Executable.find(_:)` (`Sources/ClaudepitCore/Core/Executable.swift`), which searches
`PATH` plus the usual locations (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
nvm, `/usr/bin`, `/bin`). `Herdr.resolvedPath` and both `resolveClaudePath()` helpers use
it. Assuming `/opt/homebrew/bin/herdr` is what broke the app for a user who had herdr in
`~/.local/bin`.

`Executable.find` is pure filesystem **by design — never add a subprocess to it.**
`Herdr.available()` is called from SwiftUI view bodies (session and worktree rows); a
`Process` + `waitUntilExit()` there spins the run loop, re-enters SwiftUI's transaction
flush mid-update, and aborts the app via `AG::precondition_failure` (this presented as
`AttributeGraph: cycle detected` spam followed by SIGABRT).

**2. Hook registrations are reconciled, not appended.** The commands written into
`<project>/.claude/settings.json` embed an absolute path
(`bash '/Users/<me>/.claude/claudepit-*-hook.sh'`), so a checkout that moves between
machines carries registrations pointing at a home that no longer exists. The installers
use `HookRegistration.reconcile` (`Sources/ClaudepitCore/Core/HookRegistration.swift`),
which identifies our entries by **script filename, not full path** — so a stale entry from
another machine is replaced rather than duplicated. Matching on the exact command string
instead leaves one dead hook per machine, each failing with exit 127 on every fire.

Nothing about "this machine" is persisted; the home directory is re-derived on every
launch. That is what keeps the checkout shareable — saving a prefix on first run would
re-break it the moment someone else opened it.
