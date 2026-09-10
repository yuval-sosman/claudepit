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