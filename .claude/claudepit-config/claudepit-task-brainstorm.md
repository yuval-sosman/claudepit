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