#!/usr/bin/env bats
# Unit tests for packages/lib-gh-resolve.sh
#
# resolve_real_gh must never hand mise its own shim.
# The mise shim runs mise.
# A credential command naming the shim re-enters mise forever.
# This caused the crabbot fork chain on 2026-09-28.

load test_helper

LIB="$REAL_DOTFILES_DIR/packages/lib-gh-resolve.sh"

setup() {
    setup_test_env
    # shellcheck disable=SC1090
    source "$LIB"

    # The resolver only needs readlink when PATH excludes host commands.

    TOOLBOX="$TEST_HOME/toolbox"
    mkdir -p "$TOOLBOX"
    ln -s "$(command -v readlink)" "$TOOLBOX/readlink"
}

teardown() {
    teardown_test_env
}

write_mise_shim() {
    local dir="$1"
    mkdir -p "$dir"
    printf '#!/bin/sh\nexit 0\n' > "$dir/mise"
    chmod +x "$dir/mise"
    ln -s "$dir/mise" "$dir/gh"
}

write_real_gh() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/gh" <<'EOF'
#!/bin/sh
[ "$1" = auth ] && [ "$2" = token ] || exit 64
echo real-gh
EOF
    chmod +x "$dir/gh"
}

@test "resolve_real_gh skips a mise gh shim and returns the later real gh's path" {
    write_mise_shim "$TEST_HOME/shim"
    write_real_gh "$TEST_HOME/real"

    PATH="$TEST_HOME/shim:$TEST_HOME/real:$TOOLBOX" run resolve_real_gh
    assert_success
    local expected="$TEST_HOME/real/gh"
    [[ "$output" == /* ]]
    [[ "$output" == "$expected" ]]
}

@test "resolve_real_gh returns an absolute path that survives a directory change" {
    write_real_gh "$TEST_HOME/real"
    mkdir -p "$TEST_HOME/other"

    local resolved expected
    resolved="$(cd "$TEST_HOME" && PATH="./real:$TOOLBOX" resolve_real_gh)"
    expected="$(cd "$TEST_HOME/real" && pwd -P)/gh"
    [[ "$resolved" == "$expected" ]]

    cd "$TEST_HOME/other"
    run "$resolved" auth token
    assert_success
    [[ "$output" == "real-gh" ]]
}

@test "resolve_real_gh fails when only the mise gh shim is on PATH" {
    write_mise_shim "$TEST_HOME/shim"

    PATH="$TEST_HOME/shim:$TOOLBOX" run resolve_real_gh
    assert_failure
    [[ -z "$output" ]]
}
