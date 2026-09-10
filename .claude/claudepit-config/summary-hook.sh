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
  SLUG="${PROJECT_DIR//\//-}"
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
You maintain a running project summary for this session. Current bullets: ${CURRENT_BULLETS}

After processing this turn, always write updated bullets to the file at ${SUMMARY_FILE_PATH} using a Bash tool call. There is no case where you skip writing entirely.

JSON structure to write:
{\"version\":1,\"bullets\":[\"bullet 1\",\"bullet 2\"],\"updatedAt\":${NOW}}

- Write the file silently. Do not tell the user. Do not explain what you wrote.

Rules:
- Max 15 bullets total. If adding new bullets would exceed 15, review all bullets and either combine closely related ones into a single concise bullet, or remove the least important one (minor clarifications, trivial lookups, superseded decisions). Preserve the most meaningful outcomes.
- Before adding a new bullet, check if any existing bullet covers the same topic. If a decision changed or was revised, remove the old bullet and replace it with the updated one — do not keep both. If new information extends an existing bullet, update that bullet in place rather than adding a new one.
- Outcomes only: what was built, fixed, or decided — not how.
- Past tense for work done; present tense only for the high-level topic bullet (e.g. \"Discussing X\").
- Write whenever ANY of the following happened: code was written or edited, a feature was added or changed, a bug was fixed, a design or architecture decision was made, a plan was created, configuration was changed, a test was added, or the user asked you to implement something and you did it. When in doubt, write — missing a summary is worse than writing a minor one.
- If this turn had zero code or project changes (purely conversational — user only asked a question, you only explained something), write exactly 1 bullet: one short sentence describing what this session is about at the highest level (e.g. \"Exploring how session summary storage works\"). This ensures there is always at least a reminder bullet even for lightweight sessions.
</claudepit_summary_instruction>"

python3 -c "
import json, sys
print(json.dumps({'continue': True, 'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': sys.argv[1]}}))
" "$INSTRUCTION"