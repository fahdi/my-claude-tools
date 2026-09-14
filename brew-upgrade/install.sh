#!/usr/bin/env bash
# brew-upgrade - Installer
# Makes this repo the source of truth for the nightly Homebrew cron job.
# The crontab entry points straight at bin/brew-upgrade.sh in this checkout,
# so a git pull updates the job with no reinstall.

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
SOURCE="$SCRIPT_DIR/bin/brew-upgrade.sh"
MARKER="# my-claude-tools:brew-upgrade"
SCHEDULE="${BREW_UPGRADE_SCHEDULE:-0 4 * * *}"
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) UNINSTALL=1 ;;
        --schedule)  shift; SCHEDULE="${1:?--schedule needs a cron expression}" ;;
        -h|--help)
            echo "Usage: ./install.sh [--schedule '0 4 * * *'] [--uninstall]"
            exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

# Read the current crontab, stripping any entry we previously installed.
# `crontab -l` exits non-zero when no crontab exists, which is not an error.
current="$(crontab -l 2>/dev/null || true)"
stripped="$(printf '%s\n' "$current" | grep -vF "$MARKER" || true)"

if [ "$UNINSTALL" -eq 1 ]; then
    if [ "$current" = "$stripped" ]; then
        warn "No brew-upgrade entry found in the crontab."
    else
        printf '%s\n' "$stripped" | grep -v '^$' | crontab -
        success "Removed the brew-upgrade crontab entry."
    fi
    info "The log at ~/Library/Logs/brew-upgrade.log was left in place."
    exit 0
fi

[ -f "$SOURCE" ] || die "Missing $SOURCE"
chmod +x "$SOURCE"

command -v brew >/dev/null 2>&1 || warn "brew is not on PATH right now; the job will abort and notify until it is."

{
    printf '%s\n' "$stripped" | grep -v '^$' || true
    printf '%s %s %s\n' "$SCHEDULE" "$SOURCE" "$MARKER"
} | crontab -

success "Installed: $SCHEDULE"
info "Script: $SOURCE"
info "Log:    \$HOME/Library/Logs/brew-upgrade.log"
echo
info "Verify with:  crontab -l | grep brew-upgrade"
info "Dry run with: $SOURCE --dry-run"
warn "Upgrading a formula that runs as a brew service (postgresql, php, mysql,"
warn "mailpit) restarts it. Check 'brew services list' and pick an hour you are"
warn "not working."
