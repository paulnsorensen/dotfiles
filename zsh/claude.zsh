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

    # Seed Serena memories from main repo into worktree
    local serena_src="${repo_root}/.serena"
    local serena_dst="${repo_root}/${wt_dir}/.serena"
    if [[ -d "${serena_src}" ]] && [[ ! -d "${serena_dst}" ]]; then
        cp -r "${serena_src}" "${serena_dst}"
        rm -rf "${serena_dst}/cache" 2>/dev/null
        echo "Seeded Serena memories from main repo"
    fi

    # Seed local settings for the worktree session.
    # Copies main repo's settings.local.json (LSPs, custom permissions, etc.)
    # and ensures sandbox is enabled on top. Writes to a temp file first to
    # avoid truncated settings if jq fails on malformed input.
    local claude_local="${repo_root}/${wt_dir}/.claude/settings.local.json"
    if [[ ! -f "${claude_local}" ]]; then
        mkdir -p "${repo_root}/${wt_dir}/.claude"
        local main_local="${repo_root}/.claude/settings.local.json"
        local sandbox='{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'
        local tmp="${claude_local}.tmp"
        if [[ -f "${main_local}" ]]; then
            jq -s '.[0] * .[1]' "${main_local}" <(echo "${sandbox}") > "${tmp}" \
                && mv "${tmp}" "${claude_local}" \
                && echo "Copied local settings + enabled sandboxing"
        else
            echo "${sandbox}" | jq . > "${tmp}" \
                && mv "${tmp}" "${claude_local}" \
                && echo "Enabled sandboxing for worktree"
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

# Verify worktree permissions and sandbox config
ccw-check() {
    local slug="${1:-}"
    local repo_root

    if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        echo "Not a git repository"
        return 1
    fi

    # If no slug, try to detect from current directory
    if [[ -z "$slug" ]]; then
        local cwd="$(pwd)"
        if [[ "$cwd" == */.worktrees/* ]]; then
            slug="${cwd##*/.worktrees/}"
            slug="${slug%%/*}"
        else
            echo "Usage: ccw-check <slug>"
            echo "  Or run from inside a worktree directory"
            return 1
        fi
    fi

    local wt_dir="${repo_root}/.worktrees/${slug}"
    local ok=0
    local fail=0

    echo "Checking worktree: ${slug}"
    echo "──────────────────────────────"

    # 1. Worktree exists
    if [[ -d "${wt_dir}" ]]; then
        echo "✓ Worktree directory exists"
        ((ok++))
    else
        echo "✗ Worktree directory missing: ${wt_dir}"
        ((fail++))
        echo "  Run: ccw ${slug}"
        return 1
    fi

    # 2. Permission symlink
    local claude_projects="${HOME}/.claude/projects"
    local main_key="${repo_root//[\/.]/-}"
    local wt_key="${wt_dir//[\/.]/-}"

    if [[ -L "${claude_projects}/${wt_key}" ]]; then
        local target
        target="$(readlink "${claude_projects}/${wt_key}")"
        if [[ "$target" == "${claude_projects}/${main_key}" ]]; then
            echo "✓ Permission symlink → main repo"
            ((ok++))
        else
            echo "⚠ Permission symlink points to unexpected target: ${target}"
            ((fail++))
        fi
    elif [[ -d "${claude_projects}/${wt_key}" ]]; then
        echo "⚠ Permission dir exists but is not a symlink (perms not inherited)"
        ((fail++))
    else
        echo "✗ Permission symlink missing"
        ((fail++))
        echo "  Expected: ${claude_projects}/${wt_key} → ${claude_projects}/${main_key}"
    fi

    # 3. Local settings
    local claude_local="${wt_dir}/.claude/settings.local.json"
    if [[ -f "${claude_local}" ]]; then
        local sandbox_enabled auto_allow
        sandbox_enabled="$(jq -r '.sandbox.enabled // false' "${claude_local}" 2>/dev/null)"
        auto_allow="$(jq -r '.sandbox.autoAllowBashIfSandboxed // false' "${claude_local}" 2>/dev/null)"

        if [[ "$sandbox_enabled" == "true" ]]; then
            echo "✓ Sandbox enabled"
            ((ok++))
        else
            echo "✗ Sandbox not enabled"
            ((fail++))
        fi

        if [[ "$auto_allow" == "true" ]]; then
            echo "✓ autoAllowBashIfSandboxed enabled"
            ((ok++))
        else
            echo "⚠ autoAllowBashIfSandboxed not set (you'll get permission prompts)"
            ((fail++))
        fi
    else
        echo "✗ Local settings missing: ${claude_local}"
        ((fail++))
        echo "  Run: ccw ${slug}  (it seeds settings on first launch)"
    fi

    # 4. Serena memories
    if [[ -d "${wt_dir}/.serena" ]]; then
        echo "✓ Serena memories seeded"
        ((ok++))
    else
        echo "– Serena memories not seeded (optional)"
    fi

    echo "──────────────────────────────"
    echo "${ok} passed, ${fail} issues"
    [[ $fail -eq 0 ]]
}

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
# LSP Management (local-only — not loaded for headless/CI sessions)
# ═══════════════════════════════════════════════════════════════════
alias lsp-sync='$CLAUDE_DOTFILES/plugins/lsp-sync.sh'
alias lsp-sync-dry='$CLAUDE_DOTFILES/plugins/lsp-sync.sh --dry-run'
alias lsp-disable='$CLAUDE_DOTFILES/plugins/lsp-sync.sh --disable'
alias lsp-ls='$CLAUDE_DOTFILES/plugins/lsp-sync.sh --list'
alias lsp-edit='${EDITOR:-vim} $CLAUDE_DOTFILES/plugins/lsp-registry.yaml'
