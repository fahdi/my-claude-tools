#!/usr/bin/env bash
# disk-cleanup - reclaim disk space, but only when it is actually scarce.
#
# Runs every two hours and does nothing at all unless free space has dropped
# below a threshold. That guard is the whole design: these caches exist because
# re-downloading their contents is slow, so pruning them on a healthy disk costs
# bandwidth and build time and buys nothing.
#
# Every target is pruned with its own tool's prune command, never with rm -rf.
# The distinction matters: ~/Library/pnpm/store is a content-addressable store
# that every project's node_modules hard-links into, and ~/.cache/uv works the
# same way, so deleting either directory outright breaks existing checkouts
# rather than freeing space safely. "prune" removes only unreferenced entries.
#
# Nothing here touches user data. No Downloads, no Trash, no Documents, no
# project directories.

set -uo pipefail

LOG="${DISK_CLEANUP_LOG:-$HOME/Library/Logs/disk-cleanup.log}"
MAX_LOG_BYTES="${DISK_CLEANUP_MAX_LOG_BYTES:-5242880}"
MIN_FREE_GB="${DISK_CLEANUP_MIN_FREE_GB:-40}"
VOLUME="${DISK_CLEANUP_VOLUME:-/System/Volumes/Data}"
NOTIFIER="${DISK_CLEANUP_NOTIFIER:-/usr/bin/osascript}"

# Injectable so the suite can run against fakes.
DF_BIN="${DISK_CLEANUP_DF:-df}"
UV_BIN="${DISK_CLEANUP_UV:-$(command -v uv || true)}"
PNPM_BIN="${DISK_CLEANUP_PNPM:-$(command -v pnpm || true)}"
NPM_BIN="${DISK_CLEANUP_NPM:-$(command -v npm || true)}"
BREW_BIN="${DISK_CLEANUP_BREW:-$(command -v brew || true)}"
XCRUN_BIN="${DISK_CLEANUP_XCRUN:-$(command -v xcrun || true)}"

DRY_RUN=0
FORCE=0

usage() {
    cat <<'USAGE'
Usage: disk-cleanup.sh [--dry-run] [--force] [--min-free GB] [--help]

  --dry-run       Report what would run and change nothing.
  --force         Prune even when free space is above the threshold.
  --min-free GB   Threshold in gigabytes (default 40).
  --help          This text.

Environment:
  DISK_CLEANUP_LOG           Log file (default ~/Library/Logs/disk-cleanup.log).
  DISK_CLEANUP_MIN_FREE_GB   Threshold in GB.
  DISK_CLEANUP_VOLUME        Volume to measure (default /System/Volumes/Data).
  DISK_CLEANUP_NOTIFIER      osascript-compatible binary for failure alerts.

Exit status is 0 when every attempted step succeeded, 1 otherwise.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --force)    FORCE=1 ;;
        --min-free) shift; MIN_FREE_GB="${1:?--min-free needs a number}" ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

case "$MIN_FREE_GB" in
    ''|*[!0-9]*) echo "--min-free expects a whole number of GB, got '$MIN_FREE_GB'" >&2; exit 2 ;;
esac

BREW_DIR="$(dirname "${BREW_BIN:-/opt/homebrew/bin/brew}")"
export PATH="${BREW_DIR}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$(dirname "$LOG")"
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
    [ -x "$NOTIFIER" ] || return 0
    "$NOTIFIER" -e "display notification \"$1\" with title \"Disk cleanup failed\" sound name \"Basso\"" >/dev/null 2>&1 || true
}

# Free gigabytes on the measured volume. `df -k` reports 1024-byte blocks in
# column 4; dividing by 1048576 gives whole GB.
free_gb() {
    "$DF_BIN" -k "$VOLUME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}'
}

# Runs one pruner. A target whose tool is not installed is skipped, not failed:
# not every machine has uv or Xcode.
prune_step() {
    local label="$1" bin="$2"
    shift 2
    if [ -z "$bin" ] || { [ ! -x "$bin" ] && ! command -v "$bin" >/dev/null 2>&1; }; then
        log "SKIP  ${label} (not installed)"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "WOULD ${label}: $bin $*"
        return 0
    fi
    local rc=0
    log "START ${label}: $bin $*"
    "$bin" "$@" >> "$LOG" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "OK    ${label}"
    else
        log "FAIL  ${label} (exit ${rc})"
    fi
    return "$rc"
}

before="$(free_gb)"
if [ -z "$before" ]; then
    log "ABORT could not read free space on ${VOLUME}"
    notify "could not read free space on ${VOLUME}"
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "volume:    $VOLUME"
    echo "free:      ${before}GB"
    echo "threshold: ${MIN_FREE_GB}GB"
    if [ "$before" -ge "$MIN_FREE_GB" ] && [ "$FORCE" -eq 0 ]; then
        echo "would do nothing: above threshold"
    else
        echo "would prune: uv, pnpm, npm, brew, unavailable simulators"
    fi
    exit 0
fi

# The common case: enough space, so leave the caches alone. Logged anyway, so a
# quiet log is evidence the job is running rather than evidence it is broken.
if [ "$before" -ge "$MIN_FREE_GB" ] && [ "$FORCE" -eq 0 ]; then
    log "OK    ${before}GB free on ${VOLUME}, threshold ${MIN_FREE_GB}GB, nothing to do"
    exit 0
fi

log "=============================================================="
if [ "$FORCE" -eq 1 ]; then
    log "cleanup starting (forced), ${before}GB free on ${VOLUME}"
else
    log "cleanup starting, ${before}GB free is below the ${MIN_FREE_GB}GB threshold"
fi

failed=""
prune_step "uv cache"       "$UV_BIN"    cache prune                  || failed="${failed} uv"
prune_step "pnpm store"     "$PNPM_BIN"  store prune                  || failed="${failed} pnpm"
prune_step "npm cache"      "$NPM_BIN"   cache clean --force          || failed="${failed} npm"
prune_step "brew cleanup"   "$BREW_BIN"  cleanup --prune=all          || failed="${failed} brew"
prune_step "stale sims"     "$XCRUN_BIN" simctl delete unavailable    || failed="${failed} simulators"

after="$(free_gb)"
reclaimed=$(( after - before ))
log "RESULT: ${before}GB -> ${after}GB free (${reclaimed}GB reclaimed)"

if [ -n "$failed" ]; then
    log "RESULT: failed steps:${failed}"
    notify "Failed:${failed}. See ${LOG}"
    exit 1
fi
exit 0
