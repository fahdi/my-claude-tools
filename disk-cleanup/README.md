# disk-cleanup

A scheduled job that reclaims disk space, and does nothing at all until space is
actually scarce.

## The guard is the design

These caches exist because re-downloading their contents is slow. Pruning them
on a healthy disk costs bandwidth and build time and buys nothing. So the job
runs every two hours, checks free space, and exits immediately unless it has
dropped below a threshold (40GB by default).

That means the common case is a one-line log entry saying there was nothing to
do. A quiet log is evidence the job is running, not evidence it is broken.

### Free space falling fast

A threshold alone reacts late. On 2026-11-09 a test harness filled the disk
from comfortable to full between two runs. So each run also records free space
(in `~/Library/Logs/disk-cleanup.state`), and the next run projects one interval
ahead: if space fell from 100GB to 60GB since the last run, at that rate the run
after this one would see 20GB, so it cleans now even though 60GB is above the
threshold. The guard is still the design: a disk that is not filling, or is
filling slowly, is left alone, and a sample older than
`DISK_CLEANUP_RATE_WINDOW_HOURS` (6) is not used. The log says which rule fired:

```
cleanup starting, free space falling fast: 60GB now, about 20GB by the next run at this rate, threshold 40GB
```

Only one run happens at a time. A second run that starts while one is still
going (a manual `make force` during a scheduled run, say) logs `SKIP  another
run (pid N) is in progress` and exits. A lock left by a killed run is taken over.

## What it prunes

| Target | Command | Why it is safe |
|--------|---------|----------------|
| uv cache | `uv cache prune` | Removes wheels no environment references |
| pnpm store | `pnpm store prune` | Removes packages no project references |
| npm cache | `npm cache clean --force` | Fully regenerable |
| npx installs | `npm cache npx rm <key>...` | Only entries idle 30+ days that no running process uses |
| wpmcp test cache | `bin/test-local.sh --prune`, or the fallback below | Only installs idle 6h+ with no live lock, and cores whose run has exited |
| Homebrew | `brew cleanup --prune=all` | Old versions and downloads |
| iOS simulators | `xcrun simctl delete unavailable` | Simulators for SDKs you no longer have |
| Rust builds | `cargo clean` | Only for projects idle 30+ days |
| Flutter builds | `flutter clean` | Only for projects whose `build/` and `.dart_tool/` are both idle 30+ days |
| Xcode DerivedData | `rm -rf` per entry | Only entries idle 30+ days; see the exception below |
| Docker build cache | `docker builder prune -af --filter until=720h` | Cache older than the same 30 days |
| Docker images | `docker image prune -f` | Dangling (untagged) images only |

**Every target uses its own tool's prune command, never `rm -rf`.** That
distinction is not stylistic. `~/Library/pnpm/store` is a content-addressable
store that every project's `node_modules` hard-links into, and `~/.cache/uv`
works the same way, so deleting either directory outright breaks existing
checkouts instead of safely freeing space. `prune` removes only what nothing
references.

### Rust build output is usually the real problem

`target/` is both enormous and invisible. On the machine this was written for,
fifteen Rust projects held **119GB** of build output between them, and not one
had been touched in over a month. A single service carried 25GB of `target/`
against 524KB of source. Meanwhile every package cache above added up to about
23GB, so a cleaner that skipped Rust was guarding the wrong fifth of the problem.

It is fully regenerable, but rebuilding is not free, so only directories left
untouched for `DISK_CLEANUP_TARGET_MAX_AGE_DAYS` (30 by default) are cleaned. A
project you are actively building is never disturbed. A directory called
`target/` with no `Cargo.toml` beside it is ignored, because it is not a Rust
build directory.

`--dry-run` lists every project it would clean, with sizes, before anything is
deleted:

```
Rust target/ dirs idle 30+ days:
     25G  /Users/you/Code/example.com/notifications
     18G  /Users/you/Code/example.com/messages-chat
```

### Flutter build output is the same problem

One Flutter app and its fifteen ticket worktrees held about **23GB** of
`build/`, `.dart_tool/` and `ios/build/` between them. Each worktree carried its
own 1.3GB `.dart_tool/`, often next to a much smaller `build/`, so a project
counts as stale only when **both** are idle: `flutter clean` removes both, and a
fresh `.dart_tool/` means the project is in use. A `pubspec.yaml` with no build
output, or a `build/` with no `pubspec.yaml`, is ignored. `ios/Pods` is left
alone (about 330MB per checkout, and `pod install` is slow to redo).

### The one `rm -rf`: Xcode DerivedData

Xcode has no prune command, and every entry under
`~/Library/Developer/Xcode/DerivedData` is a build cache it recreates on the
next build. Entries idle for 30+ days are removed directly. As a guard, the
configured path must end in `DerivedData`; anything else is skipped and logged,
so a bad `DISK_CLEANUP_DERIVED_DATA` cannot aim the delete anywhere else.

### A busy uv cache is skipped, not failed

Long-running `uvx` processes, typically MCP servers such as chroma-mcp or an
AWS MCP proxy, hold the uv cache lock for as long as they run, often days. From
2026-10-20 every run waited uv's default 300s for that lock, gave up, and
logged `FAIL uv cache`, so the job looked broken while uv was never pruned.

uv now waits only `DISK_CLEANUP_UV_LOCK_TIMEOUT` seconds (10 by default). A lock
timeout is logged as `BUSY  uv cache` and does not fail the run or notify; any
other uv error still does. The cache is pruned on the first run after those
processes restart. `uv cache prune --force` would skip the lock, but it can
delete files a running uvx environment still needs, so it is never used.

### A pnpm that cannot start is a warning, not a failure

On 2026-11-10 the `pnpm` on `PATH` was corepack's shim, and corepack 0.23 could
not run pnpm 12 (`Cannot find module ~/.cache/node/corepack/pnpm/12.10.1/bin/pnpm.cjs`),
so the step failed before pnpm did anything. The step now checks that pnpm
starts (`pnpm --version`) and, if not, tries `DISK_CLEANUP_PNPM_FALLBACKS`
(`~/Library/pnpm/pnpm`, `~/.local/share/pnpm/pnpm`). If none starts it logs

```
WARN  pnpm store skipped: /opt/homebrew/bin/pnpm does not start (Error: Cannot find module ...). If it is corepack's shim, update corepack: npm i -g corepack@latest
```

and `RESULT: warnings: pnpm`, without failing the run. A pnpm that starts and
then fails to prune still fails. The machine fix is still to update corepack
(0.36.0 fixed it).

### npx installs

npx installs every package spec it runs, each MCP server version and every
one-off tool, into its own directory under `~/.npm/_npx` and never removes any.
`npm cache clean` does not touch them. 66 entries held 3.6GB here, 48 untouched
for a month. Entries idle `DISK_CLEANUP_TARGET_MAX_AGE_DAYS` (30) are removed
with npm's own `npm cache npx rm`, except any that appear in a running
process's command line (an MCP server started weeks ago is still in use).

### The wpmcp test cache

The wpmcp plugin's local test harness (`bin/test-local.sh` in the wpmcp
checkout) keeps everything under `~/.cache/wpmcp-tests`: WordPress installs
keyed on WordPress, installer and plugin versions (`wp-*-plugins-*`), a per-run
copy of the core for every run (`cores/<hash>-<pid>`), a MariaDB server
(`mariadb/`), per-run configs, locks and notes. It held 19GB on 2026-10-08 and
helped fill the disk again on 2026-11-09.

When the checkout's `bin/test-local.sh` has a `--prune` option, the job runs
that (with `WPMCP_TEST_CACHE` set) and lets the harness decide. Otherwise it
falls back to removing only:

- `wp-*-plugins-*` installs whose `.last-used` is older than
  `DISK_CLEANUP_WPMCP_IDLE_HOURS` (6) and whose `locks/install-<name>` and
  `locks/pristine-<name>` are not held by a live process. A run touches
  `.last-used` on every install it uses and lasts minutes, so an install idle
  for hours is not in use. One with no `.last-used` is left alone.
- `cores/<hash>-<pid>` copies whose PID is no longer running, left by killed
  runs.

`mariadb/`, `configs/`, `locks/` and `notes/` are never touched. Like
DerivedData this is a direct `rm -rf`, so the configured path must end in
`wpmcp-tests`.

### Docker: caches yes, data never

Only the build cache (older than the idle age) and dangling images are pruned.
**Volumes, containers and tagged images are never touched**: volumes hold local
databases, and a stopped container may be a test database someone is about to
restart. A Docker Desktop that is not running is skipped, not failed.

Docker keeps everything in one disk image, and macOS does not always see the
space come back straight away. If `df` has not moved after a prune, Docker
Desktop > Settings > Resources > "Reclaim disk space" returns it.

**Nothing here touches user data.** No Downloads, no Trash, no Documents, no
source files, no Docker volumes. If you want those cleaned, do it by hand, where
you can see what is going.

A target whose tool is not installed is skipped rather than failed, and a
failing pruner does not stop the others.

## When pruning is not enough: the low-space alert

Most of what fills a disk is not safe to prune automatically: local LLM models,
IDE agent data, Docker's disk image, Android emulator images. So instead of
deleting them, the job **reports** them. If free space is still below
`DISK_CLEANUP_CRITICAL_FREE_GB` (15 by default) after a run, it logs the five
largest of `DISK_CLEANUP_REPORT_PATHS` and sends a notification naming the
biggest:

```
2026-10-08 18:00:03 PKT | LOW   only 2GB free after cleanup, below 15GB. Largest paths not pruned automatically:
2026-10-08 18:00:03 PKT | LOW      69GB  /Users/you/Library/Containers/com.docker.docker
2026-10-08 18:00:03 PKT | LOW      40GB  /Users/you/.cache
2026-10-08 18:00:03 PKT | LOW      35GB  /Users/you/.ollama
```

These paths are only ever measured, never pruned. `--dry-run` lists them too.

## What happened on 2026-10-08

The disk filled to **172MB free** while this job was installed and running
every two hours. Two separate failures:

1. **Every pruner but one was skipped.** The script looked tools up with
   `command -v` before widening `PATH`, and launchd starts agents with only
   `/usr/bin:/bin:/usr/sbin:/sbin`. So `uv`, `pnpm`, `npm`, `brew` and `cargo`
   all logged `SKIP (not installed)` on every scheduled run from 25 Sep onward
   (152 runs); only `xcrun` was ever found. Manual runs from a terminal worked,
   which hid it. Fixed by setting `PATH` first, and covered by a test that runs
   the script under launchd's bare `PATH`. `make dry-run-launchd` shows what the
   agent can see.
2. **A run that reclaimed nothing was silent.** The log read `2GB -> 2GB free
   (0GB reclaimed)` and the exit status was 0, so no notification fired. That is
   what the low-space alert above is for.

What was actually using the space, and what was done with it by hand:

| Size | What | Now |
|------|------|-----|
| 23GB | Flutter `build/`, `.dart_tool/`, `ios/build`, `ios/Pods` | Pruned automatically when idle |
| 40GB | `~/.cache` (19GB of WordPress MCP test copies, 11GB uv) | uv pruned; the rest reported |
| 35GB | `~/.ollama` models | Reported |
| 20GB | `~/.gemini` (Antigravity IDE data, three copies) | Reported |
| 6GB | Docker build cache and unused images | Pruned automatically |
| 4.5GB | iOS simulators | Reported (`xcrun simctl erase all` by hand) |

## Not yet automated

[CANDIDATES.md](CANDIDATES.md) is the backlog of remaining space, measured after
the incident: what each area is, what removing it costs, and whether it suits the
scheduled job, the report-only list, or a manual cleanup.

## Testing note: bash 3.2

`bats` runs under `/usr/bin/env bash`, which on macOS is bash 3.2. On bash
before 4.1, a failing `[[ ... ]]` that is not the last line of a test does
**not** fail the test, and `! cmd` never does on any version. Until this was
noticed, most of this suite's `[[ ]]` assertions could not fail. Every `[[ ]]`
assertion now ends in `|| false`, and negative log checks use `not_logged`.
Keep both habits when adding tests.

## Install

```bash
cd disk-cleanup
./install.sh                        # every 2 hours, prune below 40GB free
./install.sh --every 6 --min-free 60
./install.sh --uninstall
```

`--every` must divide 24 evenly, so the schedule does not jump at midnight.

It is a launchd agent rather than a crontab entry because cron skips a job whose
fire time passed while the machine was asleep and never catches up. On a laptop
that sleeps, a two-hourly cron schedule would miss most of its runs. launchd
runs a missed entry once on the next wake.

## Checking on it

```bash
make dry-run   # what it would do right now, changing nothing
make dry-run-launchd   # the same, under the bare PATH the agent gets
make status    # is the agent loaded?
make log       # tail the log
make force     # prune now regardless of free space
make test      # bats suites
```

A run that found nothing to do logs one line:

```
2026-09-14 08:00:01 PKT | OK    67GB free on /System/Volumes/Data, threshold 40GB, nothing to do
```

A run that acted logs each step and the net result:

```
2026-09-14 10:00:01 PKT | cleanup starting, 31GB free is below the 40GB threshold
2026-09-14 10:00:01 PKT | START uv cache: /opt/homebrew/bin/uv cache prune
2026-09-14 10:02:14 PKT | OK    uv cache
2026-09-14 10:02:14 PKT | SKIP  stale sims (not installed)
2026-09-14 10:02:15 PKT | RESULT: 31GB -> 48GB free (17GB reclaimed)
```

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `DISK_CLEANUP_MIN_FREE_GB` | `40` | Prune only below this |
| `DISK_CLEANUP_VOLUME` | `/System/Volumes/Data` | Volume to measure |
| `DISK_CLEANUP_LOG` | `~/Library/Logs/disk-cleanup.log` | Log file |
| `DISK_CLEANUP_CRITICAL_FREE_GB` | `15` | Alert if still below this after a run |
| `DISK_CLEANUP_NOTIFIER` | `/usr/bin/osascript` | Failure and low-space alerts |
| `DISK_CLEANUP_DF` | `df` | How free space is read |
| `DISK_CLEANUP_TARGET_MAX_AGE_DAYS` | `30` | Only clean build output (Rust, Flutter, DerivedData, Docker cache) idle this long |
| `DISK_CLEANUP_CARGO_ROOTS` | `~/Code ~/websites` | Where to look for Rust and Flutter projects |
| `DISK_CLEANUP_CARGO_DEPTH` | `7` | How deep to search for them |
| `DISK_CLEANUP_DERIVED_DATA` | `~/Library/Developer/Xcode/DerivedData` | Must end in `DerivedData` |
| `DISK_CLEANUP_UV_LOCK_TIMEOUT` | `10` | Seconds uv waits for its cache lock before the step is logged as busy |
| `DISK_CLEANUP_PNPM_FALLBACKS` | `~/Library/pnpm/pnpm:~/.local/share/pnpm/pnpm` | Colon separated; tried when the pnpm on `PATH` does not start |
| `DISK_CLEANUP_WPMCP_CACHE` | `~/.cache/wpmcp-tests` | Must end in `wpmcp-tests` |
| `DISK_CLEANUP_WPMCP_REPO` | `~/Code/wpmcppro/wpmcp` | Checkout whose `bin/test-local.sh --prune` is used when present |
| `DISK_CLEANUP_WPMCP_IDLE_HOURS` | `6` | Fallback: remove installs unused this long |
| `DISK_CLEANUP_NPX_DIR` | `~/.npm/_npx` | npx install directory |
| `DISK_CLEANUP_STATE` | `~/Library/Logs/disk-cleanup.state` | Free space at the last run, for the falling-fast check |
| `DISK_CLEANUP_RATE_WINDOW_HOURS` | `6` | Ignore a last-run sample older than this |
| `DISK_CLEANUP_LOCK` | `~/Library/Logs/disk-cleanup.lock` | One run at a time |
| `DISK_CLEANUP_REPORT_PATHS` | `~/.ollama`, `~/.cache`, `~/.gemini`, Docker's container, simulators, `~/Library/Android`, `~/Downloads` | Colon separated; measured, never pruned |
| `DISK_CLEANUP_UV` / `_PNPM` / `_NPM` / `_BREW` / `_XCRUN` / `_CARGO` / `_FLUTTER` / `_DOCKER` | from `PATH` | Tool locations |

The installer bakes `DISK_CLEANUP_MIN_FREE_GB` into the agent's environment, so
changing the threshold means reinstalling rather than editing the plist.

Every path being injectable is what lets the suite supply a fake `df` and fake
pruners, so the tests assert on thresholds and failure handling without reading
the real disk or deleting anything.

## Notes

- **The threshold is compared with `>=`.** Exactly 40GB free does not prune;
  39GB does.
- **`brew cleanup` also runs daily** in [brew-upgrade](../brew-upgrade). The
  overlap is harmless, and it means a disk filling fast still gets swept every
  two hours rather than once a day.
- **pnpm through an old corepack breaks on pnpm 12.** Corepack 0.23 looks for
  `bin/pnpm.cjs`, which pnpm 12 no longer ships, so every `pnpm` call (this
  job's included) crashed with `Cannot find module`. The machine fix is
  `npm i -g corepack@latest` (0.36.0 fixed it on 2026-11-10); the job now
  logs a warning instead of failing if it happens again.
- **Failure alerts need a logged-in GUI session.** At the login window the
  notification is dropped and the log is the only record. The exit status is
  still 1.
