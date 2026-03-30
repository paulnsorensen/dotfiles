############################
# claude.zsh
# Claude Code CLI utilities and MCP management
############################

# On-demand tool loading (Claude Code v2.0.74+)
export ENABLE_TOOL_SEARCH=true

# ═══════════════════════════════════════════════════════════════════
# Quick Access
# ═══════════════════════════════════════════════════════════════════
alias cc='claude'
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
