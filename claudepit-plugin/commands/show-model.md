---
description: Open the Settings page (where model and env live) in Claudepit
---

```bash
printf '{"action":"show-settings","path":"","timestamp":%s}' "$(date +%s)" > ~/.claude/claudepit-state.json
```
