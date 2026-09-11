## Custom Memory Strategy

You maintain a persistent feature-oriented memory for this project at:
  ~/.claude/projects/<project-slug>/memory/

### What to save
Save a memory entry for every feature or meaningful change, or a decision made about a feature — including small ones.

### When to skip — do nothing, and do it fast
The default is to do nothing. Run a memory pass only if this session actually changed the project:
code written or edited, a feature added or changed, a bug fixed, config or a hook changed, a test
added, or a design decision made that the code does not already state.

Skip the pass entirely — no file reads, no writes, no log entry, no mention of memory — when the
session was a question answered, code explained, a search or review with no edits, a command run,
or an attempt that was abandoned with nothing left behind.

Decide this from the work you just did, in one step, before opening anything. Never read MEMORY.md
or a topic file to work out whether there is something to save; reading first is the slow path and
it is wrong. When in doubt on a session that *did* change code, write; when the session changed
nothing, skip.

### File structure
- MEMORY.md — index only. One line per topic file. Keep it under 20 lines.
- One topic file per feature domain (e.g. session-loading.md, hooks.md, settings-injection.md).
- Use kebab-case filenames. Each file covers one cohesive area regardless of how many sessions touched it.

### What each topic file must contain
- Feature name and one-sentence description
- Current behavior / what was built (keep this up to date — overwrite stale descriptions)
- Key design decisions

### Session ID tracking (frontmatter)
Every topic file must carry a `sessions` array in its frontmatter. **This is mandatory — never write or update a topic file without also updating its `sessions` field.**

- **New file**: `sessions: [<current-session-id>]`
- **Existing file**: read the current `sessions` array, append the current session ID if not already present, write the updated array back. Never remove old IDs.

The current session ID is in the `session_id` field of the hook input JSON, or available in the conversation context. If uncertain, use the session ID from the summary hook context injected at the start of the conversation.

**Checklist — before finishing any memory write:**
1. Did I include/update the `sessions` array in this file's frontmatter? ✓
2. Does the array contain the current session ID? ✓

### Writing rules
- Recall before writing, but only what you are about to touch: read MEMORY.md, then read in full only the topic pages covering the areas this session changed. Never rely on the index summary alone for a page you are editing, and never read the whole memory/ directory to write one page.
- Update, don't duplicate: update existing pages rather than creating new ones. Only create a new page when the topic is genuinely new.
- Merge aggressively: if a topic file already covers the area, add to it. If two topic files cover the same domain, consolidate them before the session ends.
- Cross-references: every topic file must end with a `## See also` section listing links to related pages using standard markdown links [Page Title](./file.md). Never use wikilink syntax [[PageName]]. Keep all cross-links in this section — do not scatter them in the body.
- Sources traceability: when a page is compiled from a knowledge base document, record it in a `sources` frontmatter field so compiled knowledge traces back to raw inputs.
- Rewrite the "current behavior" section to reflect reality, not history. A memory file that describes old behavior is worse than no memory file.
- Keep memory content up-to-date, coherent and organised. Rename or delete files that are no longer relevant.
- Write memory at the end of any session where code was written, a feature was built, or a decision was made — and only then (see "When to skip" above).
- Scope the pass to this session's changes. Do not audit, re-verify, or reorganise unrelated pages; that is what the dreaming cycle is for.

## Memory Log

A log of memory activity is maintained at:
  ~/.claude/projects/<project-slug>/memory/log.json

### Maintaining the log
- No memory pass means no log entry. A session that changed nothing appends nothing.
- After a memory pass in which you wrote, updated, renamed, or deleted any topic .md files:
  1. Update the `sessions` array in each touched file's frontmatter (append current session ID if not present).
  2. Immediately append ONE log entry covering the whole pass before ending the conversation:
     {"type": "write", "sessionId": "<session-id>", "ts": <epoch>,
      "title": "<short headline of what this pass changed>",
      "summary": "<1–3 sentences: what changed and why>",
      "changes": [{"action": "create", "file": "<filename>"}, {"action": "update", "file": "MEMORY.md"}]}
  - `changes` lists every file touched in this pass. `action` is one of `create` | `update` | `delete`.
    A rename is a `delete` of the old path plus a `create` of the new one.
  - Use forward slashes for nested paths (e.g. domain/file.md), relative to the memory/ root.
- After completing a dreaming cycle (step 11), append one entry with the same shape:
  {"type": "dream", "sessionId": "<session-id>", "ts": <epoch>,
   "title": "Consolidation", "summary": "<what merged/renamed/removed>",
   "changes": [{"action": "delete", "file": "<merged-away.md>"}, {"action": "update", "file": "MEMORY.md"}]}
- Never edit or remove existing entries — append only.
- Do not add log.json to MEMORY.md. It is maintenance infrastructure, not a memory topic.
- If log.json does not exist yet, create it as an empty JSON array [] before appending.

### How dreaming is triggered
The Stop hook first checks whether this session touched a file at all; if it did not, it injects
nothing and no memory work happens. Otherwise it reads log.json and counts write entries since the
last dream entry.
When the count reaches 10, it injects the full 11-step dreaming consolidation prompt instead of the normal memory reminder.
That prompt runs the 11 steps in a subagent (Task tool, latest Sonnet model) rather than inline, so consolidation doesn't burn the session's own context.
The count resets after each dream — the next dream triggers after 10 more writes.