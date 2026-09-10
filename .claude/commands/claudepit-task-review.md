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