#!/usr/bin/env bash
# Claude Code status line — reads session JSON on stdin.
# Line 1: model | dir | git branch (+dirty marker) | context used
# Line 2: 5h window start→end (used%) | weekly window start→end (used%) | account email
# Colors: context turns red above 40% used; rate-limit %s go yellow at 60, red at 85.

input=$(cat)

# ANSI palette
R=$'\e[0m'        # reset
BOLD=$'\e[1m'
DIM=$'\e[2m'
CYAN=$'\e[36m'
BLUE=$'\e[34m'
YELLOW=$'\e[33m'
GREEN=$'\e[32m'
RED=$'\e[31m'
MAGENTA=$'\e[35m'

model=$(jq -r '.model.display_name // "Claude"' <<<"$input")
cwd=$(jq -r '.workspace.current_dir // .cwd // "?"' <<<"$input")
used=$(jq -r '.context_window.used_percentage // empty' <<<"$input")

case "$cwd" in
  "$HOME"*) dir="~${cwd#"$HOME"}" ;;
  *) dir="$cwd" ;;
esac

branch=""
if git -C "$cwd" rev-parse --is-inside-work-tree &>/dev/null; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if ! git -C "$cwd" diff --quiet 2>/dev/null || ! git -C "$cwd" diff --cached --quiet 2>/dev/null; then
    branch="$branch*"
  fi
fi

# color for a 0-100 usage figure: green, yellow at $2, red at $3
usage_color() {
  local v=${1%.*} warn=${2:-60} bad=${3:-85}
  [ -z "$v" ] && { printf '%s' "$GREEN"; return; }
  if [ "$v" -ge "$bad" ]; then printf '%s' "$RED"
  elif [ "$v" -ge "$warn" ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

sep="${DIM}|${R}"

line1="${BOLD}${MAGENTA}${model}${R} $sep ${BLUE}${dir}${R}"
[ -n "$branch" ] && line1="$line1 $sep ${YELLOW}${branch}${R}"
if [ -n "$used" ]; then
  c=$(usage_color "$used" 40 40)   # red above 40% used, per preference
  line1="$line1 $sep ${c}ctx ${used%.*}%${R}"
fi
echo "$line1"

# --- line 2: rate-limit windows + account ---
fh_reset=$(jq -r '.rate_limits.five_hour.resets_at // empty' <<<"$input")
fh_used=$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input")
wk_reset=$(jq -r '.rate_limits.seven_day.resets_at // empty' <<<"$input")
wk_used=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$input")
email=$(jq -r '.oauthAccount.emailAddress // empty' "$HOME/.claude.json" 2>/dev/null)

line2=""
if [ -n "$fh_reset" ]; then
  fh_start=$((fh_reset - 5*3600))
  seg="${CYAN}5h${R} $(date -d "@$fh_start" +%H:%M)→$(date -d "@$fh_reset" +%H:%M)"
  [ -n "$fh_used" ] && seg="$seg $(usage_color "$fh_used")(${fh_used%.*}%)${R}"
  line2="$seg"
fi
if [ -n "$wk_reset" ]; then
  wk_start=$((wk_reset - 7*24*3600))
  seg="${CYAN}wk${R} $(date -d "@$wk_start" +'%a %d %H:%M')→$(date -d "@$wk_reset" +'%a %d %H:%M')"
  [ -n "$wk_used" ] && seg="$seg $(usage_color "$wk_used")(${wk_used%.*}%)${R}"
  line2="${line2:+$line2 $sep }$seg"
fi
[ -n "$email" ] && line2="${line2:+$line2 $sep }${DIM}${email}${R}"
[ -n "$line2" ] && echo "$line2"
