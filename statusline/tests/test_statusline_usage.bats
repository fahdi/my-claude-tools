#!/usr/bin/env bats
# statusline: rate-limit rendering tests
#
# The script is fed a canned usage cache and told not to touch the network,
# so nothing here reads the real keychain or ~/.claude.

setup() {
    SL="$BATS_TEST_DIRNAME/../bin/statusline.sh"
    TMP="$BATS_TEST_TMPDIR/$BATS_TEST_NAME"
    mkdir -p "$TMP"
    export STATUSLINE_USAGE_CACHE_FILE="$TMP/usage.json"
    export STATUSLINE_NO_FETCH=1
    export STATUSLINE_USAGE_STALE_AFTER=300
    export CLAUDE_CONFIG_DIR="$TMP/profile"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    echo '{}' > "$CLAUDE_CONFIG_DIR/settings.json"
    echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
    INPUT='{"model":{"display_name":"Test"},"cwd":"'"$TMP"'","transcript_path":"'"$CLAUDE_CONFIG_DIR"'/projects/x/y.jsonl","context_window":{"context_window_size":1000,"current_usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
}

# Run the statusline and strip ANSI so assertions see plain text.
render() {
    run bash -c "printf '%s' '$INPUT' | bash '$SL' | sed 's/\x1b\[[0-9;]*m//g'"
}

future_iso() {  # days ahead
    date -u -v+"$1"d +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null \
        || date -u -d "+$1 days" +"%Y-%m-%dT%H:%M:%S+00:00"
}
past_iso() {  # days ago
    date -u -v-"$1"d +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null \
        || date -u -d "-$1 days" +"%Y-%m-%dT%H:%M:%S+00:00"
}

write_limits() {  # json array of limits, five_hour json
    jq -n --argjson limits "$1" --argjson fh "${2:-null}" \
        '{five_hour:$fh, seven_day:{utilization:3}, limits:$limits, extra_usage:{is_enabled:false}}' \
        > "$STATUSLINE_USAGE_CACHE_FILE"
}

@test "weekly-only account: no current line, weekly and scoped shown" {
    r=$(future_iso 6)
    write_limits "[
      {\"kind\":\"weekly_all\",\"percent\":3,\"resets_at\":\"$r\",\"scope\":null},
      {\"kind\":\"weekly_scoped\",\"percent\":4,\"resets_at\":\"$r\",\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}
    ]"
    render
    [ "$status" -eq 0 ]
    [[ "$output" != *"current"* ]]
    [[ "$output" == *"weekly "*"  3%"* ]]
    [[ "$output" == *"fable  "*"  4%"* ]]
}

@test "account with a session limit still shows current" {
    r=$(future_iso 1)
    write_limits "[
      {\"kind\":\"session\",\"percent\":18,\"resets_at\":\"$r\",\"scope\":null},
      {\"kind\":\"weekly_all\",\"percent\":47,\"resets_at\":\"$r\",\"scope\":null}
    ]"
    render
    [[ "$output" == *"current"*" 18%"* ]]
    [[ "$output" == *"weekly "*" 47%"* ]]
}

@test "legacy response without limits array falls back to five_hour/seven_day" {
    r=$(future_iso 1)
    jq -n --arg r "$r" '{five_hour:{utilization:12,resets_at:$r}, seven_day:{utilization:40,resets_at:$r}}' \
        > "$STATUSLINE_USAGE_CACHE_FILE"
    render
    [[ "$output" == *"current"*" 12%"* ]]
    [[ "$output" == *"weekly "*" 40%"* ]]
}

@test "legacy response with null five_hour shows only weekly" {
    r=$(future_iso 1)
    jq -n --arg r "$r" '{five_hour:null, seven_day:{utilization:40,resets_at:$r}}' \
        > "$STATUSLINE_USAGE_CACHE_FILE"
    render
    [[ "$output" != *"current"* ]]
    [[ "$output" == *"weekly "*" 40%"* ]]
}

@test "a limit whose reset has passed is marked expired, not shown as a live percent" {
    write_limits "[{\"kind\":\"weekly_all\",\"percent\":47,\"resets_at\":\"$(past_iso 1)\",\"scope\":null}]"
    render
    [[ "$output" == *"weekly "*"--%"*"(expired)"* ]]
    [[ "$output" != *" 47%"* ]]
}

@test "old cache gets an age footer" {
    write_limits "[{\"kind\":\"weekly_all\",\"percent\":3,\"resets_at\":\"$(future_iso 6)\",\"scope\":null}]"
    touch -t "$(date -v-26H +%Y%m%d%H%M 2>/dev/null || date -d '-26 hours' +%Y%m%d%H%M)" "$STATUSLINE_USAGE_CACHE_FILE"
    render
    [[ "$output" == *"usage data from 26h ago"* ]]
}

@test "fresh cache has no age footer" {
    write_limits "[{\"kind\":\"weekly_all\",\"percent\":3,\"resets_at\":\"$(future_iso 6)\",\"scope\":null}]"
    render
    [[ "$output" != *"usage data from"* ]]
}

@test "no cache and no network renders line 1 only" {
    rm -f "$STATUSLINE_USAGE_CACHE_FILE"
    render
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test"* ]]
    [[ "$output" != *"weekly"* ]]
}

@test "a backoff stamp in the future suppresses the fetch" {
    unset STATUSLINE_NO_FETCH
    export CLAUDE_CODE_OAUTH_TOKEN="not-a-real-token"
    write_limits "[{\"kind\":\"weekly_all\",\"percent\":3,\"resets_at\":\"$(future_iso 6)\",\"scope\":null}]"
    touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '-10 minutes' +%Y%m%d%H%M)" "$STATUSLINE_USAGE_CACHE_FILE"
    echo $(( $(date +%s) + 600 )) > "$TMP/usage.backoff"
    before=$(stat -f %m "$STATUSLINE_USAGE_CACHE_FILE" 2>/dev/null || stat -c %Y "$STATUSLINE_USAGE_CACHE_FILE")
    # With a fake token any real fetch would 401 and not update the cache
    # anyway, so the assertion that matters is the lock dir is never created
    # and the stamp survives.
    render
    [ -f "$TMP/usage.backoff" ]
    [ ! -d "$TMP/usage.lock" ]
    after=$(stat -f %m "$STATUSLINE_USAGE_CACHE_FILE" 2>/dev/null || stat -c %Y "$STATUSLINE_USAGE_CACHE_FILE")
    [ "$before" = "$after" ]
    [[ "$output" == *"weekly "*"  3%"* ]]
}

@test "an expired backoff stamp is removed" {
    write_limits "[{\"kind\":\"weekly_all\",\"percent\":3,\"resets_at\":\"$(future_iso 6)\",\"scope\":null}]"
    touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '-10 minutes' +%Y%m%d%H%M)" "$STATUSLINE_USAGE_CACHE_FILE"
    echo $(( $(date +%s) - 10 )) > "$TMP/usage.backoff"
    render
    [ ! -f "$TMP/usage.backoff" ]
}
