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
# Compute which LSP plugins this repo needs based on tokei line counts.
# Writes a minimal JSON gate file and prints its path. Prints nothing on failure.
_cc_lsp_gate() {
    git rev-parse --is-inside-work-tree &>/dev/null || return 0

    local threshold="${CC_LSP_GATE_THRESHOLD:-50}"
    local gate_file
    gate_file="$(mktemp -t claude-lsp-gate).json"

    tokei --output json | jq --argjson t "$threshold" '{
      enabledPlugins: {
        "bash-language-server@claude-code-lsps": (([.BASH.code//0,.Shell.code//0,.Zsh.code//0]|add) >= $t),
        "vtsls@claude-code-lsps":               (([.JavaScript.code//0,.TypeScript.code//0,.TSX.code//0,.JSX.code//0]|add) >= $t),
        "yaml-language-server@claude-code-lsps": ((.YAML.code//0) >= $t),
        "rust-analyzer@claude-code-lsps":        ((.Rust.code//0) >= $t),
        "pyright@claude-code-lsps":              ((.Python.code//0) >= $t),
        "gopls@claude-code-lsps":               ((.Go.code//0) >= $t)
      }
    }' > "$gate_file" || return 0

    echo "$gate_file"
}

cc() {
    local gate; gate="$(_cc_lsp_gate)" || gate=""
    if [[ -n "$gate" ]]; then
        claude --settings "$gate" "$@"
    else
        claude "$@"
    fi
}

ccc() {
    local gate; gate="$(_cc_lsp_gate)" || gate=""
    if [[ -n "$gate" ]]; then
        claude --settings "$gate" --continue "$@"
    else
        claude --continue "$@"
    fi
}

ccr() {
    local gate; gate="$(_cc_lsp_gate)" || gate=""
    if [[ -n "$gate" ]]; then
        claude --settings "$gate" --resume "$@"
    else
        claude --resume "$@"
    fi
}

# Fresh session: prime MCPs in last conversation, then open it interactively
ccfresh() {
  claude --continue -p '/go' && claude --continue
}

# Session monitor
alias ccm='claude-monitor'

# ═══════════════════════════════════════════════════════════════════
# ccp — launch claude with a scoped profile
# ═══════════════════════════════════════════════════════════════════
# Usage:
#   ccp                 → list available profiles and exit
#   ccp <name>          → launch the named profile from claude/profiles/<name>/
#   ccp <name> <args>   → pass extra args through to claude
#
# For default Claude Code (no profile), use `cc`.
#
# Each profile is a directory under claude/profiles/<name>/. Files are
# auto-wired if present — drop a new directory in and it works:
#   CLAUDE.md            → --append-system-prompt-file
#   settings.json        → --setting-sources "" --settings (no inherited config)
#   settings-merge.json  → --settings (additive — merges on top of the
#                          preceding settings layer: user settings when
#                          there's no settings.json in the profile, or the
#                          profile's settings.json when both are present.
#                          Use for per-profile enabledPlugins overrides.)
#   mcp-scope.yaml       → preferred; list of MCP names validated against
#                          claude/mcp/registry.yaml. Generates a strict mcp.json
#                          at launch (combined with mcp-add.json if present).
#   mcp.json             → legacy; hand-written strict mcp config.
#   mcp-add.json         → additive. Merged into mcp-scope output if both exist;
#                          otherwise --mcp-config on top of user MCPs.
#   launch.zsh           → sourced; may set extra_args=(...) for --plugin-dir,
#                          --tools, --dangerously-skip-permissions, etc.
#                          may set env_vars=(KEY=value ...) for per-profile env.
ccp() {
    local profiles_dir="$DOTFILES_DIR/claude/profiles"
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "Available profiles:"
        local dir
        for dir in "$profiles_dir"/*(/N); do
            echo "  ${${dir%/}:t}"
        done
        echo ""
        echo "Usage: ccp <name> [claude args...]"
        echo "For default Claude Code, use: cc"
        return 0
    fi
    shift

    local profile="$profiles_dir/$name"
    if [[ ! -d "$profile" ]]; then
        echo "ccp: no profile '$name' (looked in $profile)" >&2
        return 1
    fi

    local args=()
    [[ -f "$profile/CLAUDE.md" ]] && args+=(--append-system-prompt-file "$profile/CLAUDE.md")
    [[ -f "$profile/settings.json" ]] && args+=(--setting-sources "" --settings "$profile/settings.json")

    if [[ ! -f "$profile/settings.json" ]]; then
        local gate; gate="$(_cc_lsp_gate)" || gate=""
        [[ -n "$gate" ]] && args+=(--settings "$gate")
    fi

    [[ -f "$profile/settings-merge.json" ]] && args+=(--settings "$profile/settings-merge.json")
    # MCP scoping, tried in order:
    #   mcp-scope.yaml  → validated subset of registry.yaml + optional mcp-add.json,
    #                      generated into a tmp mcp.json (preferred, DRY).
    #   mcp.json        → hand-written strict MCP config (legacy).
    #   mcp-add.json    → additive only on top of user MCPs (legacy).
    local generated_mcp=""
    if [[ -f "$profile/mcp-scope.yaml" ]]; then
        generated_mcp=$(mktemp "${TMPDIR:-/tmp}/ccp-$name-mcp.XXXXXX")
        if ! "$DOTFILES_DIR/claude/mcp/gen-profile-mcp.sh" "$name" > "$generated_mcp"; then
            echo "ccp: failed to generate mcp.json for profile '$name'" >&2
            rm -f "$generated_mcp"
            return 1
        fi
        args+=(--strict-mcp-config --mcp-config "$generated_mcp")
    elif [[ -f "$profile/mcp.json" ]]; then
        args+=(--strict-mcp-config --mcp-config "$profile/mcp.json")
    elif [[ -f "$profile/mcp-add.json" ]]; then
        args+=(--mcp-config "$profile/mcp-add.json")
    fi

    local extra_args=()
    local env_vars=()
    [[ -f "$profile/launch.zsh" ]] && source "$profile/launch.zsh"

    if (( ${#env_vars[@]} > 0 )); then
        env "${env_vars[@]}" claude "${args[@]}" "${extra_args[@]}" "$@"
    else
        claude "${args[@]}" "${extra_args[@]}" "$@"
    fi
}

# Tab completion: ccp <TAB> → profile directory names
_ccp() {
    local -a profiles
    local dir
    for dir in "$DOTFILES_DIR/claude/profiles"/*(/N); do
        profiles+=("${${dir%/}:t}")
    done
    _describe 'profile' profiles
}
compdef _ccp ccp

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
