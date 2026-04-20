#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    unset CONTEXT7_API_KEY TAVILY_API_KEY
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export COPILOT_LOG="$TEST_HOME/copilot.log"

    cat > "$MOCK_BIN/copilot" << 'MOCK'
#!/bin/bash
printf 'copilot %s\n' "$*" >> "${COPILOT_LOG:-/dev/null}"
# Accept "copilot --config-dir PATH mcp get NAME"
if [[ "$1" == "--config-dir" && "$3" == "mcp" && "$4" == "get" ]]; then
    exit 0
fi
exit 1
MOCK
    chmod +x "$MOCK_BIN/copilot"

    for command_name in uvx code-review-graph npx; do
        cat > "$MOCK_BIN/$command_name" << 'MOCK'
#!/bin/bash
exit 0
MOCK
        chmod +x "$MOCK_BIN/$command_name"
    done

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

create_mock_copilot_dir() {
    local mock_root="$TEST_HOME/mock-dotfiles"
    local mock_copilot_dir="$mock_root/.copilot"

    mkdir -p "$mock_copilot_dir"
    cp "$REAL_DOTFILES_DIR/.copilot/.sync" "$mock_copilot_dir/.sync"
    cp "$REAL_DOTFILES_DIR/.copilot/mcp-config.json" "$mock_copilot_dir/mcp-config.json"

    printf '%s\n' "$mock_copilot_dir"
}

@test ".copilot .sync renders local MCP config from env placeholders" {
    local mock_copilot_dir
    mock_copilot_dir=$(create_mock_copilot_dir)

    cat > "$TEST_HOME/mock-dotfiles/.env" << 'ENV'
CONTEXT7_API_KEY=context7-secret
TAVILY_API_KEY=tavily-secret
ENV

    run bash "$mock_copilot_dir/.sync"
    assert_success
    assert_output_contains "Rendering $HOME/.copilot/mcp-config.json"
    assert_file_exists "$HOME/.copilot/mcp-config.json"
    [[ ! -L "$HOME/.copilot/mcp-config.json" ]]

    run jq -r '.mcpServers.context7.env.CONTEXT7_API_KEY' "$HOME/.copilot/mcp-config.json"
    assert_success
    [[ "$output" == "context7-secret" ]]

    run jq -r '.mcpServers.tavily.env.TAVILY_API_KEY' "$HOME/.copilot/mcp-config.json"
    assert_success
    [[ "$output" == "tavily-secret" ]]

    run jq -r '.mcpServers["code-review-graph"].command' "$HOME/.copilot/mcp-config.json"
    assert_success
    [[ "$output" == "uvx" ]]

    run jq -r '.mcpServers.tilth.command' "$HOME/.copilot/mcp-config.json"
    assert_success
    [[ "$output" == "tilth" ]]

    run cat "$COPILOT_LOG"
    assert_success
    assert_output_contains "copilot --config-dir $HOME/.copilot mcp get code-review-graph"
    assert_output_contains "copilot --config-dir $HOME/.copilot mcp get context7"
    assert_output_contains "copilot --config-dir $HOME/.copilot mcp get tavily"
    assert_output_contains "copilot --config-dir $HOME/.copilot mcp get tilth"
}

@test ".copilot .sync fails when API keys are missing" {
    local mock_copilot_dir
    mock_copilot_dir=$(create_mock_copilot_dir)

    cat > "$TEST_HOME/mock-dotfiles/.env" << 'ENV'
CONTEXT7_API_KEY=context7-secret
ENV

    run bash "$mock_copilot_dir/.sync"
    assert_failure
    assert_output_contains "TAVILY_API_KEY is not set"
}
