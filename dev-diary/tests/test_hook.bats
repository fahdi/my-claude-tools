#!/usr/bin/env bats
# Covers the hook shell script. diary.py's planning decisions are covered by
# test_diary.py; what is pinned here is the orchestration around it, and the
# portability fixes that only misbehave off macOS.

SCRIPT="$BATS_TEST_DIRNAME/../hooks/dev-diary.sh"
FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures"
LOCK="/tmp/dev-diary-lock"

setup() {
    rmdir "$LOCK" 2>/dev/null || true
    TMPROOT="$(mktemp -d)"
    export DEV_DIARY_DIR="$TMPROOT/diary"
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
}

teardown() {
    rmdir "$LOCK" 2>/dev/null || true
    rm -rf "$TMPROOT"
}

build_input() {
    printf '{"transcript_path": "%s", "cwd": "%s"}' "$1" "${2:-$PWD}"
}

@test "exits cleanly with no stdin input" {
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
}

@test "exits cleanly when the transcript does not exist" {
    run bash "$SCRIPT" <<< "$(build_input /tmp/does-not-exist.jsonl)"
    [ "$status" -eq 0 ]
}

@test "exits immediately when the lock is held" {
    mkdir "$LOCK"
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ -d "$LOCK" ]
    rmdir "$LOCK"
}

@test "releases the lock on exit" {
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ ! -d "$LOCK" ]
}

# The hook creates and git-inits the diary itself, so installing the plugin
# needs no separate setup step.
@test "bootstraps a diary that does not exist yet" {
    [ ! -d "$DEV_DIARY_DIR" ]
    run bash "$SCRIPT" <<< "$(build_input "$FIXTURE_DIR/real_session.jsonl")"
    [ "$status" -eq 0 ]
    [ -f "$DEV_DIARY_DIR/README.md" ]
    [ -d "$DEV_DIARY_DIR/.git" ]
    [ -f "$DEV_DIARY_DIR/$(date +%Y-%m-%d).md" ]
}

# The payload used to be printed as one space-separated line and split by `read`,
# which truncated any path containing a space. Windows home directories are
# "C:/Users/First Last", so this was a guaranteed failure there.
@test "handles a transcript path containing spaces" {
    local spaced="$TMPROOT/Some Folder/With Spaces"
    mkdir -p "$spaced"
    cp "$FIXTURE_DIR/real_session.jsonl" "$spaced/session.jsonl"

    run bash "$SCRIPT" <<< "$(build_input "$spaced/session.jsonl" "$spaced")"
    [ "$status" -eq 0 ]
    [ -f "$DEV_DIARY_DIR/$(date +%Y-%m-%d).md" ]
}

# macOS answers `stat -f %m`, so the BSD-only mtime read looked fine here. Force
# the Linux/WSL/Git Bash arrangement to prove the guard no longer depends on it.
@test "fresh lock survives when only GNU-style stat is available" {
    export PATH="$BATS_TEST_DIRNAME/mocks/gnu-stat:$PATH"
    run stat -f %m "$TMPROOT"
    [ "$status" -ne 0 ]

    mkdir "$LOCK"
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ -d "$LOCK" ]
    rmdir "$LOCK"
}
