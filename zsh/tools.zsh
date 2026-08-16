# tools.zsh — zoxide, atuin, yazi integration
# Source order: AFTER fzf.zsh (atuin takes Ctrl+R from fzf)

# Cache `<tool> init` output; regenerate when the tool binary is newer than the cache.
# Keyed on the binary mtime only — changing the init *flags* here won't invalidate a
# cache built with the old flags, so `rm ~/.cache/zsh-init/<tool>.zsh` after editing them.
_init_cache() {
  local bin=$commands[$1] cache=$HOME/.cache/zsh-init/$1.zsh
  shift
  if [[ ! -s $cache || $bin -nt $cache ]]; then
    mkdir -p $HOME/.cache/zsh-init
    # Write-temp + atomic swap: a failed init must not poison (or truncate) a good cache.
    # `>|` overrides noclobber (not set here, but states the overwrite intent explicitly).
    if "$@" >| $cache.tmp; then
      mv $cache.tmp $cache
    else
      rm -f $cache.tmp
    fi
  fi
  [[ -s $cache ]] && source $cache
}

# ─── zoxide (smarter cd with frecency) ──────────────────────────────────────
if command -v zoxide &>/dev/null; then
    _init_cache zoxide zoxide init zsh
fi

# ─── atuin (shell history search) ───────────────────────────────────────────
if command -v atuin &>/dev/null; then
    _init_cache atuin atuin init zsh --disable-up-arrow
fi

# ─── yazi (terminal file manager, cd-on-exit) ──────────────────────────────
if command -v yazi &>/dev/null; then
    y() {
        local tmp
        tmp="$(mktemp "${TMPDIR:-/tmp}/yazi-cwd.XXXXXX")"
        yazi "$@" --cwd-file="$tmp"
        if [[ -f "$tmp" ]]; then
            local cwd
            cwd="$(<"$tmp")"
            rm -f "$tmp"
            [[ -n "$cwd" && "$cwd" != "$PWD" ]] && cd "$cwd"
        fi
    }
fi

# ─── bun (JS/TS runtime) ─────────────────────────────────────────────────
if [[ -d "$HOME/.bun" ]]; then
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    [[ -s "$BUN_INSTALL/_bun" ]] && source "$BUN_INSTALL/_bun"
fi

# ─── sccache (Rust compile cache) ────────────────────────────────────────
# RUSTC_WRAPPER lives in cargo/config.toml ([build] rustc-wrapper = "sccache")
# so it applies to every cargo invocation, not just interactive shells.
# sccache cannot wrap incremental builds, so we must disable them globally.
# Tradeoff: net win for branch-switching / clean builds, net loss for small
# in-place edits in a single project.
if command -v sccache &>/dev/null; then
    export CARGO_INCREMENTAL=0
fi

# ─── bounded cargo parallelism (earlyoom coexistence) ────────────────────
# Parallel agent fan-outs that each run a Rust gate multiply peak memory and
# get OOM-reaped (earlyoom --prefer targets claude/node/rustc/cargo on this
# box). Cap jobs so one gate stays under the kill threshold; override
# per-shell (CARGO_BUILD_JOBS=N) for a one-off fast build.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-6}"

# ─── vaudeville (SLM hook enforcement for Claude Code) ───────────────────
export VAUDEVILLE_DEBUG="${VAUDEVILLE_DEBUG:-0}"
