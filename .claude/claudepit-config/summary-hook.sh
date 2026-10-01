#!/usr/bin/env bash
# claudepit-summary-hook: injects session summary instruction each turn
set -euo pipefail

HOOK_INPUT=$(cat)

# A loop's scheduled fire is not a person's turn: leave the summary alone. Asking for the write on
# every fire costs a tool call per fire (every minute, for /loop 1m) and — the reason it matters —
# that Bash write can stop an unattended loop at a permission prompt. The hook input doesn't say
# what kind of prompt this is, but the transcript does: a fire writes its `scheduled_task_fire`
# record before this hook runs and its prompt record after it — so a fire record that no prompt
# record (`scheduledTaskId`) has followed yet is the turn now starting. (`turn_duration` doesn't
# settle it: a fire that comes due as a turn ends is written before that turn's last records.)
# The fire record keeps the prompt squashed and cut at 200 characters, so it's compared that way;
# a `<<…>>` marker is a loop.md / built-in loop whose text expands later.
#
# The same goes for a background task's report on a loop's work. A fire that hands its task to a
# subagent ends its turn at the launch; the agent's report then arrives as a turn of its own
# (`<task-notification>`), unattended, once per fire. Asking for the write there stopped a real
# delegated `/loop 1m` at an "expansion obfuscation" prompt after its first fire. A report counts
# when the call it reports on (`<tool-use-id>`) ran in a fire's turn, a `/loop`'s first run (or
# a turn that armed one with CronCreate), or a turn that was itself such a report.
TRANSCRIPT=$(echo "$HOOK_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || true)
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  SCHEDULED=$(CLAUDEPIT_HOOK_INPUT="$HOOK_INPUT" python3 - "$TRANSCRIPT" 2>/dev/null << 'PYEOF'
import json, os, re, sys
def norm(s):
    s = ''.join(c for c in (s or '') if c >= ' ' or c in '\n\t')
    s = ' '.join(s.split())
    while s.endswith('…') or s.endswith('...'):
        s = s[:-1] if s.endswith('…') else s[:-3]
    return s.strip()
try:
    raw_prompt = json.loads(os.environ.get('CLAUDEPIT_HOOK_INPUT', '{}')).get('prompt') or ''
except Exception:
    raw_prompt = ''
prompt = norm(raw_prompt)
with open(sys.argv[1], 'rb') as f:
    f.seek(0, 2)
    f.seek(max(0, f.tell() - 4194304))
    lines = f.read().splitlines()
TOOL_ID = re.compile(r'<tool-use-id>([^<\s]+)</tool-use-id>')
def text_of(o):
    c = (o.get('message') or {}).get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return ' '.join(b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
    return ''
def is_report(o):
    return o.get('turnOrigin') == 'task_notification' or (o.get('origin') or {}).get('kind') == 'task-notification'
def loop_work(tool_id, depth=0):
    if depth > 5:
        return False
    needle = ('"id":"%s"' % tool_id).encode()
    at = next((i for i in range(len(lines) - 1, -1, -1) if needle in lines[i] and b'"tool_use"' in lines[i]), None)
    if at is None:
        return False
    for raw in reversed(lines[:at + 1]):
        if b'"type":"assistant"' in raw:
            if b'"name":"CronCreate"' in raw or (b'"name":"Skill"' in raw and b'"skill":"loop"' in raw):
                return True
            continue
        if b'"type":"user"' not in raw:
            continue
        if b'"scheduledTaskId":"' in raw or b'"turnOrigin":"scheduled"' in raw:
            return True
        if not (b'"turnOrigin":"' in raw or b'"promptSource":"typed"' in raw or b'"promptSource":"queued"' in raw
                or b'"kind":"task-notification"' in raw):
            continue   # a tool result, or the turn's own meta records
        try:
            o = json.loads(raw)
        except Exception:
            return False
        if o.get('type') != 'user':
            continue
        text = text_of(o)
        if '<command-name>/loop</command-name>' in text:
            return True
        if is_report(o):
            m = TOOL_ID.search(text)
            return bool(m) and loop_work(m.group(1), depth + 1)
        return False
    return False
report = raw_prompt if '<task-notification>' in raw_prompt else ''
if not report:
    # The report's own record is written before this hook runs.
    for raw in reversed(lines):
        if b'"type":"assistant"' in raw:
            break
        if not (b'"turnOrigin":"' in raw or b'"promptSource":"' in raw or b'"kind":"task-notification"' in raw):
            continue
        try:
            o = json.loads(raw)
        except Exception:
            break
        if o.get('type') != 'user':
            continue
        if is_report(o):
            report = text_of(o)
        break
m = TOOL_ID.search(report)
if m and loop_work(m.group(1)):
    print('1')
    sys.exit(0)
# A fire's own record can land after this hook runs (a recorded hook saw only the previous turn's
# records) — but the prompt it fires was written when the loop was set up: a CronCreate or
# ScheduleWakeup `prompt`. A prompt that is one of those is a fire. The whole transcript is
# searched: bytes.find over 67 MB is ~30 ms (mmap.find took three times as long).
def scheduled_prompts(path):
    found = set()
    with open(path, 'rb') as f:
        data = f.read()
    for marker in (b'"name":"CronCreate"', b'"name":"ScheduleWakeup"'):
        pos = data.find(marker)
        while pos != -1:
            start = data.rfind(b'\n', 0, pos) + 1
            end = data.find(b'\n', pos)
            end = len(data) if end == -1 else end
            try:
                o = json.loads(data[start:end])
                for b in (o.get('message') or {}).get('content') or []:
                    if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') in ('CronCreate', 'ScheduleWakeup'):
                        p = (b.get('input') or {}).get('prompt')
                        if isinstance(p, str) and p.strip():
                            found.add(norm(p))
            except Exception:
                pass
            pos = data.find(marker, end)
    return found
if prompt and prompt in scheduled_prompts(sys.argv[1]):
    print('1')
    sys.exit(0)
def same(fired):
    n = min(len(fired), len(prompt), 180)
    return not prompt or fired == prompt or (n >= 40 and fired[:n] == prompt[:n])
delivered = set()
replied = False
for raw in reversed(lines):
    if b'"type":"assistant"' in raw or b'"subtype":"turn_duration"' in raw:
        replied = True
        continue
    if b'"scheduledTaskId":"' in raw:
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if o.get('type') == 'user':
            content = (o.get('message') or {}).get('content')
            if not replied and isinstance(content, str) and same(norm(content)):
                print('1')   # a CLI that writes the fire's prompt record before its hooks run
                break
            delivered.add(o.get('scheduledTaskId'))
        continue
    if b'"subtype":"scheduled_task_fire"' not in raw:
        continue
    try:
        o = json.loads(raw)
    except Exception:
        continue
    if o.get('type') != 'system' or o.get('taskId') in delivered:
        break
    fired = norm(o.get('prompt'))
    if not fired or fired.startswith('<<') or same(fired):
        print('1')
    break
PYEOF
) || SCHEDULED=""
  if [[ "$SCHEDULED" == "1" ]]; then
    echo '{"continue": true}'
    exit 0
  fi
fi

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