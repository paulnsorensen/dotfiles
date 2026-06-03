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
# preamble.md replaces Claude's baked system prompt via --system-prompt-file.
# CLAUDE.md auto-discovery, hooks, plugins, auto-memory all stay active —
# only Anthropic's system prompt is swapped out. Symbol-level reads/edits
# now route through Serena (MCP) instead of dynamically gated LSP plugins.
cc() {
    local -a flags=()
    [[ -f "$AGENTS_DOTFILES/preamble.md" ]] && flags+=(--system-prompt-file "$AGENTS_DOTFILES/preamble.md")
    claude "${flags[@]}" "$@"
}

ccc() {
    local -a flags=()
    [[ -f "$AGENTS_DOTFILES/preamble.md" ]] && flags+=(--system-prompt-file "$AGENTS_DOTFILES/preamble.md")
    claude "${flags[@]}" --continue "$@"
}

ccr() {
    local -a flags=()
    [[ -f "$AGENTS_DOTFILES/preamble.md" ]] && flags+=(--system-prompt-file "$AGENTS_DOTFILES/preamble.md")
    claude "${flags[@]}" --resume "$@"
}

# Fresh session: prime MCPs in last conversation, then open it interactively
ccfresh() {
  local -a flags=()
  [[ -f "$AGENTS_DOTFILES/preamble.md" ]] && flags+=(--system-prompt-file "$AGENTS_DOTFILES/preamble.md")
  claude "${flags[@]}" --continue -p '/go' && claude "${flags[@]}" --continue
}

# Copilot CLI launch wrapper — injects the canonical allow/deny lists as
# --allow-tool / --deny-tool flags (lever 1). Copilot has no config-file
# surface for per-command rules, so the rules only apply when Copilot is
# launched through this wrapper; a bare `copilot` run gets nothing. MCP-tool
# scoping (lever 3) lands in ~/.copilot/mcp-config.json at install time and
# applies regardless of launch path.
copilot() {
    # Fail-closed: this wrapper's entire job is lowering the canonical
    # allow/deny security floor. If `ap` is missing or errors (e.g. a profile
    # that won't parse), launching Copilot unrestricted would silently drop
    # that floor — so capture the flags and exit status separately, and on any
    # failure (including a mid-stream crash after partial output) abort loudly
    # rather than launch with a missing or truncated deny set.
    local out status
    out="$(ap copilot-flags global)"
    status=$?
    if (( status != 0 )); then
        echo "copilot: permission flags unavailable (ap exited $status) — refusing to launch unrestricted." >&2
        echo "copilot: fix \`ap copilot-flags global\`, or run \`command copilot\` to bypass the floor deliberately." >&2
        return "$status"
    fi
    local -a flags=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && flags+=("$line")
    done <<< "$out"
    command copilot "${flags[@]}" "$@"
}

# ═══════════════════════════════════════════════════════════════════
# Scoped profiles — `dots profile launch <harness> <name>`
# ═══════════════════════════════════════════════════════════════════
# The retired `ccp` launcher is superseded by the harness-agnostic `ap`
# tool: profiles live at profiles/<name>/profile.yaml and launch via
#   dots profile launch claude <name> [-- claude args...]
# Isolated profiles (isolated: true) reproduce the old ccp closed-world
# semantics (strict MCP scope, --setting-sources "", --tools whitelist,
# --append-system-prompt-file, permissions deny, env, extra_args).
#   dots profile list            → list available profiles
#   dots profile describe <name> → show the resolved manifest
# For default Claude Code (no profile), use `cc`.

# ═══════════════════════════════════════════════════════════════════
# MCP Management (thin wrappers around native commands)
# ═══════════════════════════════════════════════════════════════════
CLAUDE_DOTFILES="$DOTFILES_DIR/claude"
AGENTS_DOTFILES="$DOTFILES_DIR/agents"

# Deploy the registry-derived `base` profile via `ap`. Mirrors
# chezmoi/lib/install-base-profile.sh's two-target asymmetry: the dot-dir
# harnesses (claude/codex/cursor/copilot) render under $HOME, while opencode
# writes opencode.json at the target root, so it targets $HOME/.config/opencode.
# A bare `dots profile install base` defaults --target to $PWD (the cwd trap),
# so the deploy verb must pin $HOME.
base-sync() {
    dots profile install base --target "$HOME" \
        --harness claude,codex,cursor,copilot \
        && dots profile install base --target "$HOME/.config/opencode" \
        --harness opencode
}
alias mcp='claude mcp'
alias mcp-ls='claude mcp list'
# Deploy is unified through `ap`: the registry stays the edit surface
# (mcp-edit), and base-sync renders the registry-derived union into every
# harness at $HOME (curd 7 / D1 — replaces the retired mcp sync).
alias mcp-sync='base-sync'
alias mcp-edit='${EDITOR:-vim} $AGENTS_DOTFILES/mcp/registry.yaml'

# ═══════════════════════════════════════════════════════════════════
# Hook Management (harness-agnostic — edit surface; deploy via `ap`)
# ═══════════════════════════════════════════════════════════════════
alias hook-sync='base-sync'
alias hook-edit='${EDITOR:-vim} $AGENTS_DOTFILES/hooks/registry.yaml'
alias hook-ls='yq -r ".hooks | keys | .[]" $AGENTS_DOTFILES/hooks/registry.yaml'

# ═══════════════════════════════════════════════════════════════════
# Agent Management (harness-agnostic — edit surface; deploy via `ap`)
# ═══════════════════════════════════════════════════════════════════
alias agent-sync='base-sync'
alias agent-edit='${EDITOR:-vim} $AGENTS_DOTFILES/registry.yaml'
alias agent-ls='yq -r ".agents | keys | .[]" $AGENTS_DOTFILES/registry.yaml'

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

    cd "${wt_path}" && cc "$@"
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

# Refresh a local plugin's cache so edits in the source dir take effect.
# Claude Code copies plugins into ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
# at install time, keyed by version. Same-version edits in the source don't propagate
# until the cache is rebuilt. This nukes the version dir and reinstalls.
#
# Usage: cf-refresh                    # refresh cheese-flow@local (default)
#        cf-refresh vaudeville         # refresh vaudeville@local
#        cf-refresh <plugin> <market>  # refresh <plugin>@<market>
plugin-refresh() {
    local plugin_name="${1:-cheese-flow}"
    local marketplace="${2:-local}"
    local cache_dir="$HOME/.claude/plugins/cache/$marketplace/$plugin_name"

    echo "Refreshing $plugin_name@$marketplace"

    echo "  → marketplace update $marketplace"
    claude plugin marketplace update "$marketplace" || return 1

    if [[ -d "$cache_dir" ]]; then
        echo "  → clearing $cache_dir"
        rm -rf "$cache_dir"
    fi

    echo "  → reinstalling $plugin_name"
    if ! claude plugin update "$plugin_name" -s user 2>/dev/null; then
        claude plugin install -s user "$plugin_name@$marketplace" || return 1
    fi

    echo "Done. Restart Claude Code to apply."
}
alias cf-refresh='plugin-refresh cheese-flow local'

# ═══════════════════════════════════════════════════════════════════
# Cursor plugins (local source-of-truth lives in dotfiles/cursor/)
# ═══════════════════════════════════════════════════════════════════
# Cursor reads ~/.cursor/{skills,rules,commands,hooks,modes.json,hooks.json,
# mcp.json}. The plugin source under cursor/plugins/local/ is deployed there
# by chezmoi's run_onchange_install-cursor-plugins.sh.tmpl, which dispatches
# to chezmoi/lib/install-cursor-plugin.sh per plugin folder. MCPs flow via
# agents/mcp/sync.sh's cursor harness (jq-edits ~/.cursor/mcp.json).
alias cursor-plugin-edit='${EDITOR:-vim} $DOTFILES_DIR/cursor/plugins/local'
alias cursor-plugin-sync='chezmoi apply --force --source $DOTFILES_DIR/chezmoi'
alias cursor-plugin-ls='ls -la ~/.cursor/skills/ ~/.cursor/rules/ ~/.cursor/commands/ ~/.cursor/hooks/ 2>/dev/null'

# ═══════════════════════════════════════════════════════════════════
# Vaudeville (SLM hook enforcement — Claude Code plugin)
# ═══════════════════════════════════════════════════════════════════
# Binary is installed via `uv tool install vaudeville` at ~/.local/bin.
# Tab completion is defined in zsh/completion.zsh and bound to both names.
alias vdv='vaudeville'

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
