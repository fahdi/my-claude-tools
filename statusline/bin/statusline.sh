#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

format_reset_time() {
    local iso_str="$1"
    local style="$2"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return

    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //; s/\.//g')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            ;;
    esac
    printf "%s" "$result"
}

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# ── Resolve config dir (multi-profile aware) ────────────
# transcript_path lives under the active config dir, e.g.
# ~/.claude-personal/projects/<slug>/<session>.jsonl
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
case "$transcript_path" in
    */projects/*) config_dir="${transcript_path%%/projects/*}" ;;
esac

# Default profile stores oauthAccount at ~/.claude.json (home root). A stray
# ~/.claude/.claude.json (CLI state: machineID, migration flags, no oauthAccount)
# exists and must not shadow it, so read the home-root file directly for the
# default profile. CLAUDE_CONFIG_DIR profiles keep it at <config_dir>/.claude.json.
if [ "$config_dir" = "$HOME/.claude" ]; then
    account_json="$HOME/.claude.json"
else
    account_json="$config_dir/.claude.json"
fi
# Safety net: if the resolved file has no oauthAccount but the home-root one does,
# fall back to it (covers a config dir that only holds CLI state).
if [ -f "$account_json" ] && [ "$(jq -r '.oauthAccount.emailAddress // empty' "$account_json" 2>/dev/null)" = "" ] && [ -f "$HOME/.claude.json" ]; then
    account_json="$HOME/.claude.json"
fi

account_name=""
account_email=""
if [ -f "$account_json" ]; then
    account_name=$(jq -r '.oauthAccount.displayName // empty' "$account_json" 2>/dev/null)
    account_email=$(jq -r '.oauthAccount.emailAddress // empty' "$account_json" 2>/dev/null)
fi

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

effort="default"
settings_path="$config_dir/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Thinking ──
pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line1+="${sep}"
case "$effort" in
    high)   line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac
if [ -n "$account_name" ] || [ -n "$account_email" ]; then
    line1+="${sep}${dim}👤${reset} "
    [ -n "$account_name" ] && line1+="${white}${account_name}${reset} "
    [ -n "$account_email" ] && line1+="${dim}${account_email}${reset}"
fi

# ── OAuth token resolution ──────────────────────────────
get_oauth_token() {
    local token=""

    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    # Non-default config dirs store keychain creds under a suffixed
    # service name: "Claude Code-credentials-<sha256(config_dir)[0:8]>"
    local kc_service="Claude Code-credentials"
    if [ "$config_dir" != "$HOME/.claude" ]; then
        local suffix
        suffix=$(printf '%s' "$config_dir" | shasum -a 256 2>/dev/null | cut -c1-8)
        [ -n "$suffix" ] && kc_service="Claude Code-credentials-${suffix}"
    fi

    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "$kc_service" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    local creds_file="${config_dir}/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# ── Fetch usage data (cached) ──────────────────────────
# The usage endpoint is shared by every open session and rate-limits hard
# (HTTP 429 with a Retry-After of ~120s). Three rules keep us honest:
#   1. one cache file per config dir, TTL STATUSLINE_USAGE_TTL (default 120s);
#   2. a 429 writes a backoff stamp that every session respects, so seven
#      bars do not keep the limit tripped forever;
#   3. only one process fetches at a time (mkdir lock), the rest read the cache.
# A response is accepted when it carries any limit at all. The old check for
# .five_hour froze the bar the day Anthropic dropped the five-hour limit, since
# that field is now null on accounts without it.
cache_key=$(printf '%s' "$config_dir" | shasum -a 256 2>/dev/null | cut -c1-8)
cache_dir="${STATUSLINE_USAGE_CACHE_DIR:-/tmp/claude}"
cache_file="${STATUSLINE_USAGE_CACHE_FILE:-$cache_dir/statusline-usage-cache-${cache_key:-default}.json}"
backoff_file="${cache_file%.json}.backoff"
lock_dir="${cache_file%.json}.lock"
cache_max_age="${STATUSLINE_USAGE_TTL:-120}"
mkdir -p "$(dirname "$cache_file")" 2>/dev/null

file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

now=$(date +%s)
needs_refresh=true
usage_data=""
cache_age=""

if [ -f "$cache_file" ]; then
    cache_mtime=$(file_mtime "$cache_file")
    cache_age=$(( now - ${cache_mtime:-0} ))
    if [ "$cache_age" -lt "$cache_max_age" ]; then
        needs_refresh=false
    fi
    usage_data=$(cat "$cache_file" 2>/dev/null)
fi

# Honour a backoff another render set after a 429.
if $needs_refresh && [ -f "$backoff_file" ]; then
    backoff_until=$(cat "$backoff_file" 2>/dev/null)
    if [ "${backoff_until:-0}" -gt "$now" ] 2>/dev/null; then
        needs_refresh=false
    else
        rm -f "$backoff_file"
    fi
fi

[ -n "$STATUSLINE_NO_FETCH" ] && needs_refresh=false

if $needs_refresh; then
    # Stale lock (>15s) means a previous render died mid-fetch; reclaim it.
    if [ -d "$lock_dir" ]; then
        lock_age=$(( now - $(file_mtime "$lock_dir" || echo 0) ))
        [ "$lock_age" -gt 15 ] && rmdir "$lock_dir" 2>/dev/null
    fi
    if mkdir "$lock_dir" 2>/dev/null; then
        trap 'rmdir "$lock_dir" 2>/dev/null' EXIT
        token=$(get_oauth_token)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            headers_file=$(mktemp "${TMPDIR:-/tmp}/statusline-hdr.XXXXXX" 2>/dev/null)
            response=$(curl -s --max-time 5 \
                -D "${headers_file:-/dev/null}" \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.316" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            http_status=""
            retry_after=""
            if [ -n "$headers_file" ] && [ -f "$headers_file" ]; then
                http_status=$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code}' "$headers_file")
                retry_after=$(awk 'tolower($1)=="retry-after:" {gsub(/\r/,"",$2); print $2}' "$headers_file" | tail -1)
                rm -f "$headers_file"
            fi
            if echo "$response" | jq -e '(.limits // empty) or (.seven_day // empty) or (.five_hour // empty)' >/dev/null 2>&1; then
                usage_data="$response"
                printf '%s' "$response" > "$cache_file"
                rm -f "$backoff_file"
                cache_age=0
            elif [ "$http_status" = "429" ] || echo "$response" | jq -e '.error.type == "rate_limit_error"' >/dev/null 2>&1; then
                case "$retry_after" in
                    ''|*[!0-9]*) retry_after=120 ;;
                esac
                echo $(( now + retry_after )) > "$backoff_file"
            fi
        fi
        rmdir "$lock_dir" 2>/dev/null
        trap - EXIT
    fi
fi

# ── Rate limit lines ────────────────────────────────────
# Rendered from the `limits` array so the bar follows whatever limits the
# account actually has: weekly_all, a per-model weekly_scoped, and a session
# limit only on plans that still carry one. Falls back to the legacy
# five_hour/seven_day fields when `limits` is absent.
rate_lines=""
stale_after="${STATUSLINE_USAGE_STALE_AFTER:-300}"

label_for_limit() {  # kind, scope display name
    case "$1" in
        session)       printf "current" ;;
        weekly_all)    printf "weekly" ;;
        weekly_scoped)
            local name
            name=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
            printf "%s" "${name:-scoped}" ;;
        *)             printf "%s" "$1" ;;
    esac
}

render_limit() {  # label, pct, resets_at iso, style
    local label="$1" pct="$2" reset_iso="$3" style="$4"
    local bar_width=10
    local pct_int
    pct_int=$(printf '%s' "$pct" | awk '{printf "%.0f", $1+0}')
    local reset_str
    reset_str=$(format_reset_time "$reset_iso" "$style")

    # A reset time already in the past means the number is dead, not low.
    local reset_epoch
    reset_epoch=$(iso_to_epoch "$reset_iso" 2>/dev/null)
    if [ -n "$reset_epoch" ] && [ "$reset_epoch" -lt "$now" ]; then
        printf "%b" "${white}$(printf '%-7s' "$label")${reset} $(build_bar 0 $bar_width) ${dim} --%${reset} ${dim}⟳ ${reset_str} (expired)${reset}"
        return
    fi

    local bar color fmt
    bar=$(build_bar "$pct_int" "$bar_width")
    color=$(color_for_pct "$pct_int")
    fmt=$(printf "%3d" "$pct_int")
    printf "%b" "${white}$(printf '%-7s' "$label")${reset} ${bar} ${color}${fmt}%${reset} ${dim}⟳${reset} ${white}${reset_str}${reset}"
}

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    has_limits=$(echo "$usage_data" | jq -r '(.limits | type) == "array" and (.limits | length) > 0')

    if [ "$has_limits" = "true" ]; then
        while IFS=$'\t' read -r kind pct reset_iso scope_name; do
            [ -z "$kind" ] && continue
            label=$(label_for_limit "$kind" "$scope_name")
            style="datetime"
            [ "$kind" = "session" ] && style="time"
            line=$(render_limit "$label" "$pct" "$reset_iso" "$style")
            [ -n "$rate_lines" ] && rate_lines+="\n"
            rate_lines+="$line"
        done < <(echo "$usage_data" | jq -r '
            .limits[]
            | [ .kind, (.percent // 0 | tostring), (.resets_at // ""),
                (.scope.model.display_name // "") ]
            | @tsv')
    else
        five_hour_present=$(echo "$usage_data" | jq -r '.five_hour != null')
        if [ "$five_hour_present" = "true" ]; then
            rate_lines+=$(render_limit "current" \
                "$(echo "$usage_data" | jq -r '.five_hour.utilization // 0')" \
                "$(echo "$usage_data" | jq -r '.five_hour.resets_at // ""')" time)
        fi
        seven_day_present=$(echo "$usage_data" | jq -r '.seven_day != null')
        if [ "$seven_day_present" = "true" ]; then
            [ -n "$rate_lines" ] && rate_lines+="\n"
            rate_lines+=$(render_limit "weekly" \
                "$(echo "$usage_data" | jq -r '.seven_day.utilization // 0')" \
                "$(echo "$usage_data" | jq -r '.seven_day.resets_at // ""')" datetime)
        fi
    fi

    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
        extra_bar=$(build_bar "$extra_pct" 10)
        extra_pct_color=$(color_for_pct "$extra_pct")

        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ -z "$extra_reset" ]; then
            extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        fi

        extra_col="${white}extra  ${reset} ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset}"
        extra_reset_line="${dim}resets ${reset}${white}${extra_reset}${reset}"
        [ -n "$rate_lines" ] && rate_lines+="\n"
        rate_lines+="${extra_col}"
        rate_lines+="\n${extra_reset_line}"
    fi

    # Say so when the numbers are old. A bar that silently shows yesterday
    # is worse than no bar.
    if [ -n "$rate_lines" ] && [ -n "$cache_age" ] && [ "$cache_age" -ge "$stale_after" ]; then
        if [ "$cache_age" -ge 3600 ]; then
            age_str="$(( cache_age / 3600 ))h ago"
        else
            age_str="$(( cache_age / 60 ))m ago"
        fi
        rate_lines+="\n${dim}usage data from ${age_str}${reset}"
    fi
fi

# ── Tool status ─────────────────────────────────────────
# Rendered by tool-status.sh, which lives next to this script in
# my-claude-tools/statusline/bin. ~/.claude/statusline.sh is normally a symlink
# to that repo copy, so resolve the link before looking for its sibling.
resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        case "$src" in /*) ;; *) src="$dir/$src" ;; esac
    done
    (cd -P "$(dirname "$src")" && pwd)
}

tools_line=""
tool_status="$(resolve_script_dir)/tool-status.sh"
if [ -x "$tool_status" ]; then
    tools_line=$(CLAUDE_CONFIG_DIR="$config_dir" "$tool_status" --segment 2>/dev/null)
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"
[ -n "$tools_line" ] && printf "\n\n%b" "$tools_line"

exit 0
