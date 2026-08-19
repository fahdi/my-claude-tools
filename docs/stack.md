# The stack

Everything in my Claude Code setup as of mid-August 2026, with sources. See
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
installed via npm (`get-shit-done-cc`, currently 1.42.3).

> **Heads up:** npm now flags the package as deprecated on install —
> *"Package no longer supported."* It installs and runs fine, but treat it as
> on borrowed time and don't build anything load-bearing on it without a
> migration plan.

It supplies:

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

Token-optimizing CLI proxy. It is in homebrew-core now, so plain
`brew install rtk` works with no tap (0.45.0 at time of writing). A `PreToolUse` hook on Bash
rewrites commands through `rtk` transparently, filtering and compressing output
before it hits the context window. 60-90% savings on routine dev operations.

```bash
rtk gain              # savings analytics
rtk gain --history    # per-command history
rtk discover          # scan Claude Code history for missed opportunities
rtk proxy <cmd>       # raw passthrough for debugging
```

## MCP servers

Global servers (in `~/.claude.json`):

| Server | Transport | Purpose |
|--------|-----------|---------|
| context7 | http | Current library/framework docs on demand (paired with a global rule that mandates its use). Hosted, no local node/npx: `claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp`. Works anonymously; set `CONTEXT7_API_KEY` for higher rate limits |
| figma | http | Official Figma server: read designs into code, generate designs from code, Code Connect mapping, FigJam diagrams |
| browser-tools | stdio | Console/network logs, audits from the browser |

On top of those, three more MCP surfaces arrive without their own server entries:

- **claude-in-chrome** - Anthropic's Chrome extension exposes a full toolset
  (tab context, navigation, computer control, page reading, forms, console and
  network reads, JS eval, GIF recording) for driving my real logged-in browser
- **chrome-devtools / playwright** - the plugins ship their MCP servers with
  them: DevTools protocol (traces, Lighthouse, heap snapshots) and Playwright
  automation respectively
- **claude-mem mcp-search** - the memory plugin's search server: observation
  search, timelines, tree-sitter `smart-explore` over codebases, and on-demand
  corpus building over past sessions

Per-project servers (notion, postman, Atlassian Rovo for Jira-heavy repos) stay
per-project on purpose: every always-on server is context overhead in sessions
that never use it. Newer harness builds defer MCP tool schemas until needed
(loaded via ToolSearch), which makes even a wide server roster cheap at rest.

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

Beyond plugin-bundled skills, `~/.claude/skills/` carries 59 standalone skills:

- **SEO suite** (30 skills + matching subagents): full audits, single-page and
  technical SEO, schema, backlinks, local SEO and maps intelligence, content
  briefs and competitor pages, topic clustering, sitemaps, hreflang,
  programmatic SEO, drift monitoring, GEO for AI search (AI Overviews, ChatGPT,
  Perplexity), plus data-source extensions that light up when their API is
  configured: DataForSEO, Ahrefs, Bing/IndexNow, SE Ranking, Profound,
  Firecrawl, Unlighthouse, and AI image generation for OG/hero assets
- **Design arsenal** (~18 skills): the design-taste-frontend pair (v2 default +
  v1 pinned), gpt-taste and stitch-design-taste, high-end-visual-design,
  redesign-existing-projects, image-to-code, imagegen direction for web and
  mobile, brand kits, bencium UX designers (controlled + innovative),
  industrial-brutalist and minimalist styles, use-of-color,
  web-design-guidelines, full-output-enforcement
- **Accessibility**: contrast-checker, link-purpose, accesslint-refactor
- **React/mobile**: react-best-practices (Vercel), composition-patterns,
  react-view-transitions, react-native-skills, ios-simulator-skill (29 scripts
  for simulator automation)
- **ui-ux-pro-max**: style/palette/font-pairing reference across 10 stacks
- **context7-mcp**: nudges library questions through the context7 docs server

Skills are cheap when idle (only descriptions load until invoked), so a wide
library costs little and pays off whenever a task matches.

## Agent tooling bench

Standalone agent tools installed August 2026 for evaluation, outside the Claude
Code harness itself:

| Tool | Install | Verdict so far |
|------|---------|----------------|
| [browser-use](https://github.com/browser-use/browser-use) | uv project at `~/Code/agent-tools-lab` | Category leader for Python agent browser control. Overlaps with Claude in Chrome / Playwright / chrome-devtools in-harness; earns its keep only in standalone Python agents |
| [headroom](https://github.com/headroomlabs-ai/headroom) | same venv (`headroom-ai[all]`, ships `headroom` CLI) | The interesting one: compresses tool outputs, logs, and RAG chunks before they reach the model. Same thesis as RTK at the library/proxy layer; evaluating whether it complements or duplicates it |
| [nanobot](https://github.com/HKUDS/nanobot) | `uv tool install nanobot-ai` (global `nanobot` CLI, `nanobot webui`) | Self-hosted personal agent framework from HKUDS (the LightRAG lab). Promising, v0.3.0-grade maturity; kicking tires, not building on it |
| [ai-agents-for-beginners](https://github.com/microsoft/ai-agents-for-beginners) | cloned to `~/Code/ai-agents-for-beginners` | Solid beginner course, wrong audience for this setup; kept for reference |

context7 from the same sweep was already wired in (see MCP servers above).
The lab venv is Python 3.13 via uv; run tools with `uv run` from
`~/Code/agent-tools-lab`.

## Custom commands and statusline

- **`/log`**: manual Captain's Log entry mid-session (the Stop hook covers exits)
- **`statusline.sh`**: custom bash statusline with model, git state, and context
  usage in truecolor

## Model

Default model is set in settings (`"model": "fable"` at the moment). Journaling
hooks shell out to `claude -p` for prose generation, so they ride whatever the
CLI default is.

## Rebuilding this setup on a fresh Mac

Verified end to end on a clean Apple Silicon Mac in August 2026, against
Claude Code 2.1.235. The pieces below install without any interactive step:

```bash
brew install rtk bats-core          # token proxy + Captain's Log bats suite
uv tool install pytest              # Captain's Log python suite
npm install -g get-shit-done-cc     # GSD (see the deprecation note above)

claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp
claude plugin marketplace add thedotmack/claude-mem
```

Then `cd captains-log && make test` should report 10 pytest and 10 bats tests
passing before you run `./install.sh`.

### Two things worth knowing before you start

**Adding a plugin marketplace writes to `~/.claude/settings.json`.** It lands
as an `extraKnownMarketplaces` key, not in the `~/.claude/plugins/` directory
where you might expect it. Anything that rewrites `settings.json` wholesale —
a provisioning script, a config manager, a restored backup — silently drops
your marketplaces along with your hooks. Merge into that file; never overwrite
it.

**`install.sh` is interactive.** It prompts for the diary location and offers
to create a GitHub repo, so it needs a terminal. There is no unattended flag
yet; run it by hand rather than from a setup script.
