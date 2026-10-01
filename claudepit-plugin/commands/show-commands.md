---
description: Open the Commands card in Claudepit
---

```bash
printf '{"action":"show-commands","path":"","timestamp":%s}' "$(date +%s)" > ~/.claude/claudepit-state.json
```
