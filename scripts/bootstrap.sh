#!/usr/bin/env bash
# Bootstrap a Claude Code setup from nothing.
#
# Installs the marketplaces, plugins, and MCP servers this repo documents, plus
# the third-party CLI tools they lean on. Every step is idempotent: running it
# twice is safe, and running it on a half-configured machine finishes the job
# rather than starting over.
#
#   ./scripts/bootstrap.sh              # ask before changing anything
#   ./scripts/bootstrap.sh --yes        # no prompts
#   ./scripts/bootstrap.sh --dry-run    # print the plan, change nothing
#   ./scripts/bootstrap.sh --skip-cli   # plugins and MCP only, no brew/uv

set -uo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
DIM='\033[2m'; NC='\033[0m'
info()    { printf "${BLUE}→${NC} %s\n" "$*"; }
success() { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}!${NC} %s\n" "$*"; }
fail()    { printf "${RED}✗${NC} %s\n" "$*" >&2; }
skip()    { printf "${DIM}·${NC} %s\n" "$*"; }

DRY_RUN=0; ASSUME_YES=0; SKIP_CLI=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --yes|-y)   ASSUME_YES=1 ;;
        --skip-cli) SKIP_CLI=1 ;;
        --help|-h)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          fail "Unknown option: $arg"; exit 2 ;;
    esac
done

FAILURES=0

# run <description> <command...>
run() {
    local desc="$1"; shift
    if [ "$DRY_RUN" -eq 1 ]; then
        skip "would: $desc"
        return 0
    fi
    if "$@" >/dev/null 2>&1; then
        success "$desc"
    else
        fail "$desc"
        FAILURES=$((FAILURES + 1))
    fi
}

# ── Preflight ─────────────────────────────────────────────────────────────────

echo ""
echo "  Bootstrapping a Claude Code setup"
echo "  ─────────────────────────────────"
echo ""

case "$(uname -s)" in
    Darwin)                 PLATFORM=macos ;;
    Linux)                  PLATFORM=linux ;;
    MINGW*|MSYS*|CYGWIN*)   PLATFORM=windows ;;
    *)                      PLATFORM=unknown ;;
esac
info "Platform: $PLATFORM"

MISSING=0
for tool in claude git; do
    if command -v "$tool" >/dev/null 2>&1; then
        success "$tool found"
    else
        fail "$tool is required and was not found"
        MISSING=1
    fi
done

# Windows has no dependable python3; accept any real Python 3.
PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PYTHON="$candidate"; break
    fi
done
if [ -z "$PYTHON" ] && command -v py >/dev/null 2>&1 && py -3 -c '' >/dev/null 2>&1; then
    PYTHON="py -3"
fi
if [ -n "$PYTHON" ]; then
    success "python found ($PYTHON)"
else
    fail "Python 3 is required and was not found"
    MISSING=1
fi

if [ "$PLATFORM" = "windows" ] && [ -z "${MSYSTEM:-}" ]; then
    warn "Run this from Git Bash, not PowerShell or CMD."
fi

if [ "$MISSING" -eq 1 ]; then
    echo ""
    fail "Install the missing prerequisites first. See docs/windows.md on Windows."
    exit 1
fi

# ── Confirm ───────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    echo ""
    echo "  This will add plugin marketplaces, install plugins, register the"
    echo "  context7 MCP server, and (unless --skip-cli) install CLI tools."
    echo "  Everything is idempotent and nothing is removed."
    echo ""
    read -r -p "  Continue? [Y/n] " confirm
    confirm="${confirm:-Y}"
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── Marketplaces ──────────────────────────────────────────────────────────────

echo ""
info "Plugin marketplaces"
run "marketplace: claude-plugins-official" claude plugin marketplace add anthropics/claude-plugins-official
run "marketplace: thedotmack (claude-mem)" claude plugin marketplace add thedotmack/claude-mem
run "marketplace: my-claude-tools"         claude plugin marketplace add fahdi/my-claude-tools

# ── Plugins ───────────────────────────────────────────────────────────────────

echo ""
info "Plugins"
PLUGINS=(
    # Built here
    captains-log@my-claude-tools
    dev-diary@my-claude-tools
    claude-workflows@my-claude-tools
    # Third party
    superpowers@claude-plugins-official
    plugin-dev@claude-plugins-official
    claude-code-setup@claude-plugins-official
    frontend-design@claude-plugins-official
    chrome-devtools-mcp@claude-plugins-official
    playwright@claude-plugins-official
    rust-analyzer-lsp@claude-plugins-official
    claude-mem@thedotmack
)
for plugin in "${PLUGINS[@]}"; do
    run "plugin: $plugin" claude plugin install "$plugin"
done

# ── MCP servers ───────────────────────────────────────────────────────────────

echo ""
info "MCP servers"
if [ "$DRY_RUN" -eq 0 ] && claude mcp list 2>/dev/null | grep -q '^context7'; then
    skip "mcp: context7 already registered"
else
    run "mcp: context7" claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp
fi

# ── CLI tools ─────────────────────────────────────────────────────────────────

if [ "$SKIP_CLI" -eq 1 ]; then
    echo ""
    skip "CLI tools skipped (--skip-cli)"
else
    echo ""
    info "CLI tools"

    # rtk proxies shell commands through a token-saving rewriter.
    if command -v rtk >/dev/null 2>&1; then
        skip "rtk already installed"
    elif command -v brew >/dev/null 2>&1; then
        run "rtk (brew)" brew install rtk
    else
        warn "rtk: needs Homebrew, which was not found — see docs/stack.md"
    fi

    # bats runs the shell-hook test suites. There is no Windows build.
    if command -v bats >/dev/null 2>&1; then
        skip "bats already installed"
    elif [ "$PLATFORM" = "windows" ]; then
        skip "bats: no Windows build; run the bash suites under WSL"
    elif command -v brew >/dev/null 2>&1; then
        run "bats-core (brew)" brew install bats-core
    else
        warn "bats: needs Homebrew — see https://github.com/bats-core/bats-core"
    fi

    # pytest runs the Python suites.
    if command -v pytest >/dev/null 2>&1 || [ -x "$HOME/.local/bin/pytest" ]; then
        skip "pytest already installed"
    elif command -v uv >/dev/null 2>&1; then
        run "pytest (uv)" uv tool install pytest
    else
        run "pytest (pip)" $PYTHON -m pip install --user pytest
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "  ─────────────────────────────────────────────────────"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  Dry run complete. Nothing was changed."
elif [ "$FAILURES" -eq 0 ]; then
    echo "  Done. Restart Claude Code to pick up the new plugins."
    echo ""
    echo "  The two diaries create themselves at ~/Code/captains-log and"
    echo "  ~/Code/devdiary the first time a session does real work."
else
    echo "  Finished with $FAILURES failure(s) — see the ✗ lines above."
    echo "  Re-running is safe; it will retry only what did not land."
fi
echo "  ─────────────────────────────────────────────────────"
echo ""

[ "$FAILURES" -eq 0 ]
