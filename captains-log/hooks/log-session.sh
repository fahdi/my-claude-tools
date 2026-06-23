#!/usr/bin/env bash
# Captain's Log — Claude Code Stop Hook
#
# Fires when a session ends. Reads the transcript, generates a Picard-style
# log entry via claude -p, appends to the daily file, and pushes to GitHub.
#
# Config: set CAPTAINS_LOG_DIR to override the default diary location.

DIARY_DIR="${CAPTAINS_LOG_DIR:-$HOME/Code/captains-log}"
GLOBAL_LOCK="/tmp/captains-log-global"

# Prevent recursive invocation — the claude -p call below also fires Stop
if [ -f "$GLOBAL_LOCK" ]; then
    exit 0
fi
touch "$GLOBAL_LOCK"

INPUT_FILE=$(mktemp /tmp/captains-log-input-XXXXXX)
CONV_FILE=$(mktemp /tmp/captains-log-conv-XXXXXX)
PROMPT_FILE=$(mktemp /tmp/captains-log-prompt-XXXXXX)

cleanup() {
    rm -f "$GLOBAL_LOCK" "$INPUT_FILE" "$CONV_FILE" "$PROMPT_FILE" 2>/dev/null
}
trap cleanup EXIT

# Capture stdin (hook input JSON from Claude Code)
cat > "$INPUT_FILE"

# Extract transcript path from hook payload
TRANSCRIPT_PATH=$(INPUT_FILE="$INPUT_FILE" python3 - << 'PYEOF'
import json, sys, os
try:
    with open(os.environ['INPUT_FILE']) as f:
        d = json.load(f)
    print(d.get('transcript_path', ''))
except Exception:
    pass
PYEOF
)

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    exit 0
fi

# Parse transcript — extract conversation and count tool uses
# Exits early (prints "0") if fewer than 2 tool uses (no real work done)
TOOL_COUNT=$(TRANSCRIPT_PATH="$TRANSCRIPT_PATH" CONV_FILE="$CONV_FILE" python3 - << 'PYEOF'
import json, sys, os

transcript_path = os.environ['TRANSCRIPT_PATH']
conv_file = os.environ['CONV_FILE']

messages = []
tool_use_count = 0

try:
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue

            role = msg.get('role', '')
            content = msg.get('content', '')

            if isinstance(content, list):
                for part in content:
                    if isinstance(part, dict) and part.get('type') in ('tool_use', 'tool_result'):
                        tool_use_count += 1
                text_parts = [
                    p.get('text', '') for p in content
                    if isinstance(p, dict) and p.get('type') == 'text'
                    and p.get('text', '').strip()
                ]
                text = ' '.join(text_parts)
            elif isinstance(content, str):
                text = content
            else:
                text = ''

            if text and len(text.strip()) > 20:
                snippet = text.strip()[:300].replace('\n', ' ')
                messages.append(f"{role}: {snippet}")
except Exception:
    print("0")
    sys.exit(0)

if tool_use_count < 2:
    print("0")
    sys.exit(0)

with open(conv_file, 'w') as f:
    f.write('\n'.join(messages[-25:]))

print(str(tool_use_count))
PYEOF
2>/dev/null || echo "0")

if [ "$TOOL_COUNT" = "0" ] || [ -z "$TOOL_COUNT" ]; then
    exit 0
fi

CONVERSATION=$(cat "$CONV_FILE" 2>/dev/null)
if [ -z "$CONVERSATION" ]; then
    exit 0
fi

# Calculate stardate: (year - 1966) * 1000 + (day_of_year / 366 * 1000)
STARDATE=$(python3 -c "
import datetime
now = datetime.date.today()
day = now.timetuple().tm_yday
print(f'{(now.year - 1966) * 1000 + day * 1000 / 366:.1f}')
")

TODAY=$(date +%Y-%m-%d)
TIME_NOW=$(date +%H:%M)
LOG_FILE="$DIARY_DIR/$TODAY.md"

# Build prompt in a file to avoid multiline quoting issues
cat > "$PROMPT_FILE" << PROMPT_BOUNDARY
You are Captain Jean-Luc Picard writing your Captain's Log about a software engineering session. Stardate: $STARDATE. Time: $TIME_NOW.

Based on this conversation excerpt, write a 150-200 word log entry in Picard's voice. Be formal, measured, reflective. Frame technical work as ship operations — bugs as hostile incursions, deployments as warp jumps, new code as capabilities brought online, debugging as forensic investigation. Do NOT reference "the USS Enterprise" by name. Start exactly with: "Captain's Log, Stardate $STARDATE."

Conversation excerpt:
$CONVERSATION
PROMPT_BOUNDARY

# Generate entry — claude -p runs non-interactively and does not re-trigger this hook
ENTRY=$(claude -p < "$PROMPT_FILE" 2>/dev/null || echo "")

if [ -z "$ENTRY" ]; then
    ENTRY="Captain's Log, Stardate $STARDATE. A development session concluded at ${TIME_NOW}. ${TOOL_COUNT} operations were recorded during this engagement. The full account of today's work has not been transcribed."
fi

# Create daily file if needed
if [ ! -f "$LOG_FILE" ]; then
    printf "# Captain's Log — %s\n\n" "$TODAY" > "$LOG_FILE"
fi

# Append entry
{
    echo ""
    echo "---"
    echo ""
    echo "*Logged at $TIME_NOW*"
    echo ""
    echo "$ENTRY"
    echo ""
} >> "$LOG_FILE"

# Update README index — insert link at top of Entries section if date not present
if ! grep -qF "$TODAY" "$DIARY_DIR/README.md" 2>/dev/null; then
    TODAY="$TODAY" STARDATE="$STARDATE" DIARY_DIR="$DIARY_DIR" python3 - << 'PYEOF'
import os

today    = os.environ['TODAY']
stardate = os.environ['STARDATE']
readme   = os.path.join(os.environ['DIARY_DIR'], 'README.md')

with open(readme, 'r') as f:
    content = f.read()

new_line = f'- [{today}]({today}.md) — Stardate {stardate}\n'
marker   = '## Entries\n'

if marker in content:
    idx = content.index(marker) + len(marker)
    while idx < len(content) and content[idx] == '\n':
        idx += 1
    content = content[:idx] + new_line + content[idx:]
else:
    content += f'\n## Entries\n\n{new_line}'

with open(readme, 'w') as f:
    f.write(content)
PYEOF
fi

# Commit and push
cd "$DIARY_DIR"
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "Captain's Log: $TODAY at $TIME_NOW"
    git push origin main 2>/dev/null || true
fi
