#!/usr/bin/env bats
# Tests for bin/cc-env-exec: explicit non-secret settings only.
load test_helper

setup() {
    setup_test_env
    export DOTFILES_DIR="$TEST_HOME/dotfiles"
    mkdir -p "$DOTFILES_DIR/bin/lib"
    cp "$REAL_DOTFILES_DIR/bin/lib/vault.sh" "$DOTFILES_DIR/bin/lib/vault.sh"
}

teardown() {
    teardown_test_env
}

@test "cc-env-exec requires a command" {
    run "$REAL_DOTFILES_DIR/bin/cc-env-exec"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "cc-env-exec exports documented settings and ignores unknown .env keys" {
    cat > "$DOTFILES_DIR/.env" <<'EOF'
CLAUDE_SETUP_DIR=/tmp/claude
DOTFILES_DEV=true
UNKNOWN_SETTING=must-not-be-loaded
EOF
    run "$REAL_DOTFILES_DIR/bin/cc-env-exec" bash -c \
        "printf '%s|%s|%s\n' \"\${CLAUDE_SETUP_DIR:-}\" \"\${DOTFILES_DEV:-}\" \"\${UNKNOWN_SETTING:-}\""
    [ "$status" -eq 0 ]
    [ "$output" = '/tmp/claude|true|' ]
}

@test "cc-env-exec parses values as data rather than executing .env" {
    cat > "$DOTFILES_DIR/.env" <<'EOF'
CLAUDE_SETUP_DIR=$(touch /tmp/cc-env-exec-must-not-exist)
EOF
    rm -f /tmp/cc-env-exec-must-not-exist
    run "$REAL_DOTFILES_DIR/bin/cc-env-exec" bash -c \
        "printf '%s\n' \"\$CLAUDE_SETUP_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "\$(touch /tmp/cc-env-exec-must-not-exist)" ]
    [ ! -e /tmp/cc-env-exec-must-not-exist ]
}

@test "cc-env-exec clears every retired value before exec" {
    cat > "$DOTFILES_DIR/.env" <<'EOF'
CLAUDE_SETUP_DIR=/tmp/claude
EOF
    run env DOTFILES_DIR="$DOTFILES_DIR" \
        GH_TOKEN=gh GITHUB_PERSONAL_ACCESS_TOKEN=pat \
        GITHUB_APP_PRIVATE_KEY=app-key \
        CONTEXT7_API_KEY=context7 TAVILY_API_KEY=tavily \
        SERPER_API_KEY=serper TODOIST_API_KEY=todoist \
        "$REAL_DOTFILES_DIR/bin/cc-env-exec" bash -c 'env'
    [ "$status" -eq 0 ]
    [[ "$output" != *GH_TOKEN=* ]]
    [[ "$output" != *GITHUB_PERSONAL_ACCESS_TOKEN=* ]]
    [[ "$output" != *GITHUB_APP_PRIVATE_KEY=* ]]
    [[ "$output" != *CONTEXT7_API_KEY=* ]]
    [[ "$output" != *TAVILY_API_KEY=* ]]
    [[ "$output" != *SERPER_API_KEY=* ]]
    [[ "$output" != *TODOIST_API_KEY=* ]]
}

@test "missing .env does not create a cache or fail the command" {
    run "$REAL_DOTFILES_DIR/bin/cc-env-exec" bash -c 'printf "%s\n" ok'
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
    [ ! -e "$HOME/.cache/dotfiles/secrets.env" ]
}
