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

    expected=$(yq -o=json '.opencode.config | del(.agent)' "$REGISTRY" | jq -S .)
    actual=$(jq -S 'del(.agent)' <<<"$output")
    [ "$actual" = "$expected" ]
    [ "$(jq '.agent | length' <<<"$output")" -eq 18 ]
}

@test "opencode config resets managed drift and keeps unknown live keys with a warning" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"model":"openai/gpt-6-sol","share":"auto","autoupdate":true,"runtime_key":"kept"}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -r '.model' <<<"$output")" = "openai/gpt-6.1-sol" ]
    [ "$(jq -r '.share' <<<"$output")" = "disabled" ]
    [ "$(jq -r '.autoupdate' <<<"$output")" = "false" ]
    [ "$(jq -r '.runtime_key' <<<"$output")" = "kept" ]
    [[ "$stderr" == *"WARNING"*"runtime_key"* ]]
    grep -qx 'preserved runtime_key' "$DOTFILES_STATE_DIR/harness-drift/opencode-config"
}

@test "opencode config deletes retired v1 keys" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"tools":{"read":false},"lsp":true,"compaction":{"auto":true,"prune":true},"permission":{"doom_loop":"ask"},"mcp":{"tilth":{"type":"local","command":["tilth"]}}}
JSON
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"WARNING"* ]]
    jq -e 'has("tools") or has("lsp") or (.compaction | has("prune")) or (.permission | has("doom_loop")) or (.mcp | has("tilth")) | not' <<<"$output"
    [ "$(jq -r '.compaction.auto' <<<"$output")" = "true" ]
    [ "$(jq -r '.mcp.servers.tilth.codemode' <<<"$output")" = "false" ]
}

@test "opencode config removes the retired checker from live state" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"agent":{"wheypoint-check":{"model":"openai/gpt-6-luna"},"unknown":{"model":"kept"}}}
JSON
    [ "$status" -eq 0 ]
    jq -e '.agent["wheypoint-check"] == null and .agent.unknown.model == "kept"' <<<"$output"
    [[ "$stderr" != *"wheypoint-check"* ]]
}

@test "opencode config replaces the complete live MCP subtree" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"mcp":{"todoist":{"enabled":true},"code-review-graph":{"enabled":true},"serena":{"enabled":true},"extra":{},"context7":{"environment":{"TOKEN":"synthetic"}},"servers":{"serena":{"enabled":true},"extra":{},"tilth":{"codemode":true,"stale":"removed"}}}}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -S '.mcp' <<<"$output")" = "$(yq -o=json '.opencode.config.mcp' "$REGISTRY" | jq -S .)" ]
    [ "$stderr" = "" ]
}

@test "home opencode config removes MCP overrides and preserves unrelated settings" {
    local script="$CZ_SRC/modify_opencode.json.tmpl"
    local live='{"model":"kept","custom":{"nested":[1,false,null]},"mcp":{"todoist":{},"code-review-graph":{},"serena":{},"servers":{"serena":{}}}}'
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$script" <<<"$live"
    [ "$status" -eq 0 ]
    local cleaned="$output"
    [ "$(jq -S . <<<"$cleaned")" = "$(jq -S 'del(.mcp)' <<<"$live")" ]
    [ "$stderr" = "" ]
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$script" <<<"$cleaned"
    [ "$status" -eq 0 ]
    [ "$output" = "$cleaned" ]
}

@test "home opencode config handles missing input and rejects invalid documents" {
    local script="$CZ_SRC/modify_opencode.json.tmpl"
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$script" </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
    local live
    for live in '{bad' '[]' 'null' '{} {}' '   '; do
        run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$script" <<<"$live"
        [ "$status" -eq 1 ]
        [ "$output" = "" ]
        [ "$stderr" = "OpenCode config is not a JSON object" ]
    done
}

@test "opencode config rejects a corrupt live file" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<<'{bad'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a JSON object"* ]]
}

@test "opencode config wires tilth and the shared MCP servers" {
    local config
    config=$(yq -o=json '.opencode.config' "$REGISTRY")

    [ "$(jq -c '.mcp.servers.tilth' <<<"$config")" = '{"type":"local","command":["tilth","--mcp","--edit"],"codemode":false}' ]
    [ "$(jq -r '.mcp.tilth' <<<"$config")" = "null" ]
    [ "$(jq -r '.mcp.hallouminate.command[0]' <<<"$config")" = "hallouminate" ]
    [ "$(jq -r '.mcp.milknado.command[0]' <<<"$config")" = "uvx" ]
    [ "$(jq -r '.mcp.context7.command[0]' <<<"$config")" = "/usr/local/libexec/dotfiles/agent-secret-proxy" ]
    [ "$(jq -r '.mcp.tavily.command[0]' <<<"$config")" = "/usr/local/libexec/dotfiles/agent-secret-proxy" ]
    run jq -e '[.mcp | .. | objects | has("environment")] | any' <<<"$config"
    [ "$status" -ne 0 ]
}

# Runs OpenCode against the sandboxed home. `debug config` starts a background
# service, so callers set a private port and stop the service afterwards.
opencode_in_test_home() {
    (cd "$TEST_HOME" && HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_HOME/.config" timeout 120 opencode "$@")
}

@test "OpenCode v2 keeps Tilth out of Code Mode after it normalizes the config" {
    command -v opencode >/dev/null 2>&1 || skip "opencode not installed"
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    [[ "$(opencode --version 2>/dev/null)" == *"v2."* ]] || skip "opencode v2 not installed"
    mkdir -p "$TEST_HOME/.config/opencode"
    env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null > "$TEST_HOME/.config/opencode/opencode.json"
    local port
    port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    opencode_in_test_home service set port "$port"

    run --separate-stderr opencode_in_test_home debug config
    local config_status=$status config_output=$output
    opencode_in_test_home service stop >/dev/null 2>&1 || true
    [ "$config_status" -eq 0 ]
    jq -e '[.[] | select(.type == "document") | .info.mcp.servers.tilth.codemode] == [false]' <<<"$config_output"
}

@test "opencode config appends the preamble and enables formatters without v1 LSP" {
    local config
    config=$(yq -o=json '.opencode.config' "$REGISTRY")

    [ "$(jq -c '.instructions' <<<"$config")" = '["~/.config/opencode/preamble.md"]' ]
    [ "$(jq -r '.lsp' <<<"$config")" = "null" ]
    [ "$(jq -r '.formatter' <<<"$config")" = "true" ]
    [ "$(jq -r '.autoupdate' <<<"$config")" = "false" ]
}

@test "native agents use the shared execution preamble instead of provider prompts" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    jq -e '
        .instructions == ["~/.config/opencode/preamble.md"] and
        ([.agent.build,.agent.plan,.agent.general,.agent.explore] | all(.prompt | type == "string" and length > 0 and contains("shared execution preamble"))) and
        (.agent.plan.prompt | contains("Plan only. Do not change workspace files.")) and
        (.agent.explore.prompt | contains("Read only. Do not change files."))
    ' <<<"$output"
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
    printf '{"theme":"opencode"}\n' > "$destination/.config/opencode/tui.json"
    printf '%s\n' '{"model":"kept","custom":{"nested":[1,false]},"mcp":{"todoist":{},"code-review-graph":{},"serena":{}}}' > "$destination/opencode.json"
    printf '%s\n' '{"mcp":{"servers":{"extra":{},"tilth":{"stale":"removed"}}}}' > "$destination/.config/opencode/opencode.json"
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
    [ "$(jq -S 'del(.agent)' "$destination/.config/opencode/opencode.json")" = "$(yq -o=json '.opencode.config | del(.agent)' "$REGISTRY" | jq -S .)" ]
    [ "$(jq '.agent | length' "$destination/.config/opencode/opencode.json")" -eq 18 ]
    [ "$(jq -cS . "$destination/opencode.json")" = '{"custom":{"nested":[1,false]},"model":"kept"}' ]
    cmp -s "$CZ_SRC/dot_config/opencode/cli.json" "$destination/.config/opencode/cli.json"
    [ ! -e "$destination/.config/opencode/tui.json" ]
    cmp -s "$CZ_SRC/dot_config/opencode/themes/chocolate-donut.json" "$destination/.config/opencode/themes/chocolate-donut.json"
    cmp -s "$CZ_SRC/dot_config/opencode/themes/chocolate-donut-2.json" "$destination/.config/opencode/themes/chocolate-donut-2.json"
    cmp -s "$REAL_DOTFILES_DIR/agents/lib/wheypoint-stop-gate.cjs" "$destination/.config/opencode/lib/wheypoint-stop-gate.cjs"
    run node --input-type=module -e 'import { pathToFileURL } from "node:url"; const module = await import(pathToFileURL(process.argv[1])); if (module.default.id !== "dotfiles.wheypoint-idle") process.exit(1)' "$destination/.config/opencode/plugins/wheypoint-idle.js"
    [ "$status" -eq 0 ]
    [ "$(cat "$destination/.local/share/opencode/auth.json")" = "runtime state" ]
    [ -f "$destination/.config/opencode/package.json" ]
}

@test "opencode cli config uses the chocolate-donut-2 theme and v2 keybind" {
    [ "$(jq -r '."$schema"' "$CZ_SRC/dot_config/opencode/cli.json")" = "https://opencode.ai/v2/cli.json" ]
    [ "$(jq -r '.theme.name' "$CZ_SRC/dot_config/opencode/cli.json")" = "chocolate-donut-2" ]
    [ "$(jq -r '.keybinds["prompt.editor"]' "$CZ_SRC/dot_config/opencode/cli.json")" = "ctrl+o" ]
    # Every theme slot names a palette def, so a renamed def cannot dangle.
    run jq -e '(.defs | keys) as $defs | [.theme[] | strings | select(IN($defs[]) | not)] == []' \
        "$CZ_SRC/dot_config/opencode/themes/chocolate-donut-2.json"
    [ "$status" -eq 0 ]
    # The theme mirrors the base24 scheme background and foreground.
    [ "$(jq -r '.defs.bg' "$CZ_SRC/dot_config/opencode/themes/chocolate-donut-2.json")" = "#$(yq -r '.palette.base00' "$REAL_DOTFILES_DIR/theme/schemes/chocolate-donut-2.yaml")" ]
    [ "$(jq -r '.defs.fg' "$CZ_SRC/dot_config/opencode/themes/chocolate-donut-2.json")" = "#$(yq -r '.palette.base05' "$REAL_DOTFILES_DIR/theme/schemes/chocolate-donut-2.yaml")" ]
}

@test "opencode CLI install is pinned through the mise npm backend" {
    grep -Eq '^"npm:@opencode/cli" = \{ version = "[0-9]+\.[0-9]+\.[0-9]+", allow_builds = \["@opencode/cli"\] \}$' "$CZ_SRC/dot_config/mise/config.toml"
    run grep -F 'aqua:anomalyco/opencode' "$CZ_SRC/dot_config/mise/config.toml"
    [ "$status" -ne 0 ]
}
