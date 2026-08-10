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
[[ "${1:-}" == --version ]] && printf 'v24.18.0\n'
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
