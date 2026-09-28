#!/usr/bin/env bats
# Unit tests for packages/lib-gh-resolve.sh
#
# resolve_real_gh must never hand mise its own shim: mise's `gh` shim runs
# mise, so naming it in MISE_GITHUB_CREDENTIAL_COMMAND makes mise's
# `sh -c 'gh auth token'` re-enter the shim, which re-enters mise, forever
# — the fork chain that wedged crabbot on 2026-09-28.

load test_helper

LIB="$REAL_DOTFILES_DIR/packages/lib-gh-resolve.sh"

setup() {
    setup_test_env
    # shellcheck disable=SC1090
    source "$LIB"

    # A minimal toolbox carrying only the external commands the resolver
    # needs (basename, readlink), so scenario PATHs can exclude every real
    # `gh` this host has installed (e.g. /usr/bin/gh) without breaking the
    # resolver itself.
    TOOLBOX="$TEST_HOME/toolbox"
    mkdir -p "$TOOLBOX"
    ln -s "$(command -v basename)" "$TOOLBOX/basename"
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
    printf '#!/bin/sh\necho real-gh\n' > "$dir/gh"
    chmod +x "$dir/gh"
}

@test "resolve_real_gh skips a mise gh shim and returns the later real gh's path" {
    write_mise_shim "$TEST_HOME/shim"
    write_real_gh "$TEST_HOME/real"

    PATH="$TEST_HOME/shim:$TEST_HOME/real:$TOOLBOX" run resolve_real_gh
    assert_success
    [[ "$output" == "$TEST_HOME/real/gh" ]]
}

@test "resolve_real_gh fails when only the mise gh shim is on PATH" {
    write_mise_shim "$TEST_HOME/shim"

    PATH="$TEST_HOME/shim:$TOOLBOX" run resolve_real_gh
    assert_failure
    [[ -z "$output" ]]
}
