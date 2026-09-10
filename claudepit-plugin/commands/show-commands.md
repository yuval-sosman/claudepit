---
description: Open the Commands card in Claude Cockpit
---

```bash
printf '{"action":"show-commands","path":"","timestamp":%s}' "$(date +%s)" > ~/.claude/claudepit-state.json
```
