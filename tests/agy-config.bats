#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export REGISTRY="$CZ_SRC/.chezmoidata/agy.yaml"
    export SETTINGS_SCRIPT="$CZ_SRC/dot_gemini/antigravity-cli/modify_private_settings.json"
    export MCP_SCRIPT="$CZ_SRC/dot_gemini/config/modify_private_mcp_config.json"
    export SKILLS_MANIFEST="$CZ_SRC/dot_gemini/config/skills.json"
    export RECONCILE_LIB="$CZ_SRC/lib/agy-plugin-reconcile.sh"
}

teardown() { teardown_test_env; }

@test "agy settings render from the authoritative registry with HOME expanded" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" HOME=/home/tester sh "$SETTINGS_SCRIPT" </dev/null
    [ "$status" -eq 0 ]

    expected=$(yq -o=json '.agy.settings' "$REGISTRY" \
        | jq --arg home /home/tester -S 'walk(if type == "string" then gsub("\\$\\{HOME\\}"; $home) else . end)')
    actual=$(jq -S . <<<"$output")
    [ "$actual" = "$expected" ]
    [ "$(jq -r '.agentMode' <<<"$output")" = "auto" ]
    [ "$(jq -r '.enableTerminalSandbox' <<<"$output")" = "true" ]
    [ "$(jq -r '.toolPermission' <<<"$output")" = "proceed-in-sandbox" ]
    [ "$(jq -r '.editorMode' <<<"$output")" = "vim" ]
    run jq -e '.permissions.deny | index("read_file(/home/tester/.aws/credentials)") != null' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "agy settings preserve ignore-listed runtime keys and reset managed drift" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" HOME=/home/tester sh "$SETTINGS_SCRIPT" <<'JSON'
{"agentMode":"default","editorMode":"default","trustedWorkspaces":["/home/tester/Dev"],"model":"Gemini 4 Neon (High)"}
JSON
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"WARNING"* ]]
    [ "$(jq -r '.agentMode' <<<"$output")" = "auto" ]
    [ "$(jq -r '.editorMode' <<<"$output")" = "vim" ]
    [ "$(jq -r '.trustedWorkspaces[0]' <<<"$output")" = "/home/tester/Dev" ]
    [ "$(jq -r '.model' <<<"$output")" = "Gemini 4 Neon (High)" ]
}

@test "agy settings keep unknown live keys with a warning and clear drift when clean" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SETTINGS_SCRIPT" <<'JSON'
{"agentMode":"default","futureSetting":true}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -r '.futureSetting' <<<"$output")" = "true" ]
    [ "$(jq -r '.agentMode' <<<"$output")" = "auto" ]
    [[ "$stderr" == *"WARNING"*"futureSetting"* ]]
    [[ "$stderr" == *"$REGISTRY"* ]]
    grep -qx 'preserved futureSetting' "$DOTFILES_STATE_DIR/harness-drift/agy-settings"

    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SETTINGS_SCRIPT" <<'JSON'
{"trustedWorkspaces":["/tmp"]}
JSON
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"WARNING"* ]]
    [ ! -e "$DOTFILES_STATE_DIR/harness-drift/agy-settings" ]
}

@test "agy settings delete retired keys before the drift gate runs" {
    local tmpsrc="$TEST_HOME/agy-retired"
    mkdir -p "$tmpsrc/lib" "$tmpsrc/.chezmoidata"
    cp "$REGISTRY" "$tmpsrc/.chezmoidata/agy.yaml"
    cp "$CZ_SRC/lib/drift-gate.sh" "$tmpsrc/lib/drift-gate.sh"
    cp "$CZ_SRC/lib/agy-settings-ignore.txt" "$tmpsrc/lib/agy-settings-ignore.txt"
    printf 'retiredKey\n' > "$tmpsrc/lib/agy-settings-retired.txt"

    run --separate-stderr env CHEZMOI_SOURCE_DIR="$tmpsrc" sh "$SETTINGS_SCRIPT" <<'JSON'
{"agentMode":"auto","retiredKey":"old"}
JSON
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"WARNING"* ]]
    run jq -e 'has("retiredKey") | not' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "agy settings reject corrupt live JSON" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SETTINGS_SCRIPT" <<<'[1,2,3]'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a JSON object"* ]]
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SETTINGS_SCRIPT" <<<'{bad'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a JSON object"* ]]
}

@test "agy mcp_config renders from the registry, handles empty live files, and evicts retired servers" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$MCP_SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [ "$(jq -r '.mcpServers.tilth.command' <<<"$output")" = "tilth" ]
    [ "$(jq -c '.mcpServers.tilth.args' <<<"$output")" = '["--mcp","--edit"]' ]
    [ "$(jq -r '.mcpServers.context7.command' <<<"$output")" = "/usr/local/libexec/dotfiles/agent-secret-proxy" ]
    [ "$(jq -r '.mcpServers.tavily.command' <<<"$output")" = "/usr/local/libexec/dotfiles/agent-secret-proxy" ]
    [ "$(jq -r '.mcpServers.hallouminate.command' <<<"$output")" = "hallouminate" ]
    run jq -e '.mcpServers | has("milknado") | not' <<<"$output"
    [ "$status" -eq 0 ]
    run jq -e '[.mcpServers | .. | objects | has("env")] | any' <<<"$output"
    [ "$status" -ne 0 ]

    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$MCP_SCRIPT" <<'JSON'
{"mcpServers":{"stale":{"command":"old"}},"extraKey":"kept"}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -r '.extraKey' <<<"$output")" = "kept" ]
    run jq -e '.mcpServers | has("stale") | not' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "agy mcp_config rejects corrupt live JSON" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$MCP_SCRIPT" <<<'{bad'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a JSON object"* ]]
}

@test "agy skills manifest points at the shared ~/.agents/skills cache" {
    [ -f "$SKILLS_MANIFEST" ]
    # shellcheck disable=SC2088
    [ "$(jq -r '.entries[0].path' "$SKILLS_MANIFEST")" = '~/.agents/skills' ]
    [ ! -e "$CZ_SRC/dot_gemini/config/exact_skills" ]
    [ ! -e "$CZ_SRC/dot_gemini/config/skills" ]
}

@test "agy plugin reconciler installs missing plugins, skips existing, and prunes only manifest-owned ones" {
    local mock_bin="$TEST_HOME/bin"
    local log="$TEST_HOME/agy-calls.log"
    local manifest="$TEST_HOME/.gemini/config/.chezmoi-plugin-manifest"
    mkdir -p "$mock_bin" "$(dirname "$manifest")"
    printf 'retired-plugin\nmilknado\n' > "$manifest"

    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    cat <<'JSON'
[{"name":"milknado"},{"name":"retired-plugin"},{"name":"swarm"},{"name":"hand-installed"}]
JSON
    exit 0
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    local desired
    desired=$(printf 'milknado\thttps://github.com/paulnsorensen/milknado\nhallouminate\thttps://github.com/paulnsorensen/hallouminate\n')

    # shellcheck disable=SC2016
    run env PATH="$mock_bin:$PATH" bash -c 'source "$1"; agy_plugin_reconcile "$2" "$3"' \
        _ "$RECONCILE_LIB" "$desired" "$manifest"
    [ "$status" -eq 0 ]

    # milknado was already installed; only hallouminate installs.
    grep -qx 'plugin install https://github.com/paulnsorensen/hallouminate' "$log"
    ! grep -q 'plugin install https://github.com/paulnsorensen/milknado' "$log"
    # Only manifest-owned retired-plugin uninstalls; swarm and hand-installed stay.
    grep -qx 'plugin uninstall retired-plugin' "$log"
    ! grep -q 'plugin uninstall swarm' "$log"
    ! grep -q 'plugin uninstall hand-installed' "$log"
    [ "$(cat "$manifest")" = "$(printf 'hallouminate\nmilknado')" ]
}

@test "agy plugin reconciler skips prune and leaves manifest intact when an install fails" {
    local mock_bin="$TEST_HOME/bin"
    local log="$TEST_HOME/agy-calls.log"
    local manifest="$TEST_HOME/.gemini/config/.chezmoi-plugin-manifest"
    mkdir -p "$mock_bin" "$(dirname "$manifest")"
    printf 'retired-plugin\n' > "$manifest"

    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    printf '[{"name":"retired-plugin"}]\n'
    exit 0
fi
if [[ "\$1" == "plugin" && "\$2" == "install" ]]; then
    exit 1
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    local desired
    desired=$(printf 'milknado\thttps://github.com/paulnsorensen/milknado\n')

    # shellcheck disable=SC2016
    run env PATH="$mock_bin:$PATH" bash -c 'source "$1"; agy_plugin_reconcile "$2" "$3"' \
        _ "$RECONCILE_LIB" "$desired" "$manifest"
    [ "$status" -ne 0 ]
    ! grep -q 'plugin uninstall' "$log"
    [ "$(cat "$manifest")" = "retired-plugin" ]
}

@test "agy plugin reconciler warns and returns 0 when agy CLI is missing" {
    local empty_bin="$TEST_HOME/empty-bin"
    mkdir -p "$empty_bin"
    # Keep jq reachable without agy.
    ln -s "$(command -v jq)" "$empty_bin/jq"

    # shellcheck disable=SC2016
    run --separate-stderr bash -c 'PATH="$1"; source "$2"; agy_plugin_reconcile "" "$3"' \
        _ "$empty_bin" "$RECONCILE_LIB" "$TEST_HOME/manifest"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"agy CLI not found"* ]]
}

@test "chezmoi deploys Antigravity config without replacing runtime state" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/chezmoi.toml"
    local destination="$TEST_HOME/home"
    mkdir -p "$destination/.gemini/antigravity-cli" "$destination/.gemini/config"
    printf 'oauth token\n' > "$destination/.gemini/antigravity-cli/antigravity-oauth-token"
    printf '{"trustedWorkspaces":["/work"]}\n' > "$destination/.gemini/antigravity-cli/settings.json"
    printf '{"plugins":{"swarm":{"enabled":true}}}\n' > "$destination/.gemini/config/config.json"
    : > "$destination/.gemini/config/mcp_config.json"

    cat > "$cfg" <<TOML
sourceDir = "$CZ_SRC"
destDir = "$destination"

[data]
email = "test@example.com"
work = false
localLLM = false
TOML

    run env HOME="$destination" chezmoi --config "$cfg" --source "$CZ_SRC" apply --force --exclude=scripts
    [ "$status" -eq 0 ]
    [ "$(cat "$destination/.gemini/antigravity-cli/antigravity-oauth-token")" = "oauth token" ]
    [ "$(jq -r '.plugins.swarm.enabled' "$destination/.gemini/config/config.json")" = "true" ]
    [ "$(jq -r '.agentMode' "$destination/.gemini/antigravity-cli/settings.json")" = "auto" ]
    [ "$(jq -r '.trustedWorkspaces[0]' "$destination/.gemini/antigravity-cli/settings.json")" = "/work" ]
    [ "$(jq -r '.mcpServers.tilth.command' "$destination/.gemini/config/mcp_config.json")" = "tilth" ]
    # shellcheck disable=SC2088
    [ "$(jq -r '.entries[0].path' "$destination/.gemini/config/skills.json")" = '~/.agents/skills' ]
}
