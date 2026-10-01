---
description: Open the MCP Servers card in Claudepit
---

```bash
printf '{"action":"show-mcp","path":"","timestamp":%s}' "$(date +%s)" > ~/.claude/claudepit-state.json
```
