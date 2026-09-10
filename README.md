# Claude Cockpit (`claudepit`)

A native macOS app that shows your entire Claude Code configuration — model, MCP
servers, skills, commands, agents, hooks, plugins, settings — with full provenance:
the effective value, why it has that value, and exactly which file or plugin it
comes from. Read-mostly, with a few safe validated toggles. Live-updates as config
changes on disk.

## Run

```bash
# from source (debug)
swift run ClaudepitApp

# release binary
swift build -c release --product ClaudepitApp
.build/release/ClaudepitApp
```

Tests (assert-based checks, no XCTest — see below):

```bash
swift run ClaudepitTests
```

## Ground-truth model — where each config type is consumed from

This is the reference the scanning/scoping logic implements. Each config entity is
grouped by the scope it is **effectively consumed from**: User (global `~/.claude`),
Project (`<path>/.claude`), or Local (`settings.local.json` at either level).

| Config type | global (`~/.claude`) | project (`<path>/.claude`) | local (`settings.local.json`) |
|---|---|---|---|
| **settings keys** (permissions, enabledPlugins, hooks, env, model…) | `settings.json` | `settings.json` | `settings.local.json` (both levels) |
| **MCP servers** | `settings.json` `mcpServers` | `settings.json` `mcpServers` + `.mcp.json` | `settings.local.json` `mcpServers` |
| **skills** | `skills/` dir | `skills/` dir | none — no local skills dir exists |
| **commands** | `commands/` dir | `commands/` dir | none |
| **agents** | `agents/` dir | `agents/` dir | none |
| **hooks** | `settings.json` `hooks` | `settings.json` `hooks` | `settings.local.json` `hooks` |
| **env** | `settings.json` `env` | `settings.json` `env` | `settings.local.json` `env` |

Key rules that follow from this model:

- **Directory-based types (skills / commands / agents) exist only at global and
  project scope.** `settings.local.json` is a settings-only file — there is no local
  skills/commands/agents directory. The `.local` scan reads only the settings file.
- **Settings-embedded types (MCP, hooks, env, settings keys) exist at all three
  scopes**, including local via `settings.local.json`.
- **Project MCP servers** may also come from a standalone `<project-root>/.mcp.json`
  (at the project root, not inside `.claude/`). On name conflicts, `settings.json`
  wins.
- **Plugin-contributed** skills/commands/agents/MCP are surfaced under the User
  (global) group with a distinct plugin origin tag (plugins install at the user level).
- Precedence for the effective value: `local > project > global`. Only the winning
  entry is shown under its scope; overridden copies are hidden.

## Sessions

The **Sessions** sidebar item lists Claude Code sessions parsed from
`~/.claude/projects/<slug>/<uuid>.jsonl`. When a project path is set, only that
project's sessions are shown; otherwise all sessions across projects, grouped by
project. Running sessions (file modified within the last 60s) show a green
**active** badge. Selecting a session opens a **Transcript** tab (formatted
replay with expandable tool calls) and a **Tools** tab (usage counts + every
invocation — built-in, MCP, agent, skill — with input/result on expand). The
open session's file is tailed live, so tool invocations stream in as Claude works.

The Transcript renders assistant/user text as formatted markdown (lists, tables,
code, bold/links), shows Edit/Write tool calls as colored diffs, and turns a
configured tool invocation (skill/agent/MCP) into a link that jumps to and
highlights that item in its config section.

Work done under a task is bracketed with a colored **Task N** heading and a left
accent bar; clicking the heading jumps to the TODO list and clicking a task in a
TODO list jumps to that task's section. AskUserQuestion tool calls render the
question and its options as cards with the chosen answer marked.

## Companion plugin

`claudepit-plugin/` is a Claude Code plugin that drives the app from a session via a
state file (`~/.claude/claudepit-state.json`) the app watches:

- `/set-path` — set the active project path to the session's folder
- `/show-skills`, `/show-mcp`, `/show-commands`, `/show-model`, `/show-plugins` — open that card

## Architecture notes

- **Swift Package Manager**, no Xcode required (`swift build` / `swift run`).
- `ClaudepitCore` (library) holds all testable logic (scanning, merging, writes);
  `ClaudepitApp` (executable) holds the SwiftUI UI; `ClaudepitTests` (executable) is
  an assert-based check runner (XCTest/Testing require Xcode, which isn't assumed here).
- Real glass via `NSVisualEffectView` vibrancy + `.ultraThinMaterial`.
- Live updates via a `DispatchSource` file watcher.
- Secrets (env values whose name contains TOKEN/KEY/SECRET/PASSWORD) are masked.

See `docs/superpowers/specs/` and `docs/superpowers/plans/` for the design and
implementation plan.
