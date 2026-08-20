#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../hooks/log-session.sh"
FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures"
# Must match GLOBAL_LOCK in hooks/log-session.sh. It is a DIRECTORY, created
# with mkdir because that is atomic; testing it as a file made both lock tests
# below pass against a path the hook never touches.
LOCK="/tmp/captains-log-lock"

setup() {
    rmdir "$LOCK" 2>/dev/null || true
    export DIARY_DIR="$(mktemp -d)"
    cp -r "$BATS_TEST_DIRNAME/../hooks" "$DIARY_DIR/scripts"
    git -C "$DIARY_DIR" init -q
    git -C "$DIARY_DIR" config user.email "test@test.com"
    git -C "$DIARY_DIR" config user.name "Test"
}

teardown() {
    rmdir "$LOCK" 2>/dev/null || true
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
    mkdir "$LOCK"
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    # The lock must survive: releasing it here would let the outer run's
    # inner `claude -p` re-enter the hook, which is what it guards against.
    [ -d "$LOCK" ]
    rmdir "$LOCK"
}

@test "removes lock directory on exit" {
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ ! -d "$LOCK" ]
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

# The suite copies the whole hooks/ directory into place, so it cannot notice
# an installer that ships only some of it. This closes that gap: every helper
# the hook invokes from its own directory must also be installed, or the hook
# exits 0 with no entry and no error.
@test "installer copies every file the hook calls" {
    local installer="$BATS_TEST_DIRNAME/../install.sh"
    local helper
    for helper in $(grep -oE '\$SCRIPT_DIR/[A-Za-z_]+\.py' "$SCRIPT" | sed 's|.*/||'); do
        # An actual cp into the install directory, not a passing mention: the
        # first version of this test matched the comment explaining the copy
        # and so passed with the copy itself deleted.
        grep -qE "^[[:space:]]*cp .*$helper.*\"\\\$DIARY_DIR" "$installer" \
            || { echo "install.sh never copies $helper, which log-session.sh runs"; return 1; }
    done
}
