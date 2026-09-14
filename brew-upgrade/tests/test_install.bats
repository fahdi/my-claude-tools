#!/usr/bin/env bats
# brew-upgrade installer - behaviour tests
#
# Every test injects a fake launchctl, a fake crontab and a throwaway
# LaunchAgents directory, so nothing here touches the real crontab or loads
# anything into the real launchd.

setup() {
    INSTALL="$BATS_TEST_DIRNAME/../install.sh"
    TMP="$BATS_TEST_TMPDIR/$BATS_TEST_NAME"
    mkdir -p "$TMP"

    export HOME="$TMP/home"
    mkdir -p "$HOME"
    export BREW_UPGRADE_LAUNCHD_DIR="$TMP/LaunchAgents"
    export BREW_UPGRADE_LABEL="com.test.brew-upgrade"
    export BREW_UPGRADE_LAUNCHCTL="$TMP/launchctl"
    export BREW_UPGRADE_CRONTAB="$TMP/crontab"

    PLIST="$BREW_UPGRADE_LAUNCHD_DIR/${BREW_UPGRADE_LABEL}.plist"
    CRONFILE="$TMP/crontab.state"
    : > "$CRONFILE"

    cat > "$BREW_UPGRADE_LAUNCHCTL" <<EOS
#!/usr/bin/env bash
echo "\$@" >> "$TMP/launchctl.calls"
exit 0
EOS
    chmod +x "$BREW_UPGRADE_LAUNCHCTL"

    # Stands in for crontab: -l prints state, - reads new state from stdin.
    cat > "$BREW_UPGRADE_CRONTAB" <<EOS
#!/usr/bin/env bash
case "\$1" in
    -l) cat "$CRONFILE" ;;
    -)  cat > "$CRONFILE" ;;
    -r) : > "$CRONFILE" ;;
esac
exit 0
EOS
    chmod +x "$BREW_UPGRADE_CRONTAB"
}

launchctl_calls() { cat "$TMP/launchctl.calls" 2>/dev/null || true; }

@test "launchd is the default and writes a plist" {
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ -f "$PLIST" ]
}

@test "the plist is valid property list syntax" {
    run "$INSTALL"
    run plutil -lint "$PLIST"
    [ "$status" -eq 0 ]
}

@test "default time is 04:00" {
    run "$INSTALL"
    run plutil -extract StartCalendarInterval.Hour raw -o - "$PLIST"
    [ "$output" = "4" ]
    run plutil -extract StartCalendarInterval.Minute raw -o - "$PLIST"
    [ "$output" = "0" ]
}

@test "--at sets the hour and minute" {
    run "$INSTALL" --at 23:45
    [ "$status" -eq 0 ]
    run plutil -extract StartCalendarInterval.Hour raw -o - "$PLIST"
    [ "$output" = "23" ]
    run plutil -extract StartCalendarInterval.Minute raw -o - "$PLIST"
    [ "$output" = "45" ]
}

@test "--at treats 08 and 09 as decimal, not octal" {
    run "$INSTALL" --at 09:08
    [ "$status" -eq 0 ]
    run plutil -extract StartCalendarInterval.Hour raw -o - "$PLIST"
    [ "$output" = "9" ]
    run plutil -extract StartCalendarInterval.Minute raw -o - "$PLIST"
    [ "$output" = "8" ]
}

@test "--at rejects a malformed time" {
    run "$INSTALL" --at 4am
    [ "$status" -ne 0 ]
    [ ! -f "$PLIST" ]
}

@test "--at rejects an out-of-range hour" {
    run "$INSTALL" --at 26:00
    [ "$status" -ne 0 ]
    [ ! -f "$PLIST" ]
}

@test "the agent runs the real script, not a shell string" {
    run "$INSTALL"
    run plutil -extract ProgramArguments.0 raw -o - "$PLIST"
    [[ "$output" == *"/bin/brew-upgrade.sh" ]]
}

@test "RunAtLoad is false so installing does not trigger an upgrade" {
    run "$INSTALL"
    run plutil -extract RunAtLoad raw -o - "$PLIST"
    [ "$output" = "false" ]
}

@test "the agent is bootstrapped into launchd" {
    run "$INSTALL"
    [[ "$(launchctl_calls)" == *"bootstrap"* ]]
}

@test "reinstalling boots the old agent out first" {
    run "$INSTALL"
    run "$INSTALL" --at 05:00
    [[ "$(launchctl_calls)" == *"bootout"* ]]
    run plutil -extract StartCalendarInterval.Hour raw -o - "$PLIST"
    [ "$output" = "5" ]
}

@test "installing launchd removes an existing crontab entry" {
    printf '%s\n' "0 4 * * * /old/path # my-claude-tools:brew-upgrade" > "$CRONFILE"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    run cat "$CRONFILE"
    [[ "$output" != *"my-claude-tools:brew-upgrade"* ]]
}

@test "installing launchd leaves unrelated crontab lines alone" {
    printf '%s\n' "*/15 * * * * /Users/me/speedtest.sh" > "$CRONFILE"
    run "$INSTALL"
    run cat "$CRONFILE"
    [[ "$output" == *"speedtest.sh"* ]]
}

@test "--cron installs a marked crontab entry instead" {
    run "$INSTALL" --cron
    [ "$status" -eq 0 ]
    [ ! -f "$PLIST" ]
    run cat "$CRONFILE"
    [[ "$output" == *"my-claude-tools:brew-upgrade"* ]]
}

@test "--cron removes an existing launchd agent" {
    run "$INSTALL"
    [ -f "$PLIST" ]
    run "$INSTALL" --cron
    [ ! -f "$PLIST" ]
}

@test "--schedule implies --cron" {
    run "$INSTALL" --schedule '0 5 * * 0'
    [ "$status" -eq 0 ]
    [ ! -f "$PLIST" ]
    run cat "$CRONFILE"
    [[ "$output" == *"0 5 * * 0"* ]]
}

@test "--uninstall removes the plist and boots the agent out" {
    run "$INSTALL"
    [ -f "$PLIST" ]
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    [ ! -f "$PLIST" ]
    [[ "$(launchctl_calls)" == *"bootout"* ]]
}

@test "--uninstall removes a cron entry too" {
    run "$INSTALL" --cron
    run "$INSTALL" --uninstall
    run cat "$CRONFILE"
    [[ "$output" != *"my-claude-tools:brew-upgrade"* ]]
}

@test "--uninstall on a clean machine says so and still exits 0" {
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing installed"* ]]
}

@test "unknown options are rejected before anything is written" {
    run "$INSTALL" --yolo
    [ "$status" -ne 0 ]
    [ ! -f "$PLIST" ]
}
