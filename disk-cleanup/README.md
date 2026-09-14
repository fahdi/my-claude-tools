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

## What it prunes

| Target | Command | Why it is safe |
|--------|---------|----------------|
| uv cache | `uv cache prune` | Removes wheels no environment references |
| pnpm store | `pnpm store prune` | Removes packages no project references |
| npm cache | `npm cache clean --force` | Fully regenerable |
| Homebrew | `brew cleanup --prune=all` | Old versions and downloads |
| iOS simulators | `xcrun simctl delete unavailable` | Simulators for SDKs you no longer have |

**Every target uses its own tool's prune command, never `rm -rf`.** That
distinction is not stylistic. `~/Library/pnpm/store` is a content-addressable
store that every project's `node_modules` hard-links into, and `~/.cache/uv`
works the same way, so deleting either directory outright breaks existing
checkouts instead of safely freeing space. `prune` removes only what nothing
references.

**Nothing here touches user data.** No Downloads, no Trash, no Documents, no
project directories. If you want those cleaned, do it by hand, where you can see
what is going.

A target whose tool is not installed is skipped rather than failed, and a
failing pruner does not stop the others.

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
| `DISK_CLEANUP_NOTIFIER` | `/usr/bin/osascript` | Failure alerts |
| `DISK_CLEANUP_DF` | `df` | How free space is read |
| `DISK_CLEANUP_UV` / `_PNPM` / `_NPM` / `_BREW` / `_XCRUN` | from `PATH` | Tool locations |

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
- **Failure alerts need a logged-in GUI session.** At the login window the
  notification is dropped and the log is the only record. The exit status is
  still 1.
