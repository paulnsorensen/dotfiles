#!/usr/bin/env bats

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

load test_helper

setup() {
    setup_test_env
    [[ "$(id -u)" -ne 0 ]] || skip "requires distinct current and root users"

    export FIXTURE_DOTFILES="$TEST_HOME/dotfiles"
    export INSTALL_ROOT="$TEST_HOME/root"
    mkdir -p "$FIXTURE_DOTFILES" "$INSTALL_ROOT" "$TEST_HOME/fake-bin"
    ln -s "$REAL_DOTFILES_DIR/bin" "$FIXTURE_DOTFILES/bin"
    ln -s "$REAL_DOTFILES_DIR/scripts" "$FIXTURE_DOTFILES/scripts"
    ln -s "$REAL_DOTFILES_DIR/services" "$FIXTURE_DOTFILES/services"
    cat > "$FIXTURE_DOTFILES/.env" <<'EOF'
DOTFILES_VAULT_PROVIDER=onepassword
DOTFILES_OP_ITEM=op://fixture/Agent Secrets
EOF

    cat > "$TEST_HOME/fake-bin/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    item) exit 0 ;;
    read)
        [[ "${FAIL_TODOIST_READ:-false}" != true || "${2##*/}" != TODOIST_API_KEY ]] || exit 1
        printf 'credential-%s\n' "${2##*/}"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$TEST_HOME/fake-bin/op"

    export NODE_ROOT="$TEST_HOME/node-v24.18.0"
    mkdir -p "$NODE_ROOT/bin" "$NODE_ROOT/lib/node_modules/npm/bin"
    cat > "$NODE_ROOT/bin/node" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --version) printf 'v24.18.0\n' ;;
    -p) printf '%s/bin/node\n' "$NODE_ROOT" ;;
esac
EOF
    cat > "$NODE_ROOT/lib/node_modules/npm/bin/npx-cli.js" <<'EOF'
#!/usr/bin/env node
process.exit(0)
EOF
    chmod +x "$NODE_ROOT/bin/node" "$NODE_ROOT/lib/node_modules/npm/bin/npx-cli.js"
    ln -s ../lib/node_modules/npm/bin/npx-cli.js "$NODE_ROOT/bin/npx"
    export PATH="$TEST_HOME/fake-bin:$NODE_ROOT/bin:$PATH"
}

teardown() { teardown_test_env; }

@test "vault-provision renders root-bound credentials policies and runtime" {
    printf 'TODOIST=true\n' >> "$FIXTURE_DOTFILES/.env"

    export DECOY_DOTFILES="$TEST_HOME/decoy-dotfiles"
    mkdir -p "$DECOY_DOTFILES"
    run env \
        DOTFILES_DIR="$DECOY_DOTFILES" \
        DESTDIR="$INSTALL_ROOT" \
        "$FIXTURE_DOTFILES/bin/vault-provision" \
        --request-user "$(id -un)" --operator-user root
    assert_success
    [ -z "$output" ]

    local runtime="$INSTALL_ROOT/usr/local/libexec/dotfiles/node-24.18.0"
    [ -x "$runtime/bin/node" ]
    [ -x "$runtime/bin/agent-secret-npx" ]
    [ ! -L "$runtime/bin/npx" ]
    grep -qF \
        'exec /usr/local/libexec/dotfiles/node-24.18.0/bin/node /usr/local/libexec/dotfiles/node-24.18.0/lib/node_modules/npm/bin/npx-cli.js "$@"' \
        "$runtime/bin/agent-secret-npx"
    run grep -qF "$TEST_HOME" "$runtime/bin/agent-secret-npx"
    [[ "$status" -ne 0 ]]

    local credentials="$INSTALL_ROOT/etc/dotfiles/agent-secret/credentials"
    local consumer key
    for consumer in context7 tavily todoist; do
        case "$consumer" in
            context7) key=CONTEXT7_API_KEY ;;
            tavily) key=TAVILY_API_KEY ;;
            todoist) key=TODOIST_API_KEY ;;
        esac
        [ "$(cat "$credentials/$consumer.credential")" = "credential-$key" ]
        [ "$(file_mode "$credentials/$consumer.credential")" = 600 ]
        run grep -qF "credential-$key" \
            "$INSTALL_ROOT/etc/dotfiles/agent-secret-broker/$consumer.json"
        [[ "$status" -ne 0 ]]
    done

    local policy="$INSTALL_ROOT/etc/dotfiles/agent-secret-broker"
    jq -e '.upstream.argv == [
        "/usr/local/libexec/dotfiles/node-24.18.0/bin/agent-secret-npx",
        "-y", "@upstash/context7-mcp@3.2.5"
    ] and .tools == {
        "read": ["resolve-library-id", "query-docs"],
        "write": []
    }' "$policy/context7.json" >/dev/null
    jq -e '.upstream.argv == [
        "/usr/local/libexec/dotfiles/node-24.18.0/bin/agent-secret-npx",
        "-y", "tavily-mcp@0.2.22"
    ] and .tools == {
        "read": ["tavily_search", "tavily_extract"],
        "write": []
    }' "$policy/tavily.json" >/dev/null
    jq -e '.upstream.argv == [
        "/usr/local/libexec/dotfiles/node-24.18.0/bin/agent-secret-npx",
        "-y", "@doist/todoist-mcp@12.5.0"
    ]' "$policy/todoist.json" >/dev/null
    jq -e '.tools.read == [
        "find-activity", "find-comments", "find-completed-tasks", "find-filters",
        "find-labels", "find-project-collaborators", "find-projects", "find-reminders",
        "find-sections", "find-tasks", "find-tasks-by-date", "get-overview",
        "get-productivity-stats", "get-project-activity-stats", "get-project-health",
        "get-workspace-insights", "analyze-project-health", "export-project-template",
        "fetch", "fetch-object", "list-workspaces", "search", "user-info", "view-attachment"
    ] and .tools.write == [
        "add-comments", "add-filters", "add-labels", "add-projects", "add-reminders",
        "add-sections", "add-tasks", "complete-tasks", "delete-object",
        "import-project-template", "manage-assignments", "project-management",
        "project-move", "reorder-objects", "reschedule-tasks", "uncomplete-tasks",
        "update-comments", "update-filters", "update-labels", "update-projects",
        "update-reminders", "update-sections", "update-tasks"
    ]' "$policy/todoist.json" >/dev/null

    jq -e '.provider == "onepassword" and .source == "op://fixture/Agent Secrets"' \
        "$INSTALL_ROOT/etc/dotfiles/agent-secret/provider.json" >/dev/null
}

assert_todoist_disabled() {
    run env -u TODOIST \
        FAIL_TODOIST_READ=true \
        DOTFILES_DIR="$TEST_HOME/decoy-dotfiles" \
        DESTDIR="$INSTALL_ROOT" \
        "$FIXTURE_DOTFILES/bin/vault-provision" \
        --request-user "$(id -un)" --operator-user root
    assert_success
    [ -z "$output" ]

    local credentials="$INSTALL_ROOT/etc/dotfiles/agent-secret/credentials"
    [ "$(cat "$credentials/context7.credential")" = credential-CONTEXT7_API_KEY ]
    [ "$(cat "$credentials/tavily.credential")" = credential-TAVILY_API_KEY ]
    [ ! -e "$credentials/todoist.credential" ]
    [ ! -e "$INSTALL_ROOT/etc/dotfiles/agent-secret-broker/todoist.json" ]
    [ ! -e "$INSTALL_ROOT/Library/LaunchDaemons/com.dotfiles.agent-secret.todoist.plist" ]

    local service_home=/var/lib/dotfiles-agent-secrets/todoist
    [[ "$(uname -s)" == Darwin ]] && service_home=/var/db/dotfiles-agent-secrets/todoist
    [ ! -e "$INSTALL_ROOT$service_home" ]
}

@test "vault-provision skips Todoist when TODOIST is unset" {
    assert_todoist_disabled
}

@test "vault-provision skips Todoist when TODOIST=false" {
    printf 'TODOIST=false\n' >> "$FIXTURE_DOTFILES/.env"
    assert_todoist_disabled
}

@test "vault-provision uses one sudo transaction" {
    local sudo_log="$TEST_HOME/sudo.log"
    cat > "$TEST_HOME/fake-bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_LOG"
[[ "$1" == */vault-provision && "${2:-}" == --privileged-install ]] || exit 97
DESTDIR="$INSTALL_ROOT" "$@"
EOF
    chmod +x "$TEST_HOME/fake-bin/sudo"

    run env -u DESTDIR -u TODOIST \
        INSTALL_ROOT="$INSTALL_ROOT" \
        SUDO_LOG="$sudo_log" \
        "$FIXTURE_DOTFILES/bin/vault-provision" \
        --request-user "$(id -un)" --operator-user root
    assert_success
    [ -z "$output" ]
    [ "$(wc -l < "$sudo_log")" -eq 1 ]
    [[ "$(cat "$sudo_log")" == *" --privileged-install "* ]]
    [ -f "$INSTALL_ROOT/etc/dotfiles/agent-secret/credentials/context7.credential" ]
    [ -f "$INSTALL_ROOT/etc/dotfiles/agent-secret/credentials/tavily.credential" ]
}


@test "vault-provision rejects a Node prefix inside Homebrew Cellar" {
    local cellar="$TEST_HOME/opt/homebrew/Cellar/node/24.18.0"
    mkdir -p "$cellar/bin" "$cellar/lib/node_modules/npm/bin"
    cp "$NODE_ROOT/bin/node" "$cellar/bin/node"
    cp "$NODE_ROOT/lib/node_modules/npm/bin/npx-cli.js" "$cellar/lib/node_modules/npm/bin/npx-cli.js"
    chmod +x "$cellar/bin/node" "$cellar/lib/node_modules/npm/bin/npx-cli.js"
    ln -s ../lib/node_modules/npm/bin/npx-cli.js "$cellar/bin/npx"
    export NODE_ROOT="$cellar"
    export PATH="$cellar/bin:$PATH"
    run env DESTDIR="$INSTALL_ROOT" "$FIXTURE_DOTFILES/bin/vault-provision" \
        --request-user "$(id -un)" --operator-user root
    assert_failure
    [[ "$output" == *"Homebrew Cellar"* ]]
}

@test "ensure_bitwarden_value prompts and creates only when the secret is missing" {
    local log="$TEST_HOME/bws.log"
    # shellcheck disable=SC2016
    run env BWS_LOG="$log" bash -c '
        source <(sed -n "/^ensure_bitwarden_value()/,/^}/p" "$1")
        vault_secret_value() { return 1; }
        _vault_token() { printf token; }
        _vault_project_id() { printf project; }
        bws() { printf "%s\n" "$*" >> "$BWS_LOG"; }
        ensure_bitwarden_value TAVILY_API_KEY <<< missing-value
        printf "value=%s\n" "$VAULT_PROVISION_VALUE"
    ' _ "$FIXTURE_DOTFILES/bin/vault-provision"
    assert_success
    [[ "$output" == *"Enter TAVILY_API_KEY (input hidden):"* ]]
    [[ "$output" == *"value=missing-value"* ]]
    [[ "$(cat "$log")" == *"secret create TAVILY_API_KEY missing-value project -o json"* ]]
}

@test "ensure_bitwarden_value propagates fetch errors without prompting or creating" {
    local log="$TEST_HOME/bws.log"
    # shellcheck disable=SC2016
    run env BWS_LOG="$log" bash -c '
        source <(sed -n "/^ensure_bitwarden_value()/,/^}/p" "$1")
        vault_secret_value() { return 3; }
        _vault_token() { printf token; }
        _vault_project_id() { printf project; }
        bws() { printf "%s\n" "$*" >> "$BWS_LOG"; }
        ensure_bitwarden_value TAVILY_API_KEY
    ' _ "$FIXTURE_DOTFILES/bin/vault-provision"
    [ "$status" -eq 3 ]
    [[ "$output" != *"Enter TAVILY_API_KEY"* ]]
    [ ! -e "$log" ]
}

@test "require_trusted_interpreter accepts a symlink to a root-owned interpreter" {
    ln -s /bin/sh "$TEST_HOME/node"
    run bash -c '
        eval "$(sed -n "/^require_trusted_interpreter()/,/^}/p" "$1")"
        DESTDIR= require_trusted_interpreter "$2"
    ' _ "$FIXTURE_DOTFILES/bin/vault-provision" "$TEST_HOME/node"
    assert_success
}

@test "require_trusted_interpreter rejects a user-owned interpreter and never executes it" {
    local marker="$TEST_HOME/node-executed"
    cat > "$TEST_HOME/node" <<EOF
#!/usr/bin/env bash
touch '$marker'
EOF
    chmod 755 "$TEST_HOME/node"

    run bash -c '
        eval "$(sed -n "/^require_trusted_interpreter()/,/^}/p" "$1")"
        DESTDIR= require_trusted_interpreter "$2"
    ' _ "$FIXTURE_DOTFILES/bin/vault-provision" "$TEST_HOME/node"
    assert_failure
    [[ "$output" == *"root-owned and not group/other-writable"* ]]
    [ ! -e "$marker" ]
}

@test "install_node_runtime refreshes a snapshot that only has the old two marker files" {
    local target="$INSTALL_ROOT/usr/local/libexec/dotfiles/node-24.18.0"
    mkdir -p "$target/bin" "$target/lib/node_modules/npm/bin"
    printf '#!/bin/sh\n' > "$target/bin/node"
    chmod +x "$target/bin/node"
    printf 'stale-npx-cli\n' > "$target/lib/node_modules/npm/bin/npx-cli.js"

    run env -u TODOIST DESTDIR="$INSTALL_ROOT" \
        "$FIXTURE_DOTFILES/bin/vault-provision" \
        --request-user "$(id -un)" --operator-user root
    assert_success
    [ -z "$output" ]

    [ -x "$target/bin/node" ]
    [ -x "$target/bin/npx" ]
    [ ! -L "$target/lib/node_modules/npm" ]
    [ "$(cat "$target/lib/node_modules/npm/bin/npx-cli.js")" != stale-npx-cli ]
}

@test "ensure_bitwarden_value surfaces a Bitwarden fetch failure instead of swallowing it" {
    cat > "$TEST_HOME/fake-bin/security" <<'EOF'
#!/usr/bin/env bash
printf 'test-token\n'
EOF
    cat > "$TEST_HOME/fake-bin/bws" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    chmod +x "$TEST_HOME/fake-bin/security" "$TEST_HOME/fake-bin/bws"

    # shellcheck disable=SC2016
    run env BWS_PROJECT_ID=test-project BWS_ACCESS_TOKEN=test-token DOTFILES_DIR="$FIXTURE_DOTFILES" bash -c '
        source "$DOTFILES_DIR/bin/lib/vault.sh"
        eval "$(sed -n "/^ensure_bitwarden_value()/,/^}/p" "$1")"
        ensure_bitwarden_value TAVILY_API_KEY
    ' _ "$FIXTURE_DOTFILES/bin/vault-provision"
    [ "$status" -eq 3 ]
    [[ "$output" == *"Bitwarden fetch failed"* ]]
}
