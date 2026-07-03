#!/usr/bin/env bats
# Tests for the `copilot` launch wrapper in zsh/claude.zsh — it injects the
# canonical allow/deny lists as --allow-tool/--deny-tool flags (lever 1) by
# shelling out to `ap copilot-flags global`. The wrapper uses only
# bash-compatible syntax, so we source just its definition out of the zsh
# file (keeping the test grounded in the shipped function) and exercise it
# with `ap` and `copilot` mocked on $PATH.

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
    # Mock `copilot`: record the args it was invoked with.
    cat > "$MOCK_BIN/copilot" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
EOF
    chmod +x "$MOCK_BIN/copilot"
    export MOCK_ARGS_FILE="$MOCK_BIN/args"
}

teardown() {
    rm -rf "$MOCK_BIN"
}

_mock_ap_flags() {
    cat > "$MOCK_BIN/ap" <<EOF
#!/usr/bin/env bash
printf '%s\n' $1
EOF
    chmod +x "$MOCK_BIN/ap"
}

# Mock `ap` that prints $1 to stdout then exits with status $2 (default 1) —
# models a missing/erroring `ap` or a mid-stream crash after partial output.
_mock_ap_fail() {
    cat > "$MOCK_BIN/ap" <<EOF
#!/usr/bin/env bash
printf '%s\n' $1
exit ${2:-1}
EOF
    chmod +x "$MOCK_BIN/ap"
}

@test "claude.zsh defines a copilot wrapper" {
    grep -q '^copilot() {' "$CLAUDE_ZSH"
}

@test "wrapper forwards canonical flags before user args" {
    _mock_ap_flags "'--allow-tool=shell(git)' '--deny-tool=shell(sudo)'"
    _load_copilot_wrapper
    copilot --resume
    run cat "$MOCK_ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--allow-tool=shell(git)" ]
    [ "${lines[1]}" = "--deny-tool=shell(sudo)" ]
    [ "${lines[2]}" = "--resume" ]
}

@test "wrapper preserves a flag value containing spaces as one token" {
    _mock_ap_flags "'--allow-tool=shell(gh pr view)'"
    _load_copilot_wrapper
    copilot
    run cat "$MOCK_ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--allow-tool=shell(gh pr view)" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "wrapper works when ap emits no flags" {
    _mock_ap_flags ""
    _load_copilot_wrapper
    copilot --help
    run cat "$MOCK_ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--help" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "wrapper fails closed and does not launch when ap errors" {
    _mock_ap_fail "" 1
    _load_copilot_wrapper
    run copilot --resume
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to launch unrestricted"* ]]
    # copilot must NOT have been invoked: its args file was never written.
    [ ! -f "$MOCK_ARGS_FILE" ]
}

@test "wrapper fails closed on a mid-stream crash (partial output, non-zero exit)" {
    # ap prints one flag, then crashes — the floor would be truncated, so abort.
    _mock_ap_fail "'--allow-tool=shell(git)'" 3
    _load_copilot_wrapper
    run copilot
    [ "$status" -eq 3 ]
    [[ "$output" == *"ap exited 3"* ]]
    [ ! -f "$MOCK_ARGS_FILE" ]
}
