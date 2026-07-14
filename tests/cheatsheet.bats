#!/usr/bin/env bats
# Tests for bin/cheatsheet — including a drift guard that keeps the curated
# sheet in sync with the actual zsh shortcut surface.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"
ZSH_DIR="$DOTFILES_DIR/zsh"
BIN_DIR="$DOTFILES_DIR/bin"

# Internal helpers / prompt machinery — defined in zsh/*.zsh but not user shortcuts.
INTERNAL="_cc_base _cdd sesh-sessions periodic TRAPWINCH TRAPUSR1 render_prompt update_git_cache git_time_details time_since_commit _prompt_cleanup _prompt_async_start _prompt_async_worker _prompt_git_compute _prompt_load_git_state _vaudeville_register_argcomplete _init_cache"
# zsh tmux/remote shortcuts — documented in tmux-cheatsheet, not the main sheet.
TMUX_OWNED="mtmux trl tss tsip ta tls tn tk tsw"
# Commands provided by external tools (not defined as aliases/functions here).
ALLOW="z"

strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

assert_section() {
    local clean
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"$1"* ]] || { echo "Missing section: $1"; echo "$clean"; return 1; }
}

# Every alias name + function name defined across zsh/*.zsh.
defined_names() {
    {
        grep -hoE "^[[:space:]]*alias [A-Za-z0-9_-]+=" "$ZSH_DIR"/*.zsh \
            | sed -E 's/^[[:space:]]*alias //; s/=.*//'
        grep -hoE "^[[:space:]]*[A-Za-z0-9_-]+\(\)" "$ZSH_DIR"/*.zsh \
            | sed -E 's/\(\)//; s/^[[:space:]]*//'
    } | sort -u
}

# First token of every `row "..."` in the cheatsheet source.
documented_tokens() {
    grep -oE 'row "[^"]+"' "$BIN_DIR/cheatsheet" \
        | sed -E 's/^row "//; s/"$//' | awk '{print $1}' | sort -u
}

@test "exits 0" {
    run cheatsheet
    [[ $status -eq 0 ]]
}

@test "output is not empty" {
    run cheatsheet
    [[ ${#output} -gt 100 ]]
}

@test "prints core sections" {
    run cheatsheet
    assert_section "Git"
    assert_section "Claude launchers"
    assert_section "Worktrees"
    assert_section "MCP / Hooks / Agents"
}

@test "does not document the retired base-sync entry point" {
    run cheatsheet
    local clean
    clean=$(strip_ansi "$output")
    [[ "$clean" != *"base-sync"* ]]
}

@test "points at tmux-cheatsheet for tmux keys" {
    run cheatsheet
    assert_section "tmux-cheatsheet"
    assert_section "Ctrl+Space"
}
@test "drift: every zsh alias/function is documented (minus internals + tmux sheet)" {
    # Match against the row token set (not free text) so a future alias whose
    # name happens to appear in a description can't pass vacuously.
    local documented missing=()
    documented="$(documented_tokens)"
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        case " $INTERNAL $TMUX_OWNED " in *" $name "*) continue ;; esac
        grep -qxF -- "$name" <<<"$documented" || missing+=("$name")
    done < <(defined_names)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Aliases/functions missing from bin/cheatsheet: ${missing[*]}"
        echo "Document them, or add to INTERNAL / TMUX_OWNED in this test."
        return 1
    fi
}

@test "drift: every documented shortcut resolves to a defined alias/function/bin (no dead refs)" {
    local defined unresolved=()
    defined="$(defined_names)"
    local tok
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        grep -qxF -- "$tok" <<<"$defined" && continue
        [[ -x "$BIN_DIR/$tok" ]] && continue
        case " $ALLOW " in *" $tok "*) continue ;; esac
        unresolved+=("$tok")
    done < <(documented_tokens)
    if [[ ${#unresolved[@]} -gt 0 ]]; then
        echo "Documented but undefined (dead refs): ${unresolved[*]}"
        return 1
    fi
}

@test "the dead ccfresh reference is gone" {
    run cheatsheet
    [[ "$(strip_ansi "$output")" != *"ccfresh"* ]]
}
