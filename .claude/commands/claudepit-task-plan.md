---
description: Turn a Claudepit task spec into an implementation plan (app-owned; regenerated on launch).
---
Arguments: $ARGUMENTS

You are turning an approved spec into an implementation plan. The spec is at the absolute `specPath=`
in the arguments. Produce a plan markdown file named `<today>-<slug>.md` (use `today=` from the
arguments) and write it into the absolute directory given by `plansDir=` in the arguments.
IMPORTANT: write to that absolute plansDir path exactly — never a relative `plans/…` and never a
literal `~/…`, or the app cannot find the plan.
IMPORTANT: You are ONLY writing a plan document — do NOT edit, create, or delete any source files.
Read the spec and any existing code for context, then produce the plan markdown. No code changes.
After the file is written and saved, print on its own line, LAST:
CLAUDEPIT_ARTIFACT: <the absolute plan .md path under plansDir>