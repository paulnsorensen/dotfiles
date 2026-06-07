#!/usr/bin/env bats
# shellcheck disable=SC2016  # single-quoted 'sh -c "$VAR"' is intentional:
# the variable must expand in the exec'd shell (after cc-env-exec exports
# it), not in the bats process — that expansion IS the assertion.
# Tests for the .env launch-time loader: bin/cc-env-exec loads
# $DOTFILES_DIR/.env (safe key=value parse, no command execution — matching
# zsh/core.zsh's loader) and execs the given command; _cc_base (zsh/claude.zsh)
# prepends it to the claude command on every launch path. Rationale: a new
# tmux session inherits the tmux SERVER's environment — not the launching
# client's — so a server started before a key was added would launch claude
# without it and every ${VAR}-referencing MCP in ~/.claude.json would die.
# The wrapper (rather than `tmux new-session -e K=V`) keeps secrets out of
# tmux's argv, which is `ps`-visible to other local users for the lifetime
# of the attached client.
#
# The wrapper is exercised directly; the _cc_base wiring is exercised
# end-to-end in zsh with tmux/claude mocked on $PATH.

load test_helper

CLAUDE_ZSH="$REAL_DOTFILES_DIR/zsh/claude.zsh"
CC_ENV_EXEC="$REAL_DOTFILES_DIR/bin/cc-env-exec"

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"
    export MOCK_ARGS_FILE="$MOCK_BIN/args"
    # _cc_base resolves the launcher under $DOTFILES_DIR — ship the real
    # script into the fixture so e2e tests stay grounded in shipped code.
    mkdir -p "$FIXTURE_DIR/bin"
    cp "$CC_ENV_EXEC" "$FIXTURE_DIR/bin/cc-env-exec"
}

teardown() {
    rm -rf "$FIXTURE_DIR" "$MOCK_BIN"
}

# Mock tmux: report no existing session, record new-session invocations.
_mock_tmux() {
    cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "has-session" ]] && exit 1
[[ "$1" == "new-session" ]] && printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
exit 0
EOF
    chmod +x "$MOCK_BIN/tmux"
}

# ── bin/cc-env-exec unit tests ──

@test "cc-env-exec exists and is executable" {
    [ -x "$CC_ENV_EXEC" ]
}

@test "cc-env-exec exports .env keys to the exec'd command" {
    printf 'A_KEY=one\nB_KEY=two\n' > "$FIXTURE_DIR/.env"
    export DOTFILES_DIR="$FIXTURE_DIR"
    run "$CC_ENV_EXEC" sh -c 'printf %s:%s "$A_KEY" "$B_KEY"'
    [ "$status" -eq 0 ]
    [ "$output" = "one:two" ]
}

@test "cc-env-exec skips comments and blank lines" {
    printf '# a comment\n\nKEY=val\n' > "$FIXTURE_DIR/.env"
    export DOTFILES_DIR="$FIXTURE_DIR"
    run "$CC_ENV_EXEC" sh -c 'printf %s "$KEY"'
    [ "$status" -eq 0 ]
    [ "$output" = "val" ]
}

@test "cc-env-exec keeps everything after the first = in the value" {
    printf 'TOKEN=a=b=c\n' > "$FIXTURE_DIR/.env"
    export DOTFILES_DIR="$FIXTURE_DIR"
    run "$CC_ENV_EXEC" sh -c 'printf %s "$TOKEN"'
    [ "$status" -eq 0 ]
    [ "$output" = "a=b=c" ]
}

@test "cc-env-exec still execs the command when .env is missing" {
    export DOTFILES_DIR="$FIXTURE_DIR"
    run "$CC_ENV_EXEC" sh -c 'printf ok'
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "cc-env-exec never executes value content" {
    printf 'EVIL=$(touch %s/pwned)\n' "$FIXTURE_DIR" > "$FIXTURE_DIR/.env"
    export DOTFILES_DIR="$FIXTURE_DIR"
    run "$CC_ENV_EXEC" sh -c 'printf %s "$EVIL"'
    [ "$status" -eq 0 ]
    [ "$output" = "\$(touch $FIXTURE_DIR/pwned)" ]
    [ ! -f "$FIXTURE_DIR/pwned" ]
}

@test "cc-env-exec passes the exec'd command's exit status through" {
    export DOTFILES_DIR="$FIXTURE_DIR"
    run "$CC_ENV_EXEC" sh -c 'exit 7'
    [ "$status" -eq 7 ]
}

@test "cc-env-exec without a command prints usage and exits 2" {
    run "$CC_ENV_EXEC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
}

@test "cc-env-exec skips an invalid identifier line and continues" {
    printf '1BAD=x\nGOOD=y\n' > "$FIXTURE_DIR/.env"
    export DOTFILES_DIR="$FIXTURE_DIR"
    run "$CC_ENV_EXEC" sh -c 'printf %s "$GOOD"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"y"* ]]
    [[ "$output" == *"skipping invalid .env line"* ]]
}

@test "cc-env-exec falls back to ~/Dev/dotfiles when DOTFILES_DIR is unset" {
    mkdir -p "$FIXTURE_DIR/Dev/dotfiles"
    printf 'FB_KEY=fb\n' > "$FIXTURE_DIR/Dev/dotfiles/.env"
    run env -u DOTFILES_DIR HOME="$FIXTURE_DIR" "$CC_ENV_EXEC" sh -c 'printf %s "$FB_KEY"'
    [ "$status" -eq 0 ]
    [ "$output" = "fb" ]
}

# ── _cc_base wiring (end-to-end in zsh, tmux/claude mocked) ──

@test "cc routes the tmux command through cc-env-exec with no secret in argv" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    printf 'FRESH_KEY=hot\n' > "$FIXTURE_DIR/.env"
    _mock_tmux
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR'; unset TMUX _CC_IN_SESSION; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_ARGS_FILE" ]
    # The spawned command is the wrapper + claude…
    [[ "$(tail -n 1 "$MOCK_ARGS_FILE")" == "$FIXTURE_DIR/bin/cc-env-exec claude"* ]]
    # …and the secret never appears anywhere in tmux's argv.
    ! grep -qF 'FRESH_KEY=hot' "$MOCK_ARGS_FILE"
    ! grep -qx -- '-e' "$MOCK_ARGS_FILE"
}

@test "ccw-style launch routes through cc-env-exec with no secret in argv (inside-tmux path)" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    printf 'FRESH_KEY=hot\n' > "$FIXTURE_DIR/.env"
    _mock_tmux
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR' TMUX=fake _CC_IN_SESSION=1; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_ARGS_FILE" ]
    [[ "$(tail -n 1 "$MOCK_ARGS_FILE")" == "$FIXTURE_DIR/bin/cc-env-exec claude"* ]]
    ! grep -qF 'FRESH_KEY=hot' "$MOCK_ARGS_FILE"
    ! grep -qx -- '-e' "$MOCK_ARGS_FILE"
}

@test "direct claude path gets fresh .env keys via the wrapper" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    printf 'FRESH_KEY=hot\n' > "$FIXTURE_DIR/.env"
    cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FRESH_KEY:-unset}" > "$MOCK_ARGS_FILE"
EOF
    chmod +x "$MOCK_BIN/claude"
    # TMUX set without _CC_IN_SESSION → the direct-exec else branch.
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR' TMUX=fake; unset _CC_IN_SESSION; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ "$(cat "$MOCK_ARGS_FILE")" = "hot" ]
}

@test "cc launches cleanly when .env is missing" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    # No .env in the fixture dir at all.
    _mock_tmux
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR'; unset TMUX _CC_IN_SESSION; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_ARGS_FILE" ]
    grep -qx 'new-session' "$MOCK_ARGS_FILE"
    grep -qx -- '-s' "$MOCK_ARGS_FILE"
}

@test "cc falls back to plain claude when the launcher is absent" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    rm "$FIXTURE_DIR/bin/cc-env-exec"
    _mock_tmux
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR'; unset TMUX _CC_IN_SESSION; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$MOCK_ARGS_FILE")" = "claude" ]
}

@test "user args survive the wrapper prefix (ccc → --continue is final)" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    printf 'K_ONE=v1\n' > "$FIXTURE_DIR/.env"
    _mock_tmux
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR'; unset TMUX _CC_IN_SESSION; source '$CLAUDE_ZSH'; ccc"
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$MOCK_ARGS_FILE")" = "$FIXTURE_DIR/bin/cc-env-exec claude --continue" ]
}
