#!/usr/bin/env bats
# Behavioural tests for npx MCP pins across the Claude/Codex registries and
# isolated profiles. Every exact pin carries the Renovate annotation consumed by
# the custom manager (spec: manifest-pinned-packages).

load test_helper

setup() {
    setup_test_env
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CLAUDE_YAML="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    export CODEX_YAML="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml"
    export OSS_DOCS_YAML="$REAL_DOTFILES_DIR/profiles/oss-docs/profile.yaml"
    export RENOVATE_CONFIG="$REAL_DOTFILES_DIR/renovate.json5"
}

teardown() { teardown_test_env; }

context7_arg() { yq eval '.claude.mcps.context7.args[1]' "$CLAUDE_YAML"; }
tavily_arg() { yq eval '.claude.mcps.tavily.args[1]' "$CLAUDE_YAML"; }

@test "context7 args pin an exact version, not @latest or bare" {
    run context7_arg
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^@upstash/context7-mcp@[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "tavily args pin an exact version, not @latest or bare" {
    run tavily_arg
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^tavily-mcp@[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "context7 pin is not a float (@latest or bare package name)" {
    run context7_arg
    [[ "$output" != *"@latest"* && "$output" == "@upstash/context7-mcp@"* ]]
}

@test "tavily pin is not a float (@latest or bare package name)" {
    run tavily_arg
    [[ "$output" != *"@latest"* && "$output" == "tavily-mcp@"* ]]
}

@test "context7 has an adjacent renovate annotation for its exact depName" {
    run grep -B1 'args: \["-y", "@upstash/context7-mcp@' "$CLAUDE_YAML"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# renovate: datasource=npm depName=@upstash/context7-mcp"* ]]
}

@test "tavily has an adjacent renovate annotation for its exact depName" {
    run grep -B1 'args: \["-y", "tavily-mcp@' "$CLAUDE_YAML"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# renovate: datasource=npm depName=tavily-mcp"* ]]
}

@test "Renovate's MCP manager covers Claude, Codex, and profile pin surfaces" {
    local path
    local paths=(
        '/^chezmoi\\/\\.chezmoidata\\/claude\\.yaml$/'
        '/^chezmoi\\/\\.chezmoidata\\/codex\\.yaml$/'
        '/^profiles\\/[^/]+\\/profile\\.yaml$/'
    )
    for path in "${paths[@]}"; do
        run grep -F "$path" "$RENOVATE_CONFIG"
        [ "$status" -eq 0 ]
    done
}

@test "Codex registry MCP pins carry adjacent Renovate annotations" {
    local package
    for package in '@upstash/context7-mcp' 'tavily-mcp'; do
        run grep -F -B1 "args: [\"-y\", \"$package@" "$CODEX_YAML"
        [ "$status" -eq 0 ]
        [[ "$output" == *"# renovate: datasource=npm depName=$package"* ]]
    done
}

@test "oss-docs npx MCP pins carry adjacent Renovate annotations" {
    local package
    for package in '@upstash/context7-mcp' '@playwright/mcp' 'tavily-mcp'; do
        run grep -F -B1 "args: [\"-y\", \"$package@" "$OSS_DOCS_YAML"
        [ "$status" -eq 0 ]
        [[ "$output" == *"# renovate: datasource=npm depName=$package"* ]]
    done
}
