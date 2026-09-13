---
description: Code-review a Claudepit task's diff (app-owned; regenerated on launch).
---
Arguments — Claudepit's phase brief: the task definition, then a `## Paths` section of
absolute `key=value` paths (one per line). Read the paths from there.

$ARGUMENTS

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

Write to the absolute `reviewPath=` in the arguments, in this order:

1. **Strengths** — specific, with file:line.
2. **Findings**, grouped Critical / Important / Minor. Give each one a label (`C1`, `I2`, `M3`), a
   short specific title, and the three questions answered under their own bold headings:
   **What.** the defect · **Why it matters.** the consequence · **Fix.** the concrete remedy.
   Name file:line for each.
3. **Assessment** — ready to merge? yes | with fixes | no, plus 1-2 sentences of reasoning.
4. **The machine-readable block**, last in the file (described below).

## The machine-readable block

Claudepit reads this block **out of the file** to build its findings screen, so it must be written
into `reviewPath` — not only printed. Print it as well, so a reader watching the pane sees it.

It is a JSON array between the two markers, one object per finding, ordered highest severity first.
The field names follow SARIF (the industry standard for static-analysis results) wherever SARIF has
an equivalent, so this converts to a SARIF run mechanically; `what`/`why`/`fix` are the narrative
fields SARIF has no first-class home for.

| field | required | notes |
|---|---|---|
| `ruleId` | yes | your own label for the finding — `C1`, `I2`, `M3`. Lets a reader find it in the prose above. |
| `severity` | yes | `high` (=Critical), `med` (=Important), `low` (=Minor). SARIF's `error`/`warning`/`note` are accepted too. |
| `category` | yes | one of `correctness`, `tests`, `security`, `performance`, `maintainability`, `docs`. |
| `title` | yes | short and specific — it is the headline in the UI. No trailing period. |
| `locations` | yes | array of `"path/to/File.swift:41"` strings, repo-relative. Empty array only if the finding genuinely has no site. |
| `what` | yes | the defect itself, 1-3 sentences. Plain prose, no heading. |
| `why` | yes | the consequence if it is not fixed. This is what the reader uses to triage. |
| `fix` | yes | the concrete remedy — what to change, where. Specific enough to act on without re-reading the review. |

Emit **exactly the same set of findings** as the prose above, in the same order. It is a
restatement for the machine, not a summary: `what`/`why`/`fix` carry the substance of the prose
sections, so a reader who only ever sees the UI is not missing the argument. Write valid JSON —
escape newlines and quotes inside the strings, and do not wrap the array in a code fence.

CLAUDEPIT_FINDINGS_BEGIN
[
  {
    "ruleId": "C1",
    "severity": "high",
    "category": "correctness",
    "title": "Null deref in parseUser",
    "locations": ["Sources/Parser.swift:41"],
    "what": "parseUser() force-unwraps `json[\"name\"]`, which is nil for an empty request body.",
    "why": "Any client that posts an empty body crashes the process rather than getting a 400.",
    "fix": "Bind with `guard let name = json[\"name\"] as? String else { return .invalid }`."
  },
  {
    "ruleId": "M1",
    "severity": "low",
    "category": "maintainability",
    "title": "foo is a vague name for a URL builder",
    "locations": ["Sources/Client.swift:12"],
    "what": "`foo(_:)` builds and returns a request URL, but its name says nothing about that.",
    "why": "Call sites read as `foo(path)`, so a reader has to open the definition to know what it returns.",
    "fix": "Rename to `requestURL(for:)` — four call sites, all in Client.swift."
  }
]
CLAUDEPIT_FINDINGS_END

If you found nothing, emit the markers around an empty array `[]`.

After the file is written and the block printed, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute reviewPath you wrote>