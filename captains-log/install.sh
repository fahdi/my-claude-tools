#!/usr/bin/env bash
# Captain's Log — Installer
# Sets up the diary repo and wires the Stop hook into Claude Code.

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}!${NC} $*"; }
die()     { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ── Diary location ────────────────────────────────────────────────────────────

DIARY_DIR="${CAPTAINS_LOG_DIR:-$HOME/Code/captains-log}"

echo ""
echo "  Captain's Log — Installer"
echo "  ─────────────────────────"
echo ""
echo "  Diary will be created at: $DIARY_DIR"
echo "  (Set CAPTAINS_LOG_DIR to override)"
echo ""
read -r -p "  Continue? [Y/n] " confirm
confirm="${confirm:-Y}"
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# ── Diary repo setup ──────────────────────────────────────────────────────────

if [ ! -d "$DIARY_DIR" ]; then
    info "Creating diary directory at $DIARY_DIR"
    mkdir -p "$DIARY_DIR"
fi

# Copy hook script
mkdir -p "$DIARY_DIR/scripts"
cp "$SCRIPT_DIR/hooks/log-session.sh" "$DIARY_DIR/scripts/log-session.sh"
chmod +x "$DIARY_DIR/scripts/log-session.sh"
success "Hook script installed at $DIARY_DIR/scripts/log-session.sh"

# Initialize diary git repo if needed
if [ ! -d "$DIARY_DIR/.git" ]; then
    info "Initializing git repo in $DIARY_DIR"
    git -C "$DIARY_DIR" init -b main

    TODAY=$(date +%Y-%m-%d)
    STARDATE=$(python3 -c "
import datetime
now = datetime.date.today()
day = now.timetuple().tm_yday
print(f'{(now.year - 1966) * 1000 + day * 1000 / 366:.1f}')
")

    # README
    cat > "$DIARY_DIR/README.md" << README_EOF
# Captain's Log

> *"The human adventure is just beginning."*

A developer log narrated in the voice of Captain Jean-Luc Picard.
Every Claude Code session that completes meaningful work earns an entry.

Logged automatically via Claude Code Stop hook. Manual entries via \`/log\`.

---

## Entries

- [$TODAY]($TODAY.md) — Stardate $STARDATE: Log initialized
README_EOF

    # Inaugural entry
    cat > "$DIARY_DIR/$TODAY.md" << DAY_EOF
# Captain's Log — $TODAY

---

*Logged at $(date +%H:%M)*

Captain's Log, Stardate $STARDATE. The Captain's Log system has been commissioned. The automated logging apparatus is now wired into the fabric of our development environment. Each session that concludes meaningful work shall be recorded for posterity. We are ready to begin.

DAY_EOF

    git -C "$DIARY_DIR" add -A
    git -C "$DIARY_DIR" commit -m "Initialize Captain's Log"
    success "Git repo initialized with inaugural entry"

    # Optional: push to GitHub
    if command -v gh &>/dev/null; then
        echo ""
        read -r -p "  Create a private GitHub repo for your diary? [Y/n] " gh_confirm
        gh_confirm="${gh_confirm:-Y}"
        if [[ "$gh_confirm" =~ ^[Yy]$ ]]; then
            REPO_NAME=$(basename "$DIARY_DIR")
            gh repo create "$REPO_NAME" --private --source="$DIARY_DIR" --remote=origin --push \
                && success "Pushed to GitHub as private repo: $REPO_NAME" \
                || warn "GitHub push failed — you can push manually later"
        fi
    fi
else
    # Diary repo exists — just update the hook script
    success "Diary repo already exists at $DIARY_DIR"
fi

# ── /log command ──────────────────────────────────────────────────────────────

COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$COMMANDS_DIR"
cp "$SCRIPT_DIR/commands/log.md" "$COMMANDS_DIR/log.md"
success "/log command installed at $COMMANDS_DIR/log.md"

# ── Claude Code settings — add Stop hook ──────────────────────────────────────

if [ ! -f "$CLAUDE_SETTINGS" ]; then
    warn "No Claude Code settings found at $CLAUDE_SETTINGS"
    warn "Creating minimal settings.json with Stop hook"
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    cat > "$CLAUDE_SETTINGS" << SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$DIARY_DIR/scripts/log-session.sh\"",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
    success "Created $CLAUDE_SETTINGS with Stop hook"
else
    # Check if Stop hook is already configured
    if grep -q "captains-log\|log-session" "$CLAUDE_SETTINGS" 2>/dev/null; then
        warn "A Captain's Log hook already exists in settings.json — skipping (edit manually if needed)"
    else
        # Inject Stop hook using Python — safer than sed for JSON
        DIARY_DIR="$DIARY_DIR" CLAUDE_SETTINGS="$CLAUDE_SETTINGS" python3 - << 'PYEOF'
import json, os, sys

settings_path = os.environ['CLAUDE_SETTINGS']
diary_dir = os.environ['DIARY_DIR']
hook_path = os.path.join(diary_dir, 'scripts', 'log-session.sh')

with open(settings_path, 'r') as f:
    settings = json.load(f)

stop_hook = {
    "hooks": [
        {
            "type": "command",
            "command": f'bash "{hook_path}"',
            "timeout": 60
        }
    ]
}

hooks = settings.setdefault('hooks', {})
stop_hooks = hooks.setdefault('Stop', [])

# Check again in case multiple installers ran
already = any(
    any('log-session' in h.get('command', '') for h in entry.get('hooks', []))
    for entry in stop_hooks
)
if not already:
    stop_hooks.append(stop_hook)

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYEOF
        success "Stop hook added to $CLAUDE_SETTINGS"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "  ─────────────────────────────────────────────────────"
echo "  All done. The Captain's Log is operational."
echo ""
echo "  • Auto-logging fires when any Claude Code session exits"
echo "  • Type /log in any session for a manual entry"
echo "  • Diary lives at: $DIARY_DIR"
echo "  ─────────────────────────────────────────────────────"
echo ""
