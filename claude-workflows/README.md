# Claude Workflows

Process skills — the ones that decide *how* a piece of work gets approached,
before any implementation skill gets a say.

Skills load lazily: only the description sits in context until Claude decides
the skill applies, so a plugin like this costs almost nothing at rest.

---

## Setup

```
/plugin marketplace add fahdi/my-claude-tools
/plugin install claude-workflows@my-claude-tools
```

Skills activate on their own when a task matches their description. There is
nothing to configure and no hook to wire up.

---

## Skills

### `software-factory`

A four-gate feature workflow — Product, Architecture, Program Design, Vertical
Slices — with explicit approval required at every gate before implementation
code exists. The point is to make each important decision at the moment when
changing it costs a sentence rather than a rewrite.

It fires on real features: anything that will touch several files, add an
endpoint, table, or screen, or produce a diff nobody wants to review in one
sitting. It deliberately stays out of the way for renames, copy changes, and
one-line config edits.

> **Attribution.** The methodology is
> [Dex Horthy's](https://github.com/humanlayer) at HumanLayer. The skill file
> here is a write-up of that workflow for Claude Code; the thinking is his.

---

## Files

```
claude-workflows/
├── .claude-plugin/
│   └── plugin.json
├── README.md
└── skills/
    └── software-factory/
        └── SKILL.md
```

Adding another skill means adding a sibling directory under `skills/` with its
own `SKILL.md`. Claude Code discovers it automatically — no manifest change is
needed.

---

## License

MIT for the packaging. Individual skills carry the attribution noted above.
