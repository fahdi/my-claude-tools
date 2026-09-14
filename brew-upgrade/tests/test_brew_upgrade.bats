#!/usr/bin/env bats
# brew-upgrade - behaviour tests
#
# Every test builds a fake brew and a throwaway log, so nothing here touches
# the real Homebrew installation or the real crontab.

setup() {
    TOOL="$BATS_TEST_DIRNAME/../bin/brew-upgrade.sh"
    TMP="$BATS_TEST_TMPDIR/$BATS_TEST_NAME"
    mkdir -p "$TMP"

    export BREW_UPGRADE_LOG="$TMP/cron.log"
    export BREW_UPGRADE_BREW="$TMP/brew"
    export BREW_UPGRADE_NOTIFIER="$TMP/notifier"
    export HOME="$TMP/home"
    mkdir -p "$HOME"

    # Records every notification so tests can assert on alerting.
    cat > "$BREW_UPGRADE_NOTIFIER" <<'EOS'
#!/usr/bin/env bash
echo "$@" >> "${BREW_UPGRADE_NOTIFIER}.calls"
EOS
    chmod +x "$BREW_UPGRADE_NOTIFIER"
}

# Write a fake brew that records its arguments and exits with $1 for the
# subcommand named in $2 (or 0 for everything when $2 is empty).
fake_brew() {
    local fail_code="${1:-0}" fail_cmd="${2:-}"
    cat > "$BREW_UPGRADE_BREW" <<EOS
#!/usr/bin/env bash
echo "\$@" >> "$TMP/brew.calls"
if [ -n "$fail_cmd" ] && [ "\$1" = "$fail_cmd" ]; then
    echo "simulated failure in \$1" >&2
    exit $fail_code
fi
exit 0
EOS
    chmod +x "$BREW_UPGRADE_BREW"
}

notifications() { cat "${BREW_UPGRADE_NOTIFIER}.calls" 2>/dev/null || true; }

@test "runs update, upgrade and cleanup in order" {
    fake_brew
    run "$TOOL"
    [ "$status" -eq 0 ]
    run cat "$TMP/brew.calls"
    [ "${lines[0]}" = "update" ]
    [ "${lines[1]}" = "upgrade" ]
    [ "${lines[2]}" = "cleanup --prune=all" ]
}

@test "succeeds quietly: exit 0 and no notification" {
    fake_brew
    run "$TOOL"
    [ "$status" -eq 0 ]
    [ -z "$(notifications)" ]
    grep -q "RESULT: all steps succeeded" "$BREW_UPGRADE_LOG"
}

@test "a failing step produces exit 1, not a false success" {
    fake_brew 7 upgrade
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "RESULT: failed steps: upgrade" "$BREW_UPGRADE_LOG"
}

@test "records the real exit code, not 0" {
    # Regression: reading \$? after an if/fi whose condition failed yields 0,
    # which reported every failure as "exit 0" and returned success.
    fake_brew 7 upgrade
    run "$TOOL"
    grep -q "FAIL  brew upgrade (exit 7)" "$BREW_UPGRADE_LOG"
}

@test "notifies on failure" {
    fake_brew 1 update
    run "$TOOL"
    [ "$status" -eq 1 ]
    [[ "$(notifications)" == *"Failed: update"* ]]
}

@test "keeps going after a failed step so later steps still run" {
    fake_brew 1 update
    run "$TOOL"
    run cat "$TMP/brew.calls"
    [ "${lines[1]}" = "upgrade" ]
    [ "${lines[2]}" = "cleanup --prune=all" ]
}

@test "--no-cleanup skips cleanup" {
    fake_brew
    run "$TOOL" --no-cleanup
    [ "$status" -eq 0 ]
    run cat "$TMP/brew.calls"
    [ "${#lines[@]}" -eq 2 ]
    [[ "$(cat "$TMP/brew.calls")" != *"cleanup"* ]]
}

@test "--dry-run changes nothing" {
    fake_brew
    run "$TOOL" --dry-run
    [ "$status" -eq 0 ]
    [ ! -f "$TMP/brew.calls" ]
    [[ "$output" == *"would run"* ]]
}

@test "never upgrades casks" {
    fake_brew
    run "$TOOL"
    [[ "$(cat "$TMP/brew.calls")" != *"cask"* ]]
}

@test "aborts and notifies when brew is missing" {
    rm -f "$BREW_UPGRADE_BREW"
    run "$TOOL"
    [ "$status" -eq 1 ]
    grep -q "ABORT brew not executable" "$BREW_UPGRADE_LOG"
    [[ "$(notifications)" == *"brew not found"* ]]
}

@test "rotates the log once it exceeds the size limit" {
    fake_brew
    export BREW_UPGRADE_MAX_LOG_BYTES=100
    head -c 500 /dev/zero | tr '\0' 'x' > "$BREW_UPGRADE_LOG"
    run "$TOOL"
    [ -f "${BREW_UPGRADE_LOG}.1" ]
    [ "$(wc -c < "${BREW_UPGRADE_LOG}.1" | tr -d ' ')" -eq 500 ]
}

@test "unknown options are rejected" {
    fake_brew
    run "$TOOL" --upgrade-everything
    [ "$status" -eq 2 ]
    [ ! -f "$TMP/brew.calls" ]
}
