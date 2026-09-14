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

    export DISK_CLEANUP_UV="$TMP/uv" DISK_CLEANUP_PNPM="$TMP/pnpm" \
           DISK_CLEANUP_NPM="$TMP/npm" DISK_CLEANUP_BREW="$TMP/brew" \
           DISK_CLEANUP_XCRUN="$TMP/xcrun" DISK_CLEANUP_CARGO="$TMP/cargo"

    ROOT="$TMP/src"
    mkdir -p "$ROOT"
    export DISK_CLEANUP_CARGO_ROOTS="$ROOT"
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
    [[ "$(calls)" == *"uv cache prune"* ]]
    [[ "$(calls)" == *"pnpm store prune"* ]]
    [[ "$(calls)" == *"npm cache clean --force"* ]]
    [[ "$(calls)" == *"brew cleanup --prune=all"* ]]
    [[ "$(calls)" == *"xcrun simctl delete unavailable"* ]]
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
    [[ "$(calls)" != *"rm "* ]]
    [[ "$(calls)" != *"cache clean"* ]] || [[ "$(calls)" == *"npm cache clean --force"* ]]
    # pnpm and uv must be reached through prune, never a destructive verb.
    [[ "$(calls)" == *"pnpm store prune"* ]]
    [[ "$(calls)" != *"pnpm store path"* ]]
}

@test "--force prunes even with plenty of space" {
    set_free 500
    run "$TOOL" --force
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"uv cache prune"* ]]
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
    [[ "$(calls)" == *"pnpm store prune"* ]]
}

@test "a failing pruner gives exit 1 and notifies" {
    set_free 10
    fail_tool pnpm
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "FAIL  pnpm store (exit 3)" "$DISK_CLEANUP_LOG"
    [[ "$(notifications)" == *"Failed: pnpm"* ]]
}

@test "a failing pruner does not stop the others" {
    set_free 10
    fail_tool uv
    run "$TOOL"
    [[ "$(calls)" == *"brew cleanup --prune=all"* ]]
    [[ "$(calls)" == *"xcrun simctl delete unavailable"* ]]
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
    [[ "$output" == *"would prune"* ]]
}

@test "--dry-run says so when it would do nothing" {
    set_free 100
    run "$TOOL" --dry-run
    [[ "$output" == *"would do nothing"* ]]
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
    [[ "$(calls)" == *"cargo clean --manifest-path $ROOT/idle/Cargo.toml"* ]]
}

@test "leaves an actively built target alone" {
    set_free 10
    make_rust_project active new
    run "$TOOL"
    [[ "$(calls)" != *"cargo clean"* ]]
    grep -q "nothing idle for 30+ days" "$DISK_CLEANUP_LOG"
}

@test "cleans only the stale project when both exist" {
    set_free 10
    make_rust_project idle old
    make_rust_project active new
    run "$TOOL"
    [[ "$(calls)" == *"$ROOT/idle/Cargo.toml"* ]]
    [[ "$(calls)" != *"$ROOT/active/Cargo.toml"* ]]
}

@test "a target directory with no Cargo.toml beside it is ignored" {
    set_free 10
    mkdir -p "$ROOT/not-rust/target"
    touch -t 202001010000 "$ROOT/not-rust/target"
    run "$TOOL"
    [[ "$(calls)" != *"not-rust"* ]]
}

@test "the age threshold is configurable in both directions" {
    set_free 10
    mkdir -p "$ROOT/fivedays/target"
    touch "$ROOT/fivedays/Cargo.toml"
    touch -t "$(date -v-5d '+%Y%m%d%H%M')" "$ROOT/fivedays/target"

    # A 5-day-old target is stale under a 3-day threshold.
    DISK_CLEANUP_TARGET_MAX_AGE_DAYS=3 run "$TOOL"
    [[ "$(calls)" == *"cargo clean --manifest-path $ROOT/fivedays/Cargo.toml"* ]]

    # ...and still fresh under a 10-day one.
    : > "$CALLS"
    DISK_CLEANUP_TARGET_MAX_AGE_DAYS=10 run "$TOOL"
    [[ "$(calls)" != *"cargo clean"* ]]
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
    [[ "$(notifications)" == *"cargo"* ]]
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
