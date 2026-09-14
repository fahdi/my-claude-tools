#!/usr/bin/env bash
# brew-upgrade - Installer
# Makes this repo the source of truth for the nightly Homebrew job. The job
# points straight at bin/brew-upgrade.sh in this checkout, so a git pull
# updates it with no reinstall.
#
# launchd is the default and the right choice on a laptop: cron silently skips
# a job whose fire time passed while the machine was asleep and never catches
# up, so a 04:00 cron entry never runs on a Mac that sleeps overnight. launchd
# runs a missed StartCalendarInterval job once on the next wake.
#
# --cron is kept for machines that are always awake, or where you would rather
# keep every scheduled job in one crontab.

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

LABEL="${BREW_UPGRADE_LABEL:-com.my-claude-tools.brew-upgrade}"
AGENT_DIR="${BREW_UPGRADE_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${BREW_UPGRADE_LAUNCHCTL:-/bin/launchctl}"
CRONTAB="${BREW_UPGRADE_CRONTAB:-crontab}"
PLIST="$AGENT_DIR/${LABEL}.plist"

MARKER="# my-claude-tools:brew-upgrade"
CRON_SCHEDULE="${BREW_UPGRADE_SCHEDULE:-0 4 * * *}"
AT="${BREW_UPGRADE_AT:-04:00}"

MODE="launchd"
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --cron)      MODE="cron" ;;
        --launchd)   MODE="launchd" ;;
        --uninstall) UNINSTALL=1 ;;
        --at)        shift; AT="${1:?--at needs HH:MM}" ;;
        --schedule)  shift; CRON_SCHEDULE="${1:?--schedule needs a cron expression}"; MODE="cron" ;;
        -h|--help)
            cat <<'USAGE'
Usage: ./install.sh [--at HH:MM] [--cron [--schedule '0 4 * * *']] [--uninstall]

  --at HH:MM    Time of day for the launchd agent (default 04:00).
  --cron        Install a crontab entry instead of a launchd agent.
  --schedule    Cron expression, implies --cron.
  --uninstall   Remove whichever of the two is installed (both are checked).
USAGE
            exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

# Reads the crontab, dropping any entry we installed previously.
# `crontab -l` exits non-zero when no crontab exists, which is not an error.
strip_cron_entry() {
    "$CRONTAB" -l 2>/dev/null | grep -vF "$MARKER" || true
}

remove_cron() {
    local current stripped
    current="$("$CRONTAB" -l 2>/dev/null || true)"
    stripped="$(strip_cron_entry)"
    [ "$current" = "$stripped" ] && return 1
    printf '%s\n' "$stripped" | grep -v '^$' | "$CRONTAB" - || "$CRONTAB" -r 2>/dev/null || true
    return 0
}

remove_launchd() {
    [ -f "$PLIST" ] || return 1
    "$LAUNCHCTL" bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 \
        || "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    return 0
}

if [ "$UNINSTALL" -eq 1 ]; then
    removed=0
    remove_launchd && { success "Removed the launchd agent ($LABEL)."; removed=1; }
    remove_cron    && { success "Removed the brew-upgrade crontab entry.";   removed=1; }
    [ "$removed" -eq 0 ] && warn "Nothing installed: no launchd agent and no crontab entry."
    info "The log at \$HOME/Library/Logs/brew-upgrade.log was left in place."
    exit 0
fi

[ -f "$SOURCE" ] || die "Missing $SOURCE"
chmod +x "$SOURCE"
command -v brew >/dev/null 2>&1 || warn "brew is not on PATH right now; the job will abort and notify until it is."

if [ "$MODE" = "cron" ]; then
    {
        strip_cron_entry | grep -v '^$' || true
        printf '%s %s %s\n' "$CRON_SCHEDULE" "$SOURCE" "$MARKER"
    } | "$CRONTAB" -
    remove_launchd && info "Removed the launchd agent, since you asked for cron."
    success "Installed crontab entry: $CRON_SCHEDULE"
    warn "cron does not run a job whose time passed while the Mac was asleep."
else
    case "$AT" in
        [0-9][0-9]:[0-9][0-9]) ;;
        *) die "--at expects HH:MM, got '$AT'" ;;
    esac
    hour=$((10#${AT%%:*}))
    minute=$((10#${AT##*:}))
    [ "$hour" -le 23 ] || die "hour out of range in '$AT'"
    [ "$minute" -le 59 ] || die "minute out of range in '$AT'"

    mkdir -p "$AGENT_DIR"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SOURCE}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${hour}</integer>
        <key>Minute</key>
        <integer>${minute}</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/brew-upgrade.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/brew-upgrade.launchd.log</string>
</dict>
</plist>
PLISTEOF

    # bootout first so a reinstall picks up an edited plist. It fails when
    # nothing is loaded, which is the normal first-install case.
    "$LAUNCHCTL" bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
    "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
        || "$LAUNCHCTL" load "$PLIST" >/dev/null 2>&1 \
        || die "launchctl could not load $PLIST"

    remove_cron && info "Removed the old crontab entry; launchd owns this job now."
    success "Installed launchd agent: daily at ${AT}"
    info "Label: $LABEL"
    info "Plist: $PLIST"
fi

info "Script: $SOURCE"
info "Log:    \$HOME/Library/Logs/brew-upgrade.log"
echo
warn "Upgrading a formula that runs as a brew service (postgresql, php, mysql,"
warn "mailpit) restarts it. Check 'brew services list' and pick an hour you are"
warn "not working."
