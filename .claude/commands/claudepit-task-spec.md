---
description: Write a design spec for a Claudepit task (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

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