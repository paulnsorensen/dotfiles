#!/usr/bin/env bats
# Behavioural tests for the claude registry's context7/tavily MCP pins
# (chezmoi/.chezmoidata/claude.yaml `mcps:` block) — asserts exact-version
# npx invocations with a renovate custom-manager annotation, not floats
# (spec: manifest-pinned-packages).

load test_helper

setup() {
    setup_test_env
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CLAUDE_YAML="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
}

teardown() { teardown_test_env; }

context7_arg() { yq eval '.claude.mcps.context7.args[1]' "$CLAUDE_YAML"; }
tavily_arg() { yq eval '.claude.mcps.tavily.args[1]' "$CLAUDE_YAML"; }

@test "context7 args pin an exact version, not @latest or bare" {
    run context7_arg
    [ "$status" -eq 0 ]
    [ "$output" = "@upstash/context7-mcp@3.2.4" ]
}

@test "tavily args pin an exact version, not @latest or bare" {
    run tavily_arg
    [ "$status" -eq 0 ]
    [ "$output" = "tavily-mcp@0.2.21" ]
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
    run grep -B1 'args: \["-y", "@upstash/context7-mcp@3.2.4"\]' "$CLAUDE_YAML"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# renovate: datasource=npm depName=@upstash/context7-mcp"* ]]
}

@test "tavily has an adjacent renovate annotation for its exact depName" {
    run grep -B1 'args: \["-y", "tavily-mcp@0.2.21"\]' "$CLAUDE_YAML"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# renovate: datasource=npm depName=tavily-mcp"* ]]
}
