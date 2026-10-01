---
description: Merge a Claudepit worktree's base branch into it and resolve conflicts (app-owned; regenerated on launch).
---
Arguments — Claudepit's merge brief: a `## Paths` section of absolute `key=value` values, one per
line. Read `worktreePath=`, `baseRef=`, `baseBranch=` and `branch=` from there.

$ARGUMENTS

Bring this worktree up to date with its base branch. The user clicked "Merge with Claude" because
the one-click path could not do it alone — the tree is dirty, or the merge conflicts, or both.

You are already inside the worktree at `worktreePath=`. Never create another worktree or branch,
never run `git worktree` commands, and never dispatch a subagent in worktree isolation.

## What to do

1. `git status` first. Know what is uncommitted before you move anything.
2. `git fetch` the base when `baseRef=` names a remote ref (it starts with `origin/`). A stale
   remote-tracking ref means you would merge yesterday's base and the "behind" count would not
   clear.
3. If the tree has uncommitted **tracked** changes, `git stash push` them — with a message saying
   this was you — and pop them at the end. Do not use `-u`: untracked files do not block a merge,
   and this worktree's `.claude/commands/*` are deliberately untracked.
4. `git merge --no-edit <baseRef>`.
5. Resolve every conflict by editing the files. Read enough of both sides to understand *why* each
   side changed — a conflict resolved by picking a side wholesale is usually wrong. Keep the
   intent of both the base commits and this branch's work.
6. Pop the stash if you made one, and resolve any conflicts that surfaces too.
7. Verify: `swift build --product ClaudepitApp`. Never bare `swift build` — it also builds Splash's
   `SplashImageGen`, which fails on the CLI toolchain (no CoreGraphics). Run `swift test` as well
   when the merge touched anything under `Sources/`.

## Don't stage or commit

- `git add`, `git commit`, `git stage` and `git push` — alone or combined — are denied in this
  worktree and will fail.
- That includes the merge commit. A conflicted merge stays conflicted-but-resolved in the working
  tree; the user finishes it from Claudepit's Review Changes (Source Control) sheet, the only
  place commits happen.
- `git status`, `git diff`, `git log`, `git fetch`, `git merge`, `git stash` and reads are all
  fine. Anything that stages or commits is not.
- If a conflict proves unresolvable, run `git merge --abort`, restore the stash, and say so. Do
  not leave the worktree half-merged without telling the user.

## Report

Finish by printing, in the pane:
- which commits came in from `baseBranch=` (a one-line `git log --oneline` range is enough),
- every file you resolved and the call you made on each,
- the build/test result lines,
- and the next step, verbatim: **commit the merge from Claudepit's Review changes.**