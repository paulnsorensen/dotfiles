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

    # Disable pre-commit hooks in worktrees. Prek writes to ~/.cache/prek/
    # which is outside the Seatbelt sandbox write paths, causing "Operation
    # not permitted" on every commit. Worktrees are ephemeral branches where
    # prek's claude-sync and shellcheck hooks aren't meaningful anyway.
    git -C "${repo_root}/${wt_dir}" config core.hooksPath /dev/null 2>/dev/null

    local claude_local="${repo_root}/${wt_dir}/.claude/settings.local.json"
    if [[ ! -f "${claude_local}" ]]; then
        mkdir -p "${repo_root}/${wt_dir}/.claude"
        local generator="${DOTFILES_DIR}/claude/worktree-settings.sh"
        local tmp_settings="${claude_local}.tmp"
        if [[ -f "${generator}" ]]; then
            bash "${generator}" "${DOTFILES_DIR}" > "${tmp_settings}" \
                && mv "${tmp_settings}" "${claude_local}" \
                && echo "Generated worktree settings (sandbox + $(jq '.permissions.allow | length' "${claude_local}") permissions)"
        else
            echo '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}' > "${tmp_settings}" \
                && mv "${tmp_settings}" "${claude_local}" \
                && echo "Enabled sandboxing for worktree (generator not found)"
        fi
    fi

    cd "${repo_root}/${wt_dir}" && claude "$@"
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
# lspmux (LSP multiplexer)
# ═══════════════════════════════════════════════════════════════════
alias lspmux-restart='launchctl bootout gui/$(id -u)/com.lspmux.server 2>/dev/null; sleep 1; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lspmux.server.plist && echo "lspmux restarted"'
alias lspmux-status='lspmux status'

# ═══════════════════════════════════════════════════════════════════
# Plugin Management (thin wrappers around native commands)
# ═══════════════════════════════════════════════════════════════════
alias plugin='claude plugin'
alias plugin-ls='claude plugin list'
alias plugin-sync='$CLAUDE_DOTFILES/plugins/sync.sh'
alias plugin-sync-dry='$CLAUDE_DOTFILES/plugins/sync.sh --dry-run'
alias plugin-edit='${EDITOR:-vim} $CLAUDE_DOTFILES/plugins/registry.yaml'
