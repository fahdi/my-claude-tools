# Cleanup candidates

A backlog of space that disk-cleanup does **not** reclaim yet, recorded after
the 2026-10-08 incident (see the README) so each one can be decided on later.
Sizes are what one machine measured on 2026-10-09 at 101GB free of 926GB.

Nothing here has been deleted, and nothing here is automated. Each entry says
what it is, what removing it costs, and whether it looks like a fit for the
scheduled job, a report-only path, or a one-off manual cleanup.

## Regenerable: caches and build output

| Size | Area | Removal cost | Fit |
|------|------|--------------|-----|
| ~55GB | `node_modules` inside git worktrees (one work repo had 70+ ticket worktrees at ~0.9GB each, almost all `node_modules`) | `npm install` before the worktree is next used | **Strong candidate for automation**, same idle-age gate as Rust and Flutter |
| 5.2GB | `node_modules` in projects idle 30+ days | `npm install` | Same rule as above |
| 12GB | Spotify `~/Library/Application Support/Spotify/PersistentCache` | Refills while streaming | Manual, plus a cache cap in Spotify > Settings > Storage |
| 5.1GB | `~/.npm` | Packages re-download | Already pruned (`npm cache clean`) once the PATH fix lands; verify it actually runs |
| 4.7GB | `~/Library/iTunes/iPad Software Updates` (old firmware) | None | Candidate: delete `.ipsw` files idle 30+ days |
| 4.5GB | `~/Library/Application Support/com.apple.wallpaper` (aerial videos) | macOS re-downloads on demand | Manual |
| 2.2GB | `~/Library/Caches/ms-playwright`, `ms-playwright-mcp` | Browsers re-download | Candidate: old browser revisions only (0.6GB on 2026-11-10) |
| 1.2GB | `~/.cache/wpmcp-merge-queue` (wpmcp gate logs, about 45MB each) | None, logs of past gate runs | Candidate for wpmcp's own tooling: keep the newest N or 14 days |
| 0.6GB | `~/.cache/chrome-devtools-mcp/chrome-profile` | A Chrome profile in use by the MCP server | Report only |
| 2.9GB | `~/.cache/whisper-models` | Models re-download slowly | Report only, like `~/.ollama` |
| 1.4GB | `~/.pub-cache` | `dart pub cache clean` removes all of it, so every Flutter project re-fetches | Manual |
| 1.2GB | `~/.gradle/caches` | No safe prune command; Gradle ages entries out itself after 30 days | Leave |
| 450MB | `~/Library/Caches/pip` | Re-download | Candidate: `pip cache purge` |

### Notes on `node_modules` in worktrees

- Delete `node_modules` only, never the worktree. Branches, commits and
  uncommitted changes are untouched; several worktrees had uncommitted work.
- Removing whole worktrees saves little extra, since nearly all of their size
  is `node_modules`.
- Gate on the worktree's last activity, not the `node_modules` mtime, and skip
  anything touched in the last couple of days so active work keeps its install.
- pnpm projects hard-link into the pnpm store, so their `node_modules` is far
  smaller than `du` per directory suggests. Measure with one `du` call over all
  of them, which counts each hard link once.

## Needs a decision per machine

| Size | Area | Question |
|------|------|----------|
| 9.7GB | `~/Library/Application Support/Claude/vm_bundles` | Desktop app VM image. Re-downloads, but the next use that needs it is slow |
| ~5.5GB | Older Android NDK versions under `~/Library/Android/sdk/ndk` (four installed) | Which versions do current projects pin? |
| 5.2GB | Docker volumes not attached to any container | Which project does each belong to? Never automate, volumes are databases |
| 4.5GB | Local database dumps and snapshots inside work repos | These contain **real client data**. Delete as soon as the work needing them is done; that is a data-handling rule, not just a space one |
| 4.4GB | Audible downloads (`~/Library/Containers/<uuid>`, identified by its `amzn1.account` files) | Personal: keep or remove downloaded titles in the app |

## Large but out of scope

Measured, but personal data or data a running project needs, so only ever by hand:

- `~/Music` (43GB)
- Chrome profile `~/Library/Application Support/Google/Chrome` (10GB)
- Local by Flywheel site data `~/Library/Application Support/Local/run` (18GB)
- `~/websites` (125GB), source for active sites
- Docker volumes that containers are using (~52GB)

## Automated on 2026-11-10

- `~/.cache/wpmcp-tests`: idle installs and dead runs' cores (see the README).
- `~/.npm/_npx`: entries idle 30+ days that no running process uses, through
  `npm cache npx rm`. This was 3.6GB, not part of the 5.1GB `~/.npm` above,
  because `npm cache clean` never touches it.

## Already handled on 2026-10-08

Recorded so they are not re-investigated:

- Flutter/iOS build output, Docker build cache and dangling images: now pruned
  automatically.
- Ollama models, Antigravity apps and data, `~/.cache`, iOS simulators: removed
  by hand. `~/.ollama`, `~/.cache` and `~/.gemini` are on the report-only list
  in case they grow back.
