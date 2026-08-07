# my-claude-tools

My complete Claude Code setup: the tools I built, the plugins I run, the hooks that
automate my sessions, and a guide to how I actually work with Claude day to day.

This is not a dotfiles dump. It is a working system that has shipped real projects
(a crypto forecasting service, a transcription suite, WordPress plugins, marketing
sites) and the documentation explains why each piece exists, not just how to install it.

---

## Start here

| Doc | What it covers |
|-----|----------------|
| [docs/how-i-work.md](./docs/how-i-work.md) | The philosophy: plan-first collaboration, TDD slices, memory strategy, token economy, and the writing rules I hold Claude to |
| [docs/stack.md](./docs/stack.md) | The full inventory: every plugin, skill, hook, MCP server, and CLI tool in my setup, with sources and install pointers |
| [config/settings.example.json](./config/settings.example.json) | A sanitized copy of my `~/.claude/settings.json` showing how the hooks and plugins wire together |

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
entries via `/log`. Comes with a full pytest + bats test suite.

→ [Setup guide](./captains-log/README.md)

Its factual counterpart, **Dev Diary**, runs as a second `Stop` hook in the same
session: prose lead, files changed, commands run, decisions, follow-ups. The files
changed and commands run are extracted mechanically from the transcript, so they are
ground truth rather than LLM guesses. See [docs/how-i-work.md](./docs/how-i-work.md#the-record)
for how the two fit together.

---

## Contributing

PRs welcome. Each tool lives in its own directory with a `README.md` and `install.sh`.
