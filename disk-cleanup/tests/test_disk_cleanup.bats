#!/usr/bin/env bats
# disk-cleanup - behaviour tests
#
# Free space is supplied by a fake df, and every pruner is a fake that records
# its arguments, so nothing here reads the real disk or deletes anything.

setup() {
    TOOL="$BATS_TEST_DIRNAME/../bin/disk-cleanup.sh"
    TMP="$BATS_TEST_TMPDIR/$BATS_TEST_NAME"
    mkdir -p "$TMP"
    export HOME="$TMP/home"; mkdir -p "$HOME"

    export DISK_CLEANUP_LOG="$TMP/cleanup.log"
    export DISK_CLEANUP_NOTIFIER="$TMP/notifier"
    export DISK_CLEANUP_DF="$TMP/df"
    export DISK_CLEANUP_VOLUME="/fake/volume"
    export DISK_CLEANUP_MIN_FREE_GB=40

    CALLS="$TMP/calls"
    FREEFILE="$TMP/free_gb"; echo 100 > "$FREEFILE"

    # df -k prints a header then a row; column 4 is available 1K blocks.
    cat > "$DISK_CLEANUP_DF" <<EOS
#!/usr/bin/env bash
gb=\$(cat "$FREEFILE")
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "fake 100 100 \$(( gb * 1048576 )) 50% /fake/volume"
EOS
    chmod +x "$DISK_CLEANUP_DF"

    cat > "$DISK_CLEANUP_NOTIFIER" <<EOS
#!/usr/bin/env bash
echo "\$@" >> "$TMP/notify.calls"
EOS
    chmod +x "$DISK_CLEANUP_NOTIFIER"

    for t in uv pnpm npm brew xcrun; do
        cat > "$TMP/$t" <<EOS
#!/usr/bin/env bash
echo "$t \$@" >> "$CALLS"
exit 0
EOS
        chmod +x "$TMP/$t"
    done
    cat > "$TMP/cargo" <<EOS
#!/usr/bin/env bash
echo "cargo \$@" >> "$CALLS"
exit 0
EOS
    chmod +x "$TMP/cargo"

    # flutter clean runs from inside the project, so the fake records where.
    cat > "$TMP/flutter" <<EOS
#!/usr/bin/env bash
echo "flutter \$@ in \$PWD" >> "$CALLS"
exit 0
EOS
    chmod +x "$TMP/flutter"

    # Every tool must be a fake. A real docker here would prune this machine.
    DOCKER_INFO_EXIT=0
    write_fake_docker

    export DISK_CLEANUP_UV="$TMP/uv" DISK_CLEANUP_PNPM="$TMP/pnpm" \
           DISK_CLEANUP_NPM="$TMP/npm" DISK_CLEANUP_BREW="$TMP/brew" \
           DISK_CLEANUP_XCRUN="$TMP/xcrun" DISK_CLEANUP_CARGO="$TMP/cargo" \
           DISK_CLEANUP_FLUTTER="$TMP/flutter" DISK_CLEANUP_DOCKER="$TMP/docker"

    ROOT="$TMP/src"
    mkdir -p "$ROOT"
    export DISK_CLEANUP_CARGO_ROOTS="$ROOT"

    DERIVED="$TMP/Xcode/DerivedData"
    mkdir -p "$DERIVED"
    export DISK_CLEANUP_DERIVED_DATA="$DERIVED"

    REPORTED="$TMP/reported"
    mkdir -p "$REPORTED/models" "$REPORTED/ide data"
    export DISK_CLEANUP_REPORT_PATHS="$REPORTED/models:$REPORTED/ide data:$REPORTED/absent"

    # Below this after a run, the job alerts. Low enough here that the pruning
    # tests below (10GB free) do not also trip it; the alert has its own tests.
    export DISK_CLEANUP_CRITICAL_FREE_GB=5

    # Never the real wpmcp checkout: a fake one, absent unless a test builds it.
    export DISK_CLEANUP_WPMCP_REPO="$TMP/wpmcp"
    WPCACHE="$HOME/.cache/wpmcp-tests"
    # No pnpm fallbacks unless a test supplies them, so the real pnpm on this
    # machine can never be picked up.
    export DISK_CLEANUP_PNPM_FALLBACKS=""
    # Never the real registered pruners on this machine.
    export DISK_CLEANUP_PRUNERS_FILE="$TMP/pruners"
    # The process list the npx step checks for running servers.
    PSOUT="$TMP/ps.out"; : > "$PSOUT"
    cat > "$TMP/ps" <<EOS
#!/usr/bin/env bash
cat "$PSOUT"
EOS
    chmod +x "$TMP/ps"
    export DISK_CLEANUP_PS="$TMP/ps"
}

# A docker whose daemon is up unless DOCKER_INFO_EXIT says otherwise.
write_fake_docker() {
    cat > "$TMP/docker" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "info" ]; then exit $DOCKER_INFO_EXIT; fi
echo "docker \$@" >> "$CALLS"
exit 0
EOS
    chmod +x "$TMP/docker"
}

# Builds a Flutter project at $1. $2 and $3 are the ages ("old"|"new"|"none")
# of its build/ and .dart_tool/.
make_flutter_project() {
    local name="$1" build="$2" tool="$3" d age
    mkdir -p "$ROOT/$name"
    touch "$ROOT/$name/pubspec.yaml"
    for d in build .dart_tool; do
        if [ "$d" = build ]; then age="$build"; else age="$tool"; fi
        [ "$age" = none ] && continue
        mkdir -p "$ROOT/$name/$d"
        if [ "$age" = old ]; then touch -t 202001010000 "$ROOT/$name/$d"; fi
    done
}

# Builds a Rust project at $1 whose target/ was last touched $2 ("old"|"new").
make_rust_project() {
    local name="$1" age="$2"
    mkdir -p "$ROOT/$name/target"
    touch "$ROOT/$name/Cargo.toml"
    if [ "$age" = "old" ]; then
        touch -t 202001010000 "$ROOT/$name/target"
    else
        touch "$ROOT/$name/target"
    fi
}

set_free()      { echo "$1" > "$FREEFILE"; }
calls()         { cat "$CALLS" 2>/dev/null || true; }
notifications() { cat "$TMP/notify.calls" 2>/dev/null || true; }
# A plain `! grep` cannot fail a bats test, so negative log checks go here.
not_logged()    { if grep -q "$1" "$DISK_CLEANUP_LOG"; then echo "unexpectedly logged: $1" >&2; return 1; fi; }
fail_tool() {
    cat > "$TMP/$1" <<EOS
#!/usr/bin/env bash
echo "$1 \$@" >> "$CALLS"
exit 3
EOS
    chmod +x "$TMP/$1"
}

@test "above the threshold it does nothing at all" {
    set_free 100
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
    grep -q "nothing to do" "$DISK_CLEANUP_LOG"
}

@test "a no-op run still logs, so a quiet log means healthy not broken" {
    set_free 100
    run "$TOOL"
    grep -q "100GB free" "$DISK_CLEANUP_LOG"
}

@test "below the threshold it prunes every target" {
    set_free 10
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"uv cache prune"* ]] || false
    [[ "$(calls)" == *"pnpm store prune"* ]] || false
    [[ "$(calls)" == *"npm cache clean --force"* ]] || false
    [[ "$(calls)" == *"brew cleanup --prune=all"* ]] || false
    [[ "$(calls)" == *"xcrun simctl delete unavailable"* ]] || false
}

@test "exactly at the threshold it does not prune" {
    set_free 40
    run "$TOOL"
    [ -z "$(calls)" ]
}

@test "one below the threshold it does prune" {
    set_free 39
    run "$TOOL"
    [ -n "$(calls)" ]
}

@test "it never deletes a store outright, only prunes" {
    set_free 10
    run "$TOOL"
    [[ "$(calls)" != *"rm "* ]] || false
    [[ "$(calls)" != *"cache clean"* ]] || [[ "$(calls)" == *"npm cache clean --force"* ]] || false
    # pnpm and uv must be reached through prune, never a destructive verb.
    [[ "$(calls)" == *"pnpm store prune"* ]] || false
    [[ "$(calls)" != *"pnpm store path"* ]] || false
}

@test "--force prunes even with plenty of space" {
    set_free 500
    run "$TOOL" --force
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"uv cache prune"* ]] || false
    grep -q "forced" "$DISK_CLEANUP_LOG"
}

@test "--min-free overrides the threshold" {
    set_free 100
    run "$TOOL" --min-free 200
    [ -n "$(calls)" ]
}

@test "--min-free rejects nonsense" {
    run "$TOOL" --min-free lots
    [ "$status" -eq 2 ]
    [ -z "$(calls)" ]
}

@test "a missing tool is skipped, not failed" {
    set_free 10
    export DISK_CLEANUP_UV="$TMP/does-not-exist"
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "SKIP  uv cache" "$DISK_CLEANUP_LOG"
    [[ "$(calls)" == *"pnpm store prune"* ]] || false
}

@test "a failing pruner gives exit 1 and notifies" {
    set_free 10
    fail_tool brew
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "FAIL  brew cleanup (exit 3)" "$DISK_CLEANUP_LOG"
    [[ "$(notifications)" == *"Failed: brew"* ]] || false
}

@test "a failing pruner does not stop the others" {
    set_free 10
    fail_tool uv
    run "$TOOL"
    [[ "$(calls)" == *"brew cleanup --prune=all"* ]] || false
    [[ "$(calls)" == *"xcrun simctl delete unavailable"* ]] || false
}

# Long-running uvx processes (MCP servers) hold the uv cache lock for days, so
# a locked cache is the normal state, not a failure.
busy_uv() {
    cat > "$TMP/uv" <<EOS
#!/usr/bin/env bash
echo "uv \$@ UV_LOCK_TIMEOUT=\${UV_LOCK_TIMEOUT:-unset}" >> "$CALLS"
echo "Cache is currently in-use, waiting for other uv processes to finish" >&2
echo "error: Timeout (\${UV_LOCK_TIMEOUT}s) when waiting for lock on \\\`$HOME/.cache/uv\\\`" >&2
exit 2
EOS
    chmod +x "$TMP/uv"
}

@test "a uv cache locked by running processes is skipped as busy, not failed" {
    set_free 10
    busy_uv
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "BUSY  uv cache" "$DISK_CLEANUP_LOG"
    not_logged "FAIL  uv cache"
    [ -z "$(notifications)" ]
}

@test "uv waits only briefly for its cache lock" {
    set_free 10
    busy_uv
    run "$TOOL"
    [[ "$(calls)" == *"uv cache prune UV_LOCK_TIMEOUT=10"* ]] || false
}

@test "the uv lock wait is configurable" {
    set_free 10
    busy_uv
    DISK_CLEANUP_UV_LOCK_TIMEOUT=3 run "$TOOL"
    [[ "$(calls)" == *"UV_LOCK_TIMEOUT=3"* ]] || false
}

@test "a uv failure that is not a lock timeout still fails" {
    set_free 10
    fail_tool uv
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "FAIL  uv cache (exit 3)" "$DISK_CLEANUP_LOG"
}

@test "a successful run notifies nobody" {
    set_free 10
    run "$TOOL"
    [ -z "$(notifications)" ]
}

@test "it reports how much was reclaimed" {
    set_free 10
    # The fake npm bumps reported free space, standing in for a real reclaim.
    cat > "$TMP/npm" <<EOS
#!/usr/bin/env bash
echo "npm \$@" >> "$CALLS"
echo 55 > "$FREEFILE"
EOS
    chmod +x "$TMP/npm"
    run "$TOOL"
    grep -q "10GB -> 55GB free (45GB reclaimed)" "$DISK_CLEANUP_LOG"
}

@test "--dry-run touches nothing" {
    set_free 10
    run "$TOOL" --dry-run
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
    [[ "$output" == *"would prune"* ]] || false
}

@test "--dry-run says so when it would do nothing" {
    set_free 100
    run "$TOOL" --dry-run
    [[ "$output" == *"would do nothing"* ]] || false
}

@test "unreadable free space aborts instead of guessing" {
    cat > "$DISK_CLEANUP_DF" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
    chmod +x "$DISK_CLEANUP_DF"
    run "$TOOL"
    [ "$status" -eq 1 ]
    [ -z "$(calls)" ]
    grep -q "ABORT" "$DISK_CLEANUP_LOG"
}

@test "unknown options are rejected before anything runs" {
    run "$TOOL" --nuke-everything
    [ "$status" -eq 2 ]
    [ -z "$(calls)" ]
}

@test "the log rotates past its size limit" {
    set_free 100
    export DISK_CLEANUP_MAX_LOG_BYTES=100
    head -c 500 /dev/zero | tr '\0' 'x' > "$DISK_CLEANUP_LOG"
    run "$TOOL"
    [ -f "${DISK_CLEANUP_LOG}.1" ]
}

@test "cleans a Rust target that has gone stale" {
    set_free 10
    make_rust_project idle old
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"cargo clean --manifest-path $ROOT/idle/Cargo.toml"* ]] || false
}

@test "leaves an actively built target alone" {
    set_free 10
    make_rust_project active new
    run "$TOOL"
    [[ "$(calls)" != *"cargo clean"* ]] || false
    grep -q "nothing idle for 30+ days" "$DISK_CLEANUP_LOG"
}

@test "cleans only the stale project when both exist" {
    set_free 10
    make_rust_project idle old
    make_rust_project active new
    run "$TOOL"
    [[ "$(calls)" == *"$ROOT/idle/Cargo.toml"* ]] || false
    [[ "$(calls)" != *"$ROOT/active/Cargo.toml"* ]] || false
}

@test "a target directory with no Cargo.toml beside it is ignored" {
    set_free 10
    mkdir -p "$ROOT/not-rust/target"
    touch -t 202001010000 "$ROOT/not-rust/target"
    run "$TOOL"
    [[ "$(calls)" != *"not-rust"* ]] || false
}

@test "the age threshold is configurable in both directions" {
    set_free 10
    mkdir -p "$ROOT/fivedays/target"
    touch "$ROOT/fivedays/Cargo.toml"
    touch -t "$(date -v-5d '+%Y%m%d%H%M')" "$ROOT/fivedays/target"

    # A 5-day-old target is stale under a 3-day threshold.
    DISK_CLEANUP_TARGET_MAX_AGE_DAYS=3 run "$TOOL"
    [[ "$(calls)" == *"cargo clean --manifest-path $ROOT/fivedays/Cargo.toml"* ]] || false

    # ...and still fresh under a 10-day one.
    : > "$CALLS"
    DISK_CLEANUP_TARGET_MAX_AGE_DAYS=10 run "$TOOL"
    [[ "$(calls)" != *"cargo clean"* ]] || false
}

@test "missing cargo is skipped, not failed" {
    set_free 10
    make_rust_project idle old
    export DISK_CLEANUP_CARGO="$TMP/no-cargo-here"
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "SKIP  cargo targets (cargo not installed)" "$DISK_CLEANUP_LOG"
}

@test "a source root that does not exist is skipped" {
    set_free 10
    export DISK_CLEANUP_CARGO_ROOTS="$TMP/nowhere"
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "SKIP  cargo targets (no source roots present)" "$DISK_CLEANUP_LOG"
}

@test "a failing cargo clean is reported and notified" {
    set_free 10
    make_rust_project idle old
    cat > "$TMP/cargo" <<EOS
#!/usr/bin/env bash
echo "cargo \$@" >> "$CALLS"
exit 4
EOS
    chmod +x "$TMP/cargo"
    run "$TOOL"
    [ "$status" -eq 1 ]
    [[ "$(notifications)" == *"cargo"* ]] || false
}

@test "--dry-run does not clean a stale target" {
    set_free 10
    make_rust_project idle old
    run "$TOOL" --dry-run
    [ -z "$(calls)" ]
}

@test "cargo targets are untouched above the threshold" {
    set_free 100
    make_rust_project idle old
    run "$TOOL"
    [ -z "$(calls)" ]
}

# --- launchd environment ---------------------------------------------------

@test "finds tools under launchd's minimal PATH" {
    # The regression: launchd starts the job with /usr/bin:/bin:/usr/sbin:/sbin,
    # and tools were looked up before PATH was widened, so every pruner except
    # xcrun was skipped as "not installed".
    set_free 10
    mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin"
    cp "$TMP/uv" "$HOME/.local/bin/uv"
    cp "$TMP/cargo" "$HOME/.cargo/bin/cargo"
    make_rust_project idle old
    unset DISK_CLEANUP_UV DISK_CLEANUP_CARGO
    run env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"uv cache prune"* ]] || false
    [[ "$(calls)" == *"cargo clean --manifest-path $ROOT/idle/Cargo.toml"* ]] || false
    not_logged "SKIP  uv cache"
}

# --- Flutter ---------------------------------------------------------------

@test "cleans a Flutter project whose build output has gone stale" {
    set_free 10
    make_flutter_project app old old
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"flutter clean in $ROOT/app"* ]] || false
}

@test "leaves a Flutter project with a fresh build/ alone" {
    set_free 10
    make_flutter_project app new old
    run "$TOOL"
    [[ "$(calls)" != *"flutter clean"* ]] || false
}

@test "a fresh .dart_tool/ also keeps a Flutter project" {
    set_free 10
    make_flutter_project app old new
    run "$TOOL"
    [[ "$(calls)" != *"flutter clean"* ]] || false
}

@test "a stale .dart_tool/ alone is enough to clean" {
    set_free 10
    make_flutter_project worktree none old
    run "$TOOL"
    [[ "$(calls)" == *"flutter clean in $ROOT/worktree"* ]] || false
}

@test "a pubspec.yaml with no build output is ignored" {
    set_free 10
    make_flutter_project pristine none none
    run "$TOOL"
    [[ "$(calls)" != *"flutter clean"* ]] || false
    grep -q "OK    flutter builds (nothing idle" "$DISK_CLEANUP_LOG"
}

@test "a stale build/ with no pubspec.yaml beside it is ignored" {
    set_free 10
    mkdir -p "$ROOT/not-flutter/build"
    touch -t 202001010000 "$ROOT/not-flutter/build"
    run "$TOOL"
    [[ "$(calls)" != *"flutter clean"* ]] || false
}

@test "missing flutter is skipped, not failed" {
    set_free 10
    make_flutter_project app old old
    export DISK_CLEANUP_FLUTTER="$TMP/no-flutter-here"
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "SKIP  flutter builds (flutter not installed)" "$DISK_CLEANUP_LOG"
}

# --- Xcode DerivedData -----------------------------------------------------

@test "removes idle DerivedData entries and keeps fresh ones" {
    set_free 10
    mkdir -p "$DERIVED/Old-abc/Build" "$DERIVED/Fresh-def/Build"
    touch -t 202001010000 "$DERIVED/Old-abc"
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ ! -e "$DERIVED/Old-abc" ]
    [ -d "$DERIVED/Fresh-def" ]
    [ -d "$DERIVED" ]
}

@test "refuses a DerivedData path that is not named DerivedData" {
    set_free 10
    mkdir -p "$TMP/Precious/Old-abc"
    touch -t 202001010000 "$TMP/Precious/Old-abc"
    export DISK_CLEANUP_DERIVED_DATA="$TMP/Precious"
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ -d "$TMP/Precious/Old-abc" ]
    grep -q "is not a DerivedData directory" "$DISK_CLEANUP_LOG"
}

@test "--dry-run removes no DerivedData" {
    set_free 10
    mkdir -p "$DERIVED/Old-abc"
    touch -t 202001010000 "$DERIVED/Old-abc"
    run "$TOOL" --dry-run
    [ -d "$DERIVED/Old-abc" ]
    [[ "$output" == *"$DERIVED/Old-abc"* ]] || false
}

# --- Docker ----------------------------------------------------------------

@test "prunes docker build cache by age and dangling images only" {
    set_free 10
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"docker builder prune -af --filter until=720h"* ]] || false
    [[ "$(calls)" == *"docker image prune -f"* ]] || false
    # Volumes hold local databases; containers hold state. Never either.
    [[ "$(calls)" != *"volume"* ]] || false
    [[ "$(calls)" != *"system prune"* ]] || false
    [[ "$(calls)" != *"container prune"* ]] || false
    [[ "$(calls)" != *"image prune -a"* ]] || false
}

@test "a stopped docker daemon is skipped, not failed" {
    set_free 10
    DOCKER_INFO_EXIT=1
    write_fake_docker
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" != *"docker "* ]] || false
    grep -q "SKIP  docker (daemon not running)" "$DISK_CLEANUP_LOG"
}

# --- still low after a run -------------------------------------------------

@test "alerts when space is still critical after a run, naming the largest path" {
    set_free 10
    export DISK_CLEANUP_CRITICAL_FREE_GB=15
    head -c 2097152 /dev/zero > "$REPORTED/ide data/blob"
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "LOW   only 10GB free after cleanup" "$DISK_CLEANUP_LOG"
    grep -q "LOW .*$REPORTED/ide data" "$DISK_CLEANUP_LOG"
    [[ "$(notifications)" == *"Only 10GB free after cleanup"* ]] || false
    [[ "$(notifications)" == *"Disk space still low"* ]] || false
    [[ "$(notifications)" == *"Largest: "*"$REPORTED/ide data"* ]] || false
}

@test "reported paths are never pruned" {
    set_free 1
    export DISK_CLEANUP_CRITICAL_FREE_GB=15
    touch "$REPORTED/models/model.bin"
    run "$TOOL"
    [ -f "$REPORTED/models/model.bin" ]
}

@test "no low-space alert once a run has recovered enough" {
    set_free 10
    export DISK_CLEANUP_CRITICAL_FREE_GB=15
    cat > "$TMP/npm" <<EOS
#!/usr/bin/env bash
echo "npm \$@" >> "$CALLS"
echo 30 > "$FREEFILE"
EOS
    chmod +x "$TMP/npm"
    run "$TOOL"
    not_logged "LOW"
    [ -z "$(notifications)" ]
}

@test "--dry-run lists the largest reported paths" {
    set_free 100
    run "$TOOL" --dry-run
    [[ "$output" == *"Largest paths that are reported, never pruned:"* ]] || false
    [[ "$output" == *"$REPORTED/models"* ]] || false
}

# --- pnpm that cannot start ------------------------------------------------

# corepack 0.23 shimming pnpm 12 crashed before pnpm ran, on 2026-11-10:
# "Cannot find module ~/.cache/node/corepack/pnpm/12.10.1/bin/pnpm.cjs".
broken_pnpm() {
    cat > "$1" <<EOS
#!/usr/bin/env bash
echo "broken-pnpm \$@" >> "$CALLS"
echo "Error: Cannot find module '$HOME/.cache/node/corepack/pnpm/12.10.1/bin/pnpm.cjs'" >&2
exit 1
EOS
    chmod +x "$1"
}

@test "a pnpm that cannot start is skipped with a warning, not failed" {
    set_free 10
    broken_pnpm "$TMP/pnpm"
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "WARN  pnpm store skipped" "$DISK_CLEANUP_LOG"
    grep -q "Cannot find module" "$DISK_CLEANUP_LOG"
    grep -q "corepack" "$DISK_CLEANUP_LOG"
    not_logged "FAIL  pnpm"
    [[ "$(calls)" != *"store prune"* ]] || false
    [[ "$(calls)" == *"brew cleanup"* ]] || false
    grep -q "RESULT: warnings: pnpm" "$DISK_CLEANUP_LOG"
}

@test "a broken pnpm falls back to one that runs" {
    set_free 10
    broken_pnpm "$TMP/pnpm"
    mkdir -p "$TMP/alt"
    cat > "$TMP/alt/pnpm" <<EOS
#!/usr/bin/env bash
echo "alt-pnpm \$@" >> "$CALLS"
EOS
    chmod +x "$TMP/alt/pnpm"
    export DISK_CLEANUP_PNPM_FALLBACKS="$TMP/absent/pnpm:$TMP/alt/pnpm"
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"alt-pnpm store prune"* ]] || false
    grep -q "OK    pnpm store" "$DISK_CLEANUP_LOG"
}

@test "a pnpm that starts but fails to prune still fails" {
    set_free 10
    cat > "$TMP/pnpm" <<EOS
#!/usr/bin/env bash
echo "pnpm \$@" >> "$CALLS"
[ "\$1" = "--version" ] && exit 0
exit 4
EOS
    chmod +x "$TMP/pnpm"
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "FAIL  pnpm store (exit 4)" "$DISK_CLEANUP_LOG"
}

# --- wpmcp test cache ------------------------------------------------------

# Sets the mtime of $1 to $2 hours ago.
hours_ago() { touch -t "$(date -v-"$2"H +%Y%m%d%H%M.%S)" "$1"; }

# A dead PID: a subshell that has already exited.
dead_pid() { ( exit 0 ) & local p=$!; wait "$p"; echo "$p"; }

# One cache with something of every kind in it.
make_wpmcp_cache() {
    mkdir -p "$WPCACHE"/{mariadb/data,configs,locks,cores,notes}
    echo db > "$WPCACHE/mariadb/data/ibdata1"
    echo cfg > "$WPCACHE/configs/wpmcp_test_1.php"
    hours_ago "$WPCACHE/mariadb/data/ibdata1" 200
    hours_ago "$WPCACHE/configs/wpmcp_test_1.php" 200
    local d
    for d in idle fresh locked unstamped; do
        mkdir -p "$WPCACHE/wp-7.1-aaa-plugins-$d/wordpress"
    done
    hours_ago_stamp idle 7
    hours_ago_stamp locked 30
    touch "$WPCACHE/wp-7.1-aaa-plugins-fresh/.last-used"
    # Installs from before plugin keys existed are never touched.
    mkdir -p "$WPCACHE/wp-6.9-bbb/wordpress"
    hours_ago "$WPCACHE/wp-6.9-bbb" 500
    mkdir -p "$WPCACHE/locks/install-wp-7.1-aaa-plugins-locked"
    echo $$ > "$WPCACHE/locks/install-wp-7.1-aaa-plugins-locked/pid"
    mkdir -p "$WPCACHE/cores/aaaaaaaaaaaa-$(dead_pid)" "$WPCACHE/cores/bbbbbbbbbbbb-$$"
}
hours_ago_stamp() { touch "$WPCACHE/wp-7.1-aaa-plugins-$1/.last-used"; hours_ago "$WPCACHE/wp-7.1-aaa-plugins-$1/.last-used" "$2"; }

@test "wpmcp: removes idle installs and dead runs' cores, nothing else" {
    set_free 10
    make_wpmcp_cache
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ ! -d "$WPCACHE/wp-7.1-aaa-plugins-idle" ]
    [ -d "$WPCACHE/wp-7.1-aaa-plugins-fresh" ]
    [ -d "$WPCACHE/wp-7.1-aaa-plugins-locked" ]
    [ -d "$WPCACHE/wp-7.1-aaa-plugins-unstamped" ]
    [ -d "$WPCACHE/wp-6.9-bbb" ]
    [ -z "$(ls "$WPCACHE/cores" | grep aaaaaaaaaaaa)" ]
    [ -d "$WPCACHE/cores/bbbbbbbbbbbb-$$" ]
    [ -f "$WPCACHE/mariadb/data/ibdata1" ]
    [ -f "$WPCACHE/configs/wpmcp_test_1.php" ]
    [ -d "$WPCACHE/locks/install-wp-7.1-aaa-plugins-locked" ]
    [ -d "$WPCACHE/notes" ]
    grep -q "OK    wpmcp tests: removed .*wp-7.1-aaa-plugins-idle" "$DISK_CLEANUP_LOG"
}

@test "wpmcp: an install whose lock is held by a dead run is removed" {
    set_free 10
    make_wpmcp_cache
    dead_pid > "$WPCACHE/locks/install-wp-7.1-aaa-plugins-locked/pid"
    run "$TOOL"
    [ ! -d "$WPCACHE/wp-7.1-aaa-plugins-locked" ]
}

@test "wpmcp: the idle age is configurable" {
    set_free 10
    make_wpmcp_cache
    export DISK_CLEANUP_WPMCP_IDLE_HOURS=8
    run "$TOOL"
    [ -d "$WPCACHE/wp-7.1-aaa-plugins-idle" ]
}

@test "wpmcp: uses the harness's own --prune when the checkout has it" {
    set_free 10
    make_wpmcp_cache
    mkdir -p "$DISK_CLEANUP_WPMCP_REPO/bin"
    cat > "$DISK_CLEANUP_WPMCP_REPO/bin/test-local.sh" <<EOS
#!/usr/bin/env bash
case "\$1" in
    --prune) echo "test-local \$* in \$PWD cache=\${WPMCP_TEST_CACHE}" >> "$CALLS" ;;
esac
EOS
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"test-local --prune in $DISK_CLEANUP_WPMCP_REPO cache=$WPCACHE"* ]] || false
    # The harness decides; the fallback does not run as well.
    [ -d "$WPCACHE/wp-7.1-aaa-plugins-idle" ]
}

@test "wpmcp: a checkout without --prune gets the fallback" {
    set_free 10
    make_wpmcp_cache
    mkdir -p "$DISK_CLEANUP_WPMCP_REPO/bin"
    printf '#!/usr/bin/env bash\necho "test-local $*" >> "%s"\n' "$CALLS" > "$DISK_CLEANUP_WPMCP_REPO/bin/test-local.sh"
    run "$TOOL"
    [[ "$(calls)" != *"test-local"* ]] || false
    [ ! -d "$WPCACHE/wp-7.1-aaa-plugins-idle" ]
}

@test "wpmcp: a failing --prune fails the step" {
    set_free 10
    make_wpmcp_cache
    mkdir -p "$DISK_CLEANUP_WPMCP_REPO/bin"
    printf '#!/usr/bin/env bash\ncase "$1" in --prune) exit 5 ;; esac\n' > "$DISK_CLEANUP_WPMCP_REPO/bin/test-local.sh"
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "FAIL  wpmcp tests" "$DISK_CLEANUP_LOG"
}

@test "wpmcp: a cache path not named wpmcp-tests is refused" {
    set_free 10
    make_wpmcp_cache
    mv "$WPCACHE" "$TMP/precious"
    export DISK_CLEANUP_WPMCP_CACHE="$TMP/precious"
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ -d "$TMP/precious/wp-7.1-aaa-plugins-idle" ]
    grep -q "SKIP  wpmcp tests (.* is not a wpmcp-tests directory)" "$DISK_CLEANUP_LOG"
}

@test "wpmcp: no cache is skipped, not failed" {
    set_free 10
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "SKIP  wpmcp tests (not present)" "$DISK_CLEANUP_LOG"
}

@test "wpmcp: --dry-run lists idle installs and removes nothing" {
    set_free 10
    make_wpmcp_cache
    run "$TOOL" --dry-run
    [ -d "$WPCACHE/wp-7.1-aaa-plugins-idle" ]
    [ -n "$(ls "$WPCACHE/cores" | grep aaaaaaaaaaaa)" ]
    [[ "$output" == *"wp-7.1-aaa-plugins-idle"* ]] || false
    [[ "$output" != *"wp-7.1-aaa-plugins-fresh"* ]] || false
}

# --- npx cache -------------------------------------------------------------

make_npx_entry() {
    mkdir -p "$HOME/.npm/_npx/$1/node_modules"
    if [ "$2" = old ]; then touch -t 202001010000 "$HOME/.npm/_npx/$1"; fi
}

@test "npx: removes entries idle 30+ days through npm's own command" {
    set_free 10
    make_npx_entry 0aedce19bdc09f4b old
    make_npx_entry 1111111111111111 new
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"npm cache npx rm 0aedce19bdc09f4b"* ]] || false
    [[ "$(calls)" != *"1111111111111111"* ]] || false
}

@test "npx: an idle entry a running process uses is kept" {
    set_free 10
    make_npx_entry 0aedce19bdc09f4b old
    echo "node $HOME/.npm/_npx/0aedce19bdc09f4b/node_modules/.bin/chrome-devtools-mcp" > "$PSOUT"
    run "$TOOL"
    [[ "$(calls)" != *"npx rm"* ]] || false
    grep -q "npx cache (nothing idle" "$DISK_CLEANUP_LOG"
}

@test "npx: --dry-run removes nothing" {
    set_free 10
    make_npx_entry 0aedce19bdc09f4b old
    run "$TOOL" --dry-run
    [[ "$(calls)" != *"npx rm"* ]] || false
    [[ "$output" == *"0aedce19bdc09f4b"* ]] || false
}

# --- free space falling fast -----------------------------------------------

state()        { printf '%s %s\n' "$(( $(date +%s) - $1 ))" "$2" > "$TMP/cleanup.state"; }

@test "acts above the threshold when the last run's rate would cross it by the next run" {
    # 100GB -> 60GB in an hour; at that rate the next run sees 20GB.
    state 3600 100
    set_free 60
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ -n "$(calls)" ]
    grep -q "falling fast" "$DISK_CLEANUP_LOG"
}

@test "a slow decline above the threshold does nothing" {
    state 3600 65
    set_free 60
    run "$TOOL"
    [ -z "$(calls)" ]
}

@test "a stale sample is not used to project" {
    state $(( 24 * 3600 )) 200
    set_free 60
    run "$TOOL"
    [ -z "$(calls)" ]
}

@test "rising free space does nothing" {
    state 3600 20
    set_free 60
    run "$TOOL"
    [ -z "$(calls)" ]
}

@test "every run records free space for the next one" {
    set_free 77
    run "$TOOL"
    [ "$(cut -d' ' -f2 "$TMP/cleanup.state")" = 77 ]
}

@test "--dry-run records nothing" {
    set_free 77
    run "$TOOL" --dry-run
    [ ! -e "$TMP/cleanup.state" ]
}

# --- overlapping runs ------------------------------------------------------

@test "a run already in progress makes a second one step aside" {
    set_free 10
    mkdir -p "$TMP/cleanup.lock"
    echo $$ > "$TMP/cleanup.lock/pid"
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
    grep -q "SKIP  another run (pid $$) is in progress" "$DISK_CLEANUP_LOG"
}

@test "a lock left by a dead run is taken over and released" {
    set_free 10
    mkdir -p "$TMP/cleanup.lock"
    dead_pid > "$TMP/cleanup.lock/pid"
    run "$TOOL"
    [ -n "$(calls)" ]
    [ ! -e "$TMP/cleanup.lock" ]
}

# --- registered pruners ----------------------------------------------------

write_fake_pruner() {
    cat > "$TMP/$1" <<EOS
#!/usr/bin/env bash
echo "$1 \$*" >> "$CALLS"
exit ${2:-0}
EOS
    chmod +x "$TMP/$1"
}

@test "registered: runs each listed prune command with its arguments" {
    set_free 10
    write_fake_pruner proj-a
    write_fake_pruner proj-b
    printf '# comment\n\nproj a tests|%s --prune\nproj b|%s\n' "$TMP/proj-a" "$TMP/proj-b" > "$DISK_CLEANUP_PRUNERS_FILE"
    run "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"proj-a --prune"* ]] || false
    [[ "$(calls)" == *"proj-b"* ]] || false
    grep -q "OK    proj a tests" "$DISK_CLEANUP_LOG"
}

@test "registered: no file means nothing to do" {
    set_free 10
    run "$TOOL"
    [ "$status" -eq 0 ]
    ! grep -q "registered pruner" "$DISK_CLEANUP_LOG"
}

@test "registered: a missing command is skipped, not failed" {
    set_free 10
    printf 'gone|%s --prune\n' "$TMP/not-there" > "$DISK_CLEANUP_PRUNERS_FILE"
    run "$TOOL"
    [ "$status" -eq 0 ]
    grep -q "SKIP  gone (not installed)" "$DISK_CLEANUP_LOG"
}

@test "registered: a failing command or malformed line fails the run" {
    set_free 10
    write_fake_pruner bad 3
    printf 'bad|%s\nno separator here\n' "$TMP/bad" > "$DISK_CLEANUP_PRUNERS_FILE"
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "FAIL  bad (exit 3)" "$DISK_CLEANUP_LOG"
    grep -q "malformed line: no separator here" "$DISK_CLEANUP_LOG"
}

@test "registered: dry run only reports" {
    set_free 10
    write_fake_pruner proj-a
    printf 'proj a|%s --prune\n' "$TMP/proj-a" > "$DISK_CLEANUP_PRUNERS_FILE"
    run "$TOOL" --dry-run
    [ "$status" -eq 0 ]
    [[ "$(calls)" != *"proj-a"* ]] || false
}
