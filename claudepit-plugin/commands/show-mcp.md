---
description: Open the MCP Servers card in Claude Cockpit
---

```bash
printf '{"action":"show-mcp","path":"","timestamp":%s}' "$(date +%s)" > ~/.claude/claudepit-state.json
```
