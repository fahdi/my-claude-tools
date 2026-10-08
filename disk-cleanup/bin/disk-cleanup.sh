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
# The one exception is Xcode DerivedData, which has no prune command. It is a
# pure build cache that Xcode recreates, so idle entries are removed directly,
# and only from a directory that is actually named DerivedData.
#
# Nothing here touches user data. No Downloads, no Trash, no Documents, no
# source files, no Docker volumes. Large things that are not safe to prune
# automatically (local LLM models, IDE data, Docker's disk image) are reported
# instead, so a disk that is still nearly full after a run says where to look.

set -uo pipefail

LOG="${DISK_CLEANUP_LOG:-$HOME/Library/Logs/disk-cleanup.log}"
MAX_LOG_BYTES="${DISK_CLEANUP_MAX_LOG_BYTES:-5242880}"
MIN_FREE_GB="${DISK_CLEANUP_MIN_FREE_GB:-40}"
CRITICAL_FREE_GB="${DISK_CLEANUP_CRITICAL_FREE_GB:-15}"
VOLUME="${DISK_CLEANUP_VOLUME:-/System/Volumes/Data}"
NOTIFIER="${DISK_CLEANUP_NOTIFIER:-/usr/bin/osascript}"

# PATH is set before any tool is looked up. launchd starts the job with only
# /usr/bin:/bin:/usr/sbin:/sbin, so resolving first found nothing but xcrun and
# every other pruner logged "not installed": for two weeks the scheduled job ran
# while the disk filled to 172MB and reclaimed nothing.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
resolve() { command -v "$1" 2>/dev/null || true; }

# Injectable so the suite can run against fakes.
DF_BIN="${DISK_CLEANUP_DF:-df}"
UV_BIN="${DISK_CLEANUP_UV:-$(resolve uv)}"
PNPM_BIN="${DISK_CLEANUP_PNPM:-$(resolve pnpm)}"
NPM_BIN="${DISK_CLEANUP_NPM:-$(resolve npm)}"
BREW_BIN="${DISK_CLEANUP_BREW:-$(resolve brew)}"
XCRUN_BIN="${DISK_CLEANUP_XCRUN:-$(resolve xcrun)}"
CARGO_BIN="${DISK_CLEANUP_CARGO:-$(resolve cargo)}"
FLUTTER_BIN="${DISK_CLEANUP_FLUTTER:-$(resolve flutter)}"
DOCKER_BIN="${DISK_CLEANUP_DOCKER:-$(resolve docker)}"

# Build output is the target that is both enormous and invisible: a Rust
# service with 500KB of source routinely carries 25GB of target/, and one
# Flutter app with its worktrees carried 23GB of build/ and .dart_tool/. It is
# fully regenerable, but rebuilding is not free, so only build directories left
# untouched for this many days are cleaned. An active project is never disturbed.
# The same age applies to Rust, Flutter, Xcode DerivedData and Docker's build
# cache.
TARGET_MAX_AGE_DAYS="${DISK_CLEANUP_TARGET_MAX_AGE_DAYS:-30}"
read -r -a CARGO_ROOTS <<< "${DISK_CLEANUP_CARGO_ROOTS:-$HOME/Code $HOME/websites}"
CARGO_DEPTH="${DISK_CLEANUP_CARGO_DEPTH:-7}"
DERIVED_DATA="${DISK_CLEANUP_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"

# Reported when space is still critical after a run, never pruned. Colon
# separated, because several of these paths contain spaces. Each one held
# 20GB or more when the disk filled on 2026-10-08.
REPORT_PATHS="${DISK_CLEANUP_REPORT_PATHS:-$HOME/.ollama:$HOME/.cache:$HOME/.gemini:$HOME/Library/Containers/com.docker.docker:$HOME/Library/Developer/CoreSimulator/Devices:$HOME/Library/Android:$HOME/Downloads}"

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
  DISK_CLEANUP_CRITICAL_FREE_GB
                             Alert if still below this after a run (default 15).
  DISK_CLEANUP_VOLUME        Volume to measure (default /System/Volumes/Data).
  DISK_CLEANUP_NOTIFIER      osascript-compatible binary for alerts.
  DISK_CLEANUP_CARGO_ROOTS   Where to look for Rust and Flutter projects.
  DISK_CLEANUP_TARGET_MAX_AGE_DAYS
                             Only clean build output idle this long (default 30).
  DISK_CLEANUP_DERIVED_DATA  Xcode DerivedData directory.
  DISK_CLEANUP_REPORT_PATHS  Colon-separated paths to report, never prune.

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

# brew cleanup shells out to its own helpers, so its directory goes first.
BREW_DIR="$(dirname "${BREW_BIN:-/opt/homebrew/bin/brew}")"
export PATH="${BREW_DIR}:${PATH}"

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
    local title="${2:-Disk cleanup failed}"
    [ -x "$NOTIFIER" ] || return 0
    "$NOTIFIER" -e "display notification \"$1\" with title \"${title}\" sound name \"Basso\"" >/dev/null 2>&1 || true
}

# True when $1 names an executable, by path or on PATH.
have() {
    [ -n "$1" ] && { [ -x "$1" ] || command -v "$1" >/dev/null 2>&1; }
}

# Existing directories from CARGO_ROOTS, one per line.
source_roots() {
    local r
    for r in "${CARGO_ROOTS[@]}"; do
        [ -d "$r" ] && printf '%s\n' "$r"
    done
}

# True when directory $1 has been modified within the last TARGET_MAX_AGE_DAYS.
recently_touched() {
    [ -n "$(find "$1" -maxdepth 0 -mtime "-${TARGET_MAX_AGE_DAYS}" 2>/dev/null)" ]
}

# The largest REPORT_PATHS entries, biggest first, as "SIZE  PATH" lines.
largest_report_paths() {
    local p
    local IFS=:
    for p in $REPORT_PATHS; do
        [ -e "$p" ] && du -sk "$p" 2>/dev/null
    done | sort -rn | head -n 5 | awk -F'\t' '{ printf "%5dGB  %s\n", $1 / 1048576, $2 }'
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

# Prints the manifest path of every Rust project whose target/ has gone stale.
stale_cargo_manifests() {
    local roots=() r d manifest
    for r in "${CARGO_ROOTS[@]}"; do
        [ -d "$r" ] && roots+=("$r")
    done
    [ "${#roots[@]}" -eq 0 ] && return 0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        manifest="$(dirname "$d")/Cargo.toml"
        [ -f "$manifest" ] && printf '%s\n' "$manifest"
    done < <(find "${roots[@]}" -maxdepth "$CARGO_DEPTH" -type d -name target -prune -mtime "+${TARGET_MAX_AGE_DAYS}" 2>/dev/null)
}

# Cleans Rust build directories that nothing has touched recently. Uses cargo's
# own clean rather than rm -rf, so a directory that merely looks like a target/
# but has no manifest beside it is left alone.
prune_cargo_targets() {
    local label="cargo targets"
    if [ -z "$CARGO_BIN" ] || { [ ! -x "$CARGO_BIN" ] && ! command -v "$CARGO_BIN" >/dev/null 2>&1; }; then
        log "SKIP  ${label} (cargo not installed)"
        return 0
    fi

    local roots=()
    local r
    for r in "${CARGO_ROOTS[@]}"; do
        [ -d "$r" ] && roots+=("$r")
    done
    if [ "${#roots[@]}" -eq 0 ]; then
        log "SKIP  ${label} (no source roots present)"
        return 0
    fi

    local rc=0 found=0 manifest
    while IFS= read -r manifest; do
        [ -n "$manifest" ] || continue
        found=$(( found + 1 ))
        if [ "$DRY_RUN" -eq 1 ]; then
            log "WOULD ${label}: cargo clean --manifest-path ${manifest}"
            continue
        fi
        log "START ${label}: ${manifest}"
        if "$CARGO_BIN" clean --manifest-path "$manifest" >> "$LOG" 2>&1; then
            log "OK    ${label}: ${manifest}"
        else
            rc=1
            log "FAIL  ${label}: ${manifest}"
        fi
    done < <(stale_cargo_manifests)

    if [ "$found" -eq 0 ]; then
        log "OK    ${label} (nothing idle for ${TARGET_MAX_AGE_DAYS}+ days)"
    fi
    return "$rc"
}

# Prints every Flutter project whose build output has gone stale: a pubspec.yaml
# with build/ or .dart_tool/ beside it, and neither touched recently. Both are
# checked because flutter clean removes both, and a worktree often carries a
# 1GB .dart_tool/ next to a small build/.
stale_flutter_projects() {
    local roots=() r f p d present fresh
    while IFS= read -r r; do roots+=("$r"); done < <(source_roots)
    [ "${#roots[@]}" -eq 0 ] && return 0
    while IFS= read -r f; do
        p="$(dirname "$f")"
        present=0
        fresh=0
        for d in build .dart_tool; do
            [ -d "$p/$d" ] || continue
            present=1
            recently_touched "$p/$d" && fresh=1
        done
        [ "$present" -eq 1 ] && [ "$fresh" -eq 0 ] && printf '%s\n' "$p"
    done < <(find "${roots[@]}" -maxdepth "$CARGO_DEPTH" \
                \( -name node_modules -o -name .git -o -name build -o -name .dart_tool \
                   -o -name .symlinks -o -name .pub-cache -o -name Pods \) -prune \
                -o -type f -name pubspec.yaml -print 2>/dev/null)
}

# Cleans stale Flutter build output with flutter's own clean, from inside the
# project, so a directory with no pubspec.yaml is never touched.
prune_flutter_builds() {
    local label="flutter builds"
    if ! have "$FLUTTER_BIN"; then
        log "SKIP  ${label} (flutter not installed)"
        return 0
    fi
    if [ -z "$(source_roots)" ]; then
        log "SKIP  ${label} (no source roots present)"
        return 0
    fi

    local rc=0 found=0 project
    while IFS= read -r project; do
        [ -n "$project" ] || continue
        found=$(( found + 1 ))
        if [ "$DRY_RUN" -eq 1 ]; then
            log "WOULD ${label}: flutter clean in ${project}"
            continue
        fi
        log "START ${label}: ${project}"
        if (cd "$project" && "$FLUTTER_BIN" clean) >> "$LOG" 2>&1; then
            log "OK    ${label}: ${project}"
        else
            rc=1
            log "FAIL  ${label}: ${project}"
        fi
    done < <(stale_flutter_projects)

    if [ "$found" -eq 0 ]; then
        log "OK    ${label} (nothing idle for ${TARGET_MAX_AGE_DAYS}+ days)"
    fi
    return "$rc"
}

# Prints every DerivedData entry (one per Xcode project) left idle.
stale_derived_data() {
    [ -d "$DERIVED_DATA" ] || return 0
    find "$DERIVED_DATA" -mindepth 1 -maxdepth 1 -type d -mtime "+${TARGET_MAX_AGE_DAYS}" 2>/dev/null
}

# The single rm -rf in this script. Xcode has no prune command for DerivedData,
# and every entry is a build cache it recreates on the next build. The path
# must end in DerivedData, so a misconfigured variable cannot aim this anywhere
# else.
prune_derived_data() {
    local label="DerivedData"
    case "$DERIVED_DATA" in
        */DerivedData) ;;
        *) log "SKIP  ${label} (${DERIVED_DATA} is not a DerivedData directory)"; return 0 ;;
    esac
    if [ ! -d "$DERIVED_DATA" ]; then
        log "SKIP  ${label} (not present)"
        return 0
    fi

    local rc=0 found=0 entry
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        found=$(( found + 1 ))
        if [ "$DRY_RUN" -eq 1 ]; then
            log "WOULD ${label}: remove ${entry}"
            continue
        fi
        if rm -rf "$entry" >> "$LOG" 2>&1; then
            log "OK    ${label}: removed ${entry}"
        else
            rc=1
            log "FAIL  ${label}: ${entry}"
        fi
    done < <(stale_derived_data)

    if [ "$found" -eq 0 ]; then
        log "OK    ${label} (nothing idle for ${TARGET_MAX_AGE_DAYS}+ days)"
    fi
    return "$rc"
}

# Docker's build cache and dangling images, both through docker's own prune.
# Volumes and containers are never touched: they hold local databases. A daemon
# that is not running is skipped, since there is nothing to prune and Docker
# Desktop being closed is not a failure.
prune_docker() {
    if ! have "$DOCKER_BIN"; then
        log "SKIP  docker (not installed)"
        return 0
    fi
    if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
        log "SKIP  docker (daemon not running)"
        return 0
    fi
    local rc=0
    prune_step "docker build cache" "$DOCKER_BIN" builder prune -af --filter "until=$(( TARGET_MAX_AGE_DAYS * 24 ))h" || rc=1
    prune_step "docker images"      "$DOCKER_BIN" image prune -f || rc=1
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
    echo
    # Resolved as the scheduled job sees them. Run it under launchd's PATH
    # (make dry-run-launchd) to catch a tool the agent cannot find.
    echo "tools:"
    for t in uv:"$UV_BIN" pnpm:"$PNPM_BIN" npm:"$NPM_BIN" brew:"$BREW_BIN" xcrun:"$XCRUN_BIN" \
             cargo:"$CARGO_BIN" flutter:"$FLUTTER_BIN" docker:"$DOCKER_BIN"; do
        found_at="${t#*:}"
        printf '  %-8s %s\n' "${t%%:*}" "${found_at:-(not found)}"
    done
    echo
    if [ "$before" -ge "$MIN_FREE_GB" ] && [ "$FORCE" -eq 0 ]; then
        echo "would do nothing: above threshold"
    else
        echo "would prune: uv, pnpm, npm, brew, unavailable simulators, docker build cache and dangling images"
        echo
        echo "Rust target/ dirs idle ${TARGET_MAX_AGE_DAYS}+ days:"
        n=0
        while IFS= read -r m; do
            [ -n "$m" ] || continue
            n=$(( n + 1 ))
            printf '  %6s  %s\n' "$(du -sh "$(dirname "$m")/target" 2>/dev/null | cut -f1)" "$(dirname "$m")"
        done < <(stale_cargo_manifests)
        [ "$n" -eq 0 ] && echo "  (none)"
        echo
        echo "Flutter projects with build output idle ${TARGET_MAX_AGE_DAYS}+ days:"
        n=0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            n=$(( n + 1 ))
            printf '  %6s  %s\n' "$(du -shc "$p/build" "$p/.dart_tool" 2>/dev/null | tail -n 1 | cut -f1)" "$p"
        done < <(stale_flutter_projects)
        [ "$n" -eq 0 ] && echo "  (none)"
        echo
        echo "DerivedData entries idle ${TARGET_MAX_AGE_DAYS}+ days:"
        n=0
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            n=$(( n + 1 ))
            printf '  %6s  %s\n' "$(du -sh "$e" 2>/dev/null | cut -f1)" "$e"
        done < <(stale_derived_data)
        [ "$n" -eq 0 ] && echo "  (none)"
    fi
    echo
    echo "Largest paths that are reported, never pruned:"
    largest="$(largest_report_paths)"
    if [ -n "$largest" ]; then printf '%s\n' "$largest"; else echo "  (none present)"; fi
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
prune_cargo_targets                                                     || failed="${failed} cargo"
prune_flutter_builds                                                    || failed="${failed} flutter"
prune_derived_data                                                      || failed="${failed} deriveddata"
prune_docker                                                            || failed="${failed} docker"

after="$(free_gb)"
after="${after:-$before}"
reclaimed=$(( after - before ))
log "RESULT: ${before}GB -> ${after}GB free (${reclaimed}GB reclaimed)"

# A run that reclaims nothing on a nearly full disk must not be silent. On
# 2026-10-08 the job logged "2GB -> 2GB free" and exited 0, and nobody knew
# until the disk hit 172MB. What filled it (models, IDE data, Docker's disk
# image) is not safe to prune automatically, so say where to look instead.
if [ "$after" -lt "$CRITICAL_FREE_GB" ]; then
    log "LOW   only ${after}GB free after cleanup, below ${CRITICAL_FREE_GB}GB. Largest paths not pruned automatically:"
    largest="$(largest_report_paths)"
    while IFS= read -r line; do
        [ -n "$line" ] && log "LOW   ${line}"
    done <<< "$largest"
    top="$(printf '%s\n' "$largest" | head -n 1 | sed 's/^ *//')"
    notify "Only ${after}GB free after cleanup.${top:+ Largest: ${top}}" "Disk space still low"
fi

if [ -n "$failed" ]; then
    log "RESULT: failed steps:${failed}"
    notify "Failed:${failed}. See ${LOG}"
    exit 1
fi
exit 0
