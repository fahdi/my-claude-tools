---
name: software-factory
description: Dex Horthy's 4-gate feature workflow — Product, Architecture, Program Design, Vertical Slices — with explicit user approval at every gate before implementation code exists. Use when starting a new feature, a new project, or any task expected to change several files or produce a large diff. Not for trivial tweaks like renames, copy changes, or one-line config edits.
---

# The Software Factory Playbook

Dex Horthy's (HumanLayer) workflow: make every important decision **before** implementation code exists, where changing it costs a sentence instead of a rewrite. Work through four gates in order. Stop at each gate for explicit user approval. Never merge gates. Never write implementation code before the Gate 4 slice plan is approved.

## When to run the gates

Run the full workflow when the task is a real feature: it will create or change multiple files, add an endpoint, table, or screen, or produce a diff the user would hate to review all at once (roughly 100+ lines).

Skip the gates entirely (just do the task) when any of these hold:

- Trivial tweak: rename, typo, copy change, style tweak, small config edit.
- The user explicitly says to skip the process ("just vibe it," "quick and dirty," "no process").
- The user says the code is throwaway or pure prototyping.

If unsure whether the task qualifies, ask once: "This looks big enough for the 4-gate workflow — run it, or do you want the fast version?" Respect the answer.

## Files and state

All workflow files live in `docs/plans/<feature-slug>/`:

```
docs/plans/<feature-slug>/
  00-status.md          state file: gate approvals + slice checklist
  01-product.md
  mockups/              Gate 1 screen mockups — plain HTML, one file per screen
  02-architecture.md
  03-program-design.md
  04-slices.md
```

Create `00-status.md` first, before Gate 1. Update it at every gate approval and every slice completion. Template:

```markdown
# Status: <feature name>

- Gate 1 — Product: pending | in progress | APPROVED <date>
- Gate 2 — Architecture: pending | in progress | APPROVED <date>
- Gate 3 — Program Design: pending | in progress | APPROVED <date>
- Gate 4 — Slice plan: pending | in progress | APPROVED <date>

## Slices
- [ ] Slice 1 — tracer bullet: <one line>
- [ ] Slice 2 — <one line>

## Notes for a fresh session
<anything decided in chat that a new session must know>
```

**Resume rule:** at the start of any session, if `docs/plans/<feature-slug>/00-status.md` exists for the feature being discussed, read every doc in that folder first, then continue from the first unapproved gate or first unchecked slice. Never redo an approved gate unless the user asks for it or a later gate invalidated it.

## The approval protocol (run at every gate)

1. Write the gate doc to disk.
2. Present a summary to the user: at most 5–10 bullet decisions, plus the doc path. Do not paste the whole doc into chat.
3. Ask exactly: **"Approve Gate N, or what should change?"**
4. Approval means the user clearly says yes / approve / continue. Anything else means: revise the doc to address their answer, then re-ask.
5. On approval, mark the gate APPROVED in `00-status.md` and move on.
6. **Backtracking:** if work at a later gate reveals an earlier approved decision is wrong, stop, update the earlier doc, set that gate back to "in progress" in `00-status.md`, and get re-approval before continuing.

## Gate 1 — Product (no tech talk)

Work with the user to fill this template, saved as `01-product.md`:

```markdown
# Product: <feature name>

## Problem
<the user problem, in the end-user's words — not the developer's>

## Success metric
<one real number tied to the business (conversion, latency, tickets, revenue) and how it's measured>

## Announcement — the blog post before the feature
<3–6 sentences announcing this feature to users. If you can't write it, you're building the wrong thing.>

## Screens
<one line per mockup file in ./mockups/ — or "no UI">
```

Rules for this gate:

- **Banned in this stage:** databases, schemas, endpoints, architecture, file names. If tech appears, move it to Gate 2.
- For anything with a UI: produce one plain HTML file per screen in `mockups/` — no framework, no build step, throwaway by design. Iterate on the mockups with the user until they say "yes, that."

Run the approval protocol.

## Gate 2 — Architecture

Read the relevant existing code before writing this doc — never design against an imagined codebase. Template, saved as `02-architecture.md`:

```markdown
# Architecture: <feature name>

## Fit
<which existing services/modules this touches, and how>

## Endpoints
<route + verb + purpose, one line each — or "none">

## Data
<new or changed tables/collections, with outlines of the queries that will hit them>

## Flow
<the end-to-end call order for the main path: what calls what>

## External
<third-party APIs, env var NAMES (never values), webhooks — or "none">
```

Run the approval protocol.

## Gate 3 — Program Design (the step everyone skips)

The decisions the agent would otherwise make silently mid-implementation. Template, saved as `03-program-design.md`:

```markdown
# Program Design: <feature name>

## Files
<every file created or changed, one line each on why it lives there>

## Types & signatures
<code blocks defining the types and method signatures — NO implementation bodies.
A human should be able to read these in seconds and say "right" or "wrong.">

## Call stack
<for each main flow: what calls what, top to bottom>

## Test plan
<test case names and what each one asserts — before any of them exist>

## Least confident decisions
<numbered list of the calls most worth challenging now, while changing them is free>
```

Run the approval protocol.

## Gate 4 — Vertical Slices (tracer bullets)

First write the slice plan as `04-slices.md` — one line per slice, in build order — and run the approval protocol on it. Then build one slice at a time.

Slice rules:

- **Slice 1 is the tracer bullet:** a mocked/hardcoded endpoint and a stubbed UI (or curl-able response), wired end to end. It does almost nothing — but it runs, and the user can see it.
- **Slice 2:** replace mocks with the real logic for the single happy path.
- **Slice 3+:** one capability per slice — a business rule, error handling, an edge case, polish — each ending in a working, testable state.
- **Banned:** horizontal building (all of the database, then all services, then all API, then all frontend, with nothing testable until the end).

After **every** slice:

1. Prove it works — run it, curl it, or browser-test it, and show the user the result.
2. Check the slice off in `00-status.md`.
3. Ask: "Continue to slice N+1, or re-steer?" If the trajectory is wrong, fix direction before adding more code.

## Standing rules (always on during the workflow)

- **Compact at every boundary.** At the end of every gate and every slice, make sure the docs contain everything decided — nothing important may exist only in chat. Tell the user this is a safe point to start a fresh session; a new session must be able to continue from the docs alone (see the resume rule). If the harness warns that context is running low, compact immediately, wherever you are.
- **Keep diffs reviewable.** Small slices. If the user hasn't looked at code in a long stretch, nudge them at a slice boundary — losing touch with the codebase costs weeks, exactly when the agent hits a bug it can't solve.
- **Real tests only.** Never write a test that passes against the pre-change code — a test that can't fail tests nothing. Never comment out, skip, or weaken a test to get to green.

## Optional: durable context in the codebase

When a gate produces a decision that outlives this feature, offer to record it as an ADR in `docs/adr/NNNN-<slug>.md` — context, decision, consequences; never rewrite old ADRs, supersede them. Record anything that lives outside the repo but that an agent needs to know exists (env var names, payment setup, test accounts, third-party dashboards) in `docs/external/`. Files on disk are free context — every future session starts smarter.
