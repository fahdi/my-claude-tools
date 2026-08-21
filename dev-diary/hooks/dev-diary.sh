#!/usr/bin/env bash
# Dev Diary — Claude Code Stop Hook
# Runs in parallel to the Captain's Log hook. Fires on every Stop event.
# Splits the work: hard facts (files changed, commands run) are extracted
# mechanically from the transcript, so they cannot be hallucinated; the
# interpretive parts (prose lead, decisions, follow-ups) come from `claude -p`.
# Writes to a daily markdown file and pushes to a private GitHub repo.

DIARY_DIR="${DEV_DIARY_DIR:-$HOME/Code/devdiary}"
GLOBAL_LOCK="/tmp/dev-diary-lock"

# Per-project opt-out: a .local-diary marker at or above the session cwd
# silences the global diary. A project-local hook that sets DEV_DIARY_DIR
# explicitly is not affected, so the same script can serve project diaries.
if [ -z "$DEV_DIARY_DIR" ]; then
    _d="$PWD"
    while [ "$_d" != "/" ]; do
        [ -f "$_d/.local-diary" ] && exit 0
        _d="$(dirname "$_d")"
    done
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve a Python 3 interpreter. macOS and Linux have python3; Windows ships
# python.exe plus the py launcher, and its "python3" is usually a Microsoft
# Store stub that opens the Store and runs nothing. Probe by asking each
# candidate for its version rather than trusting the name.
find_python() {
    local candidate
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1 &&
           "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    if command -v py >/dev/null 2>&1 && py -3 -c '' >/dev/null 2>&1; then
        printf '%s' 'py -3'
        return 0
    fi
    return 1
}

# Deliberately unquoted at every use site: "py -3" has to word-split.
PYTHON="$(find_python)" || exit 0

# mtime in epoch seconds. GNU coreutils (Linux, WSL, Git Bash) uses -c %Y;
# BSD/macOS uses -f %m. Prints nothing when neither works.
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

# Reclaim a stale lock left behind by a run that was SIGKILLed before its EXIT
# trap fired (e.g. hit the hook timeout while claude -p was still generating).
# Only reclaim when the age is genuinely known to exceed the timeout. Reading
# mtime with the BSD-only `stat -f %m` and defaulting failures to 0 made every
# lock look ~1.7 billion seconds old on Linux, WSL, and Git Bash, so the guard
# was cleared on every run instead of only when truly stale.
if [ -d "$GLOBAL_LOCK" ]; then
    LOCK_MTIME="$(file_mtime "$GLOBAL_LOCK")"
    if [ -n "$LOCK_MTIME" ] && [ "$LOCK_MTIME" -gt 0 ] 2>/dev/null; then
        LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
        if [ "$LOCK_AGE" -gt 90 ]; then
            rmdir "$GLOBAL_LOCK" 2>/dev/null
        fi
    fi
fi

# Atomic lock via mkdir — prevents recursion (the inner claude -p also triggers
# Stop) and races when parallel Stop hooks fire.
if ! mkdir "$GLOBAL_LOCK" 2>/dev/null; then
    exit 0
fi

INPUT_FILE=$(mktemp /tmp/dev-diary-input-XXXXXX)
FACTS_FILE=$(mktemp /tmp/dev-diary-facts-XXXXXX)
PLAN_FILE=$(mktemp /tmp/dev-diary-plan-XXXXXX)
LLM_FILE=$(mktemp /tmp/dev-diary-llm-XXXXXX)

cleanup() {
    rmdir "$GLOBAL_LOCK" 2>/dev/null
    rm -f "$INPUT_FILE" "$FACTS_FILE" "$PLAN_FILE" "$LLM_FILE" 2>/dev/null
}
trap cleanup EXIT

# Capture stdin (hook input JSON)
cat > "$INPUT_FILE"

# Extract transcript path + cwd from the hook payload
# One value per line. The previous form printed both on one line and let `read`
# split on whitespace, which truncated any path containing a space -- the normal
# case on Windows, where home directories are "C:/Users/First Last".
{ read -r TRANSCRIPT_PATH; read -r CWD; } < <(INPUT_FILE="$INPUT_FILE" $PYTHON - << 'PYEOF'
import json, os
try:
    with open(os.environ['INPUT_FILE'], encoding='utf-8') as f:
        d = json.load(f)
    print(d.get('transcript_path', ''))
    print(d.get('cwd', ''))
except Exception:
    print('')
    print('')
PYEOF
)

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    exit 0
fi
[ -z "$CWD" ] && CWD="$PWD"

# 1. Mechanical extraction
$PYTHON "$SCRIPT_DIR/diary.py" facts "$TRANSCRIPT_PATH" "$CWD" > "$FACTS_FILE" 2>/dev/null || exit 0

# Paths arrive via argv, never interpolated into a Python string literal: a
# Windows path's backslashes would otherwise be read as escape sequences.
TOOL_COUNT=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8')).get('tool_count',0))" "$FACTS_FILE" 2>/dev/null)
if [ -z "$TOOL_COUNT" ] || [ "$TOOL_COUNT" -lt 2 ] 2>/dev/null; then
    exit 0
fi

# Bootstrap the diary on first real entry so a plugin install needs no setup
# step. Runs after the tool-count gate, so a skipped session leaves no trace.
mkdir -p "$DIARY_DIR" 2>/dev/null || exit 0
if [ ! -f "$DIARY_DIR/README.md" ]; then
    cat > "$DIARY_DIR/README.md" << 'BOOTSTRAP_README'
# Dev Diary

The factual record. One entry per Claude Code session that did real work: a
prose lead, the files changed, the commands run, decisions taken, and
follow-ups. Files changed and commands run are extracted mechanically from the
session transcript, so they are ground truth rather than recollection.

Written automatically by a Claude Code Stop hook.

---

## Entries

BOOTSTRAP_README
fi
if [ ! -d "$DIARY_DIR/.git" ]; then
    git -C "$DIARY_DIR" init -b main -q 2>/dev/null || git -C "$DIARY_DIR" init -q 2>/dev/null || true
fi

# 2. Plan: dedup against recent entries, decide full vs supplemental vs skip
$PYTHON "$SCRIPT_DIR/diary.py" plan "$FACTS_FILE" "$DIARY_DIR" > "$PLAN_FILE" 2>/dev/null || exit 0

ACTION=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8')).get('action',''))" "$PLAN_FILE" 2>/dev/null)
if [ "$ACTION" != "write" ]; then
    exit 0
fi

# 3. LLM writes only the interpretive parts, from a strict factual prompt
$PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['prompt'])" "$PLAN_FILE" > "$LLM_FILE" 2>/dev/null
ENTRY_LLM=$(claude -p < "$LLM_FILE" 2>/dev/null || echo "")

TODAY=$(date +%Y-%m-%d)
TIME_NOW=$(date +%H:%M)

# 4. Render: assemble entry with mechanical facts + LLM parts, append, update README
printf '%s' "$ENTRY_LLM" | $PYTHON "$SCRIPT_DIR/diary.py" render "$PLAN_FILE" "$DIARY_DIR" "$TIME_NOW" "$TODAY" || exit 0

# 5. Commit, and push only when a remote exists (a plugin-created diary has none)
cd "$DIARY_DIR" || exit 0
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "Dev Diary: $TODAY at $TIME_NOW" >/dev/null 2>&1
    if git remote get-url origin >/dev/null 2>&1; then
        git push origin main >/dev/null 2>&1 || true
    fi
fi
