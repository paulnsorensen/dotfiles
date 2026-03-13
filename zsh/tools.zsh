# tools.zsh — zoxide, atuin, yazi integration
# Source order: AFTER fzf.zsh (atuin takes Ctrl+R from fzf)

# ─── zoxide (smarter cd with frecency) ──────────────────────────────────────
if command -v zoxide &>/dev/null; then
    eval "$(zoxide init zsh)"
fi

# ─── atuin (shell history search) ───────────────────────────────────────────
if command -v atuin &>/dev/null; then
    eval "$(atuin init zsh --disable-up-arrow)"
fi

# ─── yazi (terminal file manager, cd-on-exit) ──────────────────────────────
if command -v yazi &>/dev/null; then
    y() {
        local tmp
        tmp="$(mktemp "${TMPDIR:-/tmp}/yazi-cwd.XXXXXX")"
        yazi "$@" --cwd-file="$tmp"
        if [[ -f "$tmp" ]]; then
            local cwd
            cwd="$(cat "$tmp")"
            rm -f "$tmp"
            [[ -n "$cwd" && "$cwd" != "$PWD" ]] && cd "$cwd"
        fi
    }
fi

# ─── bun (JS/TS runtime) ─────────────────────────────────────────────────
if [[ -d "$HOME/.bun" ]]; then
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    [ -s "$BUN_INSTALL/_bun" ] && source "$BUN_INSTALL/_bun"
fi
