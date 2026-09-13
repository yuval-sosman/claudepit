---
description: Fix a Claudepit task's review findings in place (app-owned; regenerated on launch).
---
Arguments — Claudepit's phase brief: the task definition, then a `## Paths` section of
absolute `key=value` paths (one per line). Read the paths from there.

$ARGUMENTS

Fix the review findings listed under `## Requirements` above. There is no spec and no plan for
this task: **the findings are the spec.** Read the full review at the absolute
`parentReviewPath=` in the arguments first — each finding's entry there carries the file:line and
the argument behind it that the one-line summary does not.

You may already be resumed into the session that wrote this code, in which case you know it
already — re-read the review anyway; the findings are someone else's reading of your work.

## Scope is the finding list, and nothing else

Fix exactly the findings you were given. Anything else you notice — a neighbouring bug, a
refactor that would be nice, a test that could be broader — is **out of scope**: note it in the
report and leave the code alone. Unrequested changes are a defect here, because the diff this
task produces is read against the finding list and nothing else.

You are already inside the task's git worktree: never create another worktree or branch, never
run git worktree commands, and never dispatch a subagent in worktree isolation.

**NEVER commit or stage. This is a HARD rule, no exceptions:**
- Do NOT run `git add`, `git commit`, `git stage`, `git push`, or any combined form (e.g.
  `git add -A && git commit -m ...`). These commands are DENIED and will fail.
- Leave EVERY change unstaged in the working tree. The user reviews and commits from Claudepit's
  Review Changes (Source Control) sheet — that is the ONLY place commits happen.
- `git status`, `git diff`, and reads are fine; anything that stages or commits is not.

## How to execute

Create one todo per finding and work them in the order given (high severity first). These are
small, related fixes in code you can see, so do them yourself — reserve the Task tool for a
finding that turns out to be a genuine piece of work, and then brief that subagent with the
finding's full text, the hard rules above, and a DONE/BLOCKED report contract. Never dispatch two
implementers in parallel: they share this worktree and will conflict.

**A finding you disagree with is a verdict, not a skip.** If the review is wrong, say so in the
report with the evidence that disproves it and leave the code unchanged. What you must not do is
quietly pass over a finding — every item on the list gets an explicit verdict.

After each fix, run the narrowest test that covers it and read the output.

## Rulings, not stalls

Small ambiguities are yours to decide: rule, record the ruling in the report, keep going. Reserve
AskUserQuestion for decisions that genuinely belong to the user — a finding whose fix would change
product behavior, or one that implies a scope change.

## Close-out — evidence before claims

The iron law: NO COMPLETION CLAIM WITHOUT FRESH EVIDENCE. If you did not run the command in this
session and read its output, you cannot claim it passes.
1. **Reality check** — `git status --porcelain` and `git diff --stat`: the diff contains the
   fixes and nothing else.
2. **Build** — run the project's full build; evidence is exit 0.
3. **Tests** — run the FULL suite and read the pass/fail counts line; 0 failures.
Anything red from this work gets fixed before you finish.

## Report

Write to the absolute `fixPath=` in the arguments. One `##` section per finding, in the order
given, each with:
- the finding's title and severity,
- **Verdict** — Fixed | Not a defect | Deferred (and why, for the last two),
- what changed, with file:line,
- **Evidence** — the command you ran and its result line.

End the file with an "Out of scope" section listing anything you noticed and deliberately left
alone, then the build and full-suite result lines.

After the file is written, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute fixPath you wrote>