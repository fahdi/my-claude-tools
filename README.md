# my-claude-tools

Two things in one repo:

1. **A Claude Code plugin marketplace** — the tools I built, packaged so that any
   Claude pointed at this repo can install them in two lines.
2. **A written account of my whole setup** — every plugin, skill, hook, MCP server
   and CLI tool I run, and why each one earns its place.

The second is much larger than the first, and the two are not the same set. Most of
what [docs/stack.md](./docs/stack.md) describes is installed from somewhere else or
is specific to my machine; what actually ships here is the one plugin in the table
below. That gap is deliberate, and marked everywhere it matters, so you always know
whether a thing is installable or merely documented.

This is not a dotfiles dump. It is a working system that has shipped real projects
(a crypto forecasting service, a transcription suite, WordPress plugins, marketing
sites) and the documentation explains why each piece exists, not just how to install it.

---

## Install the tools

This repo is a Claude Code **plugin marketplace**. Point any Claude at it and the
tools install themselves — no cloning, no scripts, no editing `settings.json`.

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

| Plugin | Installs | What you get |
|--------|----------|--------------|
| `captains-log` | `/plugin install captains-log@my-claude-tools` | A `Stop` hook that narrates each session as Picard, plus the `/captains-log:log` command |

Each plugin still ships its own `install.sh` for people who would rather wire it
in by hand. Use one path or the other, not both — see the plugin's README.

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

One, so far.

### [Captain's Log](./captains-log)

Automatically narrates every Claude Code session in the voice of Captain Jean-Luc
Picard and commits it to a private GitHub diary.

> *"Captain's Log, Stardate 60478.1. We have brought a new authentication system online following a prolonged engagement with an OAuth provider whose documentation proved... resistant to interpretation. The crew performed admirably under pressure."*

Every session that does real work gets logged on exit via a `Stop` hook. Manual
entries via `/captains-log:log`. Comes with a full pytest + bats test suite.

→ [Setup guide](./captains-log/README.md)

---

## Documented here, but not shipped here

`docs/stack.md` inventories my full setup. Most of it is not in this repo, for one
of three reasons: it belongs to somebody else, it is too entangled with my machine
to be useful to you, or it has not been packaged yet. Nothing below is installable
from this marketplace.

| Thing | Where it actually is | Why it is not here |
|-------|----------------------|--------------------|
| **Dev Diary** | Source lives in my private diary repo at `~/Code/devdiary/scripts/` | Not packaged yet. This is the next thing on the list — see [Roadmap](#roadmap). |
| **The skills library** (~59 skills: SEO, design, a11y, React) | `~/.claude/skills/` | A mix of third-party skills and client-specific work. Sources are listed in [docs/stack.md](./docs/stack.md#skills). |
| **GSD lifecycle hooks** | `npm install -g get-shit-done-cc` | Someone else's project. |
| **RTK** (shell-command token proxy) | `brew install rtk` | Someone else's project. |
| **claude-mem, superpowers, and the other plugins** | Their own marketplaces | Install pointers are in [docs/stack.md](./docs/stack.md#plugins). |
| **`statusline.sh`** | `~/.claude/statusline.sh` | Personal, and shown in [config/settings.example.json](./config/settings.example.json). |

**Dev Diary** is worth a word since it is referenced throughout the docs: it is the
factual counterpart to Captain's Log, running as a second `Stop` hook in the same
session. Prose lead, files changed, commands run, decisions, follow-ups — with the
files and commands extracted mechanically from the transcript, so they are ground
truth rather than LLM guesses. See
[docs/how-i-work.md](./docs/how-i-work.md#the-record) for how the two fit together.

## Roadmap

- Package **Dev Diary** as a second plugin in this marketplace, with the same
  cross-platform treatment Captain's Log got.
- Extract whichever of my standalone skills are general enough to be useful to
  someone who is not me, and ship them as a skills plugin.

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
├── config/                # Sanitized settings.json reference
└── docs/                  # How I work, full stack inventory, Windows setup
```

**Why is there no top-level `skills/`, `agents/`, or `hooks/` directory?** Because
those are *per-plugin* directories, not repo-level ones. Claude Code discovers
components inside each plugin folder, which is why the command and hook above live
at `captains-log/commands/` and `captains-log/hooks/`. `captains-log` happens to
ship no skills and no agents, so those two directories simply do not exist yet. A
plugin that needed them would add them under its own folder — never at the root.

Likewise there is only one tool directory because only one tool is packaged. Adding
a second means adding a sibling of `captains-log/`, built the same way.

## Contributing

PRs welcome. Each tool is a self-contained Claude Code plugin:

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
