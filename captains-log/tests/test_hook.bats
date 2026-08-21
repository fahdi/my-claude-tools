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

# ── Portability regressions ───────────────────────────────────────────────────
# The three tests below each pin a bug that was invisible on macOS and only
# showed up on Linux, WSL, or Git Bash under Windows.

# `stat -f %m` is BSD syntax. Everywhere else it failed, the `|| echo 0`
# fallback made the lock look ~1.7 billion seconds old, and the reclaim below
# fired on every run — so the recursion guard was cleared each time instead of
# only when genuinely stale.
@test "a fresh lock is not reclaimed as stale" {
    mkdir "$LOCK"
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ -d "$LOCK" ]
    rmdir "$LOCK"
}

@test "a lock older than the timeout is reclaimed" {
    mkdir "$LOCK"
    # Backdate well past the 90s staleness threshold.
    touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)" "$LOCK"
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    run bash "$SCRIPT" <<< "$(build_input "$FIXTURE_DIR/real_session.jsonl")"
    [ "$status" -eq 0 ]
    # Reclaimed, taken, and then released by the run's own cleanup trap.
    [ ! -d "$LOCK" ]
}

# LOG_FILE was assigned but never exported, so the heredoc that reads
# os.environ['LOG_FILE'] always saw nothing and the supplemental-entry branch
# could not fire. A second run within 15 minutes must consult the first entry.
@test "a second run within the window reads the previous entry" {
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    export MOCK_PROMPT_LOG="$DIARY_DIR/../prompt.txt"
    local input today
    input=$(build_input "$FIXTURE_DIR/real_session.jsonl")

    bash "$SCRIPT" <<< "$input"
    today=$(date +%Y-%m-%d)
    grep -q "MOCK_LOG_ENTRY" "$DIARY_DIR/$today.md"
    # First run has nothing to build on, so it asks for a full entry.
    ! grep -q "PREVIOUS ENTRY" "$MOCK_PROMPT_LOG"

    bash "$SCRIPT" <<< "$input"
    # Second run inside the 15-minute window must see the first entry.
    grep -q "PREVIOUS ENTRY" "$MOCK_PROMPT_LOG"
    grep -q "MOCK_LOG_ENTRY" "$MOCK_PROMPT_LOG"
}

# Windows has no dependable `python3`: python.org ships python.exe plus the py
# launcher, and the name python3 is often a Store stub that runs nothing.
@test "resolves a genuinely working python 3 interpreter" {
    local probe
    probe=$(sed -n '/^find_python()/,/^}/p' "$SCRIPT")
    [ -n "$probe" ]

    run bash -c "$probe; find_python"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run bash -c "$probe; \$(find_python) -c 'import sys; print(sys.version_info[0])'"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

# macOS answers `stat -f %m`, so the BSD-only mtime lookup looked fine on the
# machine this hook was written on. Force the other arrangement to prove the
# reclaim logic no longer depends on which stat is installed.
@test "fresh lock survives when only GNU-style stat is available" {
    export PATH="$BATS_TEST_DIRNAME/mocks/gnu-stat:$BATS_TEST_DIRNAME/mocks:$PATH"
    run stat -f %m "$DIARY_DIR"
    [ "$status" -ne 0 ]   # the mock is in front of the real stat

    mkdir "$LOCK"
    run bash "$SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ -d "$LOCK" ]
    rmdir "$LOCK"
}
