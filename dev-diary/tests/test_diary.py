"""Tests for diary.py's planning decisions.

The plan step is where an entry is silently dropped, so it is the part worth
pinning. Run with: python3 -m pytest tests/test_diary.py
"""

import datetime
import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
DIARY = os.path.join(HERE, os.pardir, "hooks", "diary.py")
META_PREFIX = "<!-- devdiary-meta:"


def run_plan(facts, diary_dir):
    facts_path = os.path.join(diary_dir, "facts.json")
    with open(facts_path, "w") as f:
        json.dump(facts, f)
    out = subprocess.run(
        [sys.executable, DIARY, "plan", facts_path, diary_dir],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def make_facts(files=None, commands=None, project="dt"):
    return {
        "project": project,
        "branch": "main",
        "files": files if files is not None else ["/a.py"],
        "commands": commands if commands is not None else ["pytest"],
        "snippets": ["assistant: did a thing"],
        "tool_count": 5,
    }


def write_entry(diary_dir, project, files, commands, minutes_ago=1):
    """An entry in today's file, with meta the dedup window reads."""
    when = datetime.datetime.now() - datetime.timedelta(minutes=minutes_ago)
    meta = {
        "project": project,
        "time": when.strftime("%H:%M"),
        "files": files,
        "commands": commands,
    }
    today = datetime.date.today().isoformat()
    with open(os.path.join(diary_dir, f"{today}.md"), "a") as f:
        f.write(f"\n---\n\n## entry\n\n{META_PREFIX} {json.dumps(meta)} -->\n")


def test_first_entry_of_the_day_is_a_full_write(tmp_path):
    plan = run_plan(make_facts(), str(tmp_path))
    assert plan["action"] == "write"
    assert plan["mode"] == "full"


def test_nothing_concrete_is_still_skipped(tmp_path):
    """The one skip that remains: no files and no commands at all."""
    plan = run_plan(make_facts(files=[], commands=[]), str(tmp_path))
    assert plan["action"] == "skip"


def test_new_work_in_the_window_is_supplemental(tmp_path):
    write_entry(str(tmp_path), "dt", ["/a.py"], ["pytest"])
    plan = run_plan(make_facts(files=["/a.py", "/b.py"]), str(tmp_path))
    assert plan["action"] == "write"
    assert plan["mode"] == "supplemental"
    # Only the delta, so the entry does not restate the earlier one.
    assert plan["files"] == ["/b.py"]


def test_a_task_with_no_new_artifacts_is_written_not_dropped(tmp_path):
    """The behaviour this change exists for.

    Two tasks finishing inside the dedup window used to collapse into one:
    the second was skipped outright, so the diary went quiet exactly when
    several short tasks landed back to back.
    """
    write_entry(str(tmp_path), "dt", ["/a.py"], ["pytest"])
    plan = run_plan(make_facts(files=["/a.py"], commands=["pytest"]), str(tmp_path))

    assert plan["action"] == "write", "a completed task must never be dropped"
    assert plan["mode"] == "supplemental"
    assert plan["files"] == []
    assert plan["commands"] == []


def test_an_artifactless_supplemental_asks_for_prose_from_excerpts(tmp_path):
    """With no files or commands to list, the prompt must not ask the model to
    summarise an empty list, or the entry comes back hollow."""
    write_entry(str(tmp_path), "dt", ["/a.py"], ["pytest"])
    plan = run_plan(make_facts(files=["/a.py"], commands=["pytest"]), str(tmp_path))

    prompt = plan["prompt"]
    assert "activity excerpts alone" in prompt
    assert "No further detail was captured for this task." in prompt
    assert "Cover ONLY the new files and commands" not in prompt


def test_another_projects_entry_does_not_open_the_window(tmp_path):
    """Dedup is per project; work on dt must not be suppressed by an entry
    written for something else."""
    write_entry(str(tmp_path), "other-project", ["/a.py"], ["pytest"])
    plan = run_plan(make_facts(project="dt"), str(tmp_path))
    assert plan["mode"] == "full"


def test_an_entry_older_than_the_window_does_not_suppress(tmp_path):
    write_entry(str(tmp_path), "dt", ["/a.py"], ["pytest"], minutes_ago=99)
    plan = run_plan(make_facts(), str(tmp_path))
    assert plan["mode"] == "full"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
