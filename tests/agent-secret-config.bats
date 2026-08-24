#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
}

teardown() { teardown_test_env; }

assert_yaml_proxy() {
    local file=$1 query=$2 consumer=$3 command=${4:-agent-secret-proxy}
    [[ "$(yq -r "$query.command" "$file")" == "$command" ]]
    [[ "$(yq -r "$query.args | @json" "$file")" == "[\"--socket\",\"/var/run/dotfiles-agent-secrets/$consumer.sock\"]" ]]
    [[ "$(yq -r "$query | has(\"env\")" "$file")" == false ]]
    [[ "$(yq -r "$query | has(\"envFile\")" "$file")" == false ]]
}

assert_json_proxy() {
    local file=$1 query=$2 consumer=$3 command=${4:-agent-secret-proxy}
    jq -e "$query.command == \"$command\"" "$file" >/dev/null
    jq -e "$query.args == [\"--socket\", \"/var/run/dotfiles-agent-secrets/$consumer.sock\"]" "$file" >/dev/null
    jq -e "$query | has(\"env\") | not" "$file" >/dev/null
    jq -e "$query | has(\"envFile\") | not" "$file" >/dev/null
}

@test "every checked-in managed MCP definition uses its fixed secretless proxy" {
    local registry="$REAL_DOTFILES_DIR/agents/mcp/registry.yaml"
    assert_yaml_proxy "$registry" '.mcps.context7' context7
    assert_yaml_proxy "$registry" '.mcps.tavily' tavily
    assert_yaml_proxy "$registry" '.mcps.todoist' todoist

    local spec
    for spec in \
        'fe:context7' 'fe:tavily' \
        'oss-docs:context7' 'oss-docs:tavily' \
        'plugin:context7' \
        'review:context7' \
        'spec:context7' 'spec:tavily' \
        'todo:todoist'; do
        local profile=${spec%%:*} consumer=${spec#*:}
        local file="$REAL_DOTFILES_DIR/profiles/$profile/profile.yaml"
        assert_yaml_proxy \
            "$file" ".mcps[] | select(.name == \"$consumer\")" "$consumer"
    done

    local libexec_proxy=/usr/local/libexec/dotfiles/agent-secret-proxy

    local claude="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    assert_yaml_proxy "$claude" '.claude.mcps.context7' context7 "$libexec_proxy"
    assert_yaml_proxy "$claude" '.claude.mcps.tavily' tavily "$libexec_proxy"

    local codex="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml"
    assert_yaml_proxy "$codex" '.codex.mcps.context7' context7 "$libexec_proxy"
    assert_yaml_proxy "$codex" '.codex.mcps.tavily' tavily "$libexec_proxy"

    assert_json_proxy \
        "$REAL_DOTFILES_DIR/chezmoi/dot_omp/private_agent/mcp.json" \
        '.mcpServers.context7' context7 "$libexec_proxy"
}

@test "rendered Copilot MCP config contains no credential delivery channel" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local template="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    local rendered="$TEST_HOME/copilot-mcp.json"

    env -u CONTEXT7_API_KEY -u TAVILY_API_KEY -u TODOIST_API_KEY \
        -u GITHUB_APP_PRIVATE_KEY -u SERPER_API_KEY \
        -u GH_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN \
        chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template \
        < "$template" > "$rendered"

    local libexec_proxy=/usr/local/libexec/dotfiles/agent-secret-proxy
    assert_json_proxy "$rendered" '.mcpServers.context7' context7 "$libexec_proxy"
    assert_json_proxy "$rendered" '.mcpServers.tavily' tavily "$libexec_proxy"

    local retired
    for retired in \
        CONTEXT7_API_KEY TAVILY_API_KEY TODOIST_API_KEY GITHUB_APP_PRIVATE_KEY \
        SERPER_API_KEY GH_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
        ! grep -qF "$retired" "$rendered"
    done
}

@test "the daily-user environment template contains only non-secret settings" {
    local retired
    for retired in \
        CONTEXT7_API_KEY TAVILY_API_KEY TODOIST_API_KEY GITHUB_APP_PRIVATE_KEY \
        SERPER_API_KEY GH_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
        ! grep -qE "^[[:space:]]*(export[[:space:]]+)?$retired=" \
            "$REAL_DOTFILES_DIR/.env.example"
    done
}
