#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../hooks/log-session.sh"
FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures"
LOCK="/tmp/captains-log-global"

setup() {
    rm -f "$LOCK"
    export DIARY_DIR="$(mktemp -d)"
    cp -r "$BATS_TEST_DIRNAME/../hooks" "$DIARY_DIR/scripts"
    git -C "$DIARY_DIR" init -q
    git -C "$DIARY_DIR" config user.email "test@test.com"
    git -C "$DIARY_DIR" config user.name "Test"
}

teardown() {
    rm -f "$LOCK"
    rm -rf "$DIARY_DIR"
}

build_input() {
    local transcript="$1"
    printf '{"transcript_path": "%s"}' "$transcript"
}

@test "exits cleanly with no stdin input" {
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
}

@test "exits cleanly when transcript_path is missing from input" {
    run bash "$SCRIPT" <<< '{}'
    [ "$status" -eq 0 ]
}

@test "exits cleanly when transcript file does not exist" {
    run bash "$SCRIPT" <<< '{"transcript_path": "/tmp/does-not-exist.jsonl"}'
    [ "$status" -eq 0 ]
}

@test "exits immediately when global lock exists" {
    touch "$LOCK"
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    # Lock file should still exist (we did not clean it up — that's the outer run's job)
    [ -f "$LOCK" ]
    rm -f "$LOCK"
}

@test "removes lock file on exit" {
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ ! -f "$LOCK" ]
}

@test "does not create log when tool count is below threshold" {
    local input
    input=$(build_input "$FIXTURE_DIR/low_tool_count.jsonl")
    run bash "$SCRIPT" <<< "$input"
    [ "$status" -eq 0 ]
    # No log file should exist
    [ -z "$(find "$DIARY_DIR" -name '*.md' -not -path '*/.git/*' 2>/dev/null)" ]
}

@test "creates daily log file for real session" {
    # Mock claude -p so we don't need a real API call
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    local input
    input=$(build_input "$FIXTURE_DIR/real_session.jsonl")
    run bash "$SCRIPT" <<< "$input"
    [ "$status" -eq 0 ]
    local today
    today=$(date +%Y-%m-%d)
    [ -f "$DIARY_DIR/$today.md" ]
}

@test "log file contains logged-at timestamp" {
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    local input
    input=$(build_input "$FIXTURE_DIR/real_session.jsonl")
    bash "$SCRIPT" <<< "$input"
    local today
    today=$(date +%Y-%m-%d)
    grep -q "Logged at" "$DIARY_DIR/$today.md"
}

@test "log file contains mock claude output" {
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    local input
    input=$(build_input "$FIXTURE_DIR/real_session.jsonl")
    bash "$SCRIPT" <<< "$input"
    local today
    today=$(date +%Y-%m-%d)
    grep -q "MOCK_LOG_ENTRY" "$DIARY_DIR/$today.md"
}

@test "creates a git commit after logging" {
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    local input
    input=$(build_input "$FIXTURE_DIR/real_session.jsonl")
    bash "$SCRIPT" <<< "$input"
    local commits
    commits=$(git -C "$DIARY_DIR" log --oneline 2>/dev/null | wc -l | tr -d ' ')
    [ "$commits" -ge 1 ]
}
