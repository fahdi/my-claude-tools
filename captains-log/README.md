# Captain's Log

A Claude Code Stop hook that automatically writes a developer diary in the voice of Captain Jean-Luc Picard.

Every session that does real work (≥2 tool uses) gets a log entry when you exit. Manual entries available via the `/log` command.

---

## What it looks like

```
# Captain's Log — 2026-06-24

---

*Logged at 21:34*

Captain's Log, Stardate 60478.1. Following an extended engagement with a
failing authentication service, we have restored full operational capability
to the user registration system. The root cause — a misconfigured JWT
expiry window — was identified through careful forensic analysis of the
server logs. Lieutenant Commander Bash performed admirably under pressure.

We have additionally hardened the deployment pipeline against future
incidents of this nature, introducing a health check that will alert the
crew before any single point of failure propagates to the wider system.

The mission continues. There is still much to do.
```

---

## Setup

### Install as a plugin (recommended)

From inside Claude Code:

```
/plugin marketplace add fahdi/my-claude-tools
/plugin install captains-log@my-claude-tools
```

Or from a shell:

```bash
claude plugin marketplace add fahdi/my-claude-tools
claude plugin install captains-log@my-claude-tools
```

That is the whole install. The plugin registers the `Stop` hook and the
`/captains-log:log` command, and the hook creates and git-initialises your diary
at `~/Code/captains-log` the first time a session earns an entry. Nothing is
copied into `~/.claude/` and nothing is written into your `settings.json` hooks
block.

The plugin does not create a GitHub remote for you. Once the diary exists, add
one yourself if you want it backed up:

```bash
gh repo create captains-log --private --source ~/Code/captains-log --remote=origin --push
```

The hook pushes on every entry when an `origin` remote exists, and stays local
when it does not.

### Install with the script (alternative)

`install.sh` predates the plugin packaging and still works. It copies the hook
into your diary directory, writes the `Stop` hook into `~/.claude/settings.json`,
installs `/log` into `~/.claude/commands/`, and offers to create the private
GitHub repo for you:

```bash
git clone https://github.com/fahdi/my-claude-tools
cd my-claude-tools/captains-log
./install.sh
```

**Pick one or the other.** Running both gives you two `Stop` hooks pointing at
the same diary, which means two entries per session.

### Configure (optional)

Set `CAPTAINS_LOG_DIR` in your environment to use a custom diary path:

```bash
export CAPTAINS_LOG_DIR="$HOME/Documents/my-dev-log"
```

`DIARY_DIR` is also honoured and takes precedence when both are set.

---

## How it works

1. **Stop hook** (`hooks/log-session.sh`) fires when any Claude Code session ends
2. Reads the session transcript JSONL from Claude Code's session directory
3. Counts tool uses — sessions with fewer than 2 are skipped (no real work = no entry)
4. Calls `claude -p` to generate a Picard-narrated summary
5. Appends to `DIARY_DIR/YYYY-MM-DD.md` and updates `README.md` with a reverse-chronological link
6. Commits and pushes automatically

A lock directory at `/tmp/captains-log-lock` prevents the inner `claude -p` call from triggering another log entry (infinite loop guard). It is a directory rather than a file because `mkdir` is atomic, so two Stop hooks firing at once cannot both take it. A lock older than 90 seconds is treated as stale and reclaimed, since the hook's own 60-second timeout can kill a run before its cleanup trap fires.

**Stardate formula**: `(year − 1966) × 1000 + (day_of_year ÷ 366 × 1000)`  
Today's stardate: ~60478

---

## Manual logging

Type `/captains-log:log` in any Claude Code session to trigger an entry on demand (the script installer registers it as plain `/log`). Useful for mid-session milestones or when you want to narrate before exiting.

---

## Files

```
captains-log/
├── .claude-plugin/
│   └── plugin.json         # Plugin manifest
├── README.md               # This file
├── install.sh              # Standalone installer (alternative to the plugin)
├── Makefile                # make test / make validate
├── hooks/
│   ├── hooks.json          # Stop hook registration for the plugin
│   ├── log-session.sh      # Stop hook — runs on session exit
│   └── parse_transcript.py # Transcript parser the hook shells out to
├── commands/
│   └── log.md              # /captains-log:log command definition
└── tests/                  # pytest + bats suites
```

---

## Requirements

- Claude Code ≥ 2.0
- Python 3 (for transcript parsing)
- `gh` CLI (optional, for diary repo creation)
- `git` with a configured remote for your diary

---

## License

MIT
