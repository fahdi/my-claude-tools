# Running these tools on Windows

Everything in this repo works on native Windows. It needs Git for Windows,
which is a five-minute install and is what Claude Code itself recommends so its
Bash tool works at all. You do not need WSL.

If you already run Claude Code inside WSL, ignore this page — WSL behaves like
Linux and needs nothing special.

---

## 1. Install Claude Code

Open **PowerShell** (press Start, type `powershell`, press Enter) and run:

```powershell
irm https://claude.ai/install.ps1 | iex
```

Close PowerShell and open it again, then check it worked:

```powershell
claude --version
```

## 2. Install Git for Windows

Download it from [git-scm.com/downloads/win](https://git-scm.com/downloads/win)
and accept every default. This gives you `git` and Git Bash.

Claude Code runs hook scripts through Git Bash when it is installed, and falls
back to PowerShell when it is not. The Captain's Log hook is a bash script, so
Git Bash is what makes it run.

If Claude Code cannot find Git Bash afterwards, point it at the path directly in
`%USERPROFILE%\.claude\settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe"
  }
}
```

## 3. Install Python 3

Download it from [python.org/downloads](https://www.python.org/downloads/).

**On the first installer screen, tick "Add python.exe to PATH" before clicking
Install.** This is the single most common thing to get wrong, and skipping it
means the tools cannot find Python later.

Windows also ships fake `python.exe` and `python3.exe` files that do nothing
except open the Microsoft Store. If `python --version` opens the Store instead
of printing a version, turn them off: Start → "Manage app execution aliases" →
switch off both **App Installer** entries for Python.

The tools probe for a working interpreter and accept `python3`, `python`, or the
`py -3` launcher, so any one of those being real is enough.

## 4. Install the tools

In Claude Code:

```
/plugin marketplace add fahdi/my-claude-tools
/plugin install captains-log@my-claude-tools
```

That is all. Your diary appears at `C:\Users\<you>\Code\captains-log` the first
time a session does enough work to earn an entry.

## 5. Optional: back the diary up to GitHub

```powershell
gh repo create captains-log --private --source "$env:USERPROFILE\Code\captains-log" --remote=origin --push
```

Without a remote the diary just stays on your machine, which is fine.

---

## If something goes wrong

**`$'\r': command not found`**

A script was checked out with Windows line endings. The repo pins every script
to LF in `.gitattributes`, so this only affects a clone made before that landed.
Re-clone, or run inside the clone:

```powershell
git rm --cached -r .
git reset --hard
```

**No diary entry appears after a session**

The hook stays silent by design in several cases, in this order:

1. Fewer than 2 tool uses in the session — no real work, no entry.
2. A `.local-diary` file sits in the project directory or above it.
3. No working Python 3 was found.

To check the third, open **Git Bash** (not PowerShell) and run:

```bash
python3 --version || python --version || py -3 --version
```

If all three fail, redo step 3 above.

**`bash: command not found` in the hook output**

Git for Windows is not installed, or Claude Code cannot see it. Redo step 2.

**Where do I find the diary?**

`C:\Users\<you>\Code\captains-log`, one markdown file per day. Set
`CAPTAINS_LOG_DIR` in your environment to put it somewhere else.

---

## Running the tests

Only needed if you are changing the tools. From Git Bash:

```bash
pip install pytest
cd captains-log
python -m pytest tests/test_parse_transcript.py -v
```

The bats suite needs [bats-core](https://github.com/bats-core/bats-core), which
has no Windows installer; run it under WSL or leave it to CI.
