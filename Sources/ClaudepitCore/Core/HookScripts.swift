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
  # Match Claude Code's own project-dir slug: '/', '.', and '+' all become '-'
  # (a plain '/'-only replace mismatches worktree paths, which contain ".claude/worktrees").
  SLUG="${PROJECT_DIR//\//-}"
  SLUG="${SLUG//./-}"
  SLUG="${SLUG//+/-}"
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
"""

    public static let memoryHookReminder = "When you finish implementing something, always use the Custom Memory Strategy to maintain memory for these changes. Do not wait for the user to ask. Do it before session stops. If this session implemented, changed, or decided nothing, skip the memory pass entirely — write nothing, read nothing, log nothing, and say nothing about memory. Judge that from the work you just did, never by reading memory files first. When you do write, touch only the topic files this session's work actually affects."

    /// The dreaming prompt, shared by the display constant below and by the generated hook script.
    /// Tokens: `{{COUNT}}` (writes since the last dream), `{{SESSION_ID}}`, `{{TS}}` (epoch expression).
    private static let dreamingTemplate = """
\(memoryHookReminder)

DREAMING CYCLE — your memory log has reached {{COUNT}} writes since last consolidation.
Before this session ends, run the full 11-step memory consolidation. Do NOT run it inline in this
session — dispatch it to a subagent so consolidation doesn't burn this session's own context.

Use the Task tool to launch one general-purpose subagent on the latest Sonnet model
(claude-sonnet-5). Give it this checklist verbatim as its prompt, including the session ID
{{SESSION_ID}} for step 11, and wait for it to finish before the session ends:

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

# One python pass for every field we need — this hook fires on every Stop, so interpreter
# startups are the whole cost when there is nothing to remember.
FIELDS=$(echo "$HOOK_INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in ('stop_hook_active', 'session_id', 'cwd', 'transcript_path'):
    print(d.get(k, '') or '')
" 2>/dev/null || true)
IS_ACTIVE=$(sed -n 1p <<< "$FIELDS")
SESSION_ID=$(sed -n 2p <<< "$FIELDS")
PROJECT_DIR=$(sed -n 3p <<< "$FIELDS")
TRANSCRIPT=$(sed -n 4p <<< "$FIELDS")

# Bail if already inside a stop hook turn — prevents infinite loop
if [[ "$IS_ACTIVE" == "True" ]]; then
  echo '{"continue": true}'
  exit 0
fi

# Fast path: a session that never wrote a file has nothing to remember, so inject nothing at
# all — no reminder, no dreaming, no memory read. The transcript is scanned for tool calls only
# (never raw text: every transcript embeds a system prompt that mentions "git commit" and the
# like, so a plain grep would match on every session). A false positive costs only the normal
# reminder, which the strategy's own skip rule then short-circuits.
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  TOUCHED=$(python3 - "$TRANSCRIPT" 2>/dev/null << 'PYEOF'
import json, re, sys

WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
SHELL_WRITE = re.compile(
    r"(?:^|[\s;&|(])(?:sed\s+-i|tee|mv|cp|rm|mkdir|touch|patch|install)\b"
    r"|>{1,2}\s*(?!/dev/)[^\s&|;]"
    r"|<<"
    r"|git\s+(?:commit|apply|revert|rebase|merge|mv|rm|checkout\s+-b|switch\s+-c)\b")

def wrote(block):
    name = block.get("name", "")
    if name in WRITE_TOOLS:
        return True
    if name in ("Bash", "BashOutput"):
        cmd = (block.get("input") or {}).get("command") or ""
        return bool(SHELL_WRITE.search(cmd))
    return False

try:
    with open(sys.argv[1], errors="ignore") as fh:
        for line in fh:
            if '"tool_use"' not in line:
                continue
            try:
                content = (json.loads(line).get("message") or {}).get("content")
            except Exception:
                continue
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use" and wrote(block):
                    print(1)
                    sys.exit(0)
    print(0)
except Exception:
    print(1)
PYEOF
) || TOUCHED=1
  if [[ "${TOUCHED:-1}" == "0" ]]; then
    echo '{"continue": true}'
    exit 0
  fi
fi

# Match Claude Code's own project-dir slug: '/', '.', and '+' all become '-'
# (a plain '/'-only replace mismatches worktree paths, which contain ".claude/worktrees").
SLUG="${PROJECT_DIR//\//-}"
SLUG="${SLUG//./-}"
SLUG="${SLUG//+/-}"
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

    // Slash-commands run inside each task's worktree. $ARGUMENTS carries the app's phase brief
    // (see TaskRunner.phasePrompt): markdown sections for the task itself, then a `## Paths` block
    // of one `key=value` per line (taskDir= plansDir= specPath= planPath= reviewPath=
    // brainstormPath= worktreePath= attachmentsDir= today=). Each command writes its artifact to
    // the absolute path in $ARGUMENTS, THEN prints the marker LAST (last-marker-wins in
    // TaskTransition).

    public static let taskCommandBrainstorm = """
---
description: Brainstorm approaches for a Claudepit task (app-owned; regenerated on launch).
---
Arguments — Claudepit's phase brief: the task definition, then a `## Paths` section of
absolute `key=value` paths (one per line). Read the paths from there.

$ARGUMENTS

You are brainstorming with the user to REFINE a task tracked by Claudepit. This runs BEFORE the
spec phase, and its only output is a sharper task definition. The task name, description, and
requirements are in the arguments. This is an interactive conversation: explore the codebase,
surface options and trade-offs, and iterate with the user until the definition is sharp enough
that a spec could be written from it without further product decisions.

## Step 1 — Explore before you ask

Ground yourself in reality BEFORE the first question: read the files and subsystems the task
touches, skim docs and recent commits. If the surface is wide, dispatch 1-2 read-only subagents
in parallel (Task tool — Explore type if available, else general-purpose), each with one precise
question ("which views render X and where does its state live? Return file:line references"),
and read the key files yourself while they run. Never brainstorm from assumptions: a question
grounded in the actual code ("SystemPromptCard already has an actionSlot — mount the button
there?") beats a generic one ("where should the button go?"). You are already inside the task's
dedicated git worktree — never create another worktree or branch, and never run a subagent in
worktree isolation.

## Step 2 — Scope check

If the task bundles multiple independent pieces ("add analyzer + rework caching + new settings
page"), flag it immediately via AskUserQuestion: offer to narrow this task to one piece
(recommended) and record the rest as out-of-scope requirement suggestions. Don't spend questions
refining details of a task that first needs decomposition.

## Step 3 — Refine through questions

EVERY decision you need from the user goes through the AskUserQuestion tool — never print a
question as plain text and wait:
- ONE focused question per call. If a topic needs more, break it into successive questions.
- 2-4 concrete options; put your recommended option FIRST with "(Recommended)" appended.
- Put the trade-offs in each option's description — that replaces the pros/cons essay.
- The user always gets an "Other" free-text escape automatically; don't add one.
- Ask about purpose, constraints, success criteria, and anything two readings could disagree on.
  Never ask what the codebase already answers — you explored it in Step 1.

## Step 4 — Propose approaches

Once you understand the goal, propose 2-3 implementation approaches as ONE AskUserQuestion call:
each option is an approach, its description is the trade-off summary, your recommendation first.
YAGNI ruthlessly — strip unnecessary features from every approach. All of your thinking, options,
and pros/cons live in THIS CONVERSATION — never in the file.

## Step 5 — The deliverable (STRICT contract)

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
5. Turn the outcome of your brainstorm into 3-8 such suggestions. Prefer several small `requirement`
   items over one big description.

Requirement quality bar — every `requirement` value must be concrete, testable, and anchored in
the real code you explored in Step 1:
- GOOD: "Add an Analyze Prompt button to SystemPromptCard's actionSlot, visible only when isDraft is true"
- BAD:  "Add the button in a sensible place" (not testable, no anchor in the code)

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
Arguments — Claudepit's phase brief: the task definition, then a `## Paths` section of
absolute `key=value` paths (one per line). Read the paths from there.

$ARGUMENTS

You are writing the design spec for a task tracked by Claudepit. The task name, description, and
requirements are in the arguments. If a brainstorm file exists at `brainstormPath=`, read it —
accepted refinements are already folded into the requirements, but its rationales are context.
If `attachmentsDir=` is present, read the files in it — they are user-provided context.

The bar: a planner must be able to turn this spec into an implementation plan WITHOUT making a
single further product decision. The spec is the binding authority for every later phase (plan,
implement, review) — ambiguity here becomes rework there.

## Step 1 — Explore the codebase first

Read every file the task plausibly touches; follow the existing patterns you find. When the
surface is wide, dispatch 2-3 read-only subagents IN PARALLEL (one message, multiple Task tool
calls — Explore type if available, else general-purpose), each with one precise question and
told to return a compact summary with file:line references. Never design against imagined code.
You are already inside the task's dedicated git worktree — never create another worktree or
branch, and never run a subagent in worktree isolation.

## Step 2 — Close open decisions with AskUserQuestion

Every decision the user must make goes through the AskUserQuestion tool — never a plain-text
question, never a silent guess. One question per call; 2-4 options with the trade-offs in their
descriptions; your recommended option first with "(Recommended)" appended. Only ask what the
codebase cannot answer and what materially changes the design.

## Step 3 — Write the spec

Write to the absolute path given by `specPath=` in the arguments, with these sections (write
"None" under a heading rather than dropping it):

1. **Overview** — what is being built and why, 2-4 sentences.
2. **Non-Goals** — what this deliberately does NOT do (YAGNI, in writing).
3. **Requirements** — the task's requirements, each refined into concrete, testable form.
4. **Design** — the architecture, then each component: one clear purpose, its interface, what it
   depends on. A reader should know what a unit does without reading its internals; if a
   component can't be described that way, redraw the boundaries.
5. **Data flow** — how data moves end to end for the main scenarios.
6. **Error handling** — each failure mode and what the user sees.
7. **Testing strategy** — what gets unit/integration tested, and how.
8. **Acceptance criteria** — a numbered checklist, every item mechanically checkable; the
   implement phase closes by running THIS list, and code review checks it again.
9. **Out of scope / future work.**

Targeted improvements to code the work touches belong in the design; unrelated refactoring does
not.

## Step 4 — Self-review, then subagent review

Re-read the spec with fresh eyes and fix inline:
1. Placeholder scan — no TBD/TODO/vague sections.
2. Internal consistency — no section contradicts another.
3. Scope — one implementation plan's worth; if it needs decomposition, say so to the user.
4. Ambiguity — any requirement readable two ways gets pinned to one reading.

Then dispatch ONE reviewer subagent (Task tool, general-purpose) with this brief:

> Review the spec at <absolute specPath>. Check: Completeness (TODOs, placeholders, missing
> sections), Consistency (internal contradictions), Clarity (requirements ambiguous enough that
> someone could build the wrong thing), Scope (focused enough for a single plan), YAGNI
> (unrequested features). Only flag issues that would cause a flawed implementation plan — not
> wording polish. Return: "Status: Approved" or "Status: Issues Found", then each issue as
> [Section]: issue — why it matters for planning.

Fix real issues; ignore polish; do not loop more than twice.

After the file is written and saved, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute specPath you wrote>
"""

    public static let taskCommandPlan = """
---
description: Turn a Claudepit task spec into an implementation plan (app-owned; regenerated on launch).
---
Arguments — Claudepit's phase brief: the task definition, then a `## Paths` section of
absolute `key=value` paths (one per line). Read the paths from there.

$ARGUMENTS

You are turning an approved spec (absolute `specPath=` in the arguments) into an implementation
plan. Write for an engineer who is skilled but has ZERO context for this codebase and
questionable taste: exact files, real code, exact commands, how to verify — everything.

## Research in plan mode

Enter your native plan mode NOW (EnterPlanMode tool) if it is available — this phase is exactly
what plan mode is for. Read the spec, then read EVERY file the plan will touch; note existing
patterns, exact signatures, and test conventions. If plan mode is unavailable, do the same
research strictly read-only. When the plan is complete, exit plan mode (ExitPlanMode), then
produce the plan file as described below.

HARD RULE either way: you are ONLY producing a plan document — do NOT edit, create, or delete
any source files. You are already inside the task's dedicated git worktree — never create
another worktree or branch, and never run a subagent in worktree isolation. And never plan
worktree/branch setup steps: every Claudepit task already lives in its own worktree.

If research exposes a real gap or contradiction in the spec, resolve it with the AskUserQuestion
tool (2-4 options, trade-offs in the descriptions, recommended option first) — never a
plain-text question, never a silent guess.

## Plan document format

Start with this header:

# <Feature Name> Implementation Plan
**Goal:** one sentence
**Architecture:** 2-3 sentences
**Spec:** <the absolute specPath> (the plan argues from the spec; executors read both)
## Global Constraints
<project-wide requirements copied VERBATIM from the spec — exact values, naming rules, version
floors, one per line. Every task implicitly includes this section. Always include: never run
git add / git commit / git stage / git push — commits happen only in the Claudepit app.>

Then one section per task:

### Task N: <Component>
**Files:** Create / Modify / Test — exact paths (Modify with line anchors where you can)
**Interfaces:** Consumes (exact signatures from earlier tasks) / Produces (exact names, parameter
and return types later tasks rely on — an implementer sees only their own task; this block is how
neighbors learn each other's names)

Then checkbox steps (- [ ]), each ONE action of 2-5 minutes, TDD-ordered:
- [ ] Step 1: Write the failing test — with the ACTUAL test code block
- [ ] Step 2: Run it, verify it fails — exact command + expected failure message
- [ ] Step 3: Minimal implementation — the actual code block
- [ ] Step 4: Run it, verify it passes — exact command
- [ ] Step 5: Checkpoint — run the focused suite for the touched area (NO commit steps, ever)

## Right-sizing

A task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's
gate. Fold setup/scaffolding/docs into the task whose deliverable needs them; split only where a
reviewer could reject one task while approving its neighbor. Map which files each task owns
before drawing boundaries: one clear responsibility per file, follow the codebase's existing
patterns.

## No placeholders — these are plan failures, never write them

- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "handle edge cases"
- "Write tests for the above" without the actual test code
- "Similar to Task N" — repeat the code; tasks are read out of order
- Steps that describe WHAT without showing HOW (code steps require code blocks)
- References to types, functions, or methods no task defines

## Self-review, then subagent review

1. Spec coverage: for each spec requirement, point at the task that implements it; add tasks for
   gaps.
2. Placeholder scan: search the plan for the patterns above; fix them.
3. Type consistency: names and signatures used in later tasks match earlier definitions exactly.

For plans of 3+ tasks, also dispatch ONE reviewer subagent (Task tool, general-purpose):

> Review the plan at <plan path> against the spec at <absolute specPath>. Check: Completeness
> (placeholders, missing steps), Spec alignment (every requirement covered, no scope creep),
> Decomposition (clear task boundaries, actionable steps), Buildability (an engineer could follow
> it without getting stuck). Only flag what would cause a wrong build or a stuck implementer.
> Return "Status: Approved" or "Status: Issues Found" with each issue as [Task N, Step M]: issue — why.

Fix real issues; ignore polish.

## Save and hand off

Write the plan into the absolute directory given by `plansDir=`, named `<today>-<slug>.md` (use
`today=` from the arguments). Write to that absolute path exactly — never a relative `plans/…`
and never a literal `~/…`, or the app cannot find the plan. Exception: if plan mode already saved
your complete, final plan as a .md file directly under plansDir, print that file's path instead
of writing a duplicate.
After the file is written and saved, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute plan .md path under plansDir>
"""

    public static let taskCommandImplement = """
---
description: Implement a Claudepit task per its plan (app-owned; regenerated on launch).
---
Arguments — Claudepit's phase brief: the task definition, then a `## Paths` section of
absolute `key=value` paths (one per line). Read the paths from there.

$ARGUMENTS

Implement the task by following the plan at the absolute `planPath=` in the arguments. You are
already inside the task's git worktree. This is a normal coding session; the Claudepit Sessions
page will surface it. Read the plan ONCE in full, read the spec it names (the spec is the
binding authority; the plan is its argument), create one todo per plan task, then execute them
ALL in order without pausing to check in between tasks.

**NEVER commit or stage. This is a HARD rule, no exceptions:**
- Do NOT run `git add`, `git commit`, `git stage`, `git push`, or any combined form (e.g.
  `git add -A && git commit -m …`). These commands are DENIED and will fail.
- Leave EVERY change unstaged in the working tree. The user reviews and commits from Claudepit's
  Review Changes (Source Control) sheet — that is the ONLY place commits happen.
- `git status`, `git diff`, and reads are fine; anything that stages or commits is not.

## How to execute — subagent-driven, always

You are the coordinator, never the typist. Dispatch a fresh implementer subagent (Task tool,
general-purpose) per plan task — for every plan, at every size — and keep your own context for
coordination and review. Do not implement plan tasks yourself, and never fix findings yourself:
fixes go back to the implementer, so your context stays clean and every change gets reviewed.
NEVER dispatch two implementers in parallel — they share this worktree and will conflict.
Parallel subagents are for READ-ONLY work only (investigations, reviews). Batch same-shape
mechanical tasks (the same small edit across N files) into ONE dispatch — one subagent, the
whole batch, reviewed as one unit.

You are already inside the task's dedicated git worktree: never create another worktree or
branch, never run git worktree commands, and never dispatch a subagent in worktree isolation —
every subagent works in THIS checkout.

The implementer dispatch brief — give each subagent exactly this, never your session history:
1. The task's FULL text pasted from the plan (files, interfaces, steps, code).
2. One line on where this task fits in the feature.
3. The exact names and signatures earlier tasks produced.
4. The plan's Global Constraints verbatim, plus these hard rules: work only inside this
   worktree — never create worktrees or branches; NEVER run git add/commit/stage/push; follow
   the TDD steps as written; do not dispatch subagents of your own; if reality contradicts the
   task text, STOP and report instead of improvising.
5. The report contract: status DONE or BLOCKED or NEEDS_CONTEXT; files changed; what was tested
   with the actual command and its result line.

Handling reports: DONE → review before moving on (below). BLOCKED / NEEDS_CONTEXT → supply the
missing context and re-dispatch; if it is genuinely the user's decision, use AskUserQuestion.
Never ignore an escalation and never re-dispatch unchanged.

## Review between tasks

After each task, diff-check it against the task's text yourself: anything missing? anything
extra (unrequested features are a defect — YAGNI)? anything misunderstood? Do the new tests
verify real behavior rather than mocks? Treat an implementer's report as unverified claims —
check the diff, not the prose. Fix loop: at most 3 rounds per task, then make a judgment call,
record it, and move on.

## Rulings, not stalls

Small ambiguities and plan defects are yours to decide: rule with the spec as authority, keep a
running list of rulings, and keep going. Reserve AskUserQuestion for decisions that genuinely
belong to the user — product behavior, scope changes, anything irreversible. A wrong ruling
costs a visible fix; a session parked on a question costs the user their day.

## Close-out — evidence before claims

The iron law: NO COMPLETION CLAIM WITHOUT FRESH EVIDENCE. If you did not run the command in this
session and read its output, you cannot claim it passes — "should pass", "looks correct", and an
implementer's report are not evidence. While tasks are in flight the implementers run the
focused tests; after the LAST task, close out yourself:
1. **Reality check** — `git status --porcelain` and `git diff --stat`: the diff actually
   contains the work the plan describes, not just reports claiming it does.
2. **Build** — run the project's full build; evidence is exit 0.
3. **Tests** — run the FULL suite and read the pass/fail counts line; 0 failures.
4. **Acceptance criteria** — walk the spec's acceptance-criteria list one by one: a command, a
   focused test, or the exact file:line that satisfies each item.
Anything red from this work goes back to an implementer before you finish.

When finished, summarize: what was implemented per task, deviations from the plan (with why),
the rulings you made, the close-out evidence (each check with its result line), and any
acceptance criterion you could not verify. Then print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute planPath you implemented>
"""

    public static let taskCommandReview = """
---
description: Code-review a Claudepit task's diff (app-owned; regenerated on launch).
---
Arguments — Claudepit's phase brief: the task definition, then a `## Paths` section of
absolute `key=value` paths (one per line). Read the paths from there.

$ARGUMENTS

You are the final code reviewer for this task. The work is UNCOMMITTED in this worktree — plain
`git diff` misses new files — so build the review surface first. The review is read-only: never
mutate the working tree, the index, HEAD, or branch state, and never stage or commit. You are
already inside the task's dedicated git worktree — never create another worktree or branch, and
never run a subagent in worktree isolation.

## Step 1 — Build the review package

Concatenate into `<taskDir>/review-package.txt` (`taskDir=` is in the arguments):
- `git status --porcelain` (the file list)
- `git diff` (tracked changes)
- the FULL content of every untracked file from the status list

## Step 2 — Dispatch two reviewers IN PARALLEL

One message, two Task tool calls (general-purpose), so they run concurrently. Both get: the
package path, the absolute `specPath=` and `planPath=`, and these ground rules — read-only
checkout; you may read worktree files for context but never modify anything; judge the code on
its merits (rationales in comments or reports are claims, not verdicts); every finding needs
file:line, what is wrong, why it matters, and how to fix; calibrate severity honestly — not
everything is Critical.

**Reviewer A — spec compliance.** Compare the diff against the spec (and plan): Missing —
requirements skipped or claimed but absent from the diff; Extra — unrequested features,
over-engineering (YAGNI); Misunderstood — the right feature built the wrong way. Return a
verdict (compliant | issues found) plus the list.

**Reviewer B — code quality.** Correctness (bugs, edge cases, error handling), tests (verify
real behavior, not mocks; cover this change's edge cases), structure (one responsibility per
file, clean boundaries, DRY without premature abstraction, follows the codebase's patterns),
security where relevant. Return findings as Critical / Important / Minor.

## Step 3 — Merge and verify

Dedupe the two reports, then spot-check every finding against the package yourself — drop
anything the diff disproves. Calibration: **Critical** = broken behavior, data loss, security, a
spec requirement absent. **Important** = the work cannot be trusted until fixed — fragile
behavior, swallowed errors, tests that assert nothing, a missed requirement detail. **Minor** =
polish; "coverage could be broader" is Minor, not Important.

## Step 4 — Report

Write to the absolute `reviewPath=` in the arguments: Strengths (specific, with file:line);
findings grouped Critical / Important / Minor (each with file:line, what, why, fix); Assessment —
ready to merge? yes | with fixes | no, plus 1-2 sentences of reasoning.

Then print the machine-readable block — one line per finding, `severity | title | detail`, where
severity is high (=Critical), med (=Important), or low (=Minor); titles short and specific; the
detail names file:line. Example:

CLAUDEPIT_FINDINGS_BEGIN
high | Null deref in parseUser | parseUser() force-unwraps an optional that is nil on empty input (Parser.swift:41)
low | Rename foo | foo is a vague name for a URL builder (Client.swift:12)
CLAUDEPIT_FINDINGS_END

After the file is written and the block printed, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute reviewPath you wrote>
"""

    public static let taskCommands: [(filename: String, body: String)] = [
        ("claudepit-task-brainstorm.md", taskCommandBrainstorm),
        ("claudepit-task-spec.md", taskCommandSpec),
        ("claudepit-task-plan.md", taskCommandPlan),
        ("claudepit-task-implement.md", taskCommandImplement),
        ("claudepit-task-review.md", taskCommandReview),
    ]

    /// Commands removed from the pipeline; installers sweep these from projects and worktrees.
    public static let retiredTaskCommandFilenames = ["claudepit-task-verify.md"]

    /// Stale v1 agent files to delete once (superseded by taskCommands).
    public static let oldTaskAgentFilenames = [
        "claudepit-task-spec.md", "claudepit-task-plan.md",
        "claudepit-task-implement.md", "claudepit-task-review.md",
    ]
}

