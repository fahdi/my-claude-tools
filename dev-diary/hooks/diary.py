#!/usr/bin/env python3
"""Dev Diary — mechanical facts + planning + rendering for the Stop-hook diary.

Three subcommands, chained by dev-diary.sh:

  facts  <transcript.jsonl> <cwd>
      Read the session transcript and print a JSON facts object to stdout:
      {tool_count, files, commands, snippets, project, branch}
      Files and commands are pulled straight from tool_use inputs, so they are
      ground truth — no LLM involved.

  plan   <facts.json> <diary_dir>
      Decide what to do with those facts. Reads today's diary file to dedup
      against entries written in the last 15 minutes for the same project.
      Prints a plan JSON: {action: "skip"} or
      {action: "write", mode: "full"|"supplemental", files, commands,
       project, branch, prompt}. The prompt is what gets fed to `claude -p`.

  render <plan.json> <diary_dir> <time> <date>
      Read the LLM output (PROSE/DECISIONS/FOLLOWUPS blocks) from stdin,
      assemble the final markdown entry using the mechanical files/commands
      from the plan, append it to the daily file, and update README.md.
"""

# Every file here is UTF-8. Python on Windows below 3.15 still defaults open()
# to the locale codepage (cp1252), which raises UnicodeDecodeError on a
# transcript containing any non-Latin-1 character and cannot write the
# em-dashes the diary format uses.
import argparse
import datetime
import json
import os
import re
import sys

DEDUP_WINDOW_MIN = 15
MAX_COMMANDS = 40
MAX_FILES = 60
MAX_SNIPPETS = 25
CMD_MAXLEN = 240
FILES_DISPLAY = 30
CMDS_DISPLAY = 25
META_PREFIX = "<!-- devdiary-meta:"

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

# Paths that are not project work: temp dirs, agent scratchpads, memory/session
# files. Edits to these are noise in a dev diary.
NOISE_PATH_MARKERS = ("/scratchpad/", "/.claude/", "/node_modules/")
NOISE_PATH_PREFIXES = ("/tmp/", "/private/tmp/", "/var/folders/")

# A command is "notable" (worth logging) if any &&/; segment, after stripping
# leading `cd`/env prefixes, begins with one of these actions. Everything else
# (grep, cat, ls, find, sed -n, git status/log/diff/fetch, gh *list, curl checks,
# inline python -c exploration) is read-only exploration and gets dropped.
NOTABLE_RE = re.compile(
    r"""^(
        git\s+(commit|merge|push|rm|tag|rebase|cherry-pick|revert|reset|stash|init|clone|checkout\s+-b)\b
      | gh\s+(pr\s+(create|merge|ready|close)|release\s+create|repo\s+create)\b
      | (npm|yarn|pnpm|bun)\s+(install|ci|run|build|test|publish|add|remove)\b
      | npx\s+(astro\s+(build|add)|tsc)\b
      | (pytest|phpunit|jest|vitest|tsc|eslint|prettier)\b
      | make\b
      | rsync\b
      | scp\b
      | docker(-compose)?\s+(build|run|compose|up|exec|push)\b
      | kubectl\s+(apply|create|delete|rollout)\b
      | terraform\s+(apply|plan|destroy)\b
      | (pip3?|pipx)\s+install\b
      | composer\s+(install|require|update|dump-autoload)\b
      | cargo\s+(build|test|run|publish|add|fmt|clippy)\b
      | go\s+(build|test|run|install)\b
      | wp\s+\S+
      | (mkdir|mv|cp|chmod|chown|touch|rm)\b
      | ln\s+-s
      | sed\s+-i
      | tee\b
      | (python3?|bash|sh|ruby|node)\s+\.?/?[\w./-]*scripts?/
      | \./[\w./-]+
    )""",
    re.VERBOSE,
)

_STRIP_CD = re.compile(r"^cd\s+(?:'[^']*'|\"[^\"]*\"|\S+)\s+")
_STRIP_ENV = re.compile(r"^(?:\w+=(?:'[^']*'|\"[^\"]*\"|\S+)\s+)+")


def _is_noise_file(path):
    if any(m in path for m in NOISE_PATH_MARKERS):
        return True
    return path.startswith(NOISE_PATH_PREFIXES)


def _is_notable_cmd(cmd):
    for seg in re.split(r"&&|;", cmd):
        s = seg.strip()
        s = _STRIP_ENV.sub("", s)
        s = _STRIP_CD.sub("", s).strip()
        if NOTABLE_RE.match(s):
            return True
    return False


# --------------------------------------------------------------------------- #
# facts
# --------------------------------------------------------------------------- #
def cmd_facts(transcript_path, cwd):
    files = []
    seen_files = set()
    commands = []
    snippets = []
    tool_count = 0
    branch = ""

    try:
        with open(transcript_path, encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
    except OSError:
        print(json.dumps(_empty_facts(cwd)))
        return

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        if msg.get("gitBranch"):
            branch = msg["gitBranch"]

        inner = msg.get("message", msg)
        role = inner.get("role", "") or msg.get("type", "")
        content = inner.get("content", "")

        if isinstance(content, list):
            text_parts = []
            for part in content:
                if not isinstance(part, dict):
                    continue
                ptype = part.get("type")
                if ptype in ("tool_use", "tool_result"):
                    tool_count += 1
                if ptype == "tool_use":
                    name = part.get("name", "")
                    inp = part.get("input") or {}
                    if name in EDIT_TOOLS:
                        fp = inp.get("file_path")
                        if fp and fp not in seen_files and not _is_noise_file(fp):
                            seen_files.add(fp)
                            files.append(fp)
                    elif name == "Bash":
                        c = (inp.get("command") or "").strip()
                        if c and _is_notable_cmd(c):
                            commands.append(c.replace("\n", " ")[:CMD_MAXLEN])
                elif ptype == "text":
                    t = part.get("text", "")
                    if t and t.strip():
                        text_parts.append(t)
            text = " ".join(text_parts)
        elif isinstance(content, str):
            text = content
        else:
            text = ""

        if text and len(text.strip()) > 20:
            snippets.append(f"{role}: {text.strip()[:300].replace(chr(10), ' ')}")

    # Collapse consecutive duplicate commands, keep order.
    deduped_cmds = []
    for c in commands:
        if not deduped_cmds or deduped_cmds[-1] != c:
            deduped_cmds.append(c)

    facts = {
        "tool_count": tool_count,
        "files": files[:MAX_FILES],
        "commands": deduped_cmds[:MAX_COMMANDS],
        "snippets": snippets[-MAX_SNIPPETS:],
        "project": os.path.basename(cwd.rstrip("/")) or "unknown",
        "branch": branch,
    }
    print(json.dumps(facts))


def _empty_facts(cwd):
    return {
        "tool_count": 0,
        "files": [],
        "commands": [],
        "snippets": [],
        "project": os.path.basename((cwd or "").rstrip("/")) or "unknown",
        "branch": "",
    }


# --------------------------------------------------------------------------- #
# plan
# --------------------------------------------------------------------------- #
def _recent_meta(diary_dir, project):
    """Union of files+commands already logged for `project` in the last window."""
    today = datetime.date.today()
    log_file = os.path.join(diary_dir, f"{today.isoformat()}.md")
    seen_files, seen_cmds = set(), set()
    had_recent = False
    if not os.path.exists(log_file):
        return had_recent, seen_files, seen_cmds

    now = datetime.datetime.now()
    with open(log_file, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line.startswith(META_PREFIX):
                continue
            payload = line[len(META_PREFIX):].strip()
            if payload.endswith("-->"):
                payload = payload[:-3].strip()
            try:
                meta = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if meta.get("project") != project:
                continue
            try:
                h, m = meta["time"].split(":")
                entry_time = datetime.datetime(
                    today.year, today.month, today.day, int(h), int(m)
                )
            except (KeyError, ValueError):
                continue
            if (now - entry_time).total_seconds() / 60 <= DEDUP_WINDOW_MIN:
                had_recent = True
                seen_files.update(meta.get("files", []))
                seen_cmds.update(meta.get("commands", []))
    return had_recent, seen_files, seen_cmds


def _build_prompt(project, branch, files, commands, snippets, supplemental,
                  artifactless=False):
    branch_str = f" (branch {branch})" if branch else ""
    files_block = "\n".join(f"- {p}" for p in files) or "(none)"
    cmds_block = "\n".join(f"- {c}" for c in commands) or "(none)"
    snips_block = "\n".join(snippets) or "(no excerpts captured)"

    supp_note = ""
    if supplemental and artifactless:
        # No new files or commands, but the task still happened. The excerpts
        # are all there is to go on, so say so plainly rather than asking for
        # a summary of an empty list.
        supp_note = (
            "\nThis is a SHORT SUPPLEMENTAL update. Earlier work on this project "
            "today was already logged. This task changed no further files and ran "
            "no further notable commands, so describe what was done from the "
            "activity excerpts alone, in one or two sentences. Do not restate "
            "earlier work. If the excerpts do not support a specific statement, "
            'write exactly "No further detail was captured for this task."\n'
        )
    elif supplemental:
        supp_note = (
            "\nThis is a SHORT SUPPLEMENTAL update. Earlier work on this project "
            "today was already logged. Cover ONLY the new files and commands "
            "listed above; do not restate earlier work.\n"
        )

    return f"""You are writing one entry in a software developer's technical work diary.
Be precise and factual. State only what the activity below actually supports.
Do not embellish. No narrative persona, no Star Trek, no metaphors, no praise.
Plain, specific engineering English.
{supp_note}
Project: {project}{branch_str}

Files changed this session:
{files_block}

Commands run this session:
{cmds_block}

Recent activity excerpts (oldest first, newest last):
{snips_block}

Output EXACTLY three labeled blocks and nothing else. No preamble, no sign-off:
begin your response immediately with the characters "PROSE:".

PROSE:
<2 to 3 sentences on what was actually done and why, technically specific>

DECISIONS:
- <notable technical decisions or tradeoffs; write "none" as the only bullet if there were none>

FOLLOWUPS:
- <concrete unfinished work, TODOs, or known issues that were actually mentioned; write "none" if there were none>

Rules: Never use em-dashes; use commas or semicolons. Be concrete. If something is
uncertain or not supported by the activity above, leave it out rather than guessing."""


def cmd_plan(facts_path, diary_dir):
    with open(facts_path, encoding='utf-8') as f:
        facts = json.load(f)

    # Nothing concrete happened -> no entry worth writing.
    if not facts["files"] and not facts["commands"]:
        print(json.dumps({"action": "skip", "reason": "no files or commands"}))
        return

    had_recent, seen_files, seen_cmds = _recent_meta(diary_dir, facts["project"])

    artifactless = False
    if had_recent:
        new_files = [p for p in facts["files"] if p not in seen_files]
        new_cmds = [c for c in facts["commands"] if c not in seen_cmds]
        # Never drop a task. Work that touched only files and commands an
        # earlier entry in the window already listed is still a task that was
        # completed, and skipping it made the diary silent about exactly the
        # stretches where several short tasks land back to back. It becomes a
        # supplemental entry written from the excerpts instead.
        artifactless = not new_files and not new_cmds
        files, commands, mode, supplemental = new_files, new_cmds, "supplemental", True
    else:
        files, commands, mode, supplemental = (
            facts["files"],
            facts["commands"],
            "full",
            False,
        )

    plan = {
        "action": "write",
        "mode": mode,
        "project": facts["project"],
        "branch": facts["branch"],
        "files": files,
        "commands": commands,
        "prompt": _build_prompt(
            facts["project"], facts["branch"], files, commands, facts["snippets"],
            supplemental, artifactless,
        ),
    }
    print(json.dumps(plan))


# --------------------------------------------------------------------------- #
# render
# --------------------------------------------------------------------------- #
def _parse_llm(text):
    """Slice the PROSE / DECISIONS / FOLLOWUPS blocks out of the LLM output."""
    def grab(label, nxt):
        pat = rf"{label}:\s*(.*?)(?={nxt}|$)"
        m = re.search(pat, text, re.DOTALL | re.IGNORECASE)
        return m.group(1).strip() if m else ""

    prose = grab("PROSE", r"DECISIONS:")
    decisions = grab("DECISIONS", r"FOLLOWUPS:")
    followups = grab("FOLLOWUPS", r"\Z")
    return prose, decisions, followups


def _clean_bullets(block):
    """Normalize a bullet block; drop it entirely if it is just 'none'."""
    lines = [ln.strip() for ln in block.splitlines() if ln.strip()]
    out = []
    for ln in lines:
        ln = ln.lstrip("-*").strip()
        if not ln:
            continue
        if ln.lower() in ("none", "none.", "n/a"):
            continue
        out.append(f"- {ln}")
    return out


def cmd_render(plan_path, diary_dir, time_now, date_str):
    with open(plan_path, encoding='utf-8') as f:
        plan = json.load(f)

    llm_out = sys.stdin.read()
    prose, decisions_raw, followups_raw = _parse_llm(llm_out)

    if not prose:
        nf, nc = len(plan["files"]), len(plan["commands"])
        prose = (
            f"Session recorded {nf} file change(s) and {nc} command(s). "
            "No narrative summary was generated."
        )

    decisions = _clean_bullets(decisions_raw)
    followups = _clean_bullets(followups_raw)

    branch = plan.get("branch") or ""
    branch_str = f" ({branch})" if branch else ""
    supp_str = " · supplemental" if plan.get("mode") == "supplemental" else ""

    parts = [f"## {time_now} — {plan['project']}{branch_str}{supp_str}", "", prose, ""]

    if plan["files"]:
        parts.append("**Files changed**")
        parts.extend(f"- {p}" for p in plan["files"][:FILES_DISPLAY])
        extra = len(plan["files"]) - FILES_DISPLAY
        if extra > 0:
            parts.append(f"- ...and {extra} more")
        parts.append("")
    if plan["commands"]:
        parts.append("**Commands run**")
        parts.extend(f"- `{c}`" for c in plan["commands"][:CMDS_DISPLAY])
        extra = len(plan["commands"]) - CMDS_DISPLAY
        if extra > 0:
            parts.append(f"- ...and {extra} more")
        parts.append("")
    if decisions:
        parts.append("**Decisions**")
        parts.extend(decisions)
        parts.append("")
    if followups:
        parts.append("**Follow-ups**")
        parts.extend(followups)
        parts.append("")

    meta = {
        "project": plan["project"],
        "time": time_now,
        "files": plan["files"],
        "commands": plan["commands"],
    }
    parts.append(f"{META_PREFIX} {json.dumps(meta)} -->")

    entry = "\n".join(parts)

    log_file = os.path.join(diary_dir, f"{date_str}.md")
    if not os.path.exists(log_file):
        with open(log_file, "w", encoding="utf-8") as f:
            f.write(f"# Dev Diary — {date_str}\n")

    with open(log_file, "a", encoding="utf-8") as f:
        f.write("\n---\n\n")
        f.write(entry)
        f.write("\n")

    _update_readme(diary_dir, date_str)


def _update_readme(diary_dir, date_str):
    readme = os.path.join(diary_dir, "README.md")
    if not os.path.exists(readme):
        return
    with open(readme, encoding='utf-8') as f:
        content = f.read()
    if f"[{date_str}]" in content:
        return
    new_line = f"- [{date_str}]({date_str}.md)\n"
    marker = "## Entries\n"
    if marker in content:
        idx = content.index(marker) + len(marker)
        while idx < len(content) and content[idx] == "\n":
            idx += 1
        content = content[:idx] + new_line + content[idx:]
    else:
        content += f"\n## Entries\n\n{new_line}"
    with open(readme, "w", encoding="utf-8") as f:
        f.write(content)


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_facts = sub.add_parser("facts")
    p_facts.add_argument("transcript")
    p_facts.add_argument("cwd")

    p_plan = sub.add_parser("plan")
    p_plan.add_argument("facts")
    p_plan.add_argument("diary_dir")

    p_render = sub.add_parser("render")
    p_render.add_argument("plan")
    p_render.add_argument("diary_dir")
    p_render.add_argument("time")
    p_render.add_argument("date")

    args = ap.parse_args()
    if args.cmd == "facts":
        cmd_facts(args.transcript, args.cwd)
    elif args.cmd == "plan":
        cmd_plan(args.facts, args.diary_dir)
    elif args.cmd == "render":
        cmd_render(args.plan, args.diary_dir, args.time, args.date)


if __name__ == "__main__":
    main()
