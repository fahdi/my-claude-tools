#!/usr/bin/env bash
# disk-cleanup - Installer
# Makes this repo the source of truth for the disk cleanup job. The agent points
# at bin/disk-cleanup.sh in this checkout, so a git pull updates it.
#
# launchd rather than cron: cron skips a job whose fire time passed while the
# machine was asleep and never catches up, so a laptop that sleeps would miss
# most of a two-hourly schedule. launchd runs a missed StartCalendarInterval job
# once on the next wake.

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}!${NC} $*"; }
die()     { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/bin/disk-cleanup.sh"

LABEL="${DISK_CLEANUP_LABEL:-com.my-claude-tools.disk-cleanup}"
AGENT_DIR="${DISK_CLEANUP_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${DISK_CLEANUP_LAUNCHCTL:-/bin/launchctl}"
PLIST="$AGENT_DIR/${LABEL}.plist"

EVERY_HOURS="${DISK_CLEANUP_EVERY_HOURS:-2}"
MIN_FREE_GB="${DISK_CLEANUP_MIN_FREE_GB:-40}"
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) UNINSTALL=1 ;;
        --every)     shift; EVERY_HOURS="${1:?--every needs a number of hours}" ;;
        --min-free)  shift; MIN_FREE_GB="${1:?--min-free needs a number of GB}" ;;
        -h|--help)
            cat <<'USAGE'
Usage: ./install.sh [--every HOURS] [--min-free GB] [--uninstall]

  --every HOURS   How often to check, in hours (default 2). Must divide 24.
  --min-free GB   Only prune when free space is below this (default 40).
  --uninstall     Remove the agent.
USAGE
            exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

remove_agent() {
    [ -f "$PLIST" ] || return 1
    "$LAUNCHCTL" bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 \
        || "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    return 0
}

if [ "$UNINSTALL" -eq 1 ]; then
    if remove_agent; then
        success "Removed the disk-cleanup agent ($LABEL)."
    else
        warn "Nothing installed: no disk-cleanup agent found."
    fi
    info "The log at \$HOME/Library/Logs/disk-cleanup.log was left in place."
    exit 0
fi

[ -f "$SOURCE" ] || die "Missing $SOURCE"
chmod +x "$SOURCE"

case "$EVERY_HOURS" in
    ''|*[!0-9]*) die "--every expects a whole number of hours, got '$EVERY_HOURS'" ;;
esac
[ "$EVERY_HOURS" -ge 1 ] && [ "$EVERY_HOURS" -le 24 ] || die "--every must be between 1 and 24"
[ $(( 24 % EVERY_HOURS )) -eq 0 ] || die "--every must divide 24 evenly, so the schedule does not jump at midnight"
case "$MIN_FREE_GB" in
    ''|*[!0-9]*) die "--min-free expects a whole number of GB, got '$MIN_FREE_GB'" ;;
esac

# StartCalendarInterval with one entry per hour, rather than StartInterval,
# so runs land on the clock and the log is readable. launchd coalesces the
# missed entries into a single run on wake.
entries=""
h=0
while [ "$h" -lt 24 ]; do
    entries="${entries}        <dict><key>Hour</key><integer>${h}</integer><key>Minute</key><integer>0</integer></dict>
"
    h=$(( h + EVERY_HOURS ))
done

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
    <key>EnvironmentVariables</key>
    <dict>
        <key>DISK_CLEANUP_MIN_FREE_GB</key>
        <string>${MIN_FREE_GB}</string>
    </dict>
    <key>StartCalendarInterval</key>
    <array>
${entries}    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/disk-cleanup.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/disk-cleanup.launchd.log</string>
</dict>
</plist>
PLISTEOF

"$LAUNCHCTL" bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
"$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
    || "$LAUNCHCTL" load "$PLIST" >/dev/null 2>&1 \
    || die "launchctl could not load $PLIST"

success "Installed launchd agent: every ${EVERY_HOURS}h, on the hour"
info "Prunes only when free space is below ${MIN_FREE_GB}GB"
info "Label: $LABEL"
info "Plist: $PLIST"
info "Script: $SOURCE"
info "Log:    \$HOME/Library/Logs/disk-cleanup.log"
echo
info "It prunes uv, pnpm, npm, brew and unavailable simulators, each with that"
info "tool's own prune command. It never touches Downloads, Trash or projects."
