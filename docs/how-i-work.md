# How I work with Claude

This is the operating manual for how I engineer things with Claude Code. The tooling
in [stack.md](./stack.md) exists to serve these habits, not the other way around.

## The collaboration contract

My global `~/.claude/CLAUDE.md` sets the relationship before any project context loads:
Claude is a senior engineer collaborating with a peer, not an assistant serving requests.
The contract, condensed:

- **Plan first.** Discuss the approach before writing code. Surface every implementation
  choice that needs a decision, present options with trade-offs, confirm alignment,
  then implement.
- **Push back.** Question design decisions that look suboptimal. Give direct criticism
  without couching it in niceties. Never open with praise, never validate every
  decision as "absolutely right", never agree just to be agreeable.
- **Distinguish opinion from fact.** When a change is purely stylistic, say "sure,
  I'll use that approach", not "you're absolutely right".
- **Stop and discuss** when implementation uncovers something the plan did not foresee.

This works because it front-loads the thinking. Revising a plan costs a paragraph;
revising an implementation costs a session.

## The delivery loop

For anything bigger than a bugfix, work moves through a repeatable loop. My
AI forecasting service runs entirely on this pattern and it generalizes:

1. **Design council.** Before a feature is planned, run the question past multiple
   perspectives (subagents or separate prompts arguing the approach). The output is
   a decision with stated trade-offs, not a vibe.
2. **PRD and issues.** The agreed design becomes a PRD, and the PRD becomes GitHub
   issues. Every requirement is tracked; nothing lives only in chat history.
3. **TDD slices.** Each issue is implemented as a small vertical slice, test-first.
   The superpowers `test-driven-development` skill enforces the discipline: failing
   test, minimal implementation, refactor.
4. **Verify before completion.** No "done" without evidence: tests green, behavior
   demonstrated, output shown. The `verification-before-completion` skill blocks the
   reflexive "that should work now".
5. **Ship and version.** Each slice releases on its own (v1.3.0, v1.4.1, ...) so
   production moves in small reversible steps.
6. **Persist programme state.** Long-running work keeps its state in the repo
   (for example `docs/PROGRAMME.md`), so any future session can pick up exactly where
   the last one stopped, without relying on chat memory.

## Skills as guardrails

The superpowers plugin installs process skills that fire *before* action:

- "Let's build X" → `brainstorming` first. Intent and requirements before code.
- "Fix this bug" → `systematic-debugging` first. Reproduce and diagnose before patching.
- Any feature or fix → `test-driven-development`.
- Claiming completion → `verification-before-completion`.

The point is not ceremony. Each of these skills exists because the failure mode it
prevents (coding the wrong thing, patching symptoms, untested changes, false "done")
is the expensive kind. If a skill plausibly applies, it gets invoked.

## Memory strategy

Three layers, each with a different job:

1. **claude-mem** (plugin): automatic observation capture per session, searchable
   across sessions. When a new session starts I get a compressed timeline of recent
   work instead of re-explaining context. Its own stats report roughly 90% token
   savings versus re-reading raw history.
2. **Curated memory directory** (`~/.claude/projects/.../memory/`): one fact per file,
   indexed in `MEMORY.md`. This holds things the repo cannot record: who I am, feedback
   I have given Claude, project goals, external references. Wrong memories get deleted;
   duplicates get merged.
3. **In-repo state docs**: programme files, PRDs, and issue trackers live in the
   project itself. If it matters to the work, it belongs in version control, not in
   a chat transcript.

Rule of thumb: the repo records what the code is, memory records what the code cannot
say, and claude-mem bridges the sessions in between.

## Token economy

Long agentic sessions die by a thousand `git status` outputs. Two mechanisms keep
context lean:

- **RTK (Rust Token Killer)**: a `PreToolUse` hook transparently rewrites Bash
  commands through `rtk`, a proxy that filters and compresses command output before
  it reaches the model. Typical savings run 60-90% on dev operations, and `rtk gain`
  shows the running total.
- **Structured recall over raw reads**: claude-mem's `smart-explore` (tree-sitter
  AST search) instead of reading whole files; observation search instead of replaying
  old transcripts.

Cheap context is not about cost alone. A lean context window keeps the model sharp
deep into a session.

## The record

Two `Stop` hooks journal every session that does real work, writing to two private repos:

- **[Captain's Log](../captains-log/)**: the narrative. Picard summarizes the session's
  work, victories, and setbacks in character, committed to a diary repo. It is genuinely
  useful (a readable story of the day) and genuinely fun, which is why it survives.
- **Dev Diary**: the facts. A prose lead plus files changed and commands run, extracted
  mechanically from the session transcript, plus decisions and follow-ups written by
  `claude -p`. When I need to know what actually happened on a date, this is the
  source of truth.

Narrative for humans, facts for audits. Both fire automatically, so the record exists
whether or not I remember to write it.

## Documentation freshness

A global rule (`~/.claude/rules/context7.md`) requires Claude to fetch current docs
via the context7 MCP server whenever a question involves a library, framework, or CLI
tool, even well-known ones. Training data lags; APIs move. The rule exists because
"I think I know this API" is the most common source of subtle wrongness.

## Writing rules

Hard rules that apply to everything Claude produces for me, code and prose alike:

- **No em-dashes, anywhere.** Not in chat, code comments, commit messages, or docs.
  They read as AI-generated slop. Hyphens, commas, colons, parentheses, or restructure.
- **Absolute paths in chat.** File references are full paths so they are clickable
  in the terminal.
- **No AI attribution in commits.** No "Generated with Claude Code", no
  `Co-Authored-By: Claude`. The commit message describes the change, full stop.
- **No jargon in user-facing UI.** Even debug screens use capability-first language
  a normal person can read.

These live in `~/.claude/CLAUDE.md` and in curated memory, so every session enforces
them from the first message.

## Why this shape

The common thread: **make the expensive thing cheap and the invisible thing visible.**
Planning is cheap, rework is expensive, so plan first. Context is expensive, so
compress it. Session knowledge evaporates, so journal it and index it. Discipline
decays under deadline pressure, so encode it in hooks and skills that fire whether
or not anyone remembers.
