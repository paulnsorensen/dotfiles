#!/usr/bin/env bats
# Tests for simplified zsh configuration architecture

load test_helper

setup() {
    setup_test_env
    # Copy zsh files to test home
    mkdir -p "$TEST_HOME/Dev/dotfiles/zsh"
    cp "$REAL_DOTFILES_DIR/zsh"/*.zsh "$TEST_HOME/Dev/dotfiles/zsh/" 2>/dev/null || true
    cp "$REAL_DOTFILES_DIR/zshrc" "$TEST_HOME/.zshrc"
}

teardown() {
    teardown_test_env
}

@test "simplified zsh architecture has correct files" {
    # Core files should exist
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/core.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/aliases.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/completion.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/prompt.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/fzf.zsh"

    # Old over-engineered files should be gone
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/environment.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/git.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/navigation.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/misc.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/updates.zsh" ]]
    [[ ! -d "$REAL_DOTFILES_DIR/zsh/cache" ]]
}

@test "core.zsh contains essential settings" {
    local core_file="$REAL_DOTFILES_DIR/zsh/core.zsh"

    # Should have DEV_DIR export
    grep -q "export DEV_DIR" "$core_file"

    # Should have history configuration
    grep -q "HISTFILE" "$core_file"
    grep -q "HISTSIZE" "$core_file"
    grep -q "SAVEHIST" "$core_file"

    # Should have editor configuration
    grep -q "export EDITOR" "$core_file"

    # Should have vi mode setup
    grep -q "setopt VI" "$core_file"
    grep -q "KEYTIMEOUT" "$core_file"
}

@test "aliases.zsh contains consolidated aliases" {
    local aliases_file="$REAL_DOTFILES_DIR/zsh/aliases.zsh"

    # Should have git aliases
    grep -q "alias ga=" "$aliases_file"
    grep -q "alias gst=" "$aliases_file"

    # Should have cdd function
    grep -q "cdd()" "$aliases_file"

    # Should have ripgrep aliases
    grep -q "alias todos=" "$aliases_file"
    grep -q "alias rga=" "$aliases_file"

    # Should have utility aliases
    grep -q "alias uuidg=" "$aliases_file"
    grep -q "alias zrl=" "$aliases_file"
}

@test "mtmux enables adaptive predictive echo for remote tmux sessions" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "mosh() { printf '%s\n' \"\$@\"; }; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; mtmux edge main"

    assert_success
    [[ "$output" == $'--predict=adaptive\nedge\n--\ntmux\nnew\n-A\n-s\nmain' ]]
}

@test "mtmux without host exits 2 with usage" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; mtmux"

    [[ "$status" -eq 2 ]]
    [[ "$output" == *"usage: mtmux <host> [session]"* ]]
}

@test "tmux-detach-others outside tmux exits non-zero with usage" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "unset TMUX; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; tmux-detach-others"

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"usage: tmux-detach-others"* ]]
}

@test "codex profile shortcuts launch tight and scoped profiles" {
    local claude_file="$REAL_DOTFILES_DIR/zsh/claude.zsh"

    grep -Fxq 'cxp() { dots profile launch codex codex-plan "$@"; }' "$claude_file"
    grep -Fxq 'cxc() { dots profile launch codex codex-code "$@"; }' "$claude_file"
    grep -Fxq '    dots profile launch codex "$@"' "$claude_file"
}

@test "codex profile shortcuts pass through arguments" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "dots() { print -r -- \"\$*\"; }; source '$REAL_DOTFILES_DIR/zsh/claude.zsh'; cdp oss-docs --model gpt-5; cxp --sandbox workspace; cxc --model gpt-5"

    assert_success
    [[ "$output" == $'profile launch codex oss-docs --model gpt-5\nprofile launch codex codex-plan --sandbox workspace\nprofile launch codex codex-code --model gpt-5' ]]
}

@test "codex scoped profile shortcut lists profiles" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "dots() { print -r -- \"\$*\"; }; source '$REAL_DOTFILES_DIR/zsh/claude.zsh'; cdp list"

    assert_success
    [[ "$output" == "profile list" ]]
}

@test "omp wrapper appends the default-profile system prompt" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fakebin="$TEST_HOME/bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/omp" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
SH
    chmod +x "$fakebin/omp"
    # The wrapper only passes --append-system-prompt when the addendum exists.
    mkdir -p "$TEST_HOME/.omp/agent"
    printf 'addendum\n' > "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md"

    run zsh -c "PATH='$fakebin':\$PATH; HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; omp --model gpt-5"

    assert_success
    [ "${lines[0]}" = "--append-system-prompt" ]
    [ "${lines[1]}" = "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md" ]
    [ "${lines[2]}" = "--model" ]
    [ "${lines[3]}" = "gpt-5" ]
}

@test "ompt wrapper appends the tight-profile system prompt, not the default" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fakebin="$TEST_HOME/bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/omp" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
SH
    chmod +x "$fakebin/omp"
    # Both addenda exist; the derivation must pick the PI_CONFIG_DIR one.
    mkdir -p "$TEST_HOME/.omp/agent" "$TEST_HOME/.omp-tight/agent"
    printf 'default\n' > "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md"
    printf 'tight\n'   > "$TEST_HOME/.omp-tight/agent/APPEND_SYSTEM.md"

    run zsh -c "PATH='$fakebin':\$PATH; HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; ompt --model gpt-5"

    assert_success
    [ "${lines[0]}" = "--append-system-prompt" ]
    # Derives from PI_CONFIG_DIR=.omp-tight — NOT the default .omp path.
    [ "${lines[1]}" = "$TEST_HOME/.omp-tight/agent/APPEND_SYSTEM.md" ]
    [ "${lines[1]}" != "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md" ]
    [ "${lines[2]}" = "--model" ]
    [ "${lines[3]}" = "gpt-5" ]
}

@test "omp wrapper omits --append-system-prompt when the addendum is absent" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fakebin="$TEST_HOME/bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/omp" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
SH
    chmod +x "$fakebin/omp"
    # No addendum on disk (e.g. tight profile with no APPEND_SYSTEM.md): the
    # wrapper must not pass a nonexistent path to omp.
    run zsh -c "PATH='$fakebin':\$PATH; HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; ompt --model gpt-5"

    assert_success
    [ "${lines[0]}" = "--model" ]
    [ "${lines[1]}" = "gpt-5" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "completion.zsh has cdd completion" {
    local completion_file="$REAL_DOTFILES_DIR/zsh/completion.zsh"

    # Should have cdd completion function
    grep -q "_cdd()" "$completion_file"
    grep -q "compdef _cdd cdd" "$completion_file"

    # Should NOT have history config (moved to core.zsh)
    ! grep -q "HISTFILE" "$completion_file"
    ! grep -q "HISTSIZE" "$completion_file"
}

@test "completion.zsh bounds approximate-completion cost and compiles the dump" {
    local f="$REAL_DOTFILES_DIR/zsh/completion.zsh"

    # _approximate must be capped so a failed completion over a large candidate
    # set (e.g. 300+ git branches) can't run an unbounded edit-distance search.
    grep -Eq "zstyle ':completion:\*:approximate:\*' max-errors" "$f"

    # the per-keypress-cost trap _correct is dropped in favor of _match
    grep -Eq "completer .*_complete _match _approximate" "$f"
    ! grep -Eq "completer .*_correct" "$f"

    # compile the dump so compinit -C sources bytecode, not plain text
    grep -q "zrecompile" "$f"
}

@test "completion.zsh: completer + max-errors zstyles resolve (not just present in text)" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    # Behavioural, not a grep: source the file and read back what zsh's own
    # zstyle engine resolved — a bad context pattern would pass a grep but fail
    # here. Isolated HOME so compinit/zrecompile can't touch the real ~/.zcompdump.
    local zhome; zhome="$(mktemp -d)"
    run zsh -c "HOME='$zhome'; ZDOTDIR='$zhome'; source '$REAL_DOTFILES_DIR/zsh/completion.zsh' 2>/dev/null
        zstyle -L ':completion:*' completer
        zstyle -L ':completion:*:approximate:*' max-errors"
    rm -rf "$zhome"
    assert_success
    # capped fuzzy fallback: _match in, _correct out, max-errors bounded
    [[ "$output" == *"completer _oldlist _expand _complete _match _approximate"* ]]
    [[ "$output" != *"_correct"* ]]
    [[ "$output" == *"approximate:*' max-errors 1 numeric"* ]]
}

@test "zshenv sets a mosh-server idle-network timeout (moshi reconnect-storm hardening)" {
    local zshenv_file="$REAL_DOTFILES_DIR/zshenv"

    # 2026-07-08 livelock: iPhone moshi reconnect-looped ~723 logins in 2h, each
    # spawning a mosh-server that outlives its client for hours. tmux holds the
    # real session state, so an orphaned mosh-server is pure waste — safe to
    # self-exit after 4h with no client contact (man mosh-server, MOSH_SERVER_NETWORK_TMOUT).
    grep -q 'export MOSH_SERVER_NETWORK_TMOUT=14400' "$zshenv_file"
}

@test "zshrc sources files in correct order" {
    local zshrc_file="$REAL_DOTFILES_DIR/zshrc"

    # Should source our simplified files
    grep -q "source.*core.zsh" "$zshrc_file"
    grep -q "source.*aliases.zsh" "$zshrc_file"
    grep -q "source.*completion.zsh" "$zshrc_file"
    grep -q "source.*fzf.zsh" "$zshrc_file"
    grep -q "source.*prompt.zsh" "$zshrc_file"

    # Should NOT have old complex sourcing loop
    ! grep -q "for config_file" "$zshrc_file"
}

@test "cdd function works with DEV_DIR" {
    # Create mock Dev directory
    mkdir -p "$TEST_HOME/Dev/project1"
    mkdir -p "$TEST_HOME/Dev/project2"

    export DEV_DIR="$TEST_HOME/Dev"

    # Source the function
    source "$REAL_DOTFILES_DIR/zsh/aliases.zsh"

    # Test cdd without arguments - use basename to avoid path normalization issues
    run bash -c "cd /tmp && source '$REAL_DOTFILES_DIR/zsh/aliases.zsh' && cdd && pwd | xargs basename"
    assert_output_contains "Dev"
}

@test "cdd completion lists directories" {
    # Create mock Dev directory with projects
    mkdir -p "$TEST_HOME/Dev/project-a"
    mkdir -p "$TEST_HOME/Dev/project-b"

    export DEV_DIR="$TEST_HOME/Dev"

    # Test that _cdd function is defined in the file (can't source zsh in bash)
    grep -q "_cdd()" "$REAL_DOTFILES_DIR/zsh/completion.zsh"
}

@test "ripgrep aliases are defined" {
    local aliases_file="$REAL_DOTFILES_DIR/zsh/aliases.zsh"

    # Test some key ripgrep aliases exist in the file (can't source zsh in bash)
    grep -q "alias todos=" "$aliases_file"
    grep -q "alias rga=" "$aliases_file"
    grep -q "alias rgf=" "$aliases_file"
    grep -q "alias rgc=" "$aliases_file"
}

@test "fzf configuration has no syntax errors" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    # Test fzf config has valid zsh syntax
    run zsh -n "$REAL_DOTFILES_DIR/zsh/fzf.zsh"
    [[ $status -eq 0 ]]
}

@test "tmux.zsh parses cleanly" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -n "$REAL_DOTFILES_DIR/zsh/tmux.zsh"
    [[ $status -eq 0 ]]
}

@test "configuration files have no syntax errors" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local failed=0
    for f in core.zsh aliases.zsh completion.zsh fzf.zsh; do
        if ! zsh -n "$REAL_DOTFILES_DIR/zsh/$f" 2>/dev/null; then
            echo "Syntax error in: $f" >&2
            failed=1
        fi
    done
    if ! zsh -n "$REAL_DOTFILES_DIR/zshrc" 2>/dev/null; then
        echo "Syntax error in: zshrc" >&2
        failed=1
    fi
    [[ $failed -eq 0 ]]
}

@test "core.zsh activates mise, guarded so a missing binary can't break shell startup" {
    local core_file="$REAL_DOTFILES_DIR/zsh/core.zsh"

    grep -q 'command -v mise' "$core_file"
    local mise_activation="eval \"\$(mise activate zsh)\""
    grep -Fq "$mise_activation" "$core_file"

    # mise activation must come after the pyenv block so its shims win PATH
    # over any stale pyenv shim of the same tool name.
    local pyenv_line mise_line
    pyenv_line=$(grep -n 'pyenv init' "$core_file" | cut -d: -f1)
    mise_line=$(grep -n 'mise activate zsh' "$core_file" | cut -d: -f1)
    [ -n "$pyenv_line" ]
    [ -n "$mise_line" ]
    [ "$mise_line" -gt "$pyenv_line" ]
}

@test "core.zsh sources cleanly in zsh even when mise is not on PATH" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "PATH=/usr/bin:/bin; source '$REAL_DOTFILES_DIR/zsh/core.zsh'" 2>&1
    assert_success
}

# Extract the absolute gh path core.zsh embedded, from a captured
# "CRED=[<path> auth token]" (or "CRED=[unset]") marker.
_cred_gh_path() {
    [[ "$1" =~ CRED=\[([^]]*)\ auth\ token\] ]] && printf '%s' "${BASH_REMATCH[1]}"
}

@test "core.zsh hands mise a gh-backed GitHub credential command naming a real, absolute gh" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local zsh_bin
    zsh_bin="$(command -v zsh)"
    local mock_bin="$BATS_TEST_TMPDIR/bin"
    local real_dir="$BATS_TEST_TMPDIR/real"
    local toolbox="$BATS_TEST_TMPDIR/toolbox"
    local after_dir="$BATS_TEST_TMPDIR/after"
    mkdir -p "$mock_bin" "$real_dir" "$toolbox" "$after_dir"
    ln -s "$(command -v rm)" "$toolbox/rm"
    real_dir="$(cd "$real_dir" && pwd -P)"
    printf '#!/bin/sh
exit 0
' > "$mock_bin/mise"
    chmod +x "$mock_bin/mise"
    cat > "$real_dir/gh" <<'EOF'
#!/bin/sh
[ "$1" = auth ] && [ "$2" = token ] || exit 64
echo real-gh
EOF
    chmod +x "$real_dir/gh"

    run env PATH="$mock_bin:$real_dir:$toolbox" "$zsh_bin" --no-rcs -c "OSTYPE=test; unset MISE_GITHUB_CREDENTIAL_COMMAND; source '$REAL_DOTFILES_DIR/zsh/core.zsh'; cred=\"\$MISE_GITHUB_CREDENTIAL_COMMAND\"; cd '$after_dir'; printf 'CRED=[%s]' \"\$cred\"; /bin/sh -c \"\$cred\""
    assert_success
    [[ "$output" == "CRED=[$real_dir/gh auth token]real-gh" ]]
    local gh_path
    gh_path="$(_cred_gh_path "$output")"
    [[ "$gh_path" == "$real_dir/gh" ]]
    [[ -x "$gh_path" ]]
    [[ "$(basename "$(readlink -f "$gh_path")")" != "mise" ]]
}

@test "core.zsh skips a mise gh shim ahead on PATH and resolves a real gh" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local zsh_bin
    zsh_bin="$(command -v zsh)"
    local shim_dir="$BATS_TEST_TMPDIR/shim"
    local real_dir="$BATS_TEST_TMPDIR/real"
    local toolbox="$BATS_TEST_TMPDIR/toolbox"
    local after_dir="$BATS_TEST_TMPDIR/after"
    mkdir -p "$shim_dir" "$real_dir" "$toolbox" "$after_dir"
    ln -s "$(command -v rm)" "$toolbox/rm"
    real_dir="$(cd "$real_dir" && pwd -P)"

    # A fake mise binary and a gh symlink mirror mise's shim.
    printf '#!/bin/sh\nexit 0\n' > "$shim_dir/mise"
    chmod +x "$shim_dir/mise"
    ln -s "$shim_dir/mise" "$shim_dir/gh"

    cat > "$real_dir/gh" <<'EOF'
#!/bin/sh
[ "$1" = auth ] && [ "$2" = token ] || exit 64
echo real-gh
EOF
    chmod +x "$real_dir/gh"

    run env PATH="$shim_dir:$real_dir:$toolbox" "$zsh_bin" --no-rcs -c "OSTYPE=test; unset MISE_GITHUB_CREDENTIAL_COMMAND; source '$REAL_DOTFILES_DIR/zsh/core.zsh'; cred=\"\$MISE_GITHUB_CREDENTIAL_COMMAND\"; cd '$after_dir'; printf 'CRED=[%s]' \"\$cred\"; /bin/sh -c \"\$cred\""
    assert_success

    local gh_path
    gh_path="$(_cred_gh_path "$output")"
    # The resolver must skip the shim and return a real executable.
    [[ -n "$gh_path" ]]
    [[ -x "$gh_path" ]]
    [[ "$gh_path" != "$shim_dir/gh" ]]
    [[ "$(basename "$(readlink -f "$gh_path")")" != "mise" ]]
    [[ "$output" == "CRED=[$real_dir/gh auth token]real-gh" ]]
}

@test "core.zsh resolves a relative gh candidate to an absolute path" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local zsh_bin
    zsh_bin="$(command -v zsh)"
    local fixture="$BATS_TEST_TMPDIR/relative"
    mkdir -p "$fixture/shim" "$fixture/real" "$fixture/after" "$fixture/toolbox"
    ln -s "$(command -v rm)" "$fixture/toolbox/rm"
    fixture="$(cd "$fixture" && pwd -P)"
    local toolbox="$fixture/toolbox"
    printf '#!/bin/sh\nexit 0\n' > "$fixture/shim/mise"
    chmod +x "$fixture/shim/mise"
    ln -s "$fixture/shim/mise" "$fixture/shim/gh"
    cat > "$fixture/real/gh" <<'EOF'
#!/bin/sh
[ "$1" = auth ] && [ "$2" = token ] || exit 64
echo real-gh
EOF
    chmod +x "$fixture/real/gh"

    run env PATH="$toolbox" "$zsh_bin" --no-rcs -c "cd '$fixture'; path=(./shim ./real ./toolbox); export PATH; OSTYPE=test; source '$REAL_DOTFILES_DIR/zsh/core.zsh'; cred=\"\$MISE_GITHUB_CREDENTIAL_COMMAND\"; cd '$fixture/after'; printf 'CRED=[%s]' \"\$cred\"; /bin/sh -c \"\$cred\""
    assert_success
    [[ "$output" == "CRED=[$fixture/real/gh auth token]real-gh" ]]
}

@test "core.zsh does not export a credential command when only a mise gh shim is on PATH" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local zsh_bin
    zsh_bin="$(command -v zsh)"
    local shim_dir="$BATS_TEST_TMPDIR/shim-only"
    local toolbox="$BATS_TEST_TMPDIR/shim-toolbox"
    mkdir -p "$shim_dir" "$toolbox"
    ln -s "$(command -v rm)" "$toolbox/rm"
    printf '#!/bin/sh\nexit 0\n' > "$shim_dir/mise"
    chmod +x "$shim_dir/mise"
    ln -s "$shim_dir/mise" "$shim_dir/gh"

    # PATH holds only the shim dir, so no real gh exists anywhere on it.
    run env PATH="$shim_dir:$toolbox" "$zsh_bin" --no-rcs -c "OSTYPE=test; MISE_GITHUB_CREDENTIAL_COMMAND='stale auth token'; source '$REAL_DOTFILES_DIR/zsh/core.zsh'; printf 'CRED=[%s]' \"\${MISE_GITHUB_CREDENTIAL_COMMAND-unset}\""
    assert_success
    [[ "$output" == *"CRED=[unset]"* ]]
}

@test "zshenv prepends the mise shims dir ahead of stale PATH entries" {
    local zshenv_file="$REAL_DOTFILES_DIR/zshenv"

    grep -q 'mise/shims' "$zshenv_file"
    local mise_shims_guard="if [[ -d \"\$MISE_SHIMS_DIR\""
    grep -Fq "$mise_shims_guard" "$zshenv_file"
}

@test "zshenv's mise shims guard resolves ahead of a stale native PATH entry" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fake_xdg="$TEST_HOME/xdg-data"
    mkdir -p "$fake_xdg/mise/shims"
    # A stale native copy of a mise-managed tool sits earlier on PATH.
    local stale_bin="$TEST_HOME/stale-bin"
    mkdir -p "$stale_bin"
    cat > "$stale_bin/claude" <<'SH'
#!/bin/sh
echo stale
SH
    chmod +x "$stale_bin/claude"
    cat > "$fake_xdg/mise/shims/claude" <<'SH'
#!/bin/sh
echo shimmed
SH
    chmod +x "$fake_xdg/mise/shims/claude"

    run zsh -c "XDG_DATA_HOME='$fake_xdg'; PATH='$stale_bin':/usr/bin:/bin; source '$REAL_DOTFILES_DIR/zshenv'; claude"

    assert_success
    [ "$output" = "shimmed" ]
}

@test "zshenv moves existing mise shims ahead of later cargo and dotnet prepends" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fake_xdg="$TEST_HOME/xdg-data-existing"
    mkdir -p "$fake_xdg/mise/shims" "$TEST_HOME/.cargo/bin" "$TEST_HOME/.dotnet/tools"
    local stale_bin="$TEST_HOME/stale-bin-existing"
    mkdir -p "$stale_bin"
    cat > "$stale_bin/claude" <<'SH'
#!/bin/sh
echo stale
SH
    chmod +x "$stale_bin/claude"
    cat > "$fake_xdg/mise/shims/claude" <<'SH'
#!/bin/sh
echo shimmed
SH
    chmod +x "$fake_xdg/mise/shims/claude"

    run zsh -c "HOME='$TEST_HOME'; XDG_DATA_HOME='$fake_xdg'; PATH='$stale_bin:$fake_xdg/mise/shims':/usr/bin:/bin; source '$REAL_DOTFILES_DIR/zshenv'; print -r -- \$path[1]; claude"

    assert_success
    [ "${lines[0]}" = "$fake_xdg/mise/shims" ]
    [ "${lines[1]}" = "shimmed" ]
}

@test "zshenv picks Linux rustup dirs, first existing wins, and never probes /home on darwin" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fake_home="$BATS_TEST_TMPDIR/linux-home"
    mkdir -p "$fake_home/.linuxbrew/opt/rustup/bin"

    run zsh -c "OSTYPE=linux-gnu; HOME='$fake_home'; PATH=/usr/bin:/bin; source '$REAL_DOTFILES_DIR/zshenv'; print -r -- \$PATH"

    assert_success
    [[ "$output" == *"$fake_home/.linuxbrew/opt/rustup/bin"* ]]

    # Darwin never probes /home/linuxbrew: only /opt/homebrew is a candidate.
    local darwin_branch
    darwin_branch=$(sed -n '/_rustup_bin=\/opt\/homebrew/,/elif.*OSTYPE.*linux\*/p' "$REAL_DOTFILES_DIR/zshenv")
    [[ "$darwin_branch" == *"/opt/homebrew/opt/rustup/bin"* ]]
    [[ "$darwin_branch" != *"/home/linuxbrew"* ]]
}

@test "zshenv on Linux moves an inherited rustup entry ahead of brew's bin" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    [[ -d /home/linuxbrew/.linuxbrew/opt/rustup/bin ]] && skip "host linuxbrew rustup wins over the fake HOME"
    local fake_home="$BATS_TEST_TMPDIR/linux-inherit-home"
    local brew_bin="$fake_home/.linuxbrew/bin" rustup_bin="$fake_home/.linuxbrew/opt/rustup/bin"
    mkdir -p "$brew_bin" "$rustup_bin"

    run zsh -c "OSTYPE=linux-gnu; HOME='$fake_home'; PATH='/usr/bin:$brew_bin:$rustup_bin:/bin'; source '$REAL_DOTFILES_DIR/zshenv'; print -r -- \$PATH"

    assert_success
    local idx_rustup idx_brew
    idx_rustup=$(tr ':' '\n' <<< "$output" | grep -nxF "$rustup_bin" | head -1 | cut -d: -f1)
    idx_brew=$(tr ':' '\n' <<< "$output" | grep -nxF "$brew_bin" | head -1 | cut -d: -f1)
    [[ -n "$idx_rustup" && -n "$idx_brew" ]]
    [[ "$idx_rustup" -lt "$idx_brew" ]]
    [[ "$(tr ':' '\n' <<< "$output" | grep -cxF "$rustup_bin")" == 1 ]]
}

@test "core.zsh on Linux puts brew's rustup proxies ahead of brew's own bin dir" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    # core.zsh tries /home/linuxbrew first; GitHub's ubuntu runners ship brew
    # there, so it would win over the fake HOME brew below.
    [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]] && skip "host linuxbrew wins over the fake HOME brew"
    local fake_home="$BATS_TEST_TMPDIR/linux-brew-home"
    mkdir -p "$fake_home/.linuxbrew/bin" "$fake_home/.linuxbrew/opt/rustup/bin"
    cat > "$fake_home/.linuxbrew/bin/brew" <<SH
#!/bin/sh
printf 'export HOMEBREW_PREFIX="%s/.linuxbrew"\n' '$fake_home'
printf 'export PATH="%s/.linuxbrew/bin:\$PATH"\n' '$fake_home'
SH
    chmod +x "$fake_home/.linuxbrew/bin/brew"

    run zsh -c "OSTYPE=linux-gnu; HOME='$fake_home'; PATH=/usr/bin:/bin; source '$REAL_DOTFILES_DIR/zsh/core.zsh' 2>/dev/null; print -r -- \$PATH"

    assert_success
    local idx_rustup idx_brew
    idx_rustup=$(tr ':' '\n' <<< "$output" | grep -nxF "$fake_home/.linuxbrew/opt/rustup/bin" | head -1 | cut -d: -f1)
    idx_brew=$(tr ':' '\n' <<< "$output" | grep -nxF "$fake_home/.linuxbrew/bin" | head -1 | cut -d: -f1)
    [[ -n "$idx_rustup" && -n "$idx_brew" ]]
    [[ "$idx_rustup" -lt "$idx_brew" ]]
}

@test "zshenv sources cleanly with no XDG_DATA_HOME and no mise shims dir present" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "unset XDG_DATA_HOME; HOME='$TEST_HOME'; PATH=/usr/bin:/bin; source '$REAL_DOTFILES_DIR/zshenv'" 2>&1
    assert_success
}

@test "zshenv's mise shims guard is idempotent — double-sourcing doesn't grow PATH" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fake_xdg="$TEST_HOME/xdg-data-idempotent"
    mkdir -p "$fake_xdg/mise/shims"

    run zsh -c "XDG_DATA_HOME='$fake_xdg'; PATH=/usr/bin:/bin; source '$REAL_DOTFILES_DIR/zshenv'; source '$REAL_DOTFILES_DIR/zshenv'; echo \$PATH"

    assert_success
    local shims_dir="$fake_xdg/mise/shims"
    local occurrences
    occurrences=$(grep -o "$shims_dir" <<< "$output" | wc -l | tr -d ' ')
    [ "$occurrences" -eq 1 ]
}
