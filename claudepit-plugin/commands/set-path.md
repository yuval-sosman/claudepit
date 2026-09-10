---
description: Set the Claude Cockpit active project path to this session's folder
---

Write the current working directory into the cockpit state file so the app switches to it. Run exactly this, substituting the real absolute cwd:

```bash
printf '{"action":"set-path","path":"%s","timestamp":%s}' "$(pwd)" "$(date +%s)" > ~/.claude/claudepit-state.json
```

Then tell the user the cockpit is now scoped to `$(pwd)`.
