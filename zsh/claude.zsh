############################
# claude.zsh
# Claude Code CLI utilities and MCP management
############################

# ═══════════════════════════════════════════════════════════════════
# Quick Access
# ═══════════════════════════════════════════════════════════════════
alias cc='claude'
alias ccc='claude --continue'
alias ccr='claude --resume'
alias ccp='claude --print'

# ═══════════════════════════════════════════════════════════════════
# MCP Management (thin wrappers around native commands)
# ═══════════════════════════════════════════════════════════════════
CLAUDE_DOTFILES="$HOME/Dev/dotfiles/claude"

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
    local wt_dir=".worktrees/${slug}"
    local branch="claude/${slug}"

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Not a git repository"
        return 1
    fi

    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

    if [[ -d "${repo_root}/${wt_dir}" ]]; then
        echo "Resuming worktree: ${wt_dir}"
    else
        echo "Creating worktree: ${wt_dir} (branch: ${branch})"
        git -C "${repo_root}" worktree add "${wt_dir}" -b "${branch}" || return 1
    fi

    # Share Claude project permissions with the worktree.
    # Claude keys perms by absolute path (/ and . replaced with -).
    # Symlink the worktree's project dir to the main repo's so perms carry over.
    local claude_projects="${HOME}/.claude/projects"
    local main_key="${repo_root//[\/.]/-}"
    local wt_key="${repo_root}/${wt_dir}"
    wt_key="${wt_key//[\/.]/-}"

    if [[ -d "${claude_projects}/${main_key}" ]] && [[ ! -L "${claude_projects}/${wt_key}" ]]; then
        rm -rf "${claude_projects}/${wt_key}" 2>/dev/null
        ln -s "${claude_projects}/${main_key}" "${claude_projects}/${wt_key}"
        echo "Linked permissions: ${wt_key} → ${main_key}"
    fi

    cd "${repo_root}/${wt_dir}" && claude "$@"
}

# Remove worktrees whose claude/* branches are merged into main
ccw-clean() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Not a git repository"
        return 1
    fi

    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    local wt_root="${repo_root}/.worktrees"
    local cleaned=0

    if [[ ! -d "${wt_root}" ]]; then
        echo "No .worktrees/ directory"
        return 0
    fi

    # Get branches merged into main
    local merged
    merged="$(git -C "${repo_root}" branch --merged main 2>/dev/null | sed 's/^[ *]*//')"

    for slug_dir in "${wt_root}"/*(N/); do
        local slug="${slug_dir:t}"
        local branch="claude/${slug}"

        if echo "${merged}" | grep -qx "${branch}"; then
            echo "Removing: ${slug} (${branch} merged)"
            git -C "${repo_root}" worktree remove "${slug_dir}" 2>/dev/null
            git -C "${repo_root}" branch -d "${branch}" 2>/dev/null
            ((cleaned++))
        fi
    done

    if (( cleaned == 0 )); then
        echo "Nothing to clean — no merged worktrees found"
        # Show what's still active
        local active=("${wt_root}"/*(N/:t))
        if (( ${#active} > 0 )); then
            echo "Active worktrees: ${active[*]}"
        fi
    else
        echo "Cleaned ${cleaned} worktree(s)"
    fi
}

# List active worktrees
alias ccw-ls='git worktree list'

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
