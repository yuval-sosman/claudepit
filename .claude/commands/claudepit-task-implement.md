---
description: Implement a Claudepit task per its plan (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

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