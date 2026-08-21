# Dev Diary

A Claude Code `Stop` hook that records what actually happened in a session:
a prose lead, the files changed, the commands run, the decisions taken, and the
follow-ups left behind.

It is the factual counterpart to [Captain's Log](../captains-log). Captain's Log
tells the story; Dev Diary is what you consult when you need to know what was
really done on a given date.

---

## Why it is trustworthy

The split matters. **Files changed and commands run are extracted mechanically
from the session transcript**, never written by a model, so they cannot be
hallucinated or quietly rounded off. Only the interpretive parts — the prose
lead, the decisions, the follow-ups — come from `claude -p`, and they are
generated from a prompt built out of those same extracted facts.

If the diary says a file was touched, it was touched.

---

## Setup

### Install as a plugin (recommended)

```
/plugin marketplace add fahdi/my-claude-tools
/plugin install dev-diary@my-claude-tools
```

That is the whole install. The hook creates and git-initialises the diary at
`~/Code/devdiary` the first time a session earns an entry.

To back it up, add a remote yourself once the diary exists:

```bash
gh repo create devdiary --private --source ~/Code/devdiary --remote=origin --push
```

The hook pushes on every entry when an `origin` remote exists, and stays local
when it does not.

### Running alongside Captain's Log

The two are designed to run together as two `Stop` hooks in the same session,
and installing both plugins is the supported arrangement. They take separate
locks and write to separate diaries, so neither blocks the other.

---

## How it works

1. The `Stop` hook fires when a session ends and reads the transcript JSONL.
2. `diary.py facts` extracts the hard facts mechanically: tool count, files
   changed, commands run.
3. Sessions with fewer than 2 tool uses are skipped — no real work, no entry.
4. `diary.py plan` compares against recent entries and decides whether to write
   a full entry, a supplemental one, or nothing at all.
5. `claude -p` writes only the interpretive sections, from a prompt containing
   the extracted facts.
6. `diary.py render` assembles the entry, appends it to `YYYY-MM-DD.md`, and
   updates the README index.
7. The diary is committed, and pushed when a remote exists.

A lock directory at `/tmp/dev-diary-lock` stops the inner `claude -p` call from
re-triggering the hook. It is a directory because `mkdir` is atomic, so two
`Stop` hooks firing together cannot both take it. A lock older than 90 seconds
is treated as stale, since the hook's own 60-second timeout can kill a run
before its cleanup trap fires.

---

## Configuration

| Variable | Default | Effect |
|----------|---------|--------|
| `DEV_DIARY_DIR` | `~/Code/devdiary` | Where the diary lives |

A `.local-diary` file in the project directory, or any directory above it,
silences the global diary for that project. A project-local hook that sets
`DEV_DIARY_DIR` explicitly is unaffected, so the same script can serve
per-project diaries.

---

## Files

```
dev-diary/
├── .claude-plugin/
│   └── plugin.json     # Plugin manifest
├── README.md           # This file
├── Makefile            # make test / make validate
├── hooks/
│   ├── hooks.json      # Stop hook registration
│   ├── dev-diary.sh    # The hook — orchestrates the five steps above
│   └── diary.py        # facts / plan / render
└── tests/
    └── test_diary.py   # pytest suite over the planning decisions
```

---

## Requirements

- Claude Code ≥ 2.0
- `git`
- Python 3 — `python3`, `python`, or the `py -3` launcher; the hook probes for
  whichever is a real interpreter

### Platforms

macOS, Linux, WSL, and native Windows. On native Windows you need
[Git for Windows](https://git-scm.com/downloads/win); see
[docs/windows.md](../docs/windows.md).

---

## Tests

```bash
make test
```

The plan step is where an entry gets silently dropped, so that is the part the
suite pins.

---

## License

MIT
