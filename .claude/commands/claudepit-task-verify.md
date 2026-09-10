---
description: Verify a Claudepit task's implementation (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

Verify the implementation in this worktree: run the project's build and tests, exercise the plan's
acceptance criteria (plan at `planPath=`). You are already inside the task's git worktree.
Print on its own line, LAST, exactly one of:
CLAUDEPIT_VERIFY: pass
CLAUDEPIT_VERIFY: fail