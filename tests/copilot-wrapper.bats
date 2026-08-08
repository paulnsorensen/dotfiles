#!/usr/bin/env bats
# Tests for the `copilot` launch wrapper in zsh/claude.zsh. The wrapper must
# delegate directly to cheese-flow's policy-controlled profile launch surface,
# preserving the engine's argv, stdout, stderr, and exit status.

load test_helper

CLAUDE_ZSH="$REAL_DOTFILES_DIR/zsh/claude.zsh"

# Extract the `copilot() { ... }` function body from claude.zsh and source it.
_load_copilot_wrapper() {
    local fn
    fn="$(awk '/^copilot\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$CLAUDE_ZSH")"
    [[ -n "$fn" ]] || {
        echo "could not extract copilot() from $CLAUDE_ZSH" >&2
        return 1
    }
    eval "$fn"
}

setup() {
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"
    export MOCK_ARGS_FILE="$MOCK_BIN/args"
    export MOCK_STDOUT_FILE="$MOCK_BIN/stdout"
    export MOCK_STDERR_FILE="$MOCK_BIN/stderr"
    export MOCK_AP_CALLED="$MOCK_BIN/ap-called"
    export MOCK_STATUS=0

    cat > "$MOCK_BIN/cheese" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
printf 'engine stdout\n'
printf 'engine stderr\n' >&2
exit "${MOCK_STATUS:-0}"
EOF
    chmod +x "$MOCK_BIN/cheese"
}

teardown() {
    rm -rf "$MOCK_BIN"
}


_run_copilot() {
    if copilot "$@" >"$MOCK_STDOUT_FILE" 2>"$MOCK_STDERR_FILE"; then
        status=0
    else
        status=$?
    fi
}

_assert_argv() {
    local expected="$MOCK_BIN/expected"
    printf '%s\n' "$@" >"$expected"
    cmp -s "$expected" "$MOCK_ARGS_FILE"
}

@test "claude.zsh defines a copilot wrapper" {
    grep -q '^copilot() {' "$CLAUDE_ZSH"
}

@test "wrapper routes exact argv through the policy-controlled launch" {
    _load_copilot_wrapper
    MOCK_STATUS=17

    _run_copilot --resume "two words" --model opus

    [ "$status" -eq 17 ]
    [ "$(cat "$MOCK_STDOUT_FILE")" = "engine stdout" ]
    [ "$(cat "$MOCK_STDERR_FILE")" = "engine stderr" ]
    _assert_argv \
        profile launch copilot global \
        --source-root "$DOTFILES_DIR" -- \
        --resume "two words" --model opus
}
