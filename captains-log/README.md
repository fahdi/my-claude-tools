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

### 1. Install

```bash
git clone https://github.com/fahdi/my-claude-tools
cd my-claude-tools/captains-log
./install.sh
```

The installer will:
- Create your diary repo at `~/Code/captains-log` (configurable)
- Add the Stop hook to `~/.claude/settings.json`
- Install the `/log` command to `~/.claude/commands/`
- Initialize a git repo for your diary and push to GitHub (optional)

### 2. Configure (optional)

Set `CAPTAINS_LOG_DIR` in your environment to use a custom diary path:

```bash
export CAPTAINS_LOG_DIR="$HOME/Documents/my-dev-log"
```

---

## How it works

1. **Stop hook** (`hooks/log-session.sh`) fires when any Claude Code session ends
2. Reads the session transcript JSONL from Claude Code's session directory
3. Counts tool uses — sessions with fewer than 2 are skipped (no real work = no entry)
4. Calls `claude -p` to generate a Picard-narrated summary
5. Appends to `DIARY_DIR/YYYY-MM-DD.md` and updates `README.md` with a reverse-chronological link
6. Commits and pushes automatically

A lockfile at `/tmp/captains-log-global` prevents the inner `claude -p` call from triggering another log entry (infinite loop guard).

**Stardate formula**: `(year − 1966) × 1000 + (day_of_year ÷ 366 × 1000)`  
Today's stardate: ~60478

---

## Manual logging

Type `/log` in any Claude Code session to trigger an entry on demand. Useful for mid-session milestones or when you want to narrate before exiting.

---

## Files

```
captains-log/
├── README.md          # This file
├── install.sh         # One-command installer
├── hooks/
│   └── log-session.sh # Stop hook — runs on session exit
└── commands/
    └── log.md         # /log command definition
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
