# config

## `settings.example.json`

A `~/.claude/settings.json` you can copy and have work. Every path and command
in it resolves once [`scripts/bootstrap.sh`](../scripts/bootstrap.sh) has run.

The one thing it cannot supply is `statusline.sh`, which is personal and is not
in this repo — delete the `statusLine` block if you do not have your own.

### What is deliberately not in it

**No `Stop` hooks.** Captain's Log and Dev Diary both register their own `Stop`
hooks through their plugin manifests, so they never appear in `settings.json`
at all. Adding them here by hand as well is how you end up with two entries per
session. Install the plugins and leave this file alone.

**No `env` block.** The previous version carried placeholder `JIRA_TOKEN`,
`JIRA_EMAIL`, and `JIRA_BASE_URL` values for an integration that is not part of
this setup. Add your own if you need them.

**No GSD hooks.** Earlier versions of this file registered three
`~/.claude/hooks/gsd-*.js` hooks. That directory does not exist on a machine
set up from this repo, and Claude Code reports a failing hook on every event
when it is pointed at a script that is not there. If you want GSD, install it
(`npm install -g get-shit-done-cc`) and add its hooks back yourself.

The `rtk` hook stays, because `bootstrap.sh` installs `rtk` and the command
resolves. Drop that block if you skipped the CLI tools.

### Merging, not overwriting

Adding a plugin marketplace writes to `~/.claude/settings.json` under
`extraKnownMarketplaces`. Anything that rewrites the file wholesale — a
provisioning script, a config manager, a restored backup — silently drops your
marketplaces along with your hooks. Merge into this file; never replace it.
