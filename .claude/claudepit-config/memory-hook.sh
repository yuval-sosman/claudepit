#!/usr/bin/env bash
# claudepit-memory-hook: reminds Claude to write memory before session ends, triggers dreaming cycle at ≥10 writes
set -euo pipefail
EVENT="${1:-Stop}"
HOOK_INPUT=$(cat)

# Bail if already inside a stop hook turn — prevents infinite loop
IS_ACTIVE=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_hook_active', False))" 2>/dev/null || echo "False")
if [[ "$IS_ACTIVE" == "True" ]]; then
  echo '{"continue": true}'
  exit 0
fi

SESSION_ID=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)
PROJECT_DIR=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)
SLUG="${PROJECT_DIR//\//-}"
LOG_FILE="$HOME/.claude/projects/${SLUG}/memory/log.json"

WRITES_SINCE_DREAM=0
if [[ -f "$LOG_FILE" ]]; then
  WRITES_SINCE_DREAM=$(python3 - "$LOG_FILE" 2>/dev/null << 'PYEOF'
import json, sys
try:
    entries = json.load(open(sys.argv[1]))
    count = 0
    for e in reversed(entries):
        if e.get("type") == "dream":
            break
        if e.get("type") == "write":
            count += 1
    print(count)
except Exception:
    print(0)
PYEOF
) || WRITES_SINCE_DREAM=0
fi

if [[ "${WRITES_SINCE_DREAM}" -ge 10 ]]; then
  MSG="When you finish implementing something, always use the Custom Memory Strategy to maintain memory for these changes. Do not wait for the user to ask. Do it before session stops.

DREAMING CYCLE — your memory log has reached ${WRITES_SINCE_DREAM} writes since last consolidation.
Before this session ends, run the full 11-step memory consolidation:

1. Inventory — read MEMORY.md, list memory/ recursively, find orphans
2. Full read — read every topic file (check updated date, claims, links, sources)
3. Contradiction scan — find conflicting claims across pages, keep the more recent one
4. Staleness check — cross-reference recent log.json summaries against page content
5. Cross-reference integrity — verify all [text](./file.md) links resolve; fix broken/stale ones; add reciprocal links
6. Synapse formation — discover unlinked relationships (shared entities, cause-effect, temporal sequence, complementary detail) and add cross-reference links
7. Orphan resolution — reconnect or remove files not reachable from MEMORY.md
8. Reachability check — every .md must have at least one inbound link from the graph
9. Consolidation — merge closely related pages, clear sources, update all references
10. MEMORY.md sync — rewrite the index to reflect current state (max 20 lines)
11. Log the dream — append {\"type\":\"dream\",\"sessionId\":\"${SESSION_ID}\",\"ts\":\$(date +%s),\"title\":\"Consolidation\",\"summary\":\"<what merged/renamed/removed>\",\"changes\":[{\"action\":\"delete\",\"file\":\"<merged-away.md>\"},{\"action\":\"update\",\"file\":\"MEMORY.md\"}]} to memory/log.json"
else
  MSG="When you finish implementing something, always use the Custom Memory Strategy to maintain memory for these changes. Do not wait for the user to ask. Do it before session stops."
fi

python3 -c "
import json, sys
print(json.dumps({'continue': True, 'hookSpecificOutput': {'hookEventName': sys.argv[1], 'additionalContext': sys.argv[2]}}))
" "$EVENT" "$MSG"