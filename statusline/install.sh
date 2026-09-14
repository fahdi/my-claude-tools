#!/usr/bin/env bash
# statusline — Installer
# Makes this repo the source of truth for ~/.claude/statusline.sh and adds the
# tool-status segment to the bar.

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
SOURCE="$SCRIPT_DIR/bin/statusline.sh"
TARGET="$HOME/.claude/statusline.sh"

MODE="symlink"
ASSUME_YES=0
ACTION="install"
for arg in "$@"; do
    case "$arg" in
        --copy)      MODE="copy" ;;
        --uninstall) ACTION="uninstall" ;;
        --yes|-y)    ASSUME_YES=1 ;;
        --help|-h)
            echo "usage: install.sh [--copy] [--uninstall] [--yes]"
            echo "  --copy       copy the script instead of symlinking it"
            echo "  --uninstall  restore the most recent backup"
            exit 0 ;;
    esac
done

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "  $1 [Y/n] " reply
    [[ "${reply:-Y}" =~ ^[Yy]$ ]]
}

latest_backup() {
    ls -1t "$HOME/.claude/statusline.sh.bak-"* 2>/dev/null | head -1
}

# ── Uninstall ─────────────────────────────────────────────────────────────────

if [ "$ACTION" = "uninstall" ]; then
    backup="$(latest_backup || true)"
    [ -n "$backup" ] || die "No backup found at ~/.claude/statusline.sh.bak-*"
    info "Restoring $backup"
    rm -f "$TARGET"
    cp "$backup" "$TARGET"
    chmod +x "$TARGET"
    success "Restored. The tool-status segment is gone."
    exit 0
fi

# ── Preflight ─────────────────────────────────────────────────────────────────

[ -f "$SOURCE" ] || die "Missing $SOURCE"
command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

echo ""
echo "  statusline — Installer"
echo "  ──────────────────────"
echo ""
echo "  Source: $SOURCE"
echo "  Target: $TARGET ($MODE)"
echo ""

if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
    if ! diff -q "$SOURCE" "$TARGET" >/dev/null 2>&1; then
        warn "$TARGET differs from the repo copy ($(diff "$SOURCE" "$TARGET" | grep -c '^[<>]') changed lines)."
        warn "It will be backed up, not discarded."
    fi
fi

confirm "Continue?" || { echo "Aborted."; exit 0; }
echo ""

# ── Back up and link ──────────────────────────────────────────────────────────

mkdir -p "$HOME/.claude"

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    backup="$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
    cp -L "$TARGET" "$backup" 2>/dev/null || cp "$TARGET" "$backup"
    success "Backed up current statusline to $backup"
    rm -f "$TARGET"
fi

if [ "$MODE" = "symlink" ]; then
    ln -s "$SOURCE" "$TARGET"
    success "Linked $TARGET → $SOURCE"
else
    cp "$SOURCE" "$TARGET"
    chmod +x "$TARGET"
    success "Copied statusline to $TARGET"
fi

chmod +x "$SCRIPT_DIR/bin/tool-status.sh"

# ── Verify each profile points at it ──────────────────────────────────────────

echo ""
for profile in "$HOME/.claude" "$HOME"/.claude-*; do
    settings="$profile/settings.json"
    [ -f "$settings" ] || continue
    cmd=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null)
    if [ -z "$cmd" ]; then
        warn "$(basename "$profile"): no statusLine configured. Add:"
        echo '      "statusLine": { "type": "command", "command": "bash \"$HOME/.claude/statusline.sh\"" }'
    elif [[ "$cmd" == *".claude/statusline.sh"* ]]; then
        success "$(basename "$profile"): statusLine already points here"
    else
        warn "$(basename "$profile"): statusLine runs something else → $cmd"
    fi
done

# ── Smoke test ────────────────────────────────────────────────────────────────

echo ""
info "Smoke test"
echo ""
printf '%s' '{"model":{"display_name":"Opus 5"},"cwd":"'"$PWD"'","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":12000}}}' \
    | bash "$TARGET" || die "Statusline failed to render"
echo ""
echo ""
success "Installed. Start a new Claude Code session to see it."
echo ""
echo "  Full inventory with paths:  $SCRIPT_DIR/bin/tool-status.sh --full"
echo "  Add or edit probes:         $SCRIPT_DIR/config/tools.conf"
echo ""
