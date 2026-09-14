#!/usr/bin/env bash
# brew-upgrade - unattended Homebrew maintenance for cron
#
# Runs: brew update, brew upgrade (formulae), brew cleanup.
#
# Casks are deliberately NOT upgraded. Upgrading a cask can force-quit a
# running GUI app, and some casks need a sudo password that cron cannot
# supply. Upgrade those by hand.
#
# Be aware: upgrading a formula that runs as a brew service (postgresql,
# php, mysql, mailpit) restarts that service. Schedule accordingly.
#
# Every knob is an environment variable so the test suite can point the
# script at a fake brew and a throwaway log.

set -uo pipefail

BREW_BIN="${BREW_UPGRADE_BREW:-$(command -v brew || echo /opt/homebrew/bin/brew)}"
LOG="${BREW_UPGRADE_LOG:-$HOME/Library/Logs/brew-upgrade.log}"
MAX_LOG_BYTES="${BREW_UPGRADE_MAX_LOG_BYTES:-5242880}"
NOTIFIER="${BREW_UPGRADE_NOTIFIER:-/usr/bin/osascript}"
DO_CLEANUP="${BREW_UPGRADE_CLEANUP:-1}"
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: brew-upgrade.sh [--dry-run] [--no-cleanup] [--help]

  --dry-run      Print the steps that would run, change nothing.
  --no-cleanup   Skip "brew cleanup".
  --help         This text.

Environment:
  BREW_UPGRADE_BREW           Path to the brew binary.
  BREW_UPGRADE_LOG            Log file (default ~/Library/Logs/brew-upgrade.log).
  BREW_UPGRADE_MAX_LOG_BYTES  Rotate the log past this size (default 5 MiB).
  BREW_UPGRADE_NOTIFIER       osascript-compatible binary for failure alerts.
  BREW_UPGRADE_CLEANUP        Set to 0 to skip cleanup.

Exit status is 0 when every step succeeded, 1 otherwise.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --no-cleanup) DO_CLEANUP=0 ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# cron hands over a near-empty PATH, so brew's own subprocesses (git, curl)
# need the standard directories put back.
BREW_DIR="$(dirname "$BREW_BIN")"
export PATH="${BREW_DIR}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_COLOR=

mkdir -p "$(dirname "$LOG")"

# Rotate before writing so one runaway run cannot grow the log without bound.
if [ -f "$LOG" ]; then
    size=$(wc -c < "$LOG" | tr -d ' ')
    if [ "${size:-0}" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG" "${LOG}.1"
    fi
fi

log() {
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG"
}

notify() {
    # Failure alerts only. osascript needs a logged-in GUI session; at the
    # login window the notification is dropped and the log is the only record.
    [ -x "$NOTIFIER" ] || return 0
    "$NOTIFIER" -e "display notification \"$1\" with title \"Homebrew upgrade failed\" sound name \"Basso\"" >/dev/null 2>&1 || true
}

run_step() {
    local label="$1"
    shift
    local rc=0
    log "START ${label}: $*"
    # Capture the status directly. Reading $? after an if/fi whose condition
    # failed yields 0, not the status of the command that failed.
    "$@" >> "$LOG" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "OK    ${label}"
    else
        log "FAIL  ${label} (exit ${rc})"
    fi
    return "$rc"
}

if [ "$DRY_RUN" -eq 1 ]; then
    echo "brew binary: $BREW_BIN"
    echo "log file:    $LOG"
    echo "would run:   $BREW_BIN update"
    echo "would run:   $BREW_BIN upgrade"
    [ "$DO_CLEANUP" = "1" ] && echo "would run:   $BREW_BIN cleanup --prune=all"
    exit 0
fi

if [ ! -x "$BREW_BIN" ]; then
    log "ABORT brew not executable at ${BREW_BIN}"
    notify "brew not found at ${BREW_BIN}"
    exit 1
fi

log "=============================================================="
log "brew maintenance run starting"

failed=""
run_step "brew update"  "$BREW_BIN" update  || failed="${failed} update"
run_step "brew upgrade" "$BREW_BIN" upgrade || failed="${failed} upgrade"
if [ "$DO_CLEANUP" = "1" ]; then
    run_step "brew cleanup" "$BREW_BIN" cleanup --prune=all || failed="${failed} cleanup"
fi

if [ -n "$failed" ]; then
    log "RESULT: failed steps:${failed}"
    notify "Failed:${failed}. See ${LOG}"
    exit 1
fi

log "RESULT: all steps succeeded"
exit 0
