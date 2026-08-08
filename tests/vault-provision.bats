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
GITHUB_APP_ID=Iv1fixture
GITHUB_APP_INSTALLATION_ID=424242
EOF

    cat > "$TEST_HOME/fake-bin/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    item) exit 0 ;;
    read)
        if [[ "${2##*/}" == GITHUB_APP_PRIVATE_KEY ]]; then
            printf '%s%s\nfixture\n%s%s\n' \
                '-----BEGIN PRIVATE ' 'KEY-----' '-----END PRIVATE ' 'KEY-----'
        else
            printf 'credential-%s\n' "${2##*/}"
        fi
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$TEST_HOME/fake-bin/op"

    cat > "$TEST_HOME/fake-bin/github-mcp-server" <<'EOF'
#!/usr/bin/env bash
printf 'fixture github-mcp-server\n'
EOF
    chmod +x "$TEST_HOME/fake-bin/github-mcp-server"

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
    run env \
        DOTFILES_DIR="$FIXTURE_DOTFILES" \
        DESTDIR="$INSTALL_ROOT" \
        "$REAL_DOTFILES_DIR/bin/vault-provision" \
        --request-user "$(id -un)" --operator-user root
    assert_success
    [ -z "$output" ]

    local runtime="$INSTALL_ROOT/usr/local/libexec/dotfiles/node-24.18.0"
    [ -x "$runtime/bin/node" ]
    [ -x "$runtime/bin/agent-secret-npx" ]
    [ ! -L "$runtime/bin/npx" ]
    local github_runtime="$INSTALL_ROOT/usr/local/libexec/dotfiles/github-mcp-server"
    [ -x "$github_runtime" ]
    grep -qF 'fixture github-mcp-server' "$github_runtime"
    grep -qF \
        'exec /usr/local/libexec/dotfiles/node-24.18.0/bin/node /usr/local/libexec/dotfiles/node-24.18.0/lib/node_modules/npm/bin/npx-cli.js "$@"' \
        "$runtime/bin/agent-secret-npx"
    run grep -qF "$TEST_HOME" "$runtime/bin/agent-secret-npx"
    [[ "$status" -ne 0 ]]

    local credentials="$INSTALL_ROOT/etc/dotfiles/agent-secret/credentials"
    local consumer key
    for consumer in context7 tavily todoist github; do
        case "$consumer" in
            context7) key=CONTEXT7_API_KEY ;;
            tavily) key=TAVILY_API_KEY ;;
            todoist) key=TODOIST_API_KEY ;;
            github) key=GITHUB_APP_PRIVATE_KEY ;;
        esac
        if [[ "$consumer" == github ]]; then
            local pem_begin='-----BEGIN PRIVATE ''KEY-----'
            local pem_end='-----END PRIVATE ''KEY-----'
            [ "$(cat "$credentials/$consumer.credential")" = "$pem_begin
fixture
$pem_end" ]
        else
            [ "$(cat "$credentials/$consumer.credential")" = "credential-$key" ]
        fi
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
    jq -e '.upstream == {
        "argv": [
            "/usr/local/libexec/dotfiles/github-mcp-server", "stdio",
            "--app-id", "Iv1fixture",
            "--app-installation-id", "424242",
            "--toolsets", "repos,issues,pull_requests"
        ],
        "credential_env": "GITHUB_APP_PRIVATE_KEY",
        "credential_file": "/etc/dotfiles/agent-secret/credentials/github.credential"
    } and .tools.read == [
        "get_commit", "get_file_contents", "issue_read", "list_branches",
        "list_commits", "list_issues", "list_pull_requests", "pull_request_read",
        "search_code", "search_issues", "search_pull_requests", "search_repositories"
    ] and .tools.write == [
        "add_issue_comment", "create_branch", "create_or_update_file",
        "create_pull_request", "issue_write", "push_files", "update_pull_request"
    ]' "$policy/github.json" >/dev/null

    jq -e '.provider == "onepassword" and .source == "op://fixture/Agent Secrets"' \
        "$INSTALL_ROOT/etc/dotfiles/agent-secret/provider.json" >/dev/null
}
