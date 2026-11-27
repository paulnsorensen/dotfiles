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
    export SKILLS_TEMPLATE="$CZ_SRC/dot_gemini/config/skills.json.tmpl"
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

@test "agy settings report live permission entries that the registry render drops" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" HOME=/home/tester sh "$SETTINGS_SCRIPT" <<'JSON'
{"permissions":{"allow":["command(make)"]}}
JSON
    [ "$status" -eq 0 ]
    local err="$stderr"
    run jq -e '.permissions.allow | index("command(make)") == null' <<<"$output"
    [ "$status" -eq 0 ]
    [[ "$err" == *"WARNING"*'permissions.allow[command(make)]'* ]]
    grep -qF 'dropped permissions.allow[command(make)]' "$DOTFILES_STATE_DIR/harness-drift/agy-settings"
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
    local rendered="$output"
    run jq -e '.mcpServers | has("milknado") | not' <<<"$rendered"
    [ "$status" -eq 0 ]
    run jq -e '[.mcpServers | .. | objects | has("env")] | any | not' <<<"$rendered"
    [ "$status" -eq 0 ]

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

@test "agy skills manifest renders an absolute path to the shared .agents/skills cache" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    [ -f "$SKILLS_TEMPLATE" ]
    [ ! -e "$CZ_SRC/dot_gemini/config/skills.json" ]
    run chezmoi execute-template --source "$CZ_SRC" < "$SKILLS_TEMPLATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.entries[0].path' <<<"$output")" = "$HOME/.agents/skills" ]
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
    run ! grep -q 'plugin install https://github.com/paulnsorensen/milknado' "$log"
    # Only manifest-owned retired-plugin uninstalls; swarm and hand-installed stay.
    grep -qx 'plugin uninstall retired-plugin' "$log"
    run ! grep -q 'plugin uninstall swarm' "$log"
    run ! grep -q 'plugin uninstall hand-installed' "$log"
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
    run ! grep -q 'plugin uninstall' "$log"
    [ "$(cat "$manifest")" = "retired-plugin" ]
}

@test "agy plugin reconciler never adopts a pre-existing plugin and keeps successful installs after a failure" {
    local mock_bin="$TEST_HOME/bin"
    local log="$TEST_HOME/agy-calls.log"
    local manifest="$TEST_HOME/.gemini/config/.chezmoi-plugin-manifest"
    mkdir -p "$mock_bin" "$(dirname "$manifest")"
    printf 'retired-plugin\n' > "$manifest"

    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    printf '[{"name":"retired-plugin"},{"name":"by-hand"}]\n'
    exit 0
fi
if [[ "\$1" == "plugin" && "\$2" == "install" && "\$3" == *broken ]]; then
    exit 1
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    local desired
    desired=$(printf 'by-hand\thttps://example.test/by-hand\nfresh\thttps://example.test/fresh\nbroken\thttps://example.test/broken\n')

    # shellcheck disable=SC2016
    run env PATH="$mock_bin:$PATH" bash -c 'source "$1"; agy_plugin_reconcile "$2" "$3"' \
        _ "$RECONCILE_LIB" "$desired" "$manifest"
    [ "$status" -ne 0 ]
    run ! grep -q 'plugin uninstall' "$log"
    [ "$(cat "$manifest")" = "$(printf 'fresh\nretired-plugin')" ]

    : > "$log"
    desired=$(printf 'by-hand\thttps://example.test/by-hand\nfresh\thttps://example.test/fresh\n')
    # shellcheck disable=SC2016
    run env PATH="$mock_bin:$PATH" bash -c 'source "$1"; agy_plugin_reconcile "$2" "$3"' \
        _ "$RECONCILE_LIB" "$desired" "$manifest"
    [ "$status" -eq 0 ]
    grep -qx 'plugin uninstall retired-plugin' "$log"
    run ! grep -q 'plugin uninstall by-hand' "$log"
    [ "$(cat "$manifest")" = "fresh" ]
}

@test "agy plugin reconciler refuses to run when the manifest is unreadable" {
    [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 manifest"
    local mock_bin="$TEST_HOME/bin" log="$TEST_HOME/agy-calls.log"
    local manifest="$TEST_HOME/.gemini/config/.chezmoi-plugin-manifest"
    mkdir -p "$mock_bin" "$(dirname "$manifest")"
    printf 'retired-plugin\nmilknado\n' > "$manifest"
    chmod 000 "$manifest"
    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    printf '[{"name":"retired-plugin"}]\n'
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    local desired
    desired=$(printf 'milknado\thttps://github.com/paulnsorensen/milknado\n')
    # shellcheck disable=SC2016
    run env PATH="$mock_bin:$PATH" bash -c 'source "$1"; agy_plugin_reconcile "$2" "$3"' \
        _ "$RECONCILE_LIB" "$desired" "$manifest"
    chmod 600 "$manifest"
    [ "$status" -eq 1 ]
    run ! grep -qE 'plugin (install|uninstall)' "$log"
    [ "$(cat "$manifest")" = "$(printf 'retired-plugin\nmilknado')" ]
}

@test "agy plugin reconciler fails without changes when agy plugin list is not a JSON array" {
    local mock_bin="$TEST_HOME/bin" log="$TEST_HOME/agy-calls.log"
    local manifest="$TEST_HOME/.gemini/config/.chezmoi-plugin-manifest"
    mkdir -p "$mock_bin" "$(dirname "$manifest")"
    printf 'retired-plugin\n' > "$manifest"
    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    case "\$AGY_LIST_MODE" in
        fail) exit 1 ;;
        bad) printf '{bad\n' ;;
        object) printf '{}\n' ;;
        null) printf 'null\n' ;;
    esac
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    local desired mode
    desired=$(printf 'milknado\thttps://github.com/paulnsorensen/milknado\n')
    for mode in fail bad object null; do
        : > "$log"
        # shellcheck disable=SC2016
        run env AGY_LIST_MODE="$mode" PATH="$mock_bin:$PATH" bash -c 'source "$1"; agy_plugin_reconcile "$2" "$3"' \
            _ "$RECONCILE_LIB" "$desired" "$manifest"
        [ "$status" -ne 0 ] || { echo "mode $mode returned 0" >&2; return 1; }
        run ! grep -qE 'plugin (install|uninstall)' "$log"
        [ "$(cat "$manifest")" = "retired-plugin" ]
    done
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

@test "sync_agy_plugins sends both real registry sources to agy plugin install" {
    local mock_bin="$TEST_HOME/bin" log="$TEST_HOME/agy-calls.log"
    mkdir -p "$mock_bin" "$TEST_HOME/.gemini/config"
    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    printf '[]\n'
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    # shellcheck disable=SC2016
    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" bash -c 'source "$1"; sync_agy_plugins "$2"' \
        _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    grep -qx 'plugin install https://github.com/paulnsorensen/milknado' "$log"
    grep -qx 'plugin install https://github.com/paulnsorensen/hallouminate' "$log"
}

@test "sync_agy_plugins fails without uninstalling when the registry does not parse" {
    local mock_bin="$TEST_HOME/bin" log="$TEST_HOME/agy-calls.log"
    local root="$TEST_HOME/badroot" manifest="$TEST_HOME/.gemini/config/.chezmoi-plugin-manifest"
    mkdir -p "$mock_bin" "$root/chezmoi/.chezmoidata" "$root/chezmoi/lib" "$(dirname "$manifest")"
    printf 'agy: [unclosed\n' > "$root/chezmoi/.chezmoidata/agy.yaml"
    cp "$RECONCILE_LIB" "$root/chezmoi/lib/agy-plugin-reconcile.sh"
    printf 'retired-plugin\n' > "$manifest"
    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    printf '[{"name":"retired-plugin"}]\n'
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    # shellcheck disable=SC2016
    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" bash -c 'source "$1"; sync_agy_plugins "$2"' \
        _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$root"
    [ "$status" -ne 0 ]
    run ! grep -q 'plugin uninstall' "$log"
    [ "$(cat "$manifest")" = "retired-plugin" ]
}

@test "sync_agy_plugins fails and names registry entries that lack a source" {
    local mock_bin="$TEST_HOME/bin" log="$TEST_HOME/agy-calls.log"
    local root="$TEST_HOME/nosource" manifest="$TEST_HOME/.gemini/config/.chezmoi-plugin-manifest"
    mkdir -p "$mock_bin" "$root/chezmoi/.chezmoidata" "$root/chezmoi/lib" "$(dirname "$manifest")"
    printf 'agy:\n  plugins:\n    good:\n      source: https://example.test/good\n    sourceless: {}\n    blank:\n      source: ""\n' \
        > "$root/chezmoi/.chezmoidata/agy.yaml"
    cp "$RECONCILE_LIB" "$root/chezmoi/lib/agy-plugin-reconcile.sh"
    printf 'sourceless\n' > "$manifest"
    cat > "$mock_bin/agy" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "plugin" && "\$2" == "list" ]]; then
    printf '[{"name":"sourceless"}]\n'
fi
exit 0
MOCK
    chmod +x "$mock_bin/agy"

    # shellcheck disable=SC2016
    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" bash -c 'source "$1"; sync_agy_plugins "$2"' \
        _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sourceless"* ]]
    [[ "$output" == *"blank"* ]]
    [[ "$output" != *"good"* ]]
    [ ! -e "$log" ]
    [ "$(cat "$manifest")" = "sourceless" ]
}

@test "sync_agy_plugins warns when the AppArmor profile is missing or stale and stays quiet when current" {
    local mock_bin="$TEST_HOME/bin" dir="$TEST_HOME/apparmor.d"
    mkdir -p "$mock_bin" "$dir" "$TEST_HOME/.gemini/config"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1 $2" == "plugin list" ]] && printf "[]\\n"\nexit 0\n' > "$mock_bin/agy"
    chmod +x "$mock_bin/agy"
    echo 1 > "$TEST_HOME/restrict_userns"
    # shellcheck disable=SC2016
    local cmd='source "$1"; sync_agy_plugins "$2"'

    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" MISE_DATA_DIR="$TEST_HOME/mise" \
        AGY_APPARMOR_DIR="$dir" AGY_APPARMOR_SYSCTL="$TEST_HOME/restrict_userns" \
        bash -c "$cmd" _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AppArmor profile is missing or stale"*"bin/linux-install"* ]]

    printf 'stale\n' > "$dir/antigravity"
    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" MISE_DATA_DIR="$TEST_HOME/mise" \
        AGY_APPARMOR_DIR="$dir" AGY_APPARMOR_SYSCTL="$TEST_HOME/restrict_userns" \
        bash -c "$cmd" _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AppArmor profile is missing or stale"* ]]

    # shellcheck disable=SC2016
    run env HOME="$TEST_HOME" MISE_DATA_DIR="$TEST_HOME/mise" AGY_APPARMOR_SYSCTL="$TEST_HOME/restrict_userns" \
        bash -c 'source "$1/bin/lib/agy-apparmor.sh"; agy_apparmor_render' _ "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$dir/antigravity"
    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" MISE_DATA_DIR="$TEST_HOME/mise" \
        AGY_APPARMOR_DIR="$dir" AGY_APPARMOR_SYSCTL="$TEST_HOME/restrict_userns" \
        bash -c "$cmd" _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"AppArmor profile"* ]]
}

@test "sync_agy_plugins warns about the AppArmor profile when yq is missing" {
    local mock_bin="$TEST_HOME/bin" dir="$TEST_HOME/apparmor.d"
    mkdir -p "$mock_bin" "$dir" "$TEST_HOME/.gemini/config"
    printf '#!/bin/bash\nexit 0\n' > "$mock_bin/agy"
    chmod +x "$mock_bin/agy"
    echo 1 > "$TEST_HOME/restrict_userns"
    # shellcheck disable=SC2016
    local cmd='source "$1"; command() { [[ "$1 $2" == "-v yq" ]] && return 1; builtin command "$@"; }; sync_agy_plugins "$2"'

    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" MISE_DATA_DIR="$TEST_HOME/mise" \
        AGY_APPARMOR_DIR="$dir" AGY_APPARMOR_SYSCTL="$TEST_HOME/restrict_userns" \
        bash -c "$cmd" _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"yq not found"* ]]
    [[ "$output" == *"AppArmor profile is missing or stale"* ]]
}

@test "sync_agy_plugins warns when the AppArmor profile cannot render" {
    local mock_bin="$TEST_HOME/bin" dir="$TEST_HOME/apparmor.d"
    mkdir -p "$mock_bin" "$dir" "$TEST_HOME/.gemini/config"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1 $2" == "plugin list" ]] && printf "[]\\n"\nexit 0\n' > "$mock_bin/agy"
    chmod +x "$mock_bin/agy"
    echo 1 > "$TEST_HOME/restrict_userns"
    # shellcheck disable=SC2016
    local cmd='source "$1"; sync_agy_plugins "$2"'

    run env HOME="$TEST_HOME" PATH="$mock_bin:$PATH" MISE_DATA_DIR="/tmp/outside-home-mise" \
        AGY_APPARMOR_DIR="$dir" AGY_APPARMOR_SYSCTL="$TEST_HOME/restrict_userns" \
        bash -c "$cmd" _ "$REAL_DOTFILES_DIR/.sync-lib.sh" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AppArmor profile cannot render"*"unsafe binary path"* ]]
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
    [ "$(jq -r '.entries[0].path' "$destination/.gemini/config/skills.json")" = "$destination/.agents/skills" ]
}
