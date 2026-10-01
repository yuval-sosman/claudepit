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
- **`groups`** — array of group objects (id, name, color, createdAt, optional `collapsed`), in display order
- **`assignments`** — map of `sessionID → groupID`

To change group logic, edit `Sources/ClaudepitCore/Core/GroupStore.swift` and `Sources/ClaudepitCore/Model/SessionGroup.swift`.

**Which file a session's group lives in is `SessionSummary.groupKey`**, stamped by the scanner: with
a project open it is *that project's* key for every listed session — worktree checkouts
(`<slug>--claude-worktrees-…`) and subdirectories included; across all projects it is the
project that owns the session's `cwd`. Keying by the session's own folder (the old rule) gave
worktree sessions a group file the Groups tab never read. Read and write groups only through
`groupKey`, never `projectSlug` (that is the transcript folder, which `SummaryStore` uses).

**Groups live in `AppState.sessionGroups`**, loaded with the sessions (`SessionScanner.listing`).
Every edit goes through `AppState+Sessions` → `GroupStore` → `applyGroups(key:)`, which re-reads
that one file and re-stamps `groupID` in place. Don't cache groups in a view: the page once kept
its own copy refreshed only when the session *count* changed, so a group created from a row's
menu was missing from the Groups tab and the session filed into it was listed nowhere. An
assignment to a group that no longer exists reads as ungrouped (`ProjectGroups.validGroupID`).

## Sessions List (left card)

`UI/Sections/SessionList/` — `SessionListView` takes `[SessionSummary]` + a plain-data
`SessionListContext` (groups, herdr states, stats, task names) + `SessionListActions` closures,
never `AppState`, so it renders offscreen. What it shows is decided in Core and tested in
`SessionListingChecks`: `SessionListing` (date sections, search, the Groups layout — manual groups,
then one automatic group per task, then Ungrouped — live status, shift/arrow ranges),
`SessionOpening`/`SessionTitle` (titles), `ProjectFolders` (which folders are the project's).

- **Listing scope.** `ProjectFolders.folders` is shared with `ProjectUsageScanner`: the project's
  own folder, its worktree folders, and other `<slug>-…` folders **only if their transcripts' cwd
  is inside the project** — a bare prefix match listed `~/Dev/app-v2` under `~/Dev/app`, and every
  project under `~`. Claude Code's slug maps `/ . +` to `-`; both that and `Paths.slug` are tried.
- **Not listed:** a transcript with no user record (a resume stub), and one that only ran local
  commands and never got a reply. Titles come from a task phase's task name, then `ai-title`, the
  first typed prompt, the first slash command with arguments — the UUID only as a last resort.
- **Scanner cost.** No subprocesses: `TranscriptLines` searches the memory-mapped file, and
  `SessionScanner.HeadCache` re-reads a transcript only when its size/date changed (and then only
  the part that can still change). Spawning two `grep`s per transcript cost ~9 s per rescan here.
- **Liveness.** The FileWatcher watches folders, which don't change on append, so dates and the live
  dot went stale. The page calls `AppState.refreshSessionLiveness()` every 10 s while visible
  (re-stat + herdr), moving dates only forward. It stats with `attributesOfItem`, **not**
  `url.resourceValues`: a URL from a listing that prefetched date/size answers with those cached
  values forever, so `isActive` went false after a minute and flickered back on each rescan. One status slot per row: herdr's `working` /
  `blocked` (waiting) / idle (open), else "written in the last minute".
- **Selection** is `SessionListState` (Set + primary + anchor): click, ⌘-click, ⇧-click, ↑/↓
  (⇧ extends), ←/→ fold subagents, ⌘A, ⌫ trash, ⌥⌘F search. Clicking never scrolls the list; only
  keyboard moves (minimal) and deep links (`revealRequest`, centred — it also clears filters and
  unfolds groups that hide the row) do. Several selected → `SessionSelectionPanel` in the detail
  card. Selection, expansion, search and date filter survive leaving the page
  (`AppState.sessionsPageMemory`); view options persist in `@AppStorage("sessionsListPrefs")`.
- **Worktrees** read at a glance: each *existing* worktree has its own colour, drawn as a stripe
  down the row's leading edge, a pill (`task-<id>-…` shortens to the id), its automatic task
  group's icon and the session page's badge. Slots come from `WorktreeColors.assign` via
  `AppState.worktreeColorSlots` (refreshed on every worktree scan, remembered in UserDefaults): a
  worktree keeps its colour, a new one takes a free colour, two share only past the palette's 10
  (`--snapshot-sessions <p> --palette` renders them),
  and a removed worktree's sessions draw neutral. (Hashing names straight into slots made live
  worktrees collide.) Clicking the pill filters to that worktree (`worktreeFilter`, a chip). Phase
  pills are neutral so colour in the meta line only means "which worktree". Manual group colours
  stay a separate, user-picked vocabulary (the solid dot) on purpose.
- **Trash** (`SessionTrash`) takes the transcript *and* its `<id>/` folder to the Trash and removes
  the summary and group assignment; it is confirmed, and refused for a live session.
- **Debug snapshot:** `.build/debug/ClaudepitApp --snapshot-sessions <project path | all> --out <dir>
  [--tab groups] [--query q] [--demo-groups] [--demo-live] [--select a,b] [--expand id]
  [--new-group] [--empty] [--time-scan]` (`DevSessionsSnapshot.swift`) — real transcripts, no
  `AppState`, no writes.
- **Interaction harness:** `--snapshot-sessions <project> --interaction-test [--out dir]`
  (`DevSessionsInteraction.swift`) drives the real list in an offscreen key window with synthetic
  clicks and keys and asserts the outcome (54 checks: selection, ⌘/⇧-click, arrows, ⌘A, ⌫, Esc,
  subagents, inline create/rename, duplicate names, fold, + button, ⌥⌘F, ↓ from search, deep
  links, every menu's items and actions, and drops). Menus are data (`SessionListMenus` →
  `MenuEntry`, rendered by `MenuEntriesView` for both the "…" and right-click menus) and drops
  resolve in `SessionListMenus.drop`, because a SwiftUI `Menu` can't be opened and a drag can't be
  performed offscreen — only the AppKit popup and drag gesture themselves go unexercised. Rows and headers report their frames through the DEBUG-only `debugFrame(_:)` hook —
  SwiftUI builds no accessibility tree offscreen, so they can't be found by identifier. Events
  go to `window.sendEvent` (so `NSApp.currentEvent` is nil — don't read it in handlers). It
  caught three real bugs, now fixed and worth knowing as SwiftUI-on-macOS traps:
  - `onTapGesture` on a `LazyVStack` **section header** never fired; headers are a `Button`.
    Double-click (rename) is two clicks within `NSEvent.doubleClickInterval`, timed by hand.
  - The **Delete key** (U+007F) never reaches `onKeyPress` — it becomes `deleteBackward:`;
    `onDeleteCommand` catches it.
  - **↓ in a `TextField`** is eaten by the field editor (`moveDown:`); the search box is an
    `NSTextField` bridge (`SearchTextField`) whose delegate takes the command first.
  - Modifier clicks use `TapGesture().modifiers(.command)`/`(.shift)`, not
    `NSEvent.modifierFlags` read when the tap ends.

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

**Phase commands** — `ManagedInstaller.sync()` writes seven `<project>/.claude/commands/claudepit-task-{brainstorm,spec,plan,implement,review,fix,merge}.md` slash-commands on launch (**project-scoped**, Claudepit-managed projects only), **overwrite-if-changed**, and sweeps retired ones (`HookScripts.retiredTaskCommandFilenames` — currently the removed `verify` phase's command; `TaskRunner.installCommands` runs the same sweep in worktrees). Tasks that still carry `verify` in `task.json` are healed on load by `TaskStore.remapRemovedPhases` (phase `verify` falls forward to `codeReview`). Task **worktrees** get the same bodies: `TaskRunner.installCommands(inWorktree:commands:)` requires the caller to pass them, and `ensureWorktree` builds them with `ManagedInstaller.taskCommandBodies()` from the `projectRoot` it is already given — so a worktree receives the user's edited copies and honors the enable toggles instead of the `HookScripts` built-ins. `ManagedInstaller.migrateTaskCommandLocationsIfNeeded()` removes any stale global copies under `~/.claude/commands/` and the 4 pre-slash-command subagents under `~/.claude/agents/` — once per machine, recorded in the `completedMigrations` `UserDefaults` key. **Do not edit these files by hand** — edit the source in `HookScripts.swift` (`taskCommands` / `taskCommand*` strings).

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

## Updating a Worktree From Its Base

`UpdateFromBaseControl` (`UI/UpdateFromBaseControl.swift`) is the ONE view for this, hosted by both
`WorktreesSection`'s WORKTREE STATE block and `TaskDetailView`'s Worktree row, so the two can never
disagree. It offers up to three pills:

- **Update from `<base>`** — `WorktreeStager.updateFromBase`. Refuses a tracked-dirty tree.
- **Stash & update** — `WorktreeStager.updateFromBaseStashing`. Shown only when the tree is dirty
  and no merge is open.
- **Merge with Claude** — `TaskRunner.openMergeAgent`, via `AppState.openMergeAgent`.

**The stashing path restores everything on every failure.** stash (tracked only, never `-u`) →
merge → pop; a conflicted *merge* aborts and pops, returning `.conflicted`, so the user is never
left holding both a half-merge and a stash. Only a conflicted *pop* leaves work to do, and that is
the new `.stashConflicted` outcome — git keeps the stash entry on a conflicted pop, so nothing is
lost. Two git facts the state machine depends on, both verified rather than assumed: `git stash
push` with nothing to save prints "No local changes to save" and exits **0** (hence the
`refs/stash` before/after comparison — the exit code lies), and a conflicted `git stash pop` keeps
the entry while a clean one drops it.

**The merge agent is not a phase.** `openMergeAgent` is a hand-off like `openInHerdr`, but it never
touches task status — a merge is not a phase, and marking the task `.running` would hand it to the
pollers, which would land it on a phase result it never produced. `mergeAgentName` is deliberately
outside the `TaskPhase` namespace (`task-<id>-merge`, or `merge-<dirname>` with no task) so
`resolveRunning`/`resolveBlocked` cannot mistake it for a phase agent, while `HomeAgents` still
attributes it to the task via the `task-<id>-` prefix. It opens its **own** tab via
`Herdr.tabCreate` and persists nothing onto `task.worktree` — `openPhaseTab` would close the
task's stored tab and overwrite `paneID`/`tabID`, which is the bookkeeping every phase focus
depends on.

**The agent resolves, it does not commit.** `TaskRunner.installGitDenyList` denies
`Bash(git add:*)`/`Bash(git commit:*)`/`Bash(git stage:*)`/`Bash(git push:*)` in every task
worktree, and deny wins over `--permission-mode auto`. `claudepit-task-merge.md` therefore tells
the agent to drive `git fetch`/`git stash`/`git merge` (none of which are denied), resolve the
conflict markers, verify the build, and stop — the user finishes from the control's existing
**Review changes** → `WorktreeStager.commit`. Do not weaken the deny-list to "fix" this.

**The live-agent guard is the control's own.** Each host passes a *proxy* for it — `wt.isActive`/
lock state in Worktrees, `task.status` in the task panel — and neither sees the merge agent, which
belongs to no phase and takes no worktree lock. `AppState.worktreeAgentName(path:)` answers it
directly off the cached `herdrAgents` list (`Herdr.AgentEntry` already carries `cwd`, so there is
no subprocess and it is safe from a view body). When the live agent *is* our merge agent, the pill
becomes **Open merge in herdr** and only focuses — navigate, don't re-prompt, the same rule
`openInHerdr` follows.

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

## Home and Usage

Home answers each question once. **Left column (work):** Tasks, Live Agents, Recent. **Right
column (numbers):** `HomeLimitsCard` "Claude Code" (limit gauges, credits, what's using the
limits — from the CLI's `/usage` caches), `HomeUsageCard` "Usage" (what the work cost — counted
from transcripts, for **this project** or **all projects**, 7D/30D/90D), `HomeHabitsCard`
"Activity" (the year heatmap and rhythm — from `stats-cache.json`). An earlier layout repeated
per-model tokens, tokens per day and token totals in two cards with two different numbers; the
stats cache's token/model fields are no longer read at all (`StatsSnapshot` keeps only activity).
Don't reintroduce a second source for cost, tokens or models — extend the Usage card instead.

**Counting** (`Core/ProjectUsage.swift`, rules in its header comment) follows the claude-usage
plugin's definitions (a separate project — share the *definitions*, never the code): an API
call is `message.id + requestId` (Claude Code writes one line per content block, each repeating
the usage — summing lines doubles every total), keeping the line with the most output tokens;
`<synthetic>` is not a call; prompts are main-thread `promptSource` `typed`/`queued` lines;
active time caps each gap at five minutes; hit rate is Σ cache reads ÷ Σ context. When this was
built, a 30-day claudepit window and two single sessions matched that plugin's report exactly
on every figure; re-check against it after changing a rule. `SessionTranscript` applies the same
per-call rule to its `.turnUsage` events (a later line of a call replaces the event in place),
so the transcript view's token line is no longer doubled either.

- **Prices** (`Core/ModelPricing.swift`): USD per MTok with 5-minute and 1-hour cache writes
  apart, fast mode and regional routing as multipliers. An unlisted model is priced like the
  nearest version of its family and named under the card; add a table line to price a new model
  exactly. `canonical` folds provider ids (`us.anthropic.…-v1:0`, `@2025…`, `[1m]`, dates).
- **Scanning** (`Core/ProjectUsageScanner.swift`): each file's `TranscriptDigest` is cached by
  path + mtime + size, so a rescan re-reads only transcripts that changed (first scan ≈1 s per
  100 MB). `base == nil` scans every project. `AppState.reloadProjectUsage()` counts the scope in
  `AppState.usageScope` (persisted), is coalesced (one trailing rescan, and a rescan when the
  scope or project changed mid-scan), and runs from `reloadSessions()` only while Home is
  showing. A folder URL with a trailing `/` must still find the checkout — `slug(_:)` strips it.
- **Colours**: stacked bars are ordered by a fixed key (model family tier via
  `ModelBadge.familyOrder`, or the fixed token-type order) so neighbours are always the pairs
  the palette was checked for; `ModelBadge.color(for:)` is the one model→colour map for the
  whole window, and `UsagePalette` (`UI/UsageViews.swift`) holds the rest. Change a colour or an
  order only together, and re-check them as a set.
- Shared pieces (`StatTile`, `CostBreakdownView`, `StackedBar`, `Money`/`Percent`/`Elapsed`)
  live in `UI/UsageViews.swift`, used by Home and the session report alike.

## Session Transcript View

A session's page (`SessionDetailView`) is a header — title, one fact strip (start, span, models,
context gauge, tokens in/out, compactions, branch) and the Summary / Report / Context /
focus-in-sidebar / ⋯ actions — over `TranscriptView` (`UI/Transcript/`). Counts of prompts,
calls, edits, subagents and errors live on the filter chips only; the header used to repeat them. The goal it is built to: a reader
understands every step of the session — each prompt, reply, thought, tool call, injected piece of
context, hook, system prompt and system event, in order, with its time and cost.

**Three layers, each tested or checkable:**
- **`SessionTranscript`** (Core) parses the JSONL incrementally into `SessionEvent`s. Later records
  resolve into earlier events *in place* (a `tool_result` into its call, a Stop-hook summary into
  its hook run, a task notification onto the call that launched it), so an event's index is stable
  and the view keys rows on it. The one exception is `insert(_:at:)` — print-mode sessions write the
  reply before the prompt, and the prompt is moved back in front; it shifts every stored index.
  `TranscriptFileTail` is the live reader (appends, half-written lines, truncation).
- **`TranscriptModel`** (Core, pure) arranges events into turns and display rows, tags each row with
  `TranscriptFilter`s, folds runs of ≥4 routine calls (`keyTools` never fold), attaches
  Pre/PostToolUse hooks to their call (the hook's `toolUseID` *is* the call id), and answers
  `visibleRows(filters:query:runExpanded:)`. Checks: `TranscriptParseChecks`, `TranscriptModelChecks`.
- **Views** take a model plus `TranscriptActions` (closures), never `AppState`, so they render
  anywhere — including the debug snapshot tool below.

**Features the old page had, kept on purpose** — the rebuild dropped them once and the user
noticed; check them after any rework: the **Plans / Tasks / Questions** filter chips; every row
about a plan file (a Write/Edit under `Paths.plansRoot`, ExitPlanMode, plan-mode context) is styled
as a plan row, but the always-visible **Ask** (inline `PlanQAPanel`) and **Plans**
(`actions.openPlan` → the Plans page, which also scrolls its list to the plan) links, or "plan
file deleted", sit **only on a plan's Write rows** — plus, for a plan this session never writes,
its first edit (`TranscriptModel.planLinkEvents`; by request — they used to be on every plan row); **task spans**
(`TranscriptModel.taskSpans` — open on `TaskUpdate(in_progress)`, close on that task's
completion or the next task's start): a coloured bar down the span, a "Started Task N" heading
with its duration, `TaskCreate` rows showing the task's final status with a `#N` jump to its
span, and clickable TaskList / TodoWrite lines; the timeline rail's **colour key** (ⓘ); the session's
token totals; a visible **focus in sidebar** button. Links that land on a row go through
`TranscriptView.jump(toEvent:)`, which unfolds a run and clears filters that hide the target.
Row links sit in `DisclosureRow`'s `accessory` slot — *outside* the toggle button, so a click on
one never opens or folds the row.

**What the CLI records and how it shows** (catalogued from 213 real transcripts, CLI 2.1.236–285):
thinking blocks are usually *signed and empty* — counted in the turn footer, shown only when they
carry text; `attachment` records with a `rendered` field are text the model received — shown as
Context with "exact text the model received"; `prompt_snapshot` is the system prompt and tool list
(one row per distinct prompt); `total_tokens_reminder`, `deferred_tools_record`, `credential_org`
and `thinking_drop` are bookkeeping and dropped (`ContextItemBuilder.skipped`); an unknown attachment
still shows (by its `rendered` text, else raw). Task-notification bodies are **XML-escaped**
(`-&gt;`) — `TaskNotification.parse` unescapes; command output can carry **ANSI codes** —
`stripANSI`. A queued message's timestamp is when it was *sent*, its file position when it was
*delivered*; the view shows it where it was delivered.

**Sharp edges:**
- Rows are computed for one model and must never be drawn against another. The loader stamps each
  rebuild with a `generation`; `TranscriptView.currentRows` recomputes inline when `rows` is behind,
  and `TranscriptRowView` refuses indices the model doesn't have. Without both, a live transcript
  that was rewritten shorter trapped with "Index out of range" (reproduce:
  `--snapshot-transcript <big file> --shrink-test`).
- Transcripts are **trees** (`parentUuid`). Two prompts with one parent are a rewind — the person
  edited and resent — and every turn on the earlier branch is marked `rewound`, faded, and says
  which turn replaced it. Read linearly, a dead branch looks like conversation Claude received.
- Expansion state lives in one `TranscriptExpansion`, not in rows: lazy rows are recycled while
  scrolling, and per-row `@State` would reset. It holds a `mode`, the toolbar's **Expand: Edits /
  All** toggle (there is no collapse-all, by request). `.edits` is the default: every row takes
  its own default, so file edits open on their diffs and everything else, questions and plan
  approvals included, sits on one line. `.all` opens everything. It also holds the ids the reader
  flipped by hand, which a mode switch resets, and the open **panels** (plan Q&A) — tools, not
  content, so "All" never opens them.
- The toolbar ends where the rows do (`TranscriptView.rowsTrailingInset` = rail + gap + the
  list's inset), not at the window edge above the rail.
- The scroll tracker is held in `@State`, *not* `@StateObject`: observing it would re-diff the whole
  list on every scroll tick. Only the rail and the jump button observe it.
- **Live follow** moves the list on its own, so it is the first suspect for "it scrolls by itself".
  It scrolls to the end on a rebuild only while `tracker.following` holds and the reader isn't
  scrolling. `following` **starts false** and is armed only by the reader scrolling *down* into
  the end (12pt slack) or an explicit jump there (opening a live session, Latest, the rail's
  bottom), or a session going live under a reader already at the end. On macOS 15+
  (`ScrollIntent`) geometry steps where the content *size* changed are relayouts, not the reader,
  and neither arm nor clear it — while following they re-pin the end instead (lazy rows measured
  after a jump grow the content). Any upward move clears it, as does every programmatic jump away
  (rail, links, filters, a revealed panel). It used to start true and only an upward scroll
  cleared it: a session opened idle and read top-down was still "following" when it came alive,
  and every write threw the reader to the end — compounded by `isActive` flapping (see Sessions
  List → Liveness). macOS 14 falls back to the end sentinel's appear/disappear. Check:
  `--follow-test` (now also "opened idle, read down, went live" — must stay put).
- The **timeline rail** (`TranscriptRail`) marks *rows*, not turns:
  `TranscriptModel.landmark(of:)` (Core, tested) gives each notable row a kind. Turn starts are
  wide marks; edits, plan steps, questions, subagents, skills, task changes, compactions and
  failures are short ones. Marks are placed by row index. A per-turn rail was nearly empty for the
  common one-prompt session: two marks for 74 calls.
- When the row the reader is anchored on folds into a run (a fourth routine call arrived),
  `recompute()` re-anchors `topRowID` on the run, or the list loses its place.
- A panel a row's link opens (a plan's Q&A) goes in `DisclosureRow.inset`, under the title line,
  never below a long body. `expansion.requestReveal` scrolls it into view with a `nil` anchor
  (only as far as needed), leaving 44pt for the floating End/Latest button. Its field takes focus
  only on that opening click, not each time the lazy list rebuilds the row.
- Highlighters stamp their own fonts; `CodeHighlight` strips them (Splash's is proportional).
- `PathText` parses markdown **once** and lays file links over the result. Splitting the text at
  each path first broke any bold or code span around it.

**Debug snapshot tool** (DEBUG builds): render a real transcript offscreen to PNG without launching
the app or creating an `AppState` (whose pollers would drive tasks):
`.build/debug/ClaudepitApp --snapshot-transcript <file.jsonl> --out <dir> [--width N] [--height N]
[--list] [--rows A-B | --only id,id] [--open id,id] [--expand-all] [--filter a,b] [--query q]
[--scroll-to id] [--hover-row id] [--rail-key] [--reveal id] [--markdown] [--shrink-test]
[--follow-test]`. Plan links draw
(the tool supplies a stand-in `openPlan`); open a plan's Q&A with `--open <row id>/qa`. `--list` prints row ids to pick
from (add `--expand-all` to list calls inside folded runs). See `DevSnapshot.swift`. Tall PNGs:
slice with `CGImage.cropping`, not `sips --cropOffset` (it crops around the centre).

## Session Report

A session's **Report** button (`SessionDetailView`, in the header's actions) opens
`SessionReportView` as a sheet inside the app, styled and sized like the Source Control sheet
(title bar with refresh and close, Esc closes; 92% of the main window, measured at tap time
because `keyWindow` becomes the sheet once it opens). The `SessionReportRequest` carries every
path the report needs, so it reads files only. From a subagent's transcript it opens the parent
session's report (the subagent is a row there). Tiles lay out through `BalancedGridLayout`
(`UI/UsageViews.swift`): balanced rows at any width, never 5 + 1. Its column math is
`HomeLayout.balancedColumns` in Core, tested — SwiftUI measures with `nil` and `.infinity` widths
too (Home's lazy stack does on open), and `Int(.infinity)` traps, which once crashed Home.

`Core/SessionReport.swift` builds it from the session's main transcript plus its subagents,
parsed with `TranscriptDigest.parse(…, detail: true)` (per-thread input/compaction/tool-list/
resume timelines and tool timings, collected only when asked). Cost, prompts, active time and
the breakdowns come from `ProjectUsageSummary` over that one session, so they are exactly Home's.
Per session it adds: context per main-thread call (with compactions), cache misses — a call that
re-wrote more than 1,000 tokens of its thread's history, re-written = `max(0, min(previous
context − cache read − input, cache write))`, none across a compaction — each with its idle time
(from the previous response's end to the request start), the thread's cache lifetime (1 h when
it wrote mostly 1-hour entries, else 5 min), a cause (`SessionReport.cause`: model switch, tool
list change, subagent resumed, return after a break, waiting on you, slow tool, slow API, effort
change, the CLI's logged reason) and its extra cost (re-written × (write − read price)); plus
subagents (calls, cost, hit rate, peak, misses) and tools (calls, failures, total time).

- Checks: `Tests/ClaudepitTests/ProjectUsageChecks.swift` (usage, scanner, report) and
  `SessionTranscriptChecks.swift` (one `.turnUsage` per call).
