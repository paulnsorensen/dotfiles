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
# _cc_base — common launcher: prepends preamble flag, routes through
# bin/cc-env-exec (when present) so the spawned claude loads fresh .env keys
# at process start — keys never enter tmux's argv (`ps`-visible), and a
# stale tmux server env can't strip them (a new session inherits the
# SERVER's environment, not this client's). Then wraps in tmux unless
# already inside tmux ($TMUX set) or tmux is not installed.
# ccw sets _CC_IN_SESSION=1 to trigger the inside-tmux switch-client path.
_cc_base() {
    # --new (our flag, not claude's): force a brand-new session instead of the
    # default -A reattach. Strip it from the args wherever it lands so it works
    # through cc/ccc/ccr (which prepend --continue/--resume ahead of "$@").
    local force_new=
    local -a passthru=()
    local a
    for a in "$@"; do
        if [[ "$a" == --new ]]; then
            force_new=1
        else
            passthru+=("$a")
        fi
    done
    set -- "${passthru[@]}"

    local -a flags=()
    [[ -f "$AGENTS_DOTFILES/preamble.md" ]] && flags+=(--system-prompt-file "$AGENTS_DOTFILES/preamble.md")
    local -a cmd=(claude "${flags[@]}" "$@")
    local launcher="${DOTFILES_DIR:-$HOME/Dev/dotfiles}/bin/cc-env-exec"
    [[ -x "$launcher" ]] && cmd=("$launcher" "${cmd[@]}")
    # No tmux installed: run claude in place.
    if ! command -v tmux &>/dev/null; then
        "${cmd[@]}"
        return
    fi
    # Collision-safe session name (bin/cc-session-name): <repo>-<slug> for a
    # worktree, <repo> otherwise. Re-running cc/ccw for the same worktree
    # reuses its session instead of spawning another (de-sprawl), and
    # same-named worktrees across different repos no longer collide.
    # --new asks for the lowest free -N suffix so the session is guaranteed fresh.
    local -a name_args=()
    [[ -n "$force_new" ]] && name_args=(--unique)
    local session
    session="$("${DOTFILES_DIR:-$HOME/Dev/dotfiles}/bin/cc-session-name" "${name_args[@]}" "$PWD")"
    if [[ -z "$TMUX" ]]; then
        # Outside tmux: create-or-attach (-A attaches if it exists; cmd ignored
        # on attach). With --new the name is unique, so -A always creates.
        tmux new-session -A -s "$session" "${(j: :)${(@q)cmd}}"
    elif [[ -n "$_CC_IN_SESSION" || -n "$force_new" ]]; then
        # Inside tmux from ccw, or an explicit --new from a plain session:
        # dedicate a session and switch-client (never nests).
        tmux has-session -t "$session" 2>/dev/null \
            || tmux new-session -d -s "$session" "${(j: :)${(@q)cmd}}"
        tmux switch-client -t "$session"
    else
        # Bare cc inside an existing tmux session: run in place, no nesting.
        "${cmd[@]}"
    fi
}

cc()  { _cc_base "$@"; }
ccc() { _cc_base --continue "$@"; }
ccr() { _cc_base --resume "$@"; }

# ccs — jump to a running Claude/worktree tmux session via an fzf picker.
# Inside tmux: switch-client; outside: attach.
ccs() {
    command -v tmux &>/dev/null || { echo "ccs: tmux not installed" >&2; return 1; }
    command -v fzf  &>/dev/null || { echo "ccs: fzf not installed" >&2; return 1; }
    local session
    session="$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | fzf --height 40% --reverse --border-label ' claude sessions ' --prompt '🧀  ')"
    [[ -z "$session" ]] && return 0
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session"
    else
        tmux attach -t "$session"
    fi
}

# ccp <name> — launch a scoped Claude profile (profiles/<name>/profile.yaml).
#   ccp research            → dots profile launch claude research
#   ccp list                → dots profile list
ccp() {
    if [[ -z "$1" ]]; then
        echo "Usage: ccp <profile> [-- claude args...]" >&2
        echo "  ccp list   list available profiles" >&2
        return 1
    fi
    if [[ "$1" == "list" || "$1" == "ls" ]]; then
        dots profile list
        return
    fi
    dots profile launch claude "$@"
}

# Tight Codex profile shortcuts.
cxp() { dots profile launch codex codex-plan "$@"; }
cxc() { dots profile launch codex codex-code "$@"; }

# Dotfiles OMP launch shortcut — pass the repo-local overlay explicitly so it works
# from subdirectories; OMP project prompt/settings discovery is cwd-scoped.
pi() {
    local omp_dir="${DOTFILES_DIR:-$HOME/Dev/dotfiles}/.omp"
    local config="$omp_dir/config.yml"
    local append="$omp_dir/APPEND_SYSTEM.md"
    if [[ ! -r "$config" || ! -r "$append" ]]; then
        echo "pi: missing OMP overlay files under $omp_dir" >&2
        return 1
    fi
    command omp --config "$config" --append-system-prompt "$append" "$@"
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

# base-sync is RETIRED (spec: chezmoi-authoritative-claude, decision E1/A2).
# Global claude config now deploys via chezmoi from
# chezmoi/.chezmoidata/claude.yaml on `dots sync` (additions AND removals);
# other harnesses (codex/opencode/cursor/copilot) are frozen pending their own
# migration spec. `ap` remains only for scoped/ephemeral profiles (`ccp <name>`).
alias mcp='claude mcp'
alias mcp-ls='claude mcp list'
# Claude's MCP edit surface is the claude registry; `dots sync` reconciles
# ~/.claude.json user scope against it via the manifest-tracked reconcile.
alias mcp-edit='${EDITOR:-vim} $DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml'

# ═══════════════════════════════════════════════════════════════════
# Hook Management (harness-agnostic — edit surface; deploy via `ap`)
# ═══════════════════════════════════════════════════════════════════
alias hook-edit='${EDITOR:-vim} $AGENTS_DOTFILES/hooks/registry.yaml'
alias hook-ls='yq -r ".hooks | keys | .[]" $AGENTS_DOTFILES/hooks/registry.yaml'

# ═══════════════════════════════════════════════════════════════════
# Agent Management (harness-agnostic — edit surface; deploy via `ap`)
# ═══════════════════════════════════════════════════════════════════
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
#   ccw my-feature          → creates .worktrees/my-feature, branch claude/my-feature
#                              outside tmux: new-session; inside tmux: new-session + switch-client
#   ccw my-feature --resume  → same but resumes last conversation
#   ccw                     → fzf-pick an existing worktree under ~/Dev to resume
#   ccw <slug>              → worktree in the current repo
#   ccw <repo>/<slug>       → worktree in ~/Dev/<repo> (no need to cd in first)
ccw() {
    # No slug: fuzzy-pick an existing worktree across ~/Dev and jump back in.
    if [[ -z "$1" ]]; then
        command -v fzf &>/dev/null || {
            echo "Usage: ccw <slug> | ccw <repo>/<slug>   (fzf needed for the no-arg picker)" >&2
            return 1
        }
        local dev="${DEV_DIR:-$HOME/Dev}"
        local picked
        # Cover repo worktrees and one level of nesting (a worktree created
        # from inside another worktree).
        picked="$(print -l "$dev"/*/.worktrees/*(N/) "$dev"/*/.worktrees/*/.worktrees/*(N/) 2>/dev/null \
            | fzf --height 40% --reverse --border-label ' worktrees ' --prompt '🧀  ')"
        [[ -z "$picked" ]] && return 0
        cd "$picked" && _CC_IN_SESSION=1 cc
        return
    fi

    # Resolve repo + slug. A "repo/slug" arg targets ~/Dev/<repo>; a bare slug
    # uses the current repo.
    local arg="$1"
    shift
    local repo_dir slug
    if [[ "$arg" == */* ]]; then
        local repo="${arg%%/*}"
        slug="${arg#*/}"
        repo_dir="${DEV_DIR:-$HOME/Dev}/${repo}"
        [[ -d "$repo_dir" ]] || { echo "ccw: repo not found: $repo_dir" >&2; return 1; }
    else
        slug="$arg"
        repo_dir="$(git rev-parse --show-toplevel 2>/dev/null)" \
            || { echo "ccw: not in a git repo — use ccw <repo>/<slug>" >&2; return 1; }
    fi

    # Find ccw-init in DOTFILES_DIR or the target repo.
    local ccw_init="${DOTFILES_DIR}/bin/ccw-init"
    [[ -f "${ccw_init}" ]] || ccw_init="${repo_dir}/bin/ccw-init"
    [[ -f "${ccw_init}" ]] || { echo "ccw-init not found" >&2; return 1; }

    local result
    result="$(cd "${repo_dir}" && "${ccw_init}" "${slug}")" || return 1

    local wt_path
    wt_path="$(echo "$result" | jq -er '.path')" || { echo "ccw: failed to parse worktree path" >&2; return 1; }
    [[ -d "$wt_path" ]] || { echo "ccw: worktree path not found: $wt_path" >&2; return 1; }

    cd "${wt_path}" && _CC_IN_SESSION=1 cc "$@"
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

# Tear down one worktree — remove it + delete branch + kill tmux session (lives in bin/)
alias ccw-rm='$DOTFILES_DIR/bin/ccw-rm'

# Locate worktrees by branch / slug / repo / staleness (lives in bin/)
alias ccw-find='$DOTFILES_DIR/bin/ccw-find'

# GitHub helpers (gh-pr-review, gh-pr-prep, gh-issue-context) live in bin/

# ═══════════════════════════════════════════════════════════════════
# Config Shortcuts
# ═══════════════════════════════════════════════════════════════════
alias claude-settings='${EDITOR:-vim} ~/.claude/settings.json'

# ═══════════════════════════════════════════════════════════════════
# Plugin Management
# plugins: agents/plugins/registry.yaml (cross-harness; edit -> dots sync)
# claude-only plugins: claude/plugins/registry.yaml (edit -> dots sync)
# claude/plugins/sync.sh is retired; ap now handles marketplace registration.
# ═══════════════════════════════════════════════════════════════════
alias plugin='claude plugin'
alias plugin-ls='claude plugin list'
# plugin-sync: sync claude-native marketplace plugins (claude/plugins/sync.sh)
alias plugin-sync='bash $DOTFILES_DIR/claude/.sync'
# plugin-edit: the cross-harness plugin registry (SSOT for all harnesses)
alias plugin-edit='${EDITOR:-vim} $DOTFILES_DIR/agents/plugins/registry.yaml'

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
