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
- `task.json` — the record (`ProjectTask`: name, description, `phase`, `status`, `requirements`, per-phase `autoAdvance` gate, `links`).
- `attachments/` — copied-in images (storage designed; drag-in UI is a follow-up).

Key files: `Sources/ClaudepitCore/Model/Task.swift` (model), `Core/TaskStore.swift` (per-task-folder atomic load/save/delete), `Core/TaskTransition.swift` (pure phase-advance + `CLAUDEPIT_ARTIFACT:` parsing), `Core/TaskRunner.swift` (herdr orchestration actor), `UI/Sections/TasksSection.swift` + `TaskDetailView.swift`.

**Execution** — `TaskRunner` (an actor, `.shared`) runs **only while the app is open** (like `CronRunner`). One phase per `start()`: it spawns/reuses a herdr pane (`herdr pane split` → `agent start --kind claude`), prompts the matching subagent, waits for `blocked`/`done` (state read from `.result.agent.agent_status` in herdr's JSON), reads scrollback, and greps a `CLAUDEPIT_ARTIFACT: <path>` marker line to populate `links`. Subprocess calls run off-actor (`nonisolated` + `withCheckedContinuation`) so long phases don't block the actor. If herdr isn't on PATH, execution is disabled and the UI shows a notice.

**Auto-advance** — each phase has an `autoAdvance` flag. After a phase completes, `TaskTransition.onPhaseComplete` advances to the next phase (`status: .idle`) only if the flag is true; otherwise it holds with `.awaitingReview`. `AppState.driveIdleTasks()` re-invokes `start()` for any task left `.idle` on an advanced phase on the next watcher tick, chaining phases; a `driving` guard set prevents double-spawning.

**Phase commands** — `ManagedInstaller.sync()` writes six `<project>/.claude/commands/claudepit-task-{brainstorm,spec,plan,implement,verify,review}.md` slash-commands on launch (**project-scoped**, Claudepit-managed projects only), **overwrite-if-changed**. Task **worktrees** get the same bodies: `TaskRunner.installCommands(inWorktree:commands:)` requires the caller to pass them, and `ensureWorktree` builds them with `ManagedInstaller.taskCommandBodies()` from the `projectRoot` it is already given — so a worktree receives the user's edited copies and honors the enable toggles instead of the `HookScripts` built-ins. `ManagedInstaller.migrateTaskCommandLocationsIfNeeded()` removes any stale global copies under `~/.claude/commands/` and the 4 pre-slash-command subagents under `~/.claude/agents/` — once per machine, recorded in the `completedMigrations` `UserDefaults` key. **Do not edit these files by hand** — edit the source in `HookScripts.swift` (`taskCommands` / `taskCommand*` strings).

**Deep links** — from a task's detail view, buttons jump to the produced artifact using the app's focus pattern (there is no `navHistory`/`NavEntry` — that was removed): `app.focusPlanPath = path; app.selected = .plans` and `app.focusSessionID = sid; app.selected = .sessions`. `PlansSection`/`SessionsSection` consume the focus fields via `.onChange`.

**Versions** — a task keeps a **main version** (its top-level `name`/`topic`/`description`/`requirements`/`priority`/`tags`/`dependsOn` fields — TaskRunner and all views read these directly) plus optional **suggestion versions** in `ProjectTask.suggestions: [TaskVersion]?` (both `topic` and `suggestions` are Optional for Codable back-compat — missing keys decode to `nil`). Suggestions are alternate proposals compared against main. Pure mutations live on `ProjectTask`: `applyField(_:from:)` (per-field Accept) and `promote(_:now:)` (Make main — keeps old main as a suggestion). All version editing is **backlog-only**; once `status != .backlog` the versions UI and Edit/Draft buttons are locked. UI: `NewTaskSheet` doubles as the create/edit/draft form (`editing`/`taskID`/`draftMode` params); `TaskVersionsSheet` is the two-pane compare/edit/accept/promote view (reuses `planDiffLines`/`PlanDiffView`). Per-project free-text **topics** persist in `TopicStore` at `~/.claude/claudepit-task-topics/<slug>.json` (seeds the New Task Topic combo box).

## claude -p Subprocess Calls

The app spawns `claude -p` subprocesses in several places. All user-facing calls **must** pass `--bare` and set `CLAUDE_CONFIG_DIR` to `~/.claude`. `CLAUDE_CONFIG_DIR` alone is insufficient — global hooks in `~/.claude/settings.json` (matcher `*`) still fire regardless. `--bare` skips hooks, LSP, plugins, and CLAUDE.md discovery.

**Do not use a fresh temp dir** — it has no credentials and claude exits 1 with "Not logged in". Using `~/.claude` is safe because `--bare` prevents hooks from firing.

| File | Purpose | Isolation required |
|------|---------|-------------------|
| `Sources/ClaudepitCore/Core/PlanQARunner.swift` | Plan & Memory Q&A, improvement generation | ✅ `--bare` + `CLAUDE_CONFIG_DIR=~/.claude` |
| `Sources/ClaudepitCore/Core/DiscoverRunner.swift` | Semantic session search | ✅ `--bare` + `CLAUDE_CONFIG_DIR=~/.claude` |
| `Sources/ClaudepitApp/UI/Sections/PluginsSection.swift` | `/reload-plugins` (fire-and-forget) | not needed |
| `Sources/ClaudepitApp/UI/Sections/SessionDetailView.swift` | `/context` report (shown in popover) | ⚠️ `--bare` only — `-r` needs real `~/.claude`, so **no** `CLAUDE_CONFIG_DIR` override (would break resume) |

**Rule:** any new `claude -p` call that returns output shown to the user must pass `--bare` and set `CLAUDE_CONFIG_DIR` to `~/.claude`:
```swift
env["CLAUDE_CONFIG_DIR"] = "\(NSHomeDirectory())/.claude"
// and in p.arguments: "--bare"
```

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
