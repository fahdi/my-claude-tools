# brew-upgrade

A nightly cron job that keeps Homebrew formulae current, logs every run, and
raises a macOS notification only when something fails.

Homebrew drifts quietly. You notice months later when a `brew install` drags in
a dependency bump that breaks a running service. This keeps the drift to a day
at a time, and leaves a log you can read when a morning starts badly.

---

## What it runs

```
brew update
brew upgrade            # formulae only
brew cleanup --prune=all
```

Each step runs even if an earlier one failed, so one broken formula does not
block cleanup. The exit status is 0 only when every step succeeded.

**Casks are deliberately excluded.** Upgrading a cask can force-quit a running
GUI app, and some casks prompt for a sudo password that cron cannot supply.
Those stay a manual `brew upgrade --cask` when you are at the keyboard.

## Install

```bash
cd brew-upgrade
./install.sh                          # daily at 04:00
./install.sh --schedule '0 4 * * 0'   # or weekly, Sunday 04:00
./install.sh --uninstall
```

The crontab entry points at `bin/brew-upgrade.sh` inside this checkout, so a
`git pull` updates the job with no reinstall. The entry is tagged with a marker
comment, which is how the installer stays idempotent and how `--uninstall`
finds it. Your other crontab lines are left untouched.

## Before you pick an hour

Upgrading a formula that runs as a brew service restarts that service:

```bash
brew services list
```

If `postgresql@16`, `php`, `mysql` or `mailpit` are started, an upgrade will
bounce them mid-run. Pick an hour you are reliably not working. 04:00 is the
default for that reason.

## Checking on it

```bash
make dry-run   # print the steps, change nothing
make log       # tail the last 50 lines
make test      # bats suite
make lint      # shellcheck
crontab -l | grep brew-upgrade
```

A run appends a block like:

```
2026-09-14 04:00:01 PKT | ==============================================================
2026-09-14 04:00:01 PKT | brew maintenance run starting
2026-09-14 04:00:01 PKT | START brew update: /opt/homebrew/bin/brew update
2026-09-14 04:00:14 PKT | OK    brew update
2026-09-14 04:00:14 PKT | START brew upgrade: /opt/homebrew/bin/brew upgrade
2026-09-14 04:03:52 PKT | FAIL  brew upgrade (exit 1)
2026-09-14 04:03:55 PKT | RESULT: failed steps: upgrade
```

The log lives at `~/Library/Logs/brew-upgrade.log` and rotates to `.1` past
5 MiB.

## Failure notifications

A failed run fires a macOS notification through `osascript`. That needs a
logged-in GUI session: if the Mac is sitting at the login window when cron
fires, the notification is dropped and the log is the only record. The exit
status is still 1, so wrapping the job in something that watches exit codes
works if you want a stronger guarantee.

## Configuration

Every path is an environment variable, which is also how the tests point the
script at a fake brew:

| Variable | Default | Purpose |
|----------|---------|---------|
| `BREW_UPGRADE_BREW` | `$(command -v brew)` | Path to the brew binary |
| `BREW_UPGRADE_LOG` | `~/Library/Logs/brew-upgrade.log` | Log file |
| `BREW_UPGRADE_MAX_LOG_BYTES` | `5242880` | Rotate past this size |
| `BREW_UPGRADE_NOTIFIER` | `/usr/bin/osascript` | Failure alert binary |
| `BREW_UPGRADE_CLEANUP` | `1` | Set to `0` to skip cleanup |
| `BREW_UPGRADE_SCHEDULE` | `0 4 * * *` | Installer default schedule |

## Notes for anyone cloning this

Two details cost me time and are worth stating plainly:

1. **cron gives you almost no `PATH`.** brew shells out to git and curl, so the
   script rebuilds a usable `PATH` before doing anything. A job that works in
   your terminal and fails under cron is usually this.
2. **`$?` after `if cmd; then ... fi` is 0, not the command's status.** An `if`
   whose condition fails and which has no `else` exits 0. The first cut of this
   script read `$?` there, logged every failure as "exit 0" and reported
   "all steps succeeded" while a step had failed. `tests/test_brew_upgrade.bats`
   pins that behaviour so it cannot come back.
