#!/usr/bin/env bats
# Tests for both prompt systems: zsh powerline (prompt.zsh) and starship

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# ── zsh powerline prompt (prompt.zsh) ─────────────────────────────────────────

@test "prompt.zsh has valid zsh syntax" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -n "$DOTFILES_DIR/zsh/prompt.zsh"
    [[ $status -eq 0 ]]
}

@test "prompt.zsh defines time_since_commit function" {
    grep -q "^time_since_commit()" "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "prompt.zsh defines render_prompt function" {
    grep -q "^render_prompt()" "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "time_since_commit: minutes only for <1h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 1800"
    [[ "$output" == "30m" ]]
}

@test "time_since_commit: hours and minutes for 1-24h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 5400"
    [[ "$output" == "1h30m" ]]
}

@test "time_since_commit: days and hours for 24-48h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 90000"
    [[ "$output" == "1d1h" ]]
}

@test "time_since_commit: days only for >48h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 259200"
    [[ "$output" == "3d" ]]
}

@test "time_since_commit: zero seconds shows 0m" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 0"
    [[ "$output" == "0m" ]]
}

@test "prompt.zsh uses colors from colors.zsh" {
    # Verify it references the color variables, not hardcoded values
    grep -q '__SDW_' "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "prompt.zsh sets up vcs_info for git" {
    grep -q "enable git" "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "prompt.zsh registers precmd hook" {
    grep -q "add-zsh-hook precmd" "$DOTFILES_DIR/zsh/prompt.zsh"
}

# ── async git rendering (no per-keystroke git forks) ──────────────────────────

@test "prompt_precmd defers git work to the async worker (no synchronous vcs_info)" {
    local body
    body=$(sed -n '/^function prompt_precmd()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh")
    [[ "$body" == *"_prompt_async_start"* ]]
    [[ "$body" != *"vcs_info"* ]]
}

@test "render_prompt renders cached git state without forking git" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local mockbin; mockbin="$(mktemp -d)"
    cat > "$mockbin/git" <<'SH'
#!/bin/sh
echo "git $*" >> "$GIT_CALL_LOG"
SH
    chmod +x "$mockbin/git"
    run zsh -c "
      export GIT_CALL_LOG='$mockbin/calls'; : > \$GIT_CALL_LOG
      PATH='$mockbin':\$PATH
      source '$DOTFILES_DIR/zsh/prompt.zsh'
      _prompt_git_info='mybranch'; _prompt_git_time='9m'
      render_prompt
      print -r -- \"P:\$PROMPT\"
      print -r -- \"CALLS:\$(cat \$GIT_CALL_LOG)\"
    "
    rm -rf "$mockbin"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mybranch"* ]]
    [[ "$output" == *"9m"* ]]
    # render must not shell out to git — the async worker owns all git forks
    [[ "$output" != *"CALLS:git"* ]]
}

@test "_prompt_git_compute writes branch and time-since-commit to the state file" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local repo; repo="$(mktemp -d)"
    ( cd "$repo" && git init -q && \
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
    run zsh -c "
      cd '$repo'
      source '$DOTFILES_DIR/zsh/prompt.zsh'
      _prompt_async_tmp='$repo/.state'
      _prompt_git_compute
      cat '$repo/.state'
    "
    rm -rf "$repo"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "main" || "${lines[0]}" == "master" ]]
    [[ "${lines[1]}" == "0m" ]]
}

@test "_prompt_load_git_state loads branch and time from the state file" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local tmp; tmp="$(mktemp)"
    printf 'feature-x\n3h20m\n' > "$tmp"
    run zsh -c "
      source '$DOTFILES_DIR/zsh/prompt.zsh'
      _prompt_async_tmp='$tmp'
      _prompt_load_git_state
      print -r -- \"\$_prompt_git_info|\$_prompt_git_time\"
    "
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature-x|3h20m"* ]]
}

@test "_prompt_async_worker publishes state via atomic rename, leaving no scratch file" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local repo; repo="$(mktemp -d)"
    ( cd "$repo" && git init -q && \
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
    # Sourcing installs TRAPUSR1; the worker's `kill -USR1 $$` fires it harmlessly
    # (zle inactive under `zsh -c`, so reset-prompt is skipped). Run the worker in
    # the foreground so the rename completes before we inspect the tree.
    run zsh -c "
      cd '$repo'
      source '$DOTFILES_DIR/zsh/prompt.zsh'
      _prompt_async_tmp='$repo/state'
      _prompt_async_worker
      print -r -- \"EXISTS:\$([[ -f '$repo/state' ]] && echo yes)\"
      print -r -- \"BRANCH:\$(sed -n 1p '$repo/state')\"
      local -a scratch; scratch=('$repo'/state.*(N))
      print -r -- \"SCRATCHCOUNT:\${#scratch}\"
    "
    rm -rf "$repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXISTS:yes"* ]]
    [[ "$output" == *"BRANCH:main"* || "$output" == *"BRANCH:master"* ]]
    # atomic mv leaves no scratch file behind — a direct-write regression would fail this
    [[ "$output" == *"SCRATCHCOUNT:0"* ]]
}
