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