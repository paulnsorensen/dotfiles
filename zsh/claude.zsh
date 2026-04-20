############################
# claude.zsh
# Claude Code CLI utilities and MCP management
############################

# On-demand tool loading (Claude Code v2.0.74+)
export ENABLE_TOOL_SEARCH=true

# Default off: claude.ai connectors (Figma, Gmail, n8n, Drive, etc.) inject
# multi-paragraph instruction blocks into every session. Profiles that need
# specific connectors re-enable this via env_vars=(...) in their launch.zsh.
export ENABLE_CLAUDEAI_MCP_SERVERS=false

# ═══════════════════════════════════════════════════════════════════
# Quick Access
# ═══════════════════════════════════════════════════════════════════
alias ccc='claude --continue'
alias ccr='claude --resume'
alias ccp='claude --print'

# Fresh session: prime MCPs in last conversation, then open it interactively
ccfresh() {
  claude --continue -p '/go' && claude --continue
}

# Session monitor
alias ccm='claude-monitor'

# ═══════════════════════════════════════════════════════════════════
# cc — claude wrapper with profile support
# ═══════════════════════════════════════════════════════════════════
# Usage:
#   cc                 → plain claude (default dev env)
#   cc -p <name>       → launch the named profile from claude/profiles/<name>/
#   cc -p              → list available profiles
#   cc <args>          → pass through to claude (e.g. cc --resume)
#
# Each profile is a directory under claude/profiles/<name>/. Files are
# auto-wired if present — drop a new directory in and it works:
#   CLAUDE.md       → --append-system-prompt-file
#   settings.json   → --setting-sources "" --settings (no inherited config)
#   mcp.json        → --strict-mcp-config --mcp-config (replaces user MCPs)
#   mcp-add.json    → --mcp-config (additive — adds to user MCPs)
#   launch.zsh      → sourced; may set extra_args=(...) for --plugin-dir,
#                     --tools, --dangerously-skip-permissions, etc.
#                     may set env_vars=(KEY=value ...) for per-profile env.
cc() {
    if [[ "$1" == "-p" ]]; then
        shift
        _cc_launch_profile "$@"
        return
    fi
    claude "$@"
}

_cc_launch_profile() {
    local profiles_dir="$DOTFILES_DIR/claude/profiles"
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "Available profiles:"
        for dir in "$profiles_dir"/*/; do
            [[ -d "$dir" ]] && echo "  ${${dir%/}:t}"
        done
        echo ""
        echo "Usage: cc -p <name> [claude args...]"
        return 1
    fi
    shift

    local profile="$profiles_dir/$name"
    if [[ ! -d "$profile" ]]; then
        echo "cc: no profile '$name' (looked in $profile)" >&2
        return 1
    fi

    local args=()
    [[ -f "$profile/CLAUDE.md" ]] && args+=(--append-system-prompt-file "$profile/CLAUDE.md")
    [[ -f "$profile/settings.json" ]] && args+=(--setting-sources "" --settings "$profile/settings.json")
    [[ -f "$profile/mcp.json" ]] && args+=(--strict-mcp-config --mcp-config "$profile/mcp.json")
    [[ -f "$profile/mcp-add.json" ]] && args+=(--mcp-config "$profile/mcp-add.json")

    local extra_args=()
    local env_vars=()
    [[ -f "$profile/launch.zsh" ]] && source "$profile/launch.zsh"

    if (( ${#env_vars[@]} > 0 )); then
        env "${env_vars[@]}" claude "${args[@]}" "${extra_args[@]}" "$@"
    else
        claude "${args[@]}" "${extra_args[@]}" "$@"
    fi
}

# Tab completion for `cc`:
#   cc -p <TAB>     → lists profile directory names
#   cc <TAB>        → suggests -p flag
_cc() {
    if [[ "${words[CURRENT-1]}" == "-p" ]]; then
        local -a profiles
        local dir
        for dir in "$DOTFILES_DIR/claude/profiles"/*/; do
            [[ -d "$dir" ]] && profiles+=("${${dir%/}:t}")
        done
        _describe 'profile' profiles
        return
    fi
    if (( CURRENT == 2 )); then
        _values 'cc option' '-p[launch a scoped profile]'
    fi
}
compdef _cc cc

# ═══════════════════════════════════════════════════════════════════
# MCP Management (thin wrappers around native commands)
# ═══════════════════════════════════════════════════════════════════
CLAUDE_DOTFILES="$DOTFILES_DIR/claude"

alias mcp='claude mcp'
alias mcp-ls='claude mcp list'
alias mcp-sync='$CLAUDE_DOTFILES/mcp/sync.sh'
alias mcp-sync-dry='$CLAUDE_DOTFILES/mcp/sync.sh --dry-run'
alias mcp-edit='${EDITOR:-vim} $CLAUDE_DOTFILES/mcp/registry.yaml'

# Add user-scoped MCP (available in all projects)
mcp-add() {
    if [[ -z "$1" || -z "$2" ]]; then
        echo "Usage: mcp-add <name> <command> [args...]"
        echo "Example: mcp-add my-server npx -y @my/mcp-server"
        return 1
    fi
    local name="$1"
    shift
    claude mcp add -s user "$name" -- "$@"
    echo "Don't forget to add to registry: mcp-edit"
}

# ═══════════════════════════════════════════════════════════════════
# Worktree Sessions
# ═══════════════════════════════════════════════════════════════════

# Launch Claude in an isolated worktree
#   ccw my-feature        → creates .worktrees/my-feature, branch claude/my-feature, opens claude
#   ccw my-feature --resume → same but resumes last conversation
ccw() {
    if [[ -z "$1" ]]; then
        echo "Usage: ccw <slug> [claude args...]"
        echo "  ccw add-auth          Launch claude in .worktrees/add-auth"
        echo "  ccw add-auth --resume Resume last session in that worktree"
        return 1
    fi

    local slug="$1"
    shift

    # Find ccw-init relative to repo or DOTFILES_DIR
    local ccw_init="${DOTFILES_DIR}/bin/ccw-init"
    if [[ ! -f "${ccw_init}" ]]; then
        # Fallback: check if it's in the current repo
        local repo_root
        repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
        ccw_init="${repo_root}/bin/ccw-init"
    fi

    if [[ ! -f "${ccw_init}" ]]; then
        echo "ccw-init not found" >&2
        return 1
    fi

    local result
    result="$("${ccw_init}" "${slug}")" || return 1

    local wt_path
    wt_path="$(echo "$result" | jq -er '.path')" || { echo "ccw: failed to parse worktree path" >&2; return 1; }
    [[ -d "$wt_path" ]] || { echo "ccw: worktree path not found: $wt_path" >&2; return 1; }

    cd "${wt_path}" && claude "$@"
}

# Clean worktrees — single-repo (current dir) or full sweep (~/Dev)
ccw-clean() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Not a git repository"
        return 1
    fi
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    ccw-sweep --path "$repo_root" "$@"
}

# Sweep all repos under ~/Dev for stale worktrees
alias ccw-sweep='$DOTFILES_DIR/bin/ccw-sweep'

# List active worktrees
alias ccw-ls='git worktree list'

# Verify worktree permissions and sandbox config (lives in bin/)
alias ccw-check='$DOTFILES_DIR/bin/ccw-check'

# GitHub helpers (gh-pr-review, gh-pr-prep, gh-issue-context) live in bin/

# ═══════════════════════════════════════════════════════════════════
# Config Shortcuts
# ═══════════════════════════════════════════════════════════════════
alias claude-settings='${EDITOR:-vim} ~/.claude/settings.json'

# ═══════════════════════════════════════════════════════════════════
# Plugin Management (thin wrappers around native commands)
# ═══════════════════════════════════════════════════════════════════
alias plugin='claude plugin'
alias plugin-ls='claude plugin list'
alias plugin-sync='$CLAUDE_DOTFILES/plugins/sync.sh'
alias plugin-sync-dry='$CLAUDE_DOTFILES/plugins/sync.sh --dry-run'
alias plugin-edit='${EDITOR:-vim} $CLAUDE_DOTFILES/plugins/registry.yaml'

# ═══════════════════════════════════════════════════════════════════
# RTK — Rust Token Killer (github.com/rtk-ai/rtk)
# ═══════════════════════════════════════════════════════════════════
# Claude Code hook is tracked in claude/settings.json, so no Claude init
# is needed after a fresh `dots sync`. These aliases mirror the commands
# on https://github.com/rtk-ai/rtk#quick-start for the remaining agents
# plus a manual Claude refresh. All three are idempotent.
alias rtk-init-claude='rtk init -g'                       # global
alias rtk-init-cursor='rtk init -g --agent cursor'        # global
alias rtk-init-antigravity='rtk init --agent antigravity' # project-scoped, run in project root

# ═══════════════════════════════════════════════════════════════════
# Ralphify (autonomous coding loops — github.com/computerlovetech/ralphify)
# ═══════════════════════════════════════════════════════════════════
# ralph binary is installed via `uv tool install ralphify` and lives in
# ~/.local/bin. Prefer the pinned path so this works even if PATH is stale.
ralph() {
    if [[ -x "$HOME/.local/bin/ralph" ]]; then
        "$HOME/.local/bin/ralph" "$@"
    else
        command ralph "$@"
    fi
}

# rw — run a ralph with sensible defaults:
#   - 30-minute per-iteration timeout
#   - per-iteration logs captured under <ralph>/logs
#   - stop on error (-s) so a broken iteration doesn't loop forever
#   - defaults to -n 50 — sized for an overnight/12-hour run at ~15 min
#     per iteration. Use guard.sh to stop early when work is done.
rw() {
    if [[ -z "$1" || "$1" == "-h" || "$1" == "--help" ]]; then
        echo "Usage: rw <ralph-path> [extra ralph run flags...]" >&2
        echo "  rw ralphs/coverage          # sanity check: one iteration" >&2
        echo "  rw ralphs/coverage -n 50    # up to 10 iterations" >&2
        echo "  rw ralphs/coverage -n 9999  # effectively unbounded (omit cap)" >&2
        return 1
    fi
    if [[ ! -x "$HOME/.local/bin/ralph" ]] && ! command -v ralph &>/dev/null; then
        echo "rw: ralph not installed — run: uv tool install ralphify" >&2
        return 1
    fi
    local ralph_path="${1%/}"
    shift
    if [[ ! -f "$ralph_path/RALPH.md" ]]; then
        echo "rw: no RALPH.md at $ralph_path" >&2
        return 1
    fi
    local log_dir="${ralph_path}/logs"
    if ! mkdir -p "$log_dir"; then
        echo "rw: failed to create log directory: $log_dir" >&2
        return 1
    fi
    local has_n=0
    for arg in "$@"; do
        [[ "$arg" == "-n" || "$arg" == --max-iterations* ]] && has_n=1 && break
    done
    local default_n=()
    (( has_n == 0 )) && default_n=(-n 50)
    ralph run "$ralph_path" -t 1800 -l "$log_dir" -s "${default_n[@]}" "$@"
}
