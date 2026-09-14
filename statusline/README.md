# statusline

My Claude Code statusline, owned by this repo, with a segment that answers the
question the bar never could: **are my tools actually installed, and where?**

```
Opus 5 │ ✍️ 26% │ my-claude-tools (main*) │ ⏱ 54m │ ◑ default │ 👤 Fahad

current ○○○○○○○○○○   4% ⟳ 3:30pm
weekly  ●●○○○○○○○○  28% ⟳ aug 24, 11:00am

🔧 log ✔  diary ✔  rtk ✔0.45  gh ✔2.97  gsd ⚠  mem ✔
   8 plugins · 59 skills · 37 agents · 5 mcp
```

The first two blocks are the statusline I already ran (model, context, repo,
session, effort, account, rate limits). The third block is new.

## Why

My tools are wired in from four different places: `Stop` hooks pointing at
scripts in other repos, a Homebrew binary behind a `PreToolUse` hook, a plugin
from a marketplace, a framework installed by npm. Any of them can go missing
without Claude Code saying a word, because a hook whose script has been deleted
fails silently on session exit.

So the segment does not report "is it installed". It reports **is it consistent**:

| State | Meaning |
|-------|---------|
| `✔` green | Found, and wired the way it is supposed to be |
| `⚠` amber | Inconsistent: hook wired but the script is gone, plugin on disk but disabled, binary installed but not on `PATH` |
| `✘` red | Not there at all |

That yellow `gsd ⚠` above is a real finding: GSD's 57 `/gsd:*` commands live in
`~/.claude/commands/gsd`, and command directories are bound to the config dir the
session runs under, so they are not loadable from a session started on
`~/.claude-personal`. Hooks from `~/.claude/settings.json` still fire either way,
which is why `cmdset` and `hook` probes deliberately treat profiles differently.

## Profile aware

I run two config dirs: `~/.claude` holds every hook, plugin, skill and agent,
while `~/.claude-personal` is a lean profile some sessions start under. Probing
only the active one reports everything as missing, which is a lie.

So each probe walks the active profile (`CLAUDE_CONFIG_DIR`) and then
`~/.claude`, taking the first hit and recording which profile it came from.
Counts are a union deduped by name, so a skill present in both is counted once.

Override with `TOOL_STATUS_PROFILES="/path/a:/path/b"`.

## Install

```bash
./install.sh            # symlink ~/.claude/statusline.sh -> this repo
./install.sh --copy     # copy instead, if you would rather not link
./install.sh --uninstall  # restore the most recent backup
```

The installer backs up whatever `~/.claude/statusline.sh` was to
`~/.claude/statusline.sh.bak-<timestamp>`, then links this repo's copy in its
place. Because both my profiles already point `statusLine.command` at that path,
nothing in `settings.json` needs to change; the installer checks each profile
and prints the exact JSON if one is not wired.

Symlinking means edits here are live in the next session. No fork, no drift.

Requires `jq` and `bash`.

## Use it outside the bar

```bash
./bin/tool-status.sh --full     # every tool with its absolute path and state
./bin/tool-status.sh --json     # machine-readable inventory
./bin/tool-status.sh --no-cache # skip the cache
```

`--full` is the one to run when something looks wrong:

```
✔ log      Narrative session journal (Picard)
  /Users/you/Code/captains-log/scripts/log-session.sh
  wired on Stop · profile: .claude
⚠ gsd      Get Shit Done framework (/gsd:* commands)
  /Users/you/.claude/commands/gsd
  57 commands, but not in the active profile · profile: .claude
```

## Adding a tool

Add a line to [config/tools.conf](./config/tools.conf):

```
key | label | kind | probe | version | alt | health | note
```

Five kinds of probe:

| Kind | Probe | Checks |
|------|-------|--------|
| `bin` | command name | resolved on `PATH`, with an optional version command |
| `hook` | `Event:needle` | a hook command in `settings.json` containing `needle`, **and** that the script it points at exists |
| `cmdset` | suite name | a slash-command suite at `<profile>/commands/<name>`, and whether it is in the **active** profile |
| `path` | filesystem path | `$HOME` and `~` expanded |
| `plugin` | plugin id | enabled in `settings.json` **and** present under `plugins/` |
| `mcp` | server name | present in `.claude.json` `mcpServers` |

`version` is either a shell command whose output carries a version, or
`@file:<path>` to read one from a VERSION file, where `{profile}` expands to the
profile that matched.

`health` is a command that must exit 0. Being on `PATH` is not the same as being
usable: `gh` is probed with `gh auth status --active`, so a logged-out or
expired-token `gh` shows `⚠` instead of a reassuring `✔`. Health commands run
only when the cache refreshes, and are bounded at 5s.

`alt` is the "installed but not wired" fallback: if the primary probe fails and
`alt` exists, the tool reports `⚠` instead of `✘`.

Labels want to be 3-6 characters; the bar is not wide.

## Cost

The bar re-renders constantly, so the inventory is cached for 300s in
`/tmp/claude/tool-status-<hash>.json` and invalidated early whenever any
profile's `settings.json` or the manifest changes. A cached render is one
`jq` pass. Set `TOOL_STATUS_CACHE_TTL` to change the window.

`tool-status.sh` exits 0 with no output on every failure path: no `jq`, no
manifest, malformed settings. A broken inventory must never break the bar.

## Tests

```bash
make test    # 28 bats tests, none of which touch the real ~/.claude
```

Each test builds a throwaway profile in `$BATS_TEST_TMPDIR` and points
`TOOL_STATUS_PROFILES` at it.
