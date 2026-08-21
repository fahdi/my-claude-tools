---
name: log
description: Write a Captain's Log entry for this session's work and push to GitHub
allowed-tools:
  - Bash
  - Write
  - Read
---

<objective>
Write a Captain's Log entry in Captain Jean-Luc Picard's voice summarizing this session's completed work. Append it to today's diary file, update the README index, and commit + push to GitHub.
</objective>

<process>

1. **Get today's date and stardate.** Use `date` and `awk` rather than Python:
   the Bash tool is Git Bash on Windows, where `python3` frequently is not a
   working interpreter, and `awk` is always present.
   ```bash
   TODAY=$(date +%Y-%m-%d)
   STARDATE=$(awk -v y="$(date +%Y)" -v d="$(date +%j)" \
     'BEGIN { printf "%.1f", (y - 1966) * 1000 + d * 1000 / 366 }')
   echo "TODAY=$TODAY STARDATE=$STARDATE"
   ```

2. **Review this session's work** from the conversation context above — identify tasks completed, files changed, problems solved, decisions made.

3. **Write the log entry** in Captain Picard's voice:
   - Begin exactly with: `Captain's Log, Stardate [STARDATE].`
   - Formal, measured, reflective — as Picard narrates mission logs
   - Frame technical work as ship operations:
     - Bugs → hostile incursions or system anomalies
     - Deployments → warp jumps or course corrections
     - Code reviews → tactical briefings
     - Refactoring → refit operations
     - New features → capabilities brought online
     - Debugging → forensic investigation
   - 150-250 words
   - End on a forward-looking or reflective note

4. **Append to today's diary file** at `${DIARY_DIR:-${CAPTAINS_LOG_DIR:-$HOME/Code/captains-log}}/YYYY-MM-DD.md`:
   ```bash
   DIARY_DIR="${DIARY_DIR:-${CAPTAINS_LOG_DIR:-$HOME/Code/captains-log}}"
   LOG_FILE="$DIARY_DIR/$TODAY.md"
   TIME_NOW=$(date +%H:%M)

   if [ ! -f "$LOG_FILE" ]; then
     printf "# Captain's Log — %s\n\n" "$TODAY" > "$LOG_FILE"
   fi

   # Append with separator and timestamp
   {
     echo ""; echo "---"; echo ""
     echo "*Logged at $TIME_NOW*"; echo ""
     echo "[ENTRY TEXT]"; echo ""
   } >> "$LOG_FILE"
   ```

5. **Update README.md** — add link at the top of `## Entries` if this date isn't listed:
   - Format: `- [YYYY-MM-DD](YYYY-MM-DD.md) — Stardate XXXXX.X`
   - Reverse chronological order (newest first)

6. **Commit and push:**
   ```bash
   cd "${DIARY_DIR:-${CAPTAINS_LOG_DIR:-$HOME/Code/captains-log}}"
   git add -A
   git commit -m "Captain's Log: $TODAY"
   git remote get-url origin >/dev/null 2>&1 && git push origin main
   ```
   The diary has no remote unless one was added by hand, so guard the push.

7. **Confirm** with: "Captain's Log entry written and pushed. Stardate [STARDATE]."

</process>

<style_notes>
Picard speaks in full, measured sentences without contractions. He references "this crew," "this vessel," "the mission," "our endeavors." He is never flippant but occasionally philosophical. Gravitas is non-negotiable.
</style_notes>
