#!/usr/bin/env bats
# Behavioural tests for exact npx MCP pins and their Renovate annotations.
# Secret-bearing packages are pinned at the privileged provisioning boundary;
# profiles retain this convention for direct, non-secret npx MCPs.

load test_helper

setup() {
    setup_test_env
    export PROVISIONER="$REAL_DOTFILES_DIR/bin/vault-provision"
    export OSS_DOCS_YAML="$REAL_DOTFILES_DIR/profiles/oss-docs/profile.yaml"
    export RENOVATE_CONFIG="$REAL_DOTFILES_DIR/renovate.json5"
}

teardown() { teardown_test_env; }

broker_package() {
    local consumer=$1 line
    line=$(grep -E "^[[:space:]]*install_consumer $consumer " "$PROVISIONER")
    printf '%s\n' "${line##* }"
}

@test "broker upstream MCP packages pin exact versions, not floats" {
    local consumer package
    for consumer in context7 tavily todoist; do
        run broker_package "$consumer"
        [ "$status" -eq 0 ]
        package=$output
        [[ "$package" != *"@latest"* ]]
        [[ "$package" =~ @[0-9]+\.[0-9]+\.[0-9]+$ ]]
    done
}

@test "broker upstream pins carry adjacent Renovate annotations" {
    local consumer dep_name package
    for spec in \
        'context7:@upstash/context7-mcp' \
        'tavily:tavily-mcp' \
        'todoist:@doist/todoist-mcp'; do
        consumer=${spec%%:*}
        dep_name=${spec#*:}
        package=$(broker_package "$consumer")
        run grep -F -B1 \
            "install_consumer $consumer " "$PROVISIONER"
        [ "$status" -eq 0 ]
        [[ "$output" == *"# renovate: datasource=npm depName=$dep_name"* ]]
        [[ "$output" == *"$package"* ]]
    done
}

@test "Renovate covers privileged and profile npx pin surfaces" {
    local path
    for path in \
        '/^bin\\/vault-provision$/' \
        '/^profiles\\/[^/]+\\/profile\\.yaml$/'; do
        run grep -F "$path" "$RENOVATE_CONFIG"
        [ "$status" -eq 0 ]
    done
}

@test "direct profile npx MCP pins carry adjacent Renovate annotations" {
    run grep -F -B1 'args: ["-y", "@playwright/mcp@' "$OSS_DOCS_YAML"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# renovate: datasource=npm depName=@playwright/mcp"* ]]
}
