# The stack

Everything in my Claude Code setup as of August 2026, with sources. See
[how-i-work.md](./how-i-work.md) for why each piece exists;
[../config/settings.example.json](../config/settings.example.json) shows how it wires together.

## Layout

```
~/.claude/
├── CLAUDE.md              # global collaboration contract + active project context
├── RTK.md                 # RTK usage reference (loaded globally)
├── rules/context7.md      # "fetch current docs via context7" rule
├── settings.json          # hooks, plugins, statusline, model
├── hooks/                 # GSD lifecycle hooks (js)
├── commands/              # custom slash commands (/log, /gsd:*)
├── agents/                # custom subagents (GSD + SEO suites)
├── skills/                # standalone skills (SEO, design, a11y, React)
├── get-shit-done/         # GSD framework install
├── plugins/               # plugin marketplace installs
├── statusline.sh          # custom statusline script
└── projects/.../memory/   # curated cross-session memory (MEMORY.md index)
```

## Plugins

Installed from marketplaces via `/plugin`:

| Plugin | Source | What it does for me |
|--------|--------|---------------------|
| superpowers | anthropics/claude-plugins-official | Process-skill guardrails: brainstorming, systematic-debugging, TDD, verification-before-completion, plan writing/execution |
| claude-mem | thedotmack/claude-mem | Automatic session memory: observation capture, cross-session search, timeline recall, AST-based `smart-explore` |
| frontend-design | anthropics/claude-plugins-official | Anti-generic UI design guidance when building frontends |
| chrome-devtools-mcp | anthropics/claude-plugins-official | Drive Chrome via DevTools protocol: console, network, traces, Lighthouse |
| playwright | anthropics/claude-plugins-official | Browser automation and E2E-style verification |
| plugin-dev | anthropics/claude-plugins-official | Tooling for building plugins, skills, hooks, and agents |
| claude-code-setup | anthropics/claude-plugins-official | Automation recommendations for the harness itself |
| rust-analyzer-lsp | anthropics/claude-plugins-official | Rust language intelligence |

Plus **Claude in Chrome** (Anthropic's browser extension) for driving my real
browser session when a task needs logged-in state.

## GSD (Get Shit Done)

Project orchestration framework from [gsd-build/get-shit-done](https://github.com/gsd-build/get-shit-done),
installed via npm (`get-shit-done-cc`). It supplies:

- `/gsd:*` commands: new-project, discuss-phase, plan-phase, execute-phase,
  verify-work, debug, map-codebase, and about forty more
- 18 specialized subagents (planner, executor, verifier, debugger, researchers,
  UI auditors) that each own one step of the loop
- Lifecycle hooks: update check on session start, prompt guard and context monitor
  around tool use, plus its statusline

GSD is the heavyweight option for greenfield or multi-phase work. The lightweight
day-to-day loop (design council → issues → TDD slice) is described in
[how-i-work.md](./how-i-work.md#the-delivery-loop).

## RTK (Rust Token Killer)

Token-optimizing CLI proxy, installed via Homebrew. A `PreToolUse` hook on Bash
rewrites commands through `rtk` transparently, filtering and compressing output
before it hits the context window. 60-90% savings on routine dev operations.

```bash
rtk gain              # savings analytics
rtk gain --history    # per-command history
rtk discover          # scan Claude Code history for missed opportunities
rtk proxy <cmd>       # raw passthrough for debugging
```

## MCP servers

| Server | Scope | Purpose |
|--------|-------|---------|
| context7 | global | Current library/framework docs on demand (paired with a global rule that mandates its use) |
| browser-tools | global | Console/network logs, audits from the browser |
| playwright, notion, postman | per-project | Added only where a project needs them |

Per-project servers stay per-project on purpose: every always-on server is context
overhead in sessions that never use it.

## Hooks

The full lifecycle, from `~/.claude/settings.json`:

| Event | Hook | Job |
|-------|------|-----|
| SessionStart | gsd-check-update.js | Keep GSD current |
| PreToolUse (Bash) | `rtk hook claude` | Rewrite commands through the RTK proxy |
| PreToolUse (Write/Edit) | gsd-prompt-guard.js | GSD workflow guard |
| PostToolUse (Bash/Edit/Write/Agent) | gsd-context-monitor.js | Track context usage |
| Stop | captains-log/log-session.sh | Narrative session journal (Picard) |
| Stop | devdiary/dev-diary.sh | Factual session journal (files, commands, decisions) |

Both Stop hooks are lock-protected and skip sessions that did no real work. The
Captain's Log hook also supports a per-project opt-out via a `.local-diary` marker
file and reclaims stale locks left by timed-out runs.

## Skills

Beyond plugin-bundled skills, `~/.claude/skills/` carries standalone suites:

- **SEO suite** (~30 skills + matching subagents): full audits, technical SEO,
  schema, backlinks, local SEO, content briefs, topic clustering, GEO for AI search
  (AI Overviews, ChatGPT, Perplexity), drift monitoring
- **Design arsenal** (~13 skills, symlinked from `~/.agents/skills/`): anti-slop
  frontend direction, high-end visual design, brand kits, image-to-code,
  image generation direction for web and mobile, brutalist and minimalist styles
- **Accessibility**: contrast-checker, link-purpose, accesslint-refactor
- **React/mobile**: react-best-practices (Vercel), composition-patterns,
  react-view-transitions, react-native-skills, ios-simulator-skill
- **ui-ux-pro-max**: style/palette/font-pairing reference across 10 stacks

Skills are cheap when idle (only descriptions load until invoked), so a wide
library costs little and pays off whenever a task matches.

## Custom commands and statusline

- **`/log`**: manual Captain's Log entry mid-session (the Stop hook covers exits)
- **`statusline.sh`**: custom bash statusline with model, git state, and context
  usage in truecolor

## Model

Default model is set in settings (`"model": "fable"` at the moment). Journaling
hooks shell out to `claude -p` for prose generation, so they ride whatever the
CLI default is.
