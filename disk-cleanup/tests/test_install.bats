#!/usr/bin/env bats
# disk-cleanup installer - behaviour tests
#
# A fake launchctl and a throwaway LaunchAgents directory, so nothing is ever
# loaded into the real launchd.

setup() {
    INSTALL="$BATS_TEST_DIRNAME/../install.sh"
    TMP="$BATS_TEST_TMPDIR/$BATS_TEST_NAME"
    mkdir -p "$TMP"
    export HOME="$TMP/home"; mkdir -p "$HOME"
    export DISK_CLEANUP_LAUNCHD_DIR="$TMP/LaunchAgents"
    export DISK_CLEANUP_LABEL="com.test.disk-cleanup"
    export DISK_CLEANUP_LAUNCHCTL="$TMP/launchctl"
    PLIST="$DISK_CLEANUP_LAUNCHD_DIR/${DISK_CLEANUP_LABEL}.plist"

    cat > "$DISK_CLEANUP_LAUNCHCTL" <<EOS
#!/usr/bin/env bash
echo "\$@" >> "$TMP/launchctl.calls"
exit 0
EOS
    chmod +x "$DISK_CLEANUP_LAUNCHCTL"
}

hours() { plutil -extract StartCalendarInterval json -o - "$PLIST" | tr ',' '\n' | grep -o '"Hour":[0-9]*' | cut -d: -f2 | tr '\n' ' '; }

@test "writes a valid plist" {
    run "$INSTALL"
    [ "$status" -eq 0 ]
    run plutil -lint "$PLIST"
    [ "$status" -eq 0 ]
}

@test "default schedule is every 2 hours, twelve entries on the clock" {
    run "$INSTALL"
    [ "$(hours)" = "0 2 4 6 8 10 12 14 16 18 20 22 " ]
}

@test "--every 6 gives four entries" {
    run "$INSTALL" --every 6
    [ "$(hours)" = "0 6 12 18 " ]
}

@test "--every rejects a value that does not divide 24" {
    run "$INSTALL" --every 5
    [ "$status" -ne 0 ]
    [ ! -f "$PLIST" ]
    [[ "$output" == *"divide 24"* ]]
}

@test "--every rejects nonsense and out-of-range values" {
    run "$INSTALL" --every soon
    [ "$status" -ne 0 ]
    run "$INSTALL" --every 0
    [ "$status" -ne 0 ]
    run "$INSTALL" --every 48
    [ "$status" -ne 0 ]
    [ ! -f "$PLIST" ]
}

@test "the threshold is baked into the agent environment" {
    run "$INSTALL" --min-free 75
    run plutil -extract EnvironmentVariables.DISK_CLEANUP_MIN_FREE_GB raw -o - "$PLIST"
    [ "$output" = "75" ]
}

@test "--min-free rejects nonsense" {
    run "$INSTALL" --min-free plenty
    [ "$status" -ne 0 ]
    [ ! -f "$PLIST" ]
}

@test "the agent runs the real script" {
    run "$INSTALL"
    run plutil -extract ProgramArguments.0 raw -o - "$PLIST"
    [[ "$output" == *"/bin/disk-cleanup.sh" ]]
}

@test "RunAtLoad is false so installing does not start a cleanup" {
    run "$INSTALL"
    run plutil -extract RunAtLoad raw -o - "$PLIST"
    [ "$output" = "false" ]
}

@test "it is bootstrapped into launchd" {
    run "$INSTALL"
    [[ "$(cat "$TMP/launchctl.calls")" == *"bootstrap"* ]]
}

@test "reinstalling boots the old agent out first" {
    run "$INSTALL"
    run "$INSTALL" --every 4
    [[ "$(cat "$TMP/launchctl.calls")" == *"bootout"* ]]
    [ "$(hours)" = "0 4 8 12 16 20 " ]
}

@test "--uninstall removes the plist" {
    run "$INSTALL"
    [ -f "$PLIST" ]
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    [ ! -f "$PLIST" ]
}

@test "--uninstall on a clean machine still exits 0" {
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing installed"* ]]
}

@test "unknown options are rejected" {
    run "$INSTALL" --turbo
    [ "$status" -ne 0 ]
    [ ! -f "$PLIST" ]
}
