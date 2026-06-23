#!/usr/bin/env bash
# Captain's Log — Claude Code Stop Hook
# Fires when a session ends. Reads the transcript, generates a Picard-style
# log entry via claude -p, appends to the daily file, and pushes to GitHub.

DIARY_DIR="${DIARY_DIR:-$HOME/Code/captains-log}"
GLOBAL_LOCK="/tmp/captains-log-global"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prevent recursive invocation — claude -p in this script also triggers Stop
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

# Capture stdin (hook input JSON)
cat > "$INPUT_FILE"

# Extract transcript path
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

# Parse transcript via module — outputs: first line = tool count, rest = message snippets
PARSE_OUTPUT=$(python3 "$SCRIPT_DIR/parse_transcript.py" "$TRANSCRIPT_PATH" 2>/dev/null)
TOOL_COUNT=$(echo "$PARSE_OUTPUT" | head -1)
CONVERSATION=$(echo "$PARSE_OUTPUT" | tail -n +2 | head -25 | python3 -c "import sys; print('\n'.join(sys.stdin.read().splitlines()[-25:]))")

if [ "$TOOL_COUNT" = "0" ] || [ -z "$TOOL_COUNT" ] || [ "$TOOL_COUNT" -lt 2 ] 2>/dev/null; then
    exit 0
fi

if [ -z "$CONVERSATION" ]; then
    exit 0
fi

# Write conversation to temp file for prompt embedding
echo "$CONVERSATION" > "$CONV_FILE"

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

# Write prompt to file (avoids quoting issues with multiline strings)
cat > "$PROMPT_FILE" << PROMPT_BOUNDARY
You are Captain Jean-Luc Picard dictating your Captain's Log. Write a 150-200 word entry about a software engineering session.

Voice and style rules -- study these carefully:
- Picard speaks in complete, measured sentences. No sentence fragments.
- He does NOT use em-dashes or hyphens mid-sentence. He uses commas, semicolons, and full stops instead.
- He does NOT use contractions ("it is" not "it's", "we have" not "we've").
- His tone is formal, weighty, and occasionally philosophical. He reflects on the meaning of the work, not just the mechanics.
- He uses nautical and military framing naturally: "the crew", "ship's systems", "this vessel", "operations", "the mission".
- Frame technical work as ship operations: bugs are system failures or hostile incursions, deployments are course changes or warp transitions, new code is a capability brought online, debugging is a forensic investigation.
- He pauses to note what the work means, not just what was done. A line about what this effort serves is appropriate.
- Do NOT mention "the USS Enterprise" by name.
- Do NOT use em-dashes. Use commas or semicolons instead.

Stardate: $STARDATE. Time: $TIME_NOW.
Start the entry with exactly: "Captain's Log, Stardate $STARDATE."

Conversation excerpt:
$CONVERSATION
PROMPT_BOUNDARY

# Generate entry via claude -p (non-interactive, no hooks triggered for inner session)
ENTRY=$(claude -p < "$PROMPT_FILE" 2>/dev/null || echo "")

if [ -z "$ENTRY" ]; then
    ENTRY="Captain's Log, Stardate $STARDATE. A development session concluded at ${TIME_NOW} ship's time. ${TOOL_COUNT} operations were recorded. The full details of this engagement have not been transcribed."
fi

# Create daily file if needed
if [ ! -f "$LOG_FILE" ]; then
    printf "# Captain's Log — %s\n\n" "$TODAY" > "$LOG_FILE"
fi

# Append entry with separator
{
    echo ""
    echo "---"
    echo ""
    echo "*Logged at $TIME_NOW*"
    echo ""
    echo "$ENTRY"
    echo ""
} >> "$LOG_FILE"

# Update README — insert link at top of Entries list if not already present
if ! grep -qF "$TODAY" "$DIARY_DIR/README.md" 2>/dev/null; then
    TODAY="$TODAY" STARDATE="$STARDATE" DIARY_DIR="$DIARY_DIR" python3 - << 'PYEOF'
import os

today = os.environ['TODAY']
stardate = os.environ['STARDATE']
diary_dir = os.environ['DIARY_DIR']
readme = os.path.join(diary_dir, 'README.md')

with open(readme, 'r') as f:
    content = f.read()

new_line = f'- [{today}]({today}.md) — Stardate {stardate}\n'
marker = '## Entries\n'

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
