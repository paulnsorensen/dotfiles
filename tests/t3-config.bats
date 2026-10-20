#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

# The T3 guard (chezmoi/dot_t3/userdata/modify_settings.json) merges the
# registry keys from .chezmoidata/t3.yaml into the live T3 settings.json.
# T3 rewrites that file from its UI, so the guard must preserve UI state and
# only assert the provider-instance contract: drivers, wrapper binaryPaths,
# and the claudeAgent launchArgs.

teardown() { teardown_test_env; }

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export REGISTRY="$CZ_SRC/.chezmoidata/t3.yaml"
    export SCRIPT="$CZ_SRC/dot_t3/userdata/modify_settings.json"
}

@test "t3 registry forces an explicit permission mode and a settings file" {
    run yq -r '.t3.settings.providerInstances.claudeAgent.config.launchArgs' "$REGISTRY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--permission-mode auto"* ]]
    [[ "$output" == *"--settings \$HOME/.t3/userdata/claude-settings.json"* ]]
    [[ "$output" != *"bypassPermissions"* ]]
    [[ "$output" != *"dangerously-skip-permissions"* ]]
}

@test "t3 desktop package is one macOS cask with in-app updates" {
    run yq -o=json '.packages' "$REAL_DOTFILES_DIR/packages/packages.yaml"
    [ "$status" -eq 0 ]
    run jq -e '([.[] | objects | .["t3-code"]? | select(. != null)]) as $entries | ($entries | length) == 1 and $entries[0] == {"source":"cask","platform":"mac","greedy":false}' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "t3 claude-settings.json disables claude.ai connectors" {
    run jq -e '.disableClaudeAiConnectors == true' "$CZ_SRC/dot_t3/userdata/claude-settings.json"
    [ "$status" -eq 0 ]
}

@test "t3 settings render from the registry with HOME expanded" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" HOME=/home/tester sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    local rendered="$output"
    run jq -r '.providerInstances.claudeAgent.config.launchArgs' <<<"$rendered"
    [ "$output" = "--permission-mode auto --settings /home/tester/.t3/userdata/claude-settings.json" ]
    run jq -e 'has("providers") | not' <<<"$rendered"
    [ "$status" -eq 0 ]
}

@test "t3 provider instances launch the preamble wrappers" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" HOME=/home/tester sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    run jq -c '.providerInstances | [.claudeAgent, .codex, .opencode] | map([.driver, .config.binaryPath])' <<<"$output"
    local d="$REAL_DOTFILES_DIR"
    [ "$output" = '[["claudeAgent","'"$d"'/bin/dotsclaude"],["codex","'"$d"'/bin/dotscodex"],["opencode","'"$d"'/bin/dotsopencode"]]' ]
    for wrapper in dotsclaude dotscodex dotsopencode; do
        [ -x "$REAL_DOTFILES_DIR/bin/$wrapper" ]
    done
}

@test "t3 wrapper paths follow a clone outside ~/Dev" {
    local clone="$TEST_HOME/code/my dots"
    mkdir -p "$clone/chezmoi/lib" "$clone/chezmoi/.chezmoidata"
    # The script resolves the clone physically; macOS TMPDIR sits behind the
    # /var -> /private/var symlink, so compare against the physical path.
    clone="$(cd -P "$clone" && pwd)"
    cp "$REGISTRY" "$clone/chezmoi/.chezmoidata/t3.yaml"
    cp "$CZ_SRC"/lib/drift-gate.sh "$CZ_SRC"/lib/t3-settings-*.txt "$clone/chezmoi/lib/"
    run env CHEZMOI_SOURCE_DIR="$clone/chezmoi" HOME=/home/tester sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    run jq -r '.providerInstances | .claudeAgent, .codex, .opencode | .config.binaryPath' <<<"$output"
    [ "${lines[0]}" = "$clone/bin/dotsclaude" ]
    [ "${lines[1]}" = "$clone/bin/dotscodex" ]
    [ "${lines[2]}" = "$clone/bin/dotsopencode" ]
}

@test "t3 wrapper paths resolve a symlinked chezmoi source to the real clone" {
    local clone="$TEST_HOME/code/my dots"
    mkdir -p "$clone/chezmoi/lib" "$clone/chezmoi/.chezmoidata" "$TEST_HOME/share"
    cp "$REGISTRY" "$clone/chezmoi/.chezmoidata/t3.yaml"
    cp "$CZ_SRC"/lib/drift-gate.sh "$CZ_SRC"/lib/t3-settings-*.txt "$clone/chezmoi/lib/"
    ln -s "$clone/chezmoi" "$TEST_HOME/share/chezmoi"
    local real
    real=$(cd -P "$clone" && pwd)
    run env CHEZMOI_SOURCE_DIR="$TEST_HOME/share/chezmoi" HOME=/home/tester sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    run jq -r '.providerInstances.codex.config.binaryPath' <<<"$output"
    [ "$output" = "$real/bin/dotscodex" ]
}

@test "t3 settings preserve UI state and reset managed drift" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" HOME=/home/tester sh "$SCRIPT" <<'JSON'
{
  "projectSettingsFolded": true,
  "sidebarAutoSettleAfterDays": null,
  "defaultThreadEnvMode": "worktree",
  "providers": {
    "claudeAgent": { "launchArgs": "--dangerously-skip-permissions" }
  },
  "providerInstances": {
    "cursor": { "driver": "cursor", "enabled": false, "config": {} },
    "opencode": { "driver": "opencode", "enabled": true, "config": { "binaryPath": "/usr/bin/opencode", "serverUrl": "" } },
    "claudeAgent": { "driver": "claudeAgent", "enabled": true, "config": { "binaryPath": "/usr/bin/claude", "launchArgs": "--dangerously-skip-permissions", "customModels": [] } }
  }
}
JSON
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    local rendered="$output"
    run jq -c '[.projectSettingsFolded, .sidebarAutoSettleAfterDays, .defaultThreadEnvMode, .providerInstances.cursor.enabled, .providerInstances.claudeAgent.enabled, .providerInstances.opencode.config.serverUrl, .providerInstances.claudeAgent.config.customModels]' <<<"$rendered"
    [ "$output" = '[true,null,"worktree",false,true,"",[]]' ]
    run jq -r '.providerInstances.claudeAgent.config.launchArgs, .providerInstances.claudeAgent.config.binaryPath, .providerInstances.opencode.config.binaryPath' <<<"$rendered"
    [ "${lines[0]}" = "--permission-mode auto --settings /home/tester/.t3/userdata/claude-settings.json" ]
    [ "${lines[1]}" = "$REAL_DOTFILES_DIR/bin/dotsclaude" ]
    [ "${lines[2]}" = "$REAL_DOTFILES_DIR/bin/dotsopencode" ]
    run jq -e 'has("providers") | not' <<<"$rendered"
    [ "$status" -eq 0 ]
}

@test "t3 settings keep unknown live keys with a warning" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"futureSetting": 1}
JSON
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"futureSetting"* ]]
    [[ "$stderr" == *"$REGISTRY"* ]]
    run jq -r '.futureSetting' <<<"$output"
    [ "$output" = "1" ]
}

@test "t3 settings reject a corrupt live file" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<<'[1,2,3]'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a JSON object"* ]]
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<<'{bad'
    [ "$status" -eq 1 ]
}

@test "t3 settings delete a retired key from live before the gate runs" {
    local tmpsrc="$TEST_HOME/cz-src"
    mkdir -p "$tmpsrc/lib" "$tmpsrc/.chezmoidata"
    cp "$REGISTRY" "$tmpsrc/.chezmoidata/t3.yaml"
    cp "$CZ_SRC/lib/drift-gate.sh" "$tmpsrc/lib/drift-gate.sh"
    cp "$CZ_SRC/lib/t3-settings-ignore.txt" "$tmpsrc/lib/t3-settings-ignore.txt"
    printf 'oldKey\n' > "$tmpsrc/lib/t3-settings-retired.txt"
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$tmpsrc" sh "$SCRIPT" <<'JSON'
{"oldKey": "gone", "projectSettingsFolded": true}
JSON
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    run jq -e 'has("oldKey") | not' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "chezmoi deploys T3 settings without replacing runtime state" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/chezmoi.toml"
    local destination="$TEST_HOME/home"
    mkdir -p "$destination/.t3/userdata"
    printf 'runtime state\n' > "$destination/.t3/userdata/state.sqlite"
    printf '{"defaultThreadEnvMode":"worktree","providerInstances":{"cursor":{"driver":"cursor","enabled":false,"config":{}}}}\n' > "$destination/.t3/userdata/settings.json"
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
    [ "$(cat "$destination/.t3/userdata/state.sqlite")" = "runtime state" ]
    cmp -s "$CZ_SRC/dot_t3/userdata/claude-settings.json" "$destination/.t3/userdata/claude-settings.json"
    run jq -r '.defaultThreadEnvMode, .providerInstances.cursor.enabled, .providerInstances.claudeAgent.config.launchArgs' "$destination/.t3/userdata/settings.json"
    [ "${lines[0]}" = "worktree" ]
    [ "${lines[1]}" = "false" ]
    [ "${lines[2]}" = "--permission-mode auto --settings $destination/.t3/userdata/claude-settings.json" ]
}
