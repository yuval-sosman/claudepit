---
description: Set the Claudepit active project path to this session's folder
---

Write the current working directory into the Claudepit state file so the app switches to it. Run exactly this, substituting the real absolute cwd:

```bash
printf '{"action":"set-path","path":"%s","timestamp":%s}' "$(pwd)" "$(date +%s)" > ~/.claude/claudepit-state.json
```

Then tell the user Claudepit is now scoped to `$(pwd)`.
