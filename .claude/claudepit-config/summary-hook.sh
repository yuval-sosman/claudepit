#!/usr/bin/env bash
# claudepit-summary-hook: injects session summary instruction each turn
set -euo pipefail

HOOK_INPUT=$(cat)
SESSION_ID=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)
PROJECT_DIR=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

CURRENT_BULLETS="[]"
SUMMARY_FILE_PATH=""
NOW=$(date +%s)

if [[ -n "$SESSION_ID" && -n "$PROJECT_DIR" ]]; then
  # Match Claude Code's own project-dir slug: '/', '.', and '+' all become '-'
  # (a plain '/'-only replace mismatches worktree paths, which contain ".claude/worktrees").
  SLUG="${PROJECT_DIR//\//-}"
  SLUG="${SLUG//./-}"
  SLUG="${SLUG//+/-}"
  SUMMARY_DIR="$HOME/.claude/projects/${SLUG}/summary"
  SUMMARIES_FILE="${SUMMARY_DIR}/${SESSION_ID}.json"
  SUMMARY_FILE_PATH="$SUMMARIES_FILE"
  mkdir -p "$SUMMARY_DIR"

  EXISTING=$(python3 - "$SUMMARIES_FILE" 2>/dev/null << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
    print(json.dumps(data.get('bullets', [])))
except Exception:
    print('[]')
PYEOF
) || EXISTING="[]"
  CURRENT_BULLETS="${EXISTING:-[]}"
fi

INSTRUCTION="<claudepit_summary_instruction>
Current bullets: ${CURRENT_BULLETS}

After this turn, write the updated bullets to ${SUMMARY_FILE_PATH} with one Bash call, following the Session Summary rules:
{\"version\":1,\"bullets\":[\"bullet 1\",\"bullet 2\"],\"updatedAt\":${NOW}}
</claudepit_summary_instruction>"

python3 -c "
import json, sys
print(json.dumps({'continue': True, 'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': sys.argv[1]}}))
" "$INSTRUCTION"