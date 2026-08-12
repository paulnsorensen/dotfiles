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


@test "pi settings: fresh render matches the authoritative registry" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]

    expected=$(yq -o=json '.pi.settings' "$REGISTRY" | jq -S .)
    actual=$(jq -S . <<<"$output")
    [ "$actual" = "$expected" ]
}

@test "pi settings: managed drift is reset while changelog state survives" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{
  "theme": "dark",
  "defaultThinkingLevel": "off",
  "lastChangelogVersion": "0.84.1"
}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -r '.theme' <<<"$output")" = "chocolate-donut" ]
    [ "$(jq -r '.defaultThinkingLevel' <<<"$output")" = "medium" ]
    [ "$(jq -r '.lastChangelogVersion' <<<"$output")" = "0.84.1" ]
}

@test "pi settings: unknown live keys fail without emitting replacement config" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{
  "theme": "chocolate-donut",
  "futureSetting": true
}
JSON
    [ "$status" -eq 1 ]
    [[ "$output" == *"futureSetting"* ]]
    [[ "$output" == *"Fold each into the registry"* ]]
}

@test "pi config: chezmoi deploys the complete global sibling and retires old harness trees" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    cfg="$TEST_HOME/chezmoi.toml"
    destination="$TEST_HOME/home"
    mkdir -p "$destination/.config/opencode" "$destination/.config/crush" "$destination/.opencode"
    touch "$destination/.config/opencode/stale" "$destination/.config/crush/stale" "$destination/.opencode/stale"
    mkdir -p "$destination/.pi/agent/extensions"
    echo "user managed" > "$destination/.pi/agent/extensions/superset-hooks.ts"
    cat >"$cfg" <<TOML
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
    [ -f "$destination/.pi/agent/models.json" ]
    [ -f "$destination/.pi/agent/mcp.json" ]
    [ -f "$destination/.pi/agent/APPEND_SYSTEM.md" ]
    [ -f "$destination/.pi/agent/extensions/rtk.ts" ]
    [ -f "$destination/.pi/agent/extensions/cheese-flair.ts" ]
    [ "$(cat "$destination/.pi/agent/extensions/superset-hooks.ts")" = "user managed" ]
    [ -f "$destination/.pi/agent/themes/chocolate-donut.json" ]
    [ -f "$destination/.pi/agent/skills/cook/SKILL.md" ]
    [ ! -e "$destination/.config/opencode" ]
    [ ! -e "$destination/.opencode" ]
    [ ! -e "$destination/.config/crush" ]

    packages=$(jq -c '.packages' "$destination/.pi/agent/settings.json")
    [ "$packages" = '["npm:pi-mcp-adapter@2.23.0","npm:pi-subagents@0.46.0"]' ]
    [ "$(jq -r '.mcpServers.tilth.command' "$destination/.pi/agent/mcp.json")" = "tilth" ]
    [ "$(jq -r '.mcpServers.hallouminate.args[0]' "$destination/.pi/agent/mcp.json")" = "serve" ]
}

@test "pi install: package registry pins the CLI and passes the safe npm flag" {
    [ "$(yq -r '.packages[] | select(has("pi")) | .pi.pkg' "$REAL_DOTFILES_DIR/packages/packages.yaml")" = "@earendil-works/pi-coding-agent" ]
    [ "$(yq -r '.packages[] | select(has("pi")) | .pi.version' "$REAL_DOTFILES_DIR/packages/packages.yaml")" = "0.84.1" ]
    [ "$(yq -o=json -I=0 '.packages[] | select(has("pi")) | .pi.flags' "$REAL_DOTFILES_DIR/packages/packages.yaml")" = '["--ignore-scripts"]' ]
}
