---
description: Code-review a Claudepit task's diff (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

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