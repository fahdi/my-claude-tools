# my-claude-tools

My complete Claude Code setup: the tools I built, the plugins I run, the hooks that
automate my sessions, and a guide to how I actually work with Claude day to day.

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

## Tools in this repo

### [Captain's Log](./captains-log)

Automatically narrates every Claude Code session in the voice of Captain Jean-Luc
Picard and commits it to a private GitHub diary.

> *"Captain's Log, Stardate 60478.1. We have brought a new authentication system online following a prolonged engagement with an OAuth provider whose documentation proved... resistant to interpretation. The crew performed admirably under pressure."*

Every session that does real work gets logged on exit via a `Stop` hook. Manual
entries via `/captains-log:log`. Comes with a full pytest + bats test suite.

→ [Setup guide](./captains-log/README.md)

Its factual counterpart, **Dev Diary**, runs as a second `Stop` hook in the same
session: prose lead, files changed, commands run, decisions, follow-ups. The files
changed and commands run are extracted mechanically from the transcript, so they are
ground truth rather than LLM guesses. See [docs/how-i-work.md](./docs/how-i-work.md#the-record)
for how the two fit together.

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
└── docs/                  # How I work, full stack inventory
```

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
