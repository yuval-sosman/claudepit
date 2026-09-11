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