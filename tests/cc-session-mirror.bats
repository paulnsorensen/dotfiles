#!/usr/bin/env bats
# Tests for the outside-tmux attach/create branch of _cc_base (zsh/claude.zsh).
# Bug: `tmux new-session -A -s "$session"` attaches even when a client is
# ALREADY attached to that session, so a second terminal in the same repo
# mirrors the first instead of getting its own session. Fix: only reattach
# (-A) when the target session is absent or detached; when it already has a
# client, spin up a fresh uniquely-named session instead (no -A).

load test_helper

CLAUDE_ZSH="$REAL_DOTFILES_DIR/zsh/claude.zsh"

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"
    export MOCK_ARGS_FILE="$MOCK_BIN/args"
    mkdir -p "$FIXTURE_DIR/bin"
    cp "$REAL_DOTFILES_DIR/bin/cc-env-exec" "$FIXTURE_DIR/bin/cc-env-exec"
    cp "$REAL_DOTFILES_DIR/bin/cc-session-name" "$FIXTURE_DIR/bin/cc-session-name"
    # Not a git repo: cc-session-name falls back to the bare basename of
    # FIXTURE_DIR, which we can compute without hardcoding a name.
    SESSION_NAME="$("$FIXTURE_DIR/bin/cc-session-name" "$FIXTURE_DIR")"
}

teardown() {
    rm -rf "$FIXTURE_DIR" "$MOCK_BIN"
}

# Mock tmux: list-sessions reports attachment state from $MOCK_TMUX_SESSIONS
# (raw "name:attached" lines); has-session succeeds only for names listed in
# $MOCK_TMUX_HAS_SESSIONS (comma-separated); new-session invocations are
# recorded verbatim.
_mock_tmux() {
    cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    list-sessions)
        printf '%s\n' "${MOCK_TMUX_SESSIONS:-}"
        exit 0
        ;;
    has-session)
        target="${3#=}"
        IFS=',' read -ra known <<< "${MOCK_TMUX_HAS_SESSIONS:-}"
        for n in "${known[@]}"; do
            [[ "$n" == "$target" ]] && exit 0
        done
        exit 1
        ;;
    new-session)
        printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$MOCK_BIN/tmux"
}

@test "cc spins up a fresh uniquely-named session (no -A) when the target session already has a client attached" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    _mock_tmux
    export MOCK_TMUX_SESSIONS="${SESSION_NAME}:1"
    export MOCK_TMUX_HAS_SESSIONS="$SESSION_NAME"
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR'; cd '$FIXTURE_DIR'; unset TMUX; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_ARGS_FILE" ]
    # A fresh session was created, distinct from the mirrored/attached one...
    grep -qx -- "${SESSION_NAME}-2" "$MOCK_ARGS_FILE"
    ! grep -qx -- "$SESSION_NAME" "$MOCK_ARGS_FILE"
    # ...and -A (attach-if-exists, the mirroring flag) was NOT used.
    ! grep -qx -- '-A' "$MOCK_ARGS_FILE"
}

@test "cc still reattaches (-A) when the target session is detached (orphan de-sprawl preserved)" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    _mock_tmux
    export MOCK_TMUX_SESSIONS="${SESSION_NAME}:0"
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR'; cd '$FIXTURE_DIR'; unset TMUX; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_ARGS_FILE" ]
    grep -qx -- '-A' "$MOCK_ARGS_FILE"
    grep -qx -- "$SESSION_NAME" "$MOCK_ARGS_FILE"
}

@test "cc still reattaches (-A) when no session with that name exists yet" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    _mock_tmux
    export MOCK_TMUX_SESSIONS=""
    run zsh -fc "export DOTFILES_DIR='$FIXTURE_DIR'; cd '$FIXTURE_DIR'; unset TMUX; source '$CLAUDE_ZSH'; cc"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_ARGS_FILE" ]
    grep -qx -- '-A' "$MOCK_ARGS_FILE"
    grep -qx -- "$SESSION_NAME" "$MOCK_ARGS_FILE"
}
