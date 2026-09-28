#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export REGISTRY="$CZ_SRC/.chezmoidata/opencode.yaml"
    export SCRIPT="$CZ_SRC/dot_config/opencode/modify_opencode.json"
}

@test "opencode config renders from the authoritative registry" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]

    expected=$(yq -o=json '.opencode.config' "$REGISTRY" | jq -S .)
    actual=$(jq -S . <<<"$output")
    [ "$actual" = "$expected" ]
}

@test "opencode config resets managed drift and keeps unknown live keys with a warning" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"share":"auto","autoupdate":true,"model":"openai/gpt-6-sol"}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -r '.share' <<<"$output")" = "disabled" ]
    [ "$(jq -r '.autoupdate' <<<"$output")" = "false" ]
    [ "$(jq -r '.model' <<<"$output")" = "openai/gpt-6-sol" ]
    [[ "$stderr" == *"WARNING"*"model"* ]]
    grep -qx 'preserved model' "$DOTFILES_STATE_DIR/harness-drift/opencode-config"
}

@test "opencode config deletes the retired tools map" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"tools":{"read":false}}
JSON
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"WARNING"* ]]
    run jq -e '.tools' <<<"$output"
    [ "$status" -ne 0 ]
}

@test "opencode config rejects a corrupt live file" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<<'{bad'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a JSON object"* ]]
}

@test "opencode config wires tilth and the shared MCP servers" {
    local config
    config=$(yq -o=json '.opencode.config' "$REGISTRY")

    [ "$(jq -c '.mcp.tilth' <<<"$config")" = '{"type":"local","command":["tilth","--mcp","--edit"]}' ]
    [ "$(jq -r '.mcp.hallouminate.command[0]' <<<"$config")" = "hallouminate" ]
    [ "$(jq -r '.mcp.milknado.command[0]' <<<"$config")" = "uvx" ]
    [ "$(jq -r '.mcp.context7.command[0]' <<<"$config")" = "/usr/local/libexec/dotfiles/agent-secret-proxy" ]
    [ "$(jq -r '.mcp.tavily.command[0]' <<<"$config")" = "/usr/local/libexec/dotfiles/agent-secret-proxy" ]
    run jq -e '[.mcp[] | has("environment")] | any' <<<"$config"
    [ "$status" -ne 0 ]
}

@test "opencode config appends the preamble and enables LSP and formatters" {
    local config
    config=$(yq -o=json '.opencode.config' "$REGISTRY")

    [ "$(jq -c '.instructions' <<<"$config")" = '["~/.config/opencode/preamble.md"]' ]
    [ "$(jq -r '.lsp' <<<"$config")" = "true" ]
    [ "$(jq -r '.formatter' <<<"$config")" = "true" ]
    [ "$(jq -r '.autoupdate' <<<"$config")" = "false" ]
}

@test "opencode permissions deny secret paths and keep public companions" {
    local config
    config=$(yq -o=json '.opencode.config' "$REGISTRY")

    [ "$(jq -r '.permission["*"]' <<<"$config")" = "allow" ]
    [ "$(jq -r '.permission.read["*.env"]' <<<"$config")" = "deny" ]
    [ "$(jq -r '.permission.read["*.env.example"]' <<<"$config")" = "allow" ]
    [ "$(jq -r '.permission.read["*.pem"]' <<<"$config")" = "deny" ]
    [ "$(jq -r '.permission.read["~/.ssh/*"]' <<<"$config")" = "deny" ]
    [ "$(jq -r '.permission.read["~/.ssh/*.pub"]' <<<"$config")" = "allow" ]
    [ "$(jq -r '.permission.bash["sudo *"]' <<<"$config")" = "deny" ]
    # Last match wins: every allow exception must follow its deny.
    run jq -e '.permission.read | keys_unsorted | (index("*.env.example") > index("*.env.*")) and (index("~/.ssh/*.pub") > index("~/.ssh/*"))' <<<"$config"
    [ "$status" -eq 0 ]
}

@test "chezmoi deploys OpenCode config without replacing runtime state" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/chezmoi.toml"
    local destination="$TEST_HOME/home"
    mkdir -p "$destination/.config/opencode" "$destination/.local/share/opencode"
    printf 'runtime state\n' > "$destination/.local/share/opencode/auth.json"
    printf '{"dependencies":{}}\n' > "$destination/.config/opencode/package.json"
    cat > "$cfg" <<TOML
sourceDir = "$CZ_SRC"
destDir = "$destination"

[data]
email = "test@example.com"
work = false
localLLM = false
TOML

    run env HOME="$TEST_HOME" chezmoi --config "$cfg" --source "$CZ_SRC" apply --force --exclude=scripts
    [ "$status" -eq 0 ]
    [ "$(jq -S . "$destination/.config/opencode/opencode.json")" = "$(yq -o=json '.opencode.config' "$REGISTRY" | jq -S .)" ]
    cmp -s "$CZ_SRC/dot_config/opencode/tui.json" "$destination/.config/opencode/tui.json"
    cmp -s "$CZ_SRC/dot_config/opencode/themes/chocolate-donut.json" "$destination/.config/opencode/themes/chocolate-donut.json"
    [ "$(cat "$destination/.local/share/opencode/auth.json")" = "runtime state" ]
    [ -f "$destination/.config/opencode/package.json" ]
}

@test "opencode tui uses the chocolate-donut theme" {
    [ "$(jq -r '.theme' "$CZ_SRC/dot_config/opencode/tui.json")" = "chocolate-donut" ]
    # Every theme slot names a palette def, so a renamed def cannot dangle.
    run jq -e '(.defs | keys) as $defs | [.theme[] | strings | select(IN($defs[]) | not)] == []' \
        "$CZ_SRC/dot_config/opencode/themes/chocolate-donut.json"
    [ "$status" -eq 0 ]
}

@test "opencode CLI install is pinned through mise" {
    grep -Eq '^"aqua:anomalyco/opencode" = "v[0-9]+\.[0-9]+\.[0-9]+"$' "$CZ_SRC/dot_config/mise/config.toml"
}
