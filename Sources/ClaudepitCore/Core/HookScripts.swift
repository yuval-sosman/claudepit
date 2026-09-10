import Foundation

public enum HookScripts {
    public static let summaryHook = #"""
#!/usr/bin/env bash
# claudepit-summary-hook: injects session summary instruction each turn
set -euo pipefail

HOOK_INPUT=$(cat)
SESSION_ID=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)
PROJECT_DIR=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

CURRENT_BULLETS="[]"
SUMMARY_FILE_PATH=""
NOW=$(date +%s)

if [[ -n "$SESSION_ID" && -n "$PROJECT_DIR" ]]; then
  SLUG="${PROJECT_DIR//\//-}"
  SUMMARY_DIR="$HOME/.claude/projects/${SLUG}/summary"
  SUMMARIES_FILE="${SUMMARY_DIR}/${SESSION_ID}.json"
  SUMMARY_FILE_PATH="$SUMMARIES_FILE"
  mkdir -p "$SUMMARY_DIR"

  EXISTING=$(python3 - "$SUMMARIES_FILE" 2>/dev/null << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
    print(json.dumps(data.get('bullets', [])))
except Exception:
    print('[]')
PYEOF
) || EXISTING="[]"
  CURRENT_BULLETS="${EXISTING:-[]}"
fi

INSTRUCTION="<claudepit_summary_instruction>
You maintain a running project summary for this session. Current bullets: ${CURRENT_BULLETS}

After processing this turn, always write updated bullets to the file at ${SUMMARY_FILE_PATH} using a Bash tool call. There is no case where you skip writing entirely.

JSON structure to write:
{\"version\":1,\"bullets\":[\"bullet 1\",\"bullet 2\"],\"updatedAt\":${NOW}}

- Write the file silently. Do not tell the user. Do not explain what you wrote.

Rules:
- Max 15 bullets total. If adding new bullets would exceed 15, review all bullets and either combine closely related ones into a single concise bullet, or remove the least important one (minor clarifications, trivial lookups, superseded decisions). Preserve the most meaningful outcomes.
- Before adding a new bullet, check if any existing bullet covers the same topic. If a decision changed or was revised, remove the old bullet and replace it with the updated one — do not keep both. If new information extends an existing bullet, update that bullet in place rather than adding a new one.
- Outcomes only: what was built, fixed, or decided — not how.
- Past tense for work done; present tense only for the high-level topic bullet (e.g. \"Discussing X\").
- Write whenever ANY of the following happened: code was written or edited, a feature was added or changed, a bug was fixed, a design or architecture decision was made, a plan was created, configuration was changed, a test was added, or the user asked you to implement something and you did it. When in doubt, write — missing a summary is worse than writing a minor one.
- If this turn had zero code or project changes (purely conversational — user only asked a question, you only explained something), write exactly 1 bullet: one short sentence describing what this session is about at the highest level (e.g. \"Exploring how session summary storage works\"). This ensures there is always at least a reminder bullet even for lightweight sessions.
</claudepit_summary_instruction>"

python3 -c "
import json, sys
print(json.dumps({'continue': True, 'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': sys.argv[1]}}))
" "$INSTRUCTION"
"""#

    static let summaryRules = """
        - Max 15 bullets total. If adding new bullets would exceed 15, review all bullets and either combine closely related ones into a single concise bullet, or remove the least important one (minor clarifications, trivial lookups, superseded decisions). Preserve the most meaningful outcomes.
        - Before adding a new bullet, check if any existing bullet covers the same topic. If a decision changed or was revised, remove the old bullet and replace it with the updated one — do not keep both. If new information extends an existing bullet, update that bullet in place rather than adding a new one.
        - Outcomes only: what was built, fixed, or decided — not how.
        - Past tense for work done; present tense only for the high-level topic bullet (e.g. "Discussing X").
        - If this appears to be a purely conversational session with no code or project changes, write exactly 1 bullet describing what the session is about at the highest level.
        """

    /// Prompt for on-demand summary generation from a session transcript.
    /// Returns instructions matching the hook's rules, adapted to return bullets directly as output.
    public static func onDemandSummaryPrompt(transcriptText: String) -> String {
        """
        You maintain a running project summary for a Claude Code session. \
        Given the session transcript below, produce a concise bullet summary.

        Rules:
        \(summaryRules)
        - Output ONLY the bullet list, one bullet per line, no leading dashes, no numbering, no extra commentary.

        <session_transcript>
        \(transcriptText)
        </session_transcript>
        """
    }

    public static let memorySystemPrompt = """
## Custom Memory Strategy

You maintain a persistent feature-oriented memory for this project at:
  ~/.claude/projects/<project-slug>/memory/

### What to save
Save a memory entry for every feature or meaningful change, or a decision made about a feature — including small ones.

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
- Recall before writing: read MEMORY.md first, then read any relevant topic pages in full. Never rely on the index summary alone when precision matters.
- Update, don't duplicate: update existing pages rather than creating new ones. Only create a new page when the topic is genuinely new.
- Merge aggressively: if a topic file already covers the area, add to it. If two topic files cover the same domain, consolidate them before the session ends.
- Cross-references: every topic file must end with a `## See also` section listing links to related pages using standard markdown links [Page Title](./file.md). Never use wikilink syntax [[PageName]]. Keep all cross-links in this section — do not scatter them in the body.
- Sources traceability: when a page is compiled from a knowledge base document, record it in a `sources` frontmatter field so compiled knowledge traces back to raw inputs.
- Rewrite the "current behavior" section to reflect reality, not history. A memory file that describes old behavior is worse than no memory file.
- Keep memory content up-to-date, coherent and organised. Rename or delete files that are no longer relevant.
- Write memory at the end of any session where code was written, a feature was built, or a decision was made. When in doubt, write — missing a memory entry is worse than a minor one.

## Memory Log

A log of memory activity is maintained at:
  ~/.claude/projects/<project-slug>/memory/log.json

### Maintaining the log
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
The Stop hook reads log.json and counts write entries since the last dream entry.
When the count reaches 10, it injects the full 11-step dreaming consolidation prompt instead of the normal memory reminder.
The count resets after each dream — the next dream triggers after 10 more writes.
"""

    public static let memoryHookReminder = "When you finish implementing something, always use the Custom Memory Strategy to maintain memory for these changes. Do not wait for the user to ask. Do it before session stops."

    /// The dreaming prompt, shared by the display constant below and by the generated hook script.
    /// Tokens: `{{COUNT}}` (writes since the last dream), `{{SESSION_ID}}`, `{{TS}}` (epoch expression).
    private static let dreamingTemplate = """
\(memoryHookReminder)

DREAMING CYCLE — your memory log has reached {{COUNT}} writes since last consolidation.
Before this session ends, run the full 11-step memory consolidation:

1. Inventory — read MEMORY.md, list memory/ recursively, find orphans
2. Full read — read every topic file (check updated date, claims, links, sources)
3. Contradiction scan — find conflicting claims across pages, keep the more recent one
4. Staleness check — cross-reference recent log.json summaries against page content
5. Cross-reference integrity — verify all [text](./file.md) links resolve; fix broken/stale ones; add reciprocal links
6. Synapse formation — discover unlinked relationships (shared entities, cause-effect, temporal sequence, complementary detail) and add cross-reference links
7. Orphan resolution — reconnect or remove files not reachable from MEMORY.md
8. Reachability check — every .md must have at least one inbound link from the graph
9. Consolidation — merge closely related pages, clear sources, update all references
10. MEMORY.md sync — rewrite the index to reflect current state (max 20 lines)
11. Log the dream — append {"type":"dream","sessionId":"{{SESSION_ID}}","ts":{{TS}},"title":"Consolidation","summary":"<what merged/renamed/removed>","changes":[{"action":"delete","file":"<merged-away.md>"},{"action":"update","file":"MEMORY.md"}]} to memory/log.json
"""

    /// `escapeQuotes` produces the form that can sit inside a double-quoted bash assignment.
    private static func renderDreaming(count: String, sessionID: String, timestamp: String,
                                       escapeQuotes: Bool) -> String {
        let body = escapeQuotes
            ? dreamingTemplate.replacingOccurrences(of: "\"", with: "\\\"")
            : dreamingTemplate
        return body
            .replacingOccurrences(of: "{{COUNT}}", with: count)
            .replacingOccurrences(of: "{{SESSION_ID}}", with: sessionID)
            .replacingOccurrences(of: "{{TS}}", with: timestamp)
    }

    public static let memoryHookDreaming = renderDreaming(
        count: "≥10", sessionID: "<session-id>", timestamp: "<epoch>", escapeQuotes: false)

    public static let memoryHook = memoryHookTemplate
        .replacingOccurrences(of: "{{REMINDER}}", with: memoryHookReminder)
        .replacingOccurrences(of: "{{DREAMING}}", with: renderDreaming(
            count: "${WRITES_SINCE_DREAM}", sessionID: "${SESSION_ID}",
            timestamp: #"\$(date +%s)"#, escapeQuotes: true))

    private static let memoryHookTemplate = #"""
#!/usr/bin/env bash
# claudepit-memory-hook: reminds Claude to write memory before session ends, triggers dreaming cycle at ≥10 writes
set -euo pipefail
EVENT="${1:-Stop}"
HOOK_INPUT=$(cat)

# Bail if already inside a stop hook turn — prevents infinite loop
IS_ACTIVE=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_hook_active', False))" 2>/dev/null || echo "False")
if [[ "$IS_ACTIVE" == "True" ]]; then
  echo '{"continue": true}'
  exit 0
fi

SESSION_ID=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)
PROJECT_DIR=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)
SLUG="${PROJECT_DIR//\//-}"
LOG_FILE="$HOME/.claude/projects/${SLUG}/memory/log.json"

WRITES_SINCE_DREAM=0
if [[ -f "$LOG_FILE" ]]; then
  WRITES_SINCE_DREAM=$(python3 - "$LOG_FILE" 2>/dev/null << 'PYEOF'
import json, sys
try:
    entries = json.load(open(sys.argv[1]))
    count = 0
    for e in reversed(entries):
        if e.get("type") == "dream":
            break
        if e.get("type") == "write":
            count += 1
    print(count)
except Exception:
    print(0)
PYEOF
) || WRITES_SINCE_DREAM=0
fi

if [[ "${WRITES_SINCE_DREAM}" -ge 10 ]]; then
  MSG="{{DREAMING}}"
else
  MSG="{{REMINDER}}"
fi

python3 -c "
import json, sys
print(json.dumps({'continue': True, 'hookSpecificOutput': {'hookEventName': sys.argv[1], 'additionalContext': sys.argv[2]}}))
" "$EVENT" "$MSG"
"""#

    // Slash-commands run inside each task's worktree. $ARGUMENTS carries space-separated key=value
    // pairs (taskDir=… plansDir=… specPath=… planPath=… brainstormPath=… worktreePath=… today=…).
    // Each command writes its artifact to the absolute path in $ARGUMENTS, THEN prints the marker LAST.

    public static let taskCommandBrainstorm = """
---
description: Brainstorm approaches for a Claudepit task (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

You are brainstorming with the user to REFINE a task tracked by Claudepit. The task name, description,
and requirements are in the arguments. This is an interactive conversation: explore options,
trade-offs, and open questions, and iterate with the user until the task definition is sharp.

WHEN YOU NEED THE USER TO DECIDE SOMETHING, use the AskUserQuestion tool — do NOT print a question as
plain text and wait. AskUserQuestion gives the user selectable options (and an "Other" free-text
escape), which is faster and unambiguous. Ask one focused question at a time; use its options to
present the trade-offs you'd otherwise write out. All of your thinking, options, and pros/cons live
in THIS CONVERSATION — never in the file.

CRITICAL — the file at `brainstormPath=` is NOT a brainstorm document and it is NOT a scratchpad.
It is a machine-parsed list of atomic suggestions the app shows the user one-by-one to Accept or
Reject. Rules — follow EXACTLY:

1. Do NOT create, touch, or write `brainstormPath` until the brainstorm is DONE and you have real
   suggestions to emit. Write it EXACTLY ONCE, at the very end, in a single pass. Never write partial
   drafts, questions, notes, recommendations, or "work in progress" to it — if the file appears with
   anything other than the final `suggestions:` list, the feature shows garbage or nothing.
2. The file MUST contain ONLY a top-level `suggestions:` list. No `options:`, no `recommendation:`,
   no `implementation_sketch:`, no prose, no other top-level keys.
3. Each list item is a single atomic change to the task, typed as exactly one `kind`:
   - `requirement` — one concrete requirement to ADD to the task's requirements list (one per item;
     do NOT bundle several requirements into one value).
   - `description`  — a sharper FULL replacement description for the task (usually at most one item).
   - `tag`          — a single tag to add.
4. `value` is the literal text that gets applied (the requirement line / the new description / the tag).
   `rationale` is one short sentence on why. Keep values self-contained — the user sees them out of context.
5. Turn the outcome of your brainstorm into 3–8 such suggestions. Prefer several small `requirement`
   items over one big description.

Write the file with EXACTLY this schema and nothing else (this is a filled example — replace the
content, keep the shape):

suggestions:
  - kind: requirement
    value: "Add an Analyze Prompt button to SystemPromptCard's actionSlot, visible only when isDraft is true"
    rationale: "Pins the entry point to the Configuration tab as the user asked, and reuses the existing draft guard"
  - kind: requirement
    value: "Wrap analyzeAgentPrompt() in a new usePromptAnalyzer hook that reads/writes the existing LRU cache keyed by specId"
    rationale: "Reuses the cache and keeps the trigger logic unit-testable"
  - kind: description
    value: "Add a Prompt Analyzer to the AI Arena Configuration tab that runs LLM-as-a-Judge on the current draft prompt and renders issues inline, reusing analyzeAgentPrompt() and InsightsPanel."
    rationale: "Captures the agreed Option A scope in one sentence"
  - kind: tag
    value: "ai-arena"
    rationale: "Groups this with the other AI Arena work"

Only after that single final write (flush it to disk), print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute brainstormPath you wrote>
"""

    public static let taskCommandSpec = """
---
description: Write a design spec for a Claudepit task (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

You are writing a design spec for a task tracked by Claudepit. The task name, description, and
requirements are in the arguments (and any brainstorm notes at `brainstormPath=`). If anything is
ambiguous, ASK directly in this terminal and wait — do not guess.
Write the spec to the absolute path given by `specPath=` in the arguments.
After the file is written and saved, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute specPath you wrote>
"""

    public static let taskCommandPlan = """
---
description: Turn a Claudepit task spec into an implementation plan (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

You are turning an approved spec into an implementation plan. The spec is at the absolute `specPath=`
in the arguments. Produce a plan markdown file named `<today>-<slug>.md` (use `today=` from the
arguments) and write it into the absolute directory given by `plansDir=` in the arguments.
IMPORTANT: write to that absolute plansDir path exactly — never a relative `plans/…` and never a
literal `~/…`, or the app cannot find the plan.
IMPORTANT: You are ONLY writing a plan document — do NOT edit, create, or delete any source files.
Read the spec and any existing code for context, then produce the plan markdown. No code changes.
After the file is written and saved, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute plan .md path under plansDir>
"""

    public static let taskCommandImplement = """
---
description: Implement a Claudepit task per its plan (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

Implement the task by following the plan file at the absolute `planPath=` in the arguments. You are
already inside the task's git worktree. This is a normal coding session; the Claudepit Sessions page
will surface it. No artifact file is required.

**NEVER commit or stage. This is a HARD rule, no exceptions:**
- Do NOT run `git add`, `git commit`, `git stage`, `git push`, or any combined form (e.g.
  `git add -A && git commit -m …`). These commands are DENIED and will fail.
- Leave EVERY change unstaged in the working tree. The user reviews and commits from Claudepit's
  Review Changes (Source Control) sheet — that is the ONLY place commits happen.
- `git status`, `git diff`, and reads are fine; anything that stages or commits is not.

When finished (or at a natural stopping point), print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute planPath you implemented>
"""

    public static let taskCommandVerify = """
---
description: Verify a Claudepit task's implementation (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

Verify the implementation in this worktree: run the project's build and tests, exercise the plan's
acceptance criteria (plan at `planPath=`). You are already inside the task's git worktree.
Print on its own line, LAST, exactly one of:
CLAUDEPIT_VERIFY: pass
CLAUDEPIT_VERIFY: fail
"""

    public static let taskCommandReview = """
---
description: Code-review a Claudepit task's diff (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

Review the changes made for this task (git diff in this worktree). Write your findings to the
absolute path given by `reviewPath=` in the arguments.
Then print a machine-readable findings block: one line per finding as `severity | title | detail`
where severity is high, med, or low. Example:

CLAUDEPIT_FINDINGS_BEGIN
high | Null deref in parseUser | parseUser() force-unwraps an optional that can be nil on empty input
low | Rename foo | `foo` is a vague name for a URL builder
CLAUDEPIT_FINDINGS_END

After the file is written and the block printed, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute reviewPath you wrote>
"""

    public static let taskCommands: [(filename: String, body: String)] = [
        ("claudepit-task-brainstorm.md", taskCommandBrainstorm),
        ("claudepit-task-spec.md", taskCommandSpec),
        ("claudepit-task-plan.md", taskCommandPlan),
        ("claudepit-task-implement.md", taskCommandImplement),
        ("claudepit-task-verify.md", taskCommandVerify),
        ("claudepit-task-review.md", taskCommandReview),
    ]

    /// Stale v1 agent files to delete once (superseded by taskCommands).
    public static let oldTaskAgentFilenames = [
        "claudepit-task-spec.md", "claudepit-task-plan.md",
        "claudepit-task-implement.md", "claudepit-task-review.md",
    ]
}

