#!/usr/bin/env bash
# claudepit-memory-hook: reminds Claude to write memory before session ends, triggers dreaming cycle at ≥10 writes
set -euo pipefail
EVENT="${1:-Stop}"
HOOK_INPUT=$(cat)

# One python pass for every field we need — this hook fires on every Stop, so interpreter
# startups are the whole cost when there is nothing to remember.
FIELDS=$(echo "$HOOK_INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in ('stop_hook_active', 'session_id', 'cwd', 'transcript_path'):
    print(d.get(k, '') or '')
" 2>/dev/null || true)
IS_ACTIVE=$(sed -n 1p <<< "$FIELDS")
SESSION_ID=$(sed -n 2p <<< "$FIELDS")
PROJECT_DIR=$(sed -n 3p <<< "$FIELDS")
TRANSCRIPT=$(sed -n 4p <<< "$FIELDS")

# Bail if already inside a stop hook turn — prevents infinite loop
if [[ "$IS_ACTIVE" == "True" ]]; then
  echo '{"continue": true}'
  exit 0
fi

# Fast path: a session that never wrote a file has nothing to remember, so inject nothing at
# all — no reminder, no dreaming, no memory read. The transcript is scanned for tool calls only
# (never raw text: every transcript embeds a system prompt that mentions "git commit" and the
# like, so a plain grep would match on every session). A false positive costs only the normal
# reminder, which the strategy's own skip rule then short-circuits.
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  TOUCHED=$(python3 - "$TRANSCRIPT" 2>/dev/null << 'PYEOF'
import json, re, sys

WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
SHELL_WRITE = re.compile(
    r"(?:^|[\s;&|(])(?:sed\s+-i|tee|mv|cp|rm|mkdir|touch|patch|install)\b"
    r"|>{1,2}\s*(?!/dev/)[^\s&|;]"
    r"|<<"
    r"|git\s+(?:commit|apply|revert|rebase|merge|mv|rm|checkout\s+-b|switch\s+-c)\b")

def wrote(block):
    name = block.get("name", "")
    if name in WRITE_TOOLS:
        return True
    if name in ("Bash", "BashOutput"):
        cmd = (block.get("input") or {}).get("command") or ""
        return bool(SHELL_WRITE.search(cmd))
    return False

try:
    with open(sys.argv[1], errors="ignore") as fh:
        for line in fh:
            if '"tool_use"' not in line:
                continue
            try:
                content = (json.loads(line).get("message") or {}).get("content")
            except Exception:
                continue
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use" and wrote(block):
                    print(1)
                    sys.exit(0)
    print(0)
except Exception:
    print(1)
PYEOF
) || TOUCHED=1
  if [[ "${TOUCHED:-1}" == "0" ]]; then
    echo '{"continue": true}'
    exit 0
  fi
fi

# Match Claude Code's own project-dir slug: '/', '.', and '+' all become '-'
# (a plain '/'-only replace mismatches worktree paths, which contain ".claude/worktrees").
SLUG="${PROJECT_DIR//\//-}"
SLUG="${SLUG//./-}"
SLUG="${SLUG//+/-}"
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
  MSG="When you finish implementing something, always use the Custom Memory Strategy to maintain memory for these changes. Do not wait for the user to ask. Do it before session stops. If this session implemented, changed, or decided nothing, skip the memory pass entirely — write nothing, read nothing, log nothing, and say nothing about memory. Judge that from the work you just did, never by reading memory files first. When you do write, touch only the topic files this session's work actually affects.

DREAMING CYCLE — your memory log has reached ${WRITES_SINCE_DREAM} writes since last consolidation.
Before this session ends, run the full 11-step memory consolidation. Do NOT run it inline in this
session — dispatch it to a subagent so consolidation doesn't burn this session's own context.

Use the Task tool to launch one general-purpose subagent on the latest Sonnet model
(claude-sonnet-5). Give it this checklist verbatim as its prompt, including the session ID
${SESSION_ID} for step 11, and wait for it to finish before the session ends:

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
  MSG="When you finish implementing something, always use the Custom Memory Strategy to maintain memory for these changes. Do not wait for the user to ask. Do it before session stops. If this session implemented, changed, or decided nothing, skip the memory pass entirely — write nothing, read nothing, log nothing, and say nothing about memory. Judge that from the work you just did, never by reading memory files first. When you do write, touch only the topic files this session's work actually affects."
fi

python3 -c "
import json, sys
print(json.dumps({'continue': True, 'hookSpecificOutput': {'hookEventName': sys.argv[1], 'additionalContext': sys.argv[2]}}))
" "$EVENT" "$MSG"