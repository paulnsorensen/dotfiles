#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export REGISTRY="$CZ_SRC/.chezmoidata/pi.yaml"
    export SCRIPT="$CZ_SRC/dot_pi/private_agent/modify_settings.json"
}

@test "pi settings render from the authoritative registry" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]

    expected=$(yq -o=json '.pi.settings' "$REGISTRY" | jq -S .)
    actual=$(jq -S . <<<"$output")
    [ "$actual" = "$expected" ]
}

@test "pi settings preserve changelog state and reset managed drift" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"theme":"dark","defaultThinkingLevel":"off","lastChangelogVersion":"0.86.0"}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -r '.theme' <<<"$output")" = "chocolate-donut" ]
    [ "$(jq -r '.defaultThinkingLevel' <<<"$output")" = "medium" ]
    [ "$(jq -r '.lastChangelogVersion' <<<"$output")" = "0.86.0" ]
}

@test "pi settings reject unknown live keys" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"theme":"chocolate-donut","futureSetting":true}
JSON
    [ "$status" -eq 1 ]
    [[ "$output" == *"futureSetting"* ]]
}

@test "pi registry pins the selected mainstream packages" {
    run yq -o=json -I=0 '.pi.settings.packages' "$REGISTRY"
    [ "$status" -eq 0 ]
    [ "$output" = '["npm:pi-mcp-adapter@2.37.0","npm:pi-subagents@0.70.1","npm:pi-web-access@0.30.0","npm:@gotgenes/pi-permission-system@33.0.8","npm:pi-vim@0.14.2"]' ]
}

@test "pi uses shared agent skills instead of a copied skill tree" {
    [ ! -e "$CZ_SRC/dot_pi/private_agent/exact_skills" ]
    [ ! -e "$CZ_SRC/dot_pi/private_agent/skills" ]
}

@test "pi native config exposes MCP and protects sensitive paths" {
    local mcp="$CZ_SRC/dot_pi/private_agent/mcp.json"
    local permissions="$CZ_SRC/dot_pi/private_agent/extensions/pi-permission-system/config.json"

    [ "$(jq -r '.mcpServers.tilth.command' "$mcp")" = "tilth" ]
    [ "$(jq -r '.mcpServers.hallouminate.command' "$mcp")" = "hallouminate" ]
    [ "$(jq -r '.yoloMode' "$permissions")" = "true" ]
    [ "$(jq -r '.permission.tilth_write' "$permissions")" = "allow" ]
    [ "$(jq -r '.permission.path["*.env"]' "$permissions")" = "deny" ]
    [ "$(jq -r '.permission.path["*.env.example"]' "$permissions")" = "allow" ]
    [ "$(jq -r '.permission.path["~/.ssh/*"]' "$permissions")" = "deny" ]
}

@test "chezmoi deploys Pi config without replacing runtime state" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/chezmoi.toml"
    local destination="$TEST_HOME/home"
    mkdir -p "$destination/.pi/agent"
    printf 'runtime state\n' > "$destination/.pi/agent/auth.json"
    printf '{"providers":{"local-llm":{}}}\n' > "$destination/.pi/agent/models.json"
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
    [ -f "$destination/.pi/agent/settings.json" ]
    run find "$destination/.pi/agent" -name models.json -print
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$destination/.pi/agent/mcp.json" ]
    [ -f "$destination/.pi/agent/APPEND_SYSTEM.md" ]
    [ -f "$destination/.pi/agent/themes/chocolate-donut.json" ]
    [ -f "$destination/.pi/agent/extensions/cheese-flair.ts" ]
    [ "$(cat "$destination/.pi/agent/auth.json")" = "runtime state" ]
    [ "$(jq -S . "$destination/.pi/agent/settings.json")" = "$(yq -o=json '.pi.settings' "$REGISTRY" | jq -S .)" ]
    cmp -s "$CZ_SRC/dot_pi/private_agent/mcp.json" "$destination/.pi/agent/mcp.json"
    cmp -s "$CZ_SRC/dot_pi/private_agent/APPEND_SYSTEM.md" "$destination/.pi/agent/APPEND_SYSTEM.md"
    cmp -s "$CZ_SRC/dot_pi/private_agent/themes/chocolate-donut.json" "$destination/.pi/agent/themes/chocolate-donut.json"
    cmp -s "$CZ_SRC/dot_pi/private_agent/extensions/cheese-flair.ts" "$destination/.pi/agent/extensions/cheese-flair.ts"
    cmp -s "$CZ_SRC/dot_pi/private_agent/extensions/pi-permission-system/config.json" "$destination/.pi/agent/extensions/pi-permission-system/config.json"
}

@test "pi CLI install is pinned and lifecycle scripts are disabled" {
    [ "$(yq -r '.packages[] | select(has("pi")) | .pi.pkg' "$REAL_DOTFILES_DIR/packages/packages.yaml")" = "@earendil-works/pi-coding-agent" ]
    [ "$(yq -r '.packages[] | select(has("pi")) | .pi.version' "$REAL_DOTFILES_DIR/packages/packages.yaml")" = "0.87.1" ]
    [ "$(yq -o=json -I=0 '.packages[] | select(has("pi")) | .pi.flags' "$REAL_DOTFILES_DIR/packages/packages.yaml")" = '["--ignore-scripts"]' ]
}
