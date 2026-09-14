#!/usr/bin/env bats
# tool-status — behaviour tests
#
# Every test builds a throwaway Claude profile so nothing here reads the real
# ~/.claude.

setup() {
    TOOL="$BATS_TEST_DIRNAME/../bin/tool-status.sh"
    TMP="$BATS_TEST_TMPDIR/$BATS_TEST_NAME"
    PROFILE="$TMP/profile"
    mkdir -p "$PROFILE/skills" "$PROFILE/agents" "$PROFILE/commands" "$PROFILE/plugins"
    MANIFEST="$TMP/tools.conf"

    export TOOL_STATUS_PROFILES="$PROFILE"
    export TOOL_STATUS_MANIFEST="$MANIFEST"
    export TOOL_STATUS_CACHE_DIR="$TMP/cache"
    export TOOL_STATUS_CACHE_TTL=300
    export CLAUDE_CONFIG_DIR="$PROFILE"

    echo '{}' > "$PROFILE/settings.json"
    echo '{}' > "$PROFILE/.claude.json"
}

# Write a Stop hook pointing at $1 into the fake profile.
wire_stop_hook() {
    jq -n --arg cmd "bash \"$1\"" \
        '{hooks:{Stop:[{hooks:[{type:"command",command:$cmd}]}]}}' > "$PROFILE/settings.json"
}

state_of() {  # key
    run "$TOOL" --json --no-cache
    printf '%s' "$output" | jq -r --arg k "$1" '.tools[] | select(.key==$k) | .state'
}

@test "emits valid JSON" {
    echo 'rtk|rtk|bin|rtk|||proxy' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e . >/dev/null
}

@test "hook wired to an existing script reports ok" {
    script="$TMP/log-session.sh"; touch "$script"
    wire_stop_hook "$script"
    echo 'captains-log|log|hook|Stop:log-session.sh||| journal' > "$MANIFEST"
    [ "$(state_of captains-log)" = "ok" ]
}

@test "hook wired to a missing script reports warn, not ok" {
    wire_stop_hook "$TMP/gone.sh"
    echo 'captains-log|log|hook|Stop:gone.sh|||journal' > "$MANIFEST"
    [ "$(state_of captains-log)" = "warn" ]
}

@test "hook that is not wired at all reports missing" {
    echo 'captains-log|log|hook|Stop:log-session.sh|||journal' > "$MANIFEST"
    [ "$(state_of captains-log)" = "missing" ]
}

@test "records the absolute path of a wired hook script" {
    script="$TMP/dev-diary.sh"; touch "$script"
    wire_stop_hook "$script"
    echo 'devdiary|diary|hook|Stop:dev-diary.sh|||journal' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools[0].path')" = "$script" ]
}

@test "binary missing from PATH but present at alt path reports warn" {
    mkdir -p "$TMP/framework"
    echo "gsd|gsd|bin|definitely-not-a-real-binary-xyz||$TMP/framework|framework" > "$MANIFEST"
    [ "$(state_of gsd)" = "warn" ]
}

@test "binary missing everywhere reports missing" {
    echo 'gsd|gsd|bin|definitely-not-a-real-binary-xyz|||framework' > "$MANIFEST"
    [ "$(state_of gsd)" = "missing" ]
}

@test "path probe resolves \$HOME" {
    echo 'home|home|path|$HOME|||home dir' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools[0].path')" = "$HOME" ]
}

@test "plugin enabled in settings and present on disk reports ok" {
    mkdir -p "$PROFILE/plugins/cache/vendor/claude-mem"
    jq -n '{enabledPlugins:{"claude-mem@vendor":true}}' > "$PROFILE/settings.json"
    echo 'claude-mem|mem|plugin|claude-mem@vendor|||memory' > "$MANIFEST"
    [ "$(state_of claude-mem)" = "ok" ]
}

@test "plugin on disk but disabled reports warn" {
    mkdir -p "$PROFILE/plugins/cache/vendor/claude-mem"
    echo 'claude-mem|mem|plugin|claude-mem@vendor|||memory' > "$MANIFEST"
    [ "$(state_of claude-mem)" = "warn" ]
}

@test "mcp server present in .claude.json reports ok" {
    jq -n '{mcpServers:{context7:{type:"http"}}}' > "$PROFILE/.claude.json"
    echo 'context7|c7|mcp|context7|||docs' > "$MANIFEST"
    [ "$(state_of context7)" = "ok" ]
}

@test "skills are counted by SKILL.md, including symlinked ones" {
    mkdir -p "$PROFILE/skills/real" "$TMP/external/linked"
    touch "$PROFILE/skills/real/SKILL.md" "$TMP/external/linked/SKILL.md"
    ln -s "$TMP/external/linked" "$PROFILE/skills/linked"
    mkdir -p "$PROFILE/skills/not-a-skill"
    echo 'rtk|rtk|bin|rtk|||proxy' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.counts.skills')" = "2" ]
}

@test "comments and blank lines in the manifest are skipped" {
    printf '# a comment\n\nrtk|rtk|bin|rtk|||proxy\n' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools | length')" = "1" ]
}

@test "segment output names every tool in the manifest" {
    printf 'rtk|rtk|bin|rtk|||proxy\ngsd|gsd|bin|nope-xyz|||framework\n' > "$MANIFEST"
    run "$TOOL" --segment --no-cache
    [[ "$output" == *"rtk"* ]]
    [[ "$output" == *"gsd"* ]]
    [[ "$output" == *"plugins"* ]]
}

@test "full output includes absolute paths" {
    script="$TMP/log-session.sh"; touch "$script"
    wire_stop_hook "$script"
    echo 'captains-log|log|hook|Stop:log-session.sh|||journal' > "$MANIFEST"
    run "$TOOL" --full --no-cache
    [[ "$output" == *"$script"* ]]
}

@test "cache is written and reused until the manifest changes" {
    echo 'rtk|rtk|bin|rtk|||proxy' > "$MANIFEST"
    run "$TOOL" --json
    [ "$status" -eq 0 ]
    [ "$(find "$TOOL_STATUS_CACHE_DIR" -name 'tool-status-*.json' | wc -l | tr -d ' ')" = "1" ]

    # A manifest newer than the cache must invalidate it.
    sleep 1
    printf 'rtk|rtk|bin|rtk|||proxy\ngsd|gsd|bin|nope-xyz|||framework\n' > "$MANIFEST"
    run "$TOOL" --json
    [ "$(printf '%s' "$output" | jq -r '.tools | length')" = "2" ]
}

@test "settings.json newer than the cache invalidates it" {
    echo 'captains-log|log|hook|Stop:log-session.sh|||journal' > "$MANIFEST"
    run "$TOOL" --json
    [ "$(printf '%s' "$output" | jq -r '.tools[0].state')" = "missing" ]

    sleep 1
    script="$TMP/log-session.sh"; touch "$script"
    wire_stop_hook "$script"
    run "$TOOL" --json
    [ "$(printf '%s' "$output" | jq -r '.tools[0].state')" = "ok" ]
}

@test "a missing manifest exits cleanly with no output" {
    export TOOL_STATUS_MANIFEST="$TMP/does-not-exist.conf"
    run "$TOOL" --segment
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an unknown kind is ignored rather than fatal" {
    printf 'weird|weird|nonsense|x|||?\nrtk|rtk|bin|rtk|||proxy\n' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.tools | length')" = "1" ]
}

@test "falls back to the default profile when the active one is bare" {
    other="$TMP/other"; mkdir -p "$other"
    script="$TMP/log-session.sh"; touch "$script"
    jq -n --arg cmd "bash \"$script\"" \
        '{hooks:{Stop:[{hooks:[{type:"command",command:$cmd}]}]}}' > "$other/settings.json"
    export TOOL_STATUS_PROFILES="$PROFILE:$other"
    echo 'captains-log|log|hook|Stop:log-session.sh|||journal' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools[0].state')" = "ok" ]
    [ "$(printf '%s' "$output" | jq -r '.tools[0].profile')" = "other" ]
}

@test "cmdset present in the active profile reports ok" {
    mkdir -p "$PROFILE/commands/gsd/plan-phase"
    echo 'gsd|gsd|cmdset|gsd|||framework' > "$MANIFEST"
    [ "$(state_of gsd)" = "ok" ]
}

@test "cmdset present only in another profile reports warn, not ok" {
    other="$TMP/other"; mkdir -p "$other/commands/gsd/plan-phase"
    echo '{}' > "$other/settings.json"
    export TOOL_STATUS_PROFILES="$PROFILE:$other"
    export CLAUDE_CONFIG_DIR="$PROFILE"
    echo 'gsd|gsd|cmdset|gsd|||framework' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools[0].state')" = "warn" ]
    [[ "$(printf '%s' "$output" | jq -r '.tools[0].detail')" == *"not in the active profile"* ]]
}

@test "cmdset with no commands directory anywhere reports missing" {
    echo 'gsd|gsd|cmdset|gsd|||framework' > "$MANIFEST"
    [ "$(state_of gsd)" = "missing" ]
}

@test "version can be read from a VERSION file with {profile} expanded" {
    mkdir -p "$PROFILE/commands/gsd/plan-phase" "$PROFILE/get-shit-done"
    echo "1.30.0" > "$PROFILE/get-shit-done/VERSION"
    echo 'gsd|gsd|cmdset|gsd|@file:{profile}/get-shit-done/VERSION||framework' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools[0].version')" = "1.30.0" ]
}

@test "binary on PATH whose health check passes reports ok" {
    echo 'gh|gh|bin|true|||true|github cli' > "$MANIFEST"
    [ "$(state_of gh)" = "ok" ]
}

@test "binary on PATH whose health check fails reports warn, not ok" {
    echo 'gh|gh|bin|true|||false|github cli' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools[0].state')" = "warn" ]
    [[ "$(printf '%s' "$output" | jq -r '.tools[0].detail')" == *"failed"* ]]
    [ -n "$(printf '%s' "$output" | jq -r '.tools[0].path')" ]
}

@test "binary with no health check is judged on PATH alone" {
    echo 'gh|gh|bin|true||||github cli' > "$MANIFEST"
    run "$TOOL" --json --no-cache
    [ "$(printf '%s' "$output" | jq -r '.tools[0].state')" = "ok" ]
    [ "$(printf '%s' "$output" | jq -r '.tools[0].detail')" = "on PATH" ]
}

@test "a health check on a missing binary does not mask the missing state" {
    echo 'gh|gh|bin|definitely-not-a-real-binary-xyz|||true|github cli' > "$MANIFEST"
    [ "$(state_of gh)" = "missing" ]
}
