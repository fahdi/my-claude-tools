#!/usr/bin/env bash
# tool-status — where my Claude Code tools are installed, and whether they still work.
#
#   tool-status.sh              compact two-line segment for the statusline
#   tool-status.sh --full       panel with absolute paths and notes
#   tool-status.sh --json       machine-readable inventory
#   tool-status.sh --no-cache   force a fresh probe
#
# Profile-aware: probes the active config dir (CLAUDE_CONFIG_DIR) and the default
# ~/.claude, because a tool wired in one profile is still installed when you are
# running the other. Override with TOOL_STATUS_PROFILES="/path/a:/path/b".
#
# Never fails loudly: the statusline calls this on every render, so any error
# path exits 0 with no output rather than corrupting the bar.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANIFEST="${TOOL_STATUS_MANIFEST:-$TOOL_ROOT/config/tools.conf}"
CACHE_TTL="${TOOL_STATUS_CACHE_TTL:-300}"
CACHE_DIR="${TOOL_STATUS_CACHE_DIR:-/tmp/claude}"

MODE="segment"
USE_CACHE=1
for arg in "$@"; do
    case "$arg" in
        --full|-f)     MODE="full" ;;
        --json|-j)     MODE="json" ;;
        --segment|-s)  MODE="segment" ;;
        --no-cache|-n) USE_CACHE=0 ;;
        --help|-h)     sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$MANIFEST" ] || exit 0

# ── Profiles ────────────────────────────────────────────
ACTIVE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROFILES=()
if [ -n "${TOOL_STATUS_PROFILES:-}" ]; then
    IFS=':' read -r -a PROFILES <<< "$TOOL_STATUS_PROFILES"
else
    PROFILES=("$ACTIVE_DIR")
    [ "$ACTIVE_DIR" != "$HOME/.claude" ] && [ -d "$HOME/.claude" ] && PROFILES+=("$HOME/.claude")
fi

settings_of() { printf '%s/settings.json' "$1"; }
account_of() {
    local p="$1"
    if [ -f "$p/.claude.json" ]; then printf '%s/.claude.json' "$p"
    elif [ "$p" = "$HOME/.claude" ]; then printf '%s/.claude.json' "$HOME"
    else printf '%s/.claude.json' "$p"; fi
}
profile_name() { basename "$1"; }

# ── Colors (same palette as the statusline) ─────────────
green='\033[38;2;0;175;80m'
red='\033[38;2;255;85;85m'
amber='\033[38;2;255;176;85m'   # warn; same orange the statusline already uses
white='\033[38;2;220;220;220m'
cyan='\033[38;2;86;182;194m'
dim='\033[2m'
reset='\033[0m'

# ── Helpers ─────────────────────────────────────────────
expand_path() {
    local p="${1:-}"
    p="${p/#\~/$HOME}"
    p="${p//\$HOME/$HOME}"
    printf '%s' "$p"
}

run_bounded() {
    if command -v timeout >/dev/null 2>&1; then timeout 3 "$@" 2>/dev/null
    else "$@" 2>/dev/null; fi
}

# First version-looking token in a command's first output line.
probe_version() {
    local cmd="${1:-}"
    [ -z "$cmd" ] && return 0
    local bin="${cmd%% *}"
    command -v "$bin" >/dev/null 2>&1 || return 0
    # shellcheck disable=SC2086
    run_bounded $cmd | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# A version comes either from running a command or from reading a VERSION file.
# @file:/path/VERSION  — {profile} in the path expands to the profile that matched.
resolve_version_spec() {
    local spec="${1:-}" prof="${2:-}" f
    case "$spec" in
        "") return 0 ;;
        @file:*)
            f="${spec#@file:}"
            f="${f//\{profile\}/$prof}"
            f="$(expand_path "$f")"
            [ -f "$f" ] && head -1 "$f" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
            ;;
        *) probe_version "$spec" ;;
    esac
}

short_version() { [ -n "${1:-}" ] && printf '%s' "$1" | cut -d. -f1,2; }

# The first path-looking token in a hook command, quotes stripped.
extract_path() { printf '%s\n' "${1:-}" | grep -oE '[^" ]*/[^" ]+' | head -1; }

# A tool can be on PATH and still unusable (gh logged out, a CLI missing its
# config). health commands run in a subshell and only their exit code matters.
health_ok() {
    local cmd="${1:-}" bin="${1%% *}"
    [ -z "$cmd" ] && return 0
    command -v "$bin" >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then timeout 5 sh -c "$cmd" >/dev/null 2>&1
    else sh -c "$cmd" >/dev/null 2>&1; fi
}

# ── Probes ──────────────────────────────────────────────
# Each sets STATE (ok|warn|missing), FOUND_PATH, VERSION, DETAIL.
probe_bin() {  # name version alt health  (profile-independent)
    local name="$1" vcmd="${2:-}" health="${4:-}" alt; alt="$(expand_path "${3:-}")"
    FOUND_PATH="$(command -v "$name" 2>/dev/null)"
    if [ -n "$FOUND_PATH" ]; then
        VERSION="$(resolve_version_spec "$vcmd")"
        if [ -z "$health" ]; then
            STATE="ok"; DETAIL="on PATH"
        elif health_ok "$health"; then
            STATE="ok"; DETAIL="on PATH, \`$health\` passes"
        else
            STATE="warn"; DETAIL="on PATH but \`$health\` failed"
        fi
    elif [ -n "$alt" ] && [ -e "$alt" ]; then
        STATE="warn"; FOUND_PATH="$alt"; DETAIL="installed but not on PATH"
    else
        STATE="missing"; DETAIL="not on PATH"
    fi
}

probe_hook() {  # Event:needle profile
    local event="${1%%:*}" needle="${1#*:}" prof="$2" settings cmd target
    settings="$(settings_of "$prof")"
    [ -f "$settings" ] || { STATE="missing"; DETAIL="no settings.json"; return; }
    cmd=$(jq -r --arg ev "$event" --arg needle "$needle" '
        (.hooks[$ev] // [])[]? | (.hooks // [])[]? | (.command // empty)
        | select(contains($needle))' "$settings" 2>/dev/null | head -1)
    if [ -n "$cmd" ]; then
        target="$(extract_path "$cmd")"
        FOUND_PATH="$target"
        if [ -n "$target" ] && [ -e "$target" ]; then
            STATE="ok"; DETAIL="wired on $event"
        else
            STATE="warn"; DETAIL="wired on $event but script is missing"
        fi
    else
        STATE="missing"; DETAIL="no $event hook found"
    fi
}

probe_path() {  # path (profile-independent)
    local p; p="$(expand_path "$1")"
    if [ -e "$p" ]; then STATE="ok"; FOUND_PATH="$p"; DETAIL="present"
    else STATE="missing"; DETAIL="not found at $p"; fi
}

probe_plugin() {  # id profile
    local id="$1" prof="$2" settings on="" p
    settings="$(settings_of "$prof")"
    p=$(find "$prof/plugins" -maxdepth 4 -type d -name "${id%%@*}" 2>/dev/null | head -1)
    [ -f "$settings" ] && on=$(jq -r --arg id "$id" '(.enabledPlugins // {})[$id] // false' "$settings" 2>/dev/null)
    if [ "$on" = "true" ]; then
        if [ -n "$p" ]; then STATE="ok"; FOUND_PATH="$p"; DETAIL="enabled"
        else STATE="warn"; FOUND_PATH="$settings"; DETAIL="enabled but not found on disk"; fi
    elif [ -n "$p" ]; then
        STATE="warn"; FOUND_PATH="$p"; DETAIL="installed but not enabled"
    else
        STATE="missing"; DETAIL="not installed"
    fi
}

probe_cmdset() {  # name profile
    local name="$1" prof="$2" dir="$2/commands/$1" n
    if [ -d "$dir" ]; then
        n=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        FOUND_PATH="$dir"
        if [ "$prof" = "$ACTIVE_DIR" ]; then
            STATE="ok";   DETAIL="$n commands loadable"
        else
            # Component dirs are bound to the config dir the session runs under,
            # unlike settings.json hooks. Present elsewhere is not present here.
            STATE="warn"; DETAIL="$n commands, but not in the active profile"
        fi
    else
        STATE="missing"; DETAIL="no commands/$name directory"
    fi
}

probe_mcp() {  # name profile
    local name="$1" account; account="$(account_of "$2")"
    if [ -f "$account" ] && jq -e --arg n "$name" '(.mcpServers // {})[$n]' "$account" >/dev/null 2>&1; then
        STATE="ok"; FOUND_PATH="$account"; DETAIL="configured"
    else
        STATE="missing"; DETAIL="not configured"
    fi
}

# ── Census (union across profiles, deduped by name) ─────
union_count() {  # subdir [find-type]
    local sub="$1" type="${2:-}" p n
    n=$(for p in "${PROFILES[@]}"; do
            [ -d "$p/$sub" ] || continue
            if [ -n "$type" ]; then find "$p/$sub" -mindepth 1 -maxdepth 1 -type "$type" 2>/dev/null
            else find "$p/$sub" -mindepth 1 -maxdepth 1 2>/dev/null; fi
        done | sed 's|.*/||' | sort -u | grep -c .)
    printf '%s' "${n:-0}"
}

# Skills and agents can be symlinks into other repos, so probe by content
# (a skill is a directory carrying SKILL.md) rather than by inode type.
union_skills() {
    local p e n
    n=$(for p in "${PROFILES[@]}"; do
            [ -d "$p/skills" ] || continue
            for e in "$p/skills"/*; do
                [ -f "$e/SKILL.md" ] && printf '%s\n' "${e##*/}"
            done
        done | sort -u | grep -c .)
    printf '%s' "${n:-0}"
}

union_agents() {
    local p e n
    n=$(for p in "${PROFILES[@]}"; do
            [ -d "$p/agents" ] || continue
            for e in "$p/agents"/*.md; do
                [ -e "$e" ] && printf '%s\n' "${e##*/}"
            done
        done | sort -u | grep -c .)
    printf '%s' "${n:-0}"
}

union_jq_count() {  # jq-filter-producing-strings  file-selector(settings|account)
    local filter="$1" which="$2" p f n
    n=$(for p in "${PROFILES[@]}"; do
            if [ "$which" = "settings" ]; then f="$(settings_of "$p")"; else f="$(account_of "$p")"; fi
            [ -f "$f" ] || continue
            jq -r "$filter" "$f" 2>/dev/null
        done | sort -u | grep -c .)
    printf '%s' "${n:-0}"
}

# ── Collect ─────────────────────────────────────────────
collect() {
    local entries=() key label kind probe vcmd alt health note prof found_prof
    while IFS='|' read -r key label kind probe vcmd alt health note; do
        [ -z "${key:-}" ] && continue
        case "$key" in \#*) continue ;; esac

        STATE="missing"; FOUND_PATH=""; VERSION=""; DETAIL=""; found_prof=""
        case "$kind" in
            bin)  probe_bin "$probe" "${vcmd:-}" "${alt:-}" "${health:-}" ;;
            path) probe_path "$probe" ;;
            *)
                for prof in "${PROFILES[@]}"; do
                    STATE="missing"; FOUND_PATH=""; VERSION=""; DETAIL=""
                    case "$kind" in
                        hook)   probe_hook "$probe" "$prof" ;;
                        cmdset) probe_cmdset "$probe" "$prof" ;;
                        plugin) probe_plugin "$probe" "$prof" ;;
                        mcp)    probe_mcp "$probe" "$prof" ;;
                        *)      continue 2 ;;
                    esac
                    found_prof="$(profile_name "$prof")"
                    [ "$STATE" != "missing" ] && VERSION="$(resolve_version_spec "${vcmd:-}" "$prof")"
                    [ "$STATE" != "missing" ] && break
                done
                ;;
        esac

        entries+=("$(jq -n \
            --arg key "$key" --arg label "$label" --arg kind "$kind" \
            --arg state "$STATE" --arg path "${FOUND_PATH:-}" \
            --arg version "${VERSION:-}" --arg detail "${DETAIL:-}" \
            --arg note "${note:-}" --arg profile "${found_prof:-}" \
            '{key:$key,label:$label,kind:$kind,state:$state,path:$path,
              version:$version,detail:$detail,note:$note,profile:$profile}')")
    done < "$MANIFEST"

    local counts profiles_json
    counts=$(jq -n \
        --argjson plugins  "$(union_jq_count '(.enabledPlugins // {}) | to_entries[] | select(.value) | .key' settings)" \
        --argjson skills   "$(union_skills)" \
        --argjson agents   "$(union_agents)" \
        --argjson commands "$(union_count commands)" \
        --argjson hooks    "$(union_jq_count '(.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | .command' settings)" \
        --argjson mcp      "$(union_jq_count '(.mcpServers // {}) | keys[]' account)" \
        '{plugins:$plugins,skills:$skills,agents:$agents,commands:$commands,hooks:$hooks,mcp:$mcp}')

    profiles_json=$(printf '%s\n' "${PROFILES[@]}" | jq -R . | jq -s .)

    printf '%s\n' "${entries[@]}" | jq -s \
        --argjson counts "$counts" --argjson profiles "$profiles_json" \
        --arg active "$ACTIVE_DIR" --arg root "$TOOL_ROOT" \
        '{active_profile:$active, profiles:$profiles, tool_root:$root,
          tools:., counts:$counts}'
}

# ── Cache ───────────────────────────────────────────────
cache_file() {
    local key
    key=$(printf '%s' "${PROFILES[*]}$MANIFEST" | shasum -a 256 2>/dev/null | cut -c1-8)
    printf '%s/tool-status-%s.json' "$CACHE_DIR" "${key:-default}"
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

newest_settings_mtime() {
    local p m newest=0
    for p in "${PROFILES[@]}"; do
        m=$(mtime "$(settings_of "$p")"); [ -n "${m:-}" ] && [ "$m" -gt "$newest" ] && newest="$m"
    done
    printf '%s' "$newest"
}

inventory() {
    local file; file="$(cache_file)"
    if [ "$USE_CACHE" = 1 ] && [ -s "$file" ]; then
        local now cm age sm mm
        now=$(date +%s); cm=$(mtime "$file"); age=$(( now - ${cm:-0} ))
        sm=$(newest_settings_mtime); mm=$(mtime "$MANIFEST")
        if [ "$age" -lt "$CACHE_TTL" ] && [ "${sm:-0}" -le "${cm:-0}" ] && [ "${mm:-0}" -le "${cm:-0}" ]; then
            cat "$file"; return
        fi
    fi
    local json; json="$(collect)"
    [ -z "$json" ] && return 1
    mkdir -p "$CACHE_DIR" 2>/dev/null
    printf '%s' "$json" > "$file" 2>/dev/null
    printf '%s' "$json"
}

# ── Render ──────────────────────────────────────────────
render_segment() {
    local json="$1" out="🔧 " label state version first=1 counts
    while IFS=$'\t' read -r label state version; do
        [ -z "$label" ] && continue
        [ "$first" = 1 ] || out+="  "
        first=0
        case "$state" in
            ok)   out+="${green}${label} ✔${reset}"
                  [ -n "$version" ] && out+="${dim}$(short_version "$version")${reset}" ;;
            warn) out+="${amber}${label} ⚠${reset}" ;;
            *)    out+="${red}${label} ✘${reset}" ;;
        esac
    done < <(printf '%s' "$json" | jq -r '.tools[] | [.label, .state, (.version // "")] | @tsv')

    counts=$(printf '%s' "$json" | jq -r '
        .counts | ["\(.plugins) plugins","\(.skills) skills","\(.agents) agents","\(.mcp) mcp"]
        | join(" · ")')
    out+="\n   ${white}${counts}${reset}"
    printf '%b' "$out"
}

render_full() {
    local json="$1" label state path detail note profile mark color
    printf '%b\n' "${cyan}Claude tools${reset}  ${dim}source $(printf '%s' "$json" | jq -r .tool_root)${reset}"
    printf '%b\n' "${dim}profiles: $(printf '%s' "$json" | jq -r '.profiles | join(", ")')${reset}"
    echo
    while IFS=$'\t' read -r label state path detail note profile; do
        [ -z "$label" ] && continue
        case "$state" in
            ok)   mark="✔"; color="$green" ;;
            warn) mark="⚠"; color="$amber" ;;
            *)    mark="✘"; color="$red" ;;
        esac
        printf '%b\n' "  ${color}${mark}${reset} ${white}$(printf '%-8s' "$label")${reset} ${dim}${note}${reset}"
        [ -n "$path" ] && printf '%b\n' "    ${cyan}${path}${reset}"
        printf '%b\n' "    ${dim}${detail}${profile:+ · profile: $profile}${reset}"
    done < <(printf '%s' "$json" | jq -r '
        .tools[] | [.label,.state,(.path//""),.detail,.note,(.profile//"")] | @tsv')
    echo
    printf '%b\n' "  ${white}$(printf '%s' "$json" | jq -r '
        .counts | to_entries | map("\(.value) \(.key)") | join(" · ")')${reset}"
}

json="$(inventory)" || exit 0
[ -z "$json" ] && exit 0

case "$MODE" in
    json)    printf '%s\n' "$json" ;;
    full)    render_full "$json" ;;
    segment) render_segment "$json" ;;
esac
exit 0
