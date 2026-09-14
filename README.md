# my-claude-tools

Two things in one repo:

1. **A Claude Code plugin marketplace** — the tools I built, packaged so that any
   Claude pointed at this repo can install them in two lines.
2. **A written account of my whole setup** — every plugin, skill, hook, MCP server
   and CLI tool I run, and why each one earns its place.

Anything I built that belongs in a plugin is packaged as one. Anything that is a
skill is packaged as a skill. Everything third-party is documented *and* installed
for you by [`scripts/bootstrap.sh`](./scripts/bootstrap.sh), so a fresh machine
reaches a known-good state in one command rather than a checklist.

This is not a dotfiles dump. It is a working system that has shipped real projects
(a crypto forecasting service, a transcription suite, WordPress plugins, marketing
sites) and the documentation explains why each piece exists, not just how to install it.

---

## Install the tools

This repo is a Claude Code **plugin marketplace**. Point any Claude at it and the
tools install themselves — no cloning, no scripts, no editing `settings.json`.

### Everything at once

```bash
git clone https://github.com/fahdi/my-claude-tools
cd my-claude-tools
./scripts/bootstrap.sh
```

That adds the marketplaces, installs all three plugins here plus the eight
third-party ones I run, registers the context7 MCP server, and installs the CLI
tools they depend on. Every step is idempotent, so running it again on a
half-configured machine finishes the job instead of starting over. `--dry-run`
prints the plan without touching anything; `--skip-cli` leaves Homebrew alone;
`--no-captains-log` skips the Picard diary.

**Dev Diary is the one to keep everywhere; Captain's Log is the one you turn on
where you want it.** The factual record earns its place on every project. The
Picard narration earns its place on the projects you are enjoying. Either can be
switched at any time with `/plugin disable captains-log` and `/plugin enable
captains-log`, so the choice at install time is not binding.

### Just the plugins from this repo

From inside Claude Code:

```
/plugin marketplace add fahdi/my-claude-tools
/plugin install captains-log@my-claude-tools
```

| Plugin | What you get |
|--------|--------------|
| [`captains-log`](./captains-log) | A `Stop` hook that narrates each session as Picard, plus the `/captains-log:log` command. Optional — see below |
| [`dev-diary`](./dev-diary) | A `Stop` hook that records the facts: files changed and commands run, extracted mechanically from the transcript |
| [`claude-workflows`](./claude-workflows) | The `software-factory` skill: four approval gates before implementation code exists |

Captain's Log also ships an `install.sh` for wiring it in by hand. Use one path
or the other, not both — see its README.

Works on macOS, Linux, WSL, and native Windows. Windows needs
[Git for Windows](https://git-scm.com/downloads/win), which is also what lets
Claude Code use its own Bash tool — see [docs/windows.md](./docs/windows.md).

---

## Start here

| Doc | What it covers |
|-----|----------------|
| [docs/how-i-work.md](./docs/how-i-work.md) | The philosophy: plan-first collaboration, TDD slices, memory strategy, token economy, and the writing rules I hold Claude to |
| [docs/stack.md](./docs/stack.md) | The full inventory: every plugin, skill, hook, MCP server, and CLI tool in my setup, with sources and install pointers |
| [config/settings.example.json](./config/settings.example.json) | A sanitized copy of my `~/.claude/settings.json` showing how the hooks and plugins wire together |
| [docs/windows.md](./docs/windows.md) | Step-by-step setup on native Windows, and what to check when a hook stays silent |

## The system in five lines

1. **Plan before code.** Claude is a senior peer, not an autocomplete. We align on approach, surface the decisions, then implement.
2. **Small slices, test-first.** Every feature lands as a TDD slice with its own issue, its own tests, and its own release.
3. **Everything leaves a trail.** Two `Stop` hooks journal every session: one narrates it as Captain Picard, one records the cold facts.
4. **Memory is infrastructure.** claude-mem observations plus a curated memory directory mean sessions build on each other instead of starting over.
5. **Tokens are a budget.** RTK proxies shell commands (60-90% savings), claude-mem compresses recall, and skills load on demand.

## Tools that ship here

### [Captain's Log](./captains-log)

Automatically narrates every Claude Code session in the voice of Captain Jean-Luc
Picard and commits it to a private GitHub diary.

> *"Captain's Log, Stardate 60478.1. We have brought a new authentication system online following a prolonged engagement with an OAuth provider whose documentation proved... resistant to interpretation. The crew performed admirably under pressure."*

Every session that does real work gets logged on exit via a `Stop` hook. Manual
entries via `/captains-log:log`. Comes with a full pytest + bats test suite.

→ [Setup guide](./captains-log/README.md)

### [Dev Diary](./dev-diary)

The factual counterpart. A prose lead, the files changed, the commands run, the
decisions taken, and the follow-ups left behind.

The split is the point: **files changed and commands run are extracted
mechanically from the transcript**, never written by a model, so they cannot be
hallucinated. Only the interpretive parts come from `claude -p`. When I need to
know what actually happened on a date, this is the source of truth.

The two are designed to run together as two `Stop` hooks in one session.
Narrative for humans, facts for audits.

→ [Setup guide](./dev-diary/README.md)

### [Claude Workflows](./claude-workflows)

Process skills. Currently one: `software-factory`, a four-gate feature workflow
that forces every important decision before implementation code exists, when
changing it still costs a sentence instead of a rewrite. The methodology is
[Dex Horthy's](https://github.com/humanlayer) at HumanLayer; the skill file is a
write-up of it for Claude Code.

→ [Setup guide](./claude-workflows/README.md)

### [Statusline](./statusline)

My statusline, owned by this repo, with a segment that reports whether every tool
in the setup is actually installed and correctly wired.

```
🔧 log ✔  diary ✔  rtk ✔0.45  gh ✔2.97  gsd ⚠  mem ✔
   8 plugins · 59 skills · 37 agents · 5 mcp
```

Green means found *and* wired; yellow means inconsistent (a `Stop` hook pointing
at a deleted script, a plugin on disk but disabled, a `gh` on `PATH` but logged
out); red means gone. `tool-status.sh --full` prints every absolute path.
Profile-aware, since `~/.claude` and `~/.claude-personal` hold different halves
of the setup. `~/.claude/statusline.sh` becomes a symlink into the repo, so edits
here are live in the next session.

→ [Setup guide](./statusline/README.md)

---

### [brew-upgrade](./brew-upgrade)

A nightly cron job that keeps Homebrew formulae current, logs every run, and
raises a notification only when something fails.

```
launchd agent, daily at 04:00   # brew update, brew upgrade, brew cleanup
```

Casks are deliberately excluded: upgrading one can force-quit a running GUI app,
and some need a sudo password a scheduled job cannot supply. Every step runs even
if an earlier one failed, so a single broken formula does not block cleanup, and
the exit status is 0 only when all of them succeeded. The agent points at this
checkout, so a `git pull` updates the job with no reinstall.

It is a launchd agent rather than a crontab entry because cron never runs a job
whose time passed while the Mac was asleep and never catches up, which on a
laptop means a 04:00 entry can go months without firing and fail silently.
`--cron` is still available for machines that stay awake.

Not a plugin: it ships no hooks, commands or skills, and nothing about it runs
inside Claude Code.

→ [Setup guide](./brew-upgrade/README.md)


### [disk-cleanup](./disk-cleanup)

A launchd agent that reclaims disk space every two hours, and does nothing at
all until space is actually scarce.

```
2026-09-14 08:00 | OK  67GB free, threshold 40GB, nothing to do
```

The guard is the design. These caches exist because re-downloading their
contents is slow, so pruning them on a healthy disk costs bandwidth and build
time and buys nothing. Below the threshold it prunes uv, pnpm, npm, Homebrew and
unavailable iOS simulators, each with that tool's own prune command rather than
`rm -rf`: `~/Library/pnpm/store` and `~/.cache/uv` are content-addressable
stores that projects hard-link into, so deleting them outright breaks existing
checkouts instead of freeing space. Nothing it touches is user data.

Not a plugin, for the same reason as the two above.

→ [Setup guide](./disk-cleanup/README.md)


## Documented here, but not shipped here

These are somebody else's work, so this repo documents and installs them rather
than vendoring them. `bootstrap.sh` handles all of it.

| Thing | Source | Installed by bootstrap |
|-------|--------|------------------------|
| **superpowers, plugin-dev, claude-code-setup, frontend-design, chrome-devtools-mcp, playwright, rust-analyzer-lsp** | `anthropics/claude-plugins-official` | Yes |
| **claude-mem** | `thedotmack/claude-mem` | Yes |
| **context7 MCP server** | `mcp.context7.com` | Yes |
| **RTK** (shell-command token proxy) | `brew install rtk` | Yes, unless `--skip-cli` |
| **bats-core, pytest** (test runners) | Homebrew / uv | Yes, unless `--skip-cli` |
| **GSD** (`get-shit-done-cc`) | npm | No — see [docs/stack.md](./docs/stack.md#gsd-get-shit-done-archive) |

Not everything in [docs/stack.md](./docs/stack.md) is on any one machine. That
document is an inventory of a working setup over time, including a large skills
library that lives elsewhere; it marks what is current. This repo is the part you
can install.

---

## Repo layout

```
my-claude-tools/
├── .claude-plugin/
│   └── marketplace.json   # Marketplace manifest — lists every plugin here
├── captains-log/          # Plugin: Picard-voiced session diary
│   ├── .claude-plugin/plugin.json
│   ├── commands/          # Slash commands
│   ├── hooks/             # hooks.json + hook scripts
│   ├── tests/             # pytest + bats
│   └── install.sh         # Standalone install path
├── dev-diary/             # Plugin: the factual session record
│   ├── .claude-plugin/plugin.json
│   ├── hooks/             # hooks.json + hook script + diary.py
│   └── tests/             # pytest
├── claude-workflows/      # Plugin: process skills
│   ├── .claude-plugin/plugin.json
│   └── skills/
│       └── software-factory/SKILL.md
├── statusline/            # Tool: the statusline and its tool-status segment
│   ├── bin/               # statusline.sh + tool-status.sh
│   ├── config/            # tools.conf: what tool-status probes
│   ├── tests/             # bats
│   └── install.sh         # Symlinks ~/.claude/statusline.sh here
├── brew-upgrade/          # Tool: nightly Homebrew maintenance
│   ├── bin/               # brew-upgrade.sh
│   ├── tests/             # bats: the script, and the installer
│   └── install.sh         # Installs the launchd agent (or a crontab entry)
├── disk-cleanup/          # Tool: threshold-guarded cache pruning
│   ├── bin/               # disk-cleanup.sh
│   ├── tests/             # bats: the script, and the installer
│   └── install.sh         # Installs the launchd agent
├── scripts/
│   └── bootstrap.sh       # One-command setup for everything, including 3rd party
├── config/                # A settings.json you can actually copy
└── docs/                  # How I work, stack inventory, Windows setup
```

**Why is there no top-level `skills/`, `agents/`, or `hooks/` directory?** Because
those are *per-plugin* directories, not repo-level ones. Claude Code discovers
components inside each plugin folder, which is why the command and hook above live
at `captains-log/commands/` and `captains-log/hooks/`. `captains-log` happens to
ship no skills and no agents, so those two directories simply do not exist yet. A
plugin that needed them would add them under its own folder — never at the root.

`claude-workflows/` is the counter-example that makes the rule concrete: it ships a
skill and no hook, so it has `skills/` and no `hooks/`. `dev-diary/` is the reverse.
Each plugin carries exactly the directories it needs.

## Contributing

PRs welcome. Most tools here are self-contained Claude Code plugins. Two are not:
`statusline/`, `brew-upgrade/` and `disk-cleanup/` ship no hooks, commands or
skills and never run inside Claude Code, so they stay plain directories with
their own `install.sh` and stay out of `marketplace.json`. Package a new tool as a plugin when it has
components Claude Code can discover, and as a plain directory when it does not.

For a plugin:

1. Create `<tool-name>/.claude-plugin/plugin.json` with `name`, `version`, and `description`.
2. Put components in the conventional directories — `commands/`, `agents/`,
   `skills/`, `hooks/hooks.json`. Reference your own files with
   `${CLAUDE_PLUGIN_ROOT}`, never a hardcoded or `~`-relative path.
3. Add an entry to `.claude-plugin/marketplace.json`.
4. Add a `README.md` and, ideally, tests.
5. Validate before opening the PR:

```bash
claude plugin validate . --strict              # marketplace manifest
claude plugin validate ./<tool-name> --strict  # plugin manifest + hooks
```
