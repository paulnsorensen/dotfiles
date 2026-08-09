#!/usr/bin/env bats
# Provider selection and secret-isolation assertions for bin/lib/vault.sh.
load test_helper

setup() {
    setup_test_env
    export VAULT_LIB="$REAL_DOTFILES_DIR/bin/lib/vault.sh"
    export DOTFILES_DIR="$TEST_HOME/dotfiles"
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$DOTFILES_DIR" "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
    unset DOTFILES_VAULT_PROVIDER DOTFILES_OP_ITEM BWS_PROJECT_ID BWS_ACCESS_TOKEN
}

teardown() {
    teardown_test_env
}

@test "vault_resolve selects an explicitly ready 1Password item" {
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "item get dotfiles --vault Employee --format json" ]]
EOF
    chmod +x "$MOCK_BIN/op"
    cat > "$DOTFILES_DIR/.env" <<'EOF'
DOTFILES_VAULT_PROVIDER=onepassword
DOTFILES_OP_ITEM=op://Employee/dotfiles
EOF

    run bash -c "source '$VAULT_LIB'; vault_resolve"
    [ "$status" -eq 0 ]
    [ "$output" = onepassword ]
}

@test "vault_resolve rejects an unready explicit provider without cache fallback" {
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$MOCK_BIN/op"
    export DOTFILES_VAULT_PROVIDER=onepassword
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    mkdir -p "$HOME/.cache/dotfiles"
    printf 'CONTEXT7_API_KEY=retired-cache-value\n' > "$HOME/.cache/dotfiles/secrets.env"

    run bash -c "source '$VAULT_LIB'; vault_unset_retired_secrets; vault_resolve"
    [ "$status" -ne 0 ]
    [ ! -e "$HOME/.cache/dotfiles/secrets.env" ]
}

@test "vault_load_settings exports the explicit non-secret allowlist only" {
    cat > "$DOTFILES_DIR/.env" <<'EOF'
CLAUDE_SETUP_DIR=/tmp/claude
DOTFILES_DEV=true
UNKNOWN_SETTING=must-not-escape
CONTEXT7_API_KEY=retired-value
TAVILY_API_KEY=retired-value
SERPER_API_KEY=retired-value
TODOIST_API_KEY=retired-value
GH_TOKEN=retired-value
GITHUB_PERSONAL_ACCESS_TOKEN=retired-value
GITHUB_APP_PRIVATE_KEY=retired-value
EOF
    export CONTEXT7_API_KEY=inherited-value
    export TAVILY_API_KEY=inherited-value
    export GITHUB_APP_PRIVATE_KEY=inherited-value
    export UNKNOWN_SETTING=inherited-value

    run env DOTFILES_DIR="$DOTFILES_DIR" bash -c "source '$VAULT_LIB'; vault_load_settings '$DOTFILES_DIR/.env'; printf '%s|%s|%s|%s|%s\n' \"\${CLAUDE_SETUP_DIR:-}\" \"\${DOTFILES_DEV:-}\" \"\${UNKNOWN_SETTING:-}\" \"\${CONTEXT7_API_KEY+x}\" \"\${GITHUB_APP_PRIVATE_KEY+x}\""
    [ "$status" -eq 0 ]
    [ "$output" = '/tmp/claude|true|inherited-value||' ]
}

@test "retired secret names are cleared before a child exec" {
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

@test "sourced vault library records an absolute path before lockf re-exec" {
    mkdir -p "$TEST_HOME/changed-directory"
    run bash -c "cd '$TEST_HOME/changed-directory'; source '$VAULT_LIB'; cd /; printf '%s\n' \"\$_VAULT_LIBRARY_PATH\""
    [ "$status" -eq 0 ]
    [[ "$output" == /*/bin/lib/vault.sh ]]
}

@test "runtime secret reader refuses retired non-runtime keys" {
    run bash -c "source '$VAULT_LIB'; vault_secret_value onepassword GH_TOKEN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refusing non-runtime secret key"* ]]
}
