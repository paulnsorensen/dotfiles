#!/usr/bin/env bats
# Behavioural tests for the hallouminate nightly + cross-harness installer.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export LIB="$REAL_DOTFILES_DIR/chezmoi/lib/hallouminate-install.sh"
    export CALLS="$TEST_HOME/calls.log"
    export CACHE="$TEST_HOME/cache/hallouminate"
    export HALLOUMINATE_OPENCODE_CONFIG="$TEST_HOME/opencode/opencode.json"
    export HALLOUMINATE_CURSOR_CONFIG="$TEST_HOME/cursor/mcp.json"
    export HALLOUMINATE_CRUSH_CONFIG="$TEST_HOME/crush/crush.json"
    export HALLOUMINATE_SHARED_SKILLS="$TEST_HOME/agents/skills"
    export HALLOUMINATE_OPENCODE_SKILLS="$TEST_HOME/opencode/skills"
    export HALLOUMINATE_CLAUDE_INSTALLED="$TEST_HOME/claude/installed_plugins.json"
    mkdir -p "$TEST_HOME/bin"
    export PATH="$TEST_HOME/bin:$PATH"
}

teardown() { teardown_test_env; }

make_npm() {
    local latest="${1-1.2.3}" current="${2-1.2.3}"
    cat > "$TEST_HOME/bin/npm" <<SH
#!/usr/bin/env bash
printf 'npm %s\n' "\$*" >> "$CALLS"
case "\$1 \$2 \$3" in
    "view @paulnsorensen/hallouminate-nightly version") printf '%s\n' "$latest" ;;
    "ls -g @paulnsorensen/hallouminate-nightly")
        if [[ -f "$TEST_HOME/npm-current" ]]; then
            cat "$TEST_HOME/npm-current"
        elif [[ -n "$current" ]]; then
            printf '└── @paulnsorensen/hallouminate-nightly@%s\n' "$current"
        fi
        ;;
    "ls -g hallouminate") exit 1 ;;
    "install -g @paulnsorensen/hallouminate-nightly@latest") printf '└── @paulnsorensen/hallouminate-nightly@1.2.3\n' > "$TEST_HOME/npm-current" ;;
esac
exit 0
SH
    chmod +x "$TEST_HOME/bin/npm"
}

make_marketplace() {
    mkdir -p "$CACHE/.git" "$CACHE/.claude-plugin" "$CACHE/plugins/hallouminate/skills/wiki-query"
    printf '{"name":"hallouminate","metadata":{"pluginRoot":"./plugins"},"plugins":[{"name":"hallouminate","source":"./hallouminate"}]}\n' > "$CACHE/.claude-plugin/marketplace.json"
    printf '# Wiki Query\n' > "$CACHE/plugins/hallouminate/skills/wiki-query/SKILL.md"

    cat > "$TEST_HOME/bin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$CALLS"
exit 0
SH
    chmod +x "$TEST_HOME/bin/git"
}

make_harness() {
    local cli="$1"
    cat > "$TEST_HOME/bin/$cli" <<SH
#!/usr/bin/env bash
printf '$cli %s\n' "\$*" >> "$CALLS"
exit 0
SH
    chmod +x "$TEST_HOME/bin/$cli"
}

@test "nightly install fails explicitly when npm is missing" {
    mkdir -p "$TEST_HOME/empty-path"
    run env PATH="$TEST_HOME/empty-path" /bin/bash -c "source '$LIB' && hallouminate_install_nightly"
    [ "$status" -ne 0 ]
    [[ "$output" == *"npm not found"* ]]
    [[ "$output" != *"offline?"* ]]
}

@test "nightly install is a no-op when the current package is latest" {
    make_npm 1.2.3 1.2.3
    run bash -c "source '$LIB' && hallouminate_install_nightly"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already latest"* ]]
    run grep -q 'npm install' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "nightly install updates through npm and verifies the installed package" {
    make_npm 1.2.3 1.0.0
    run bash -c "source '$LIB' && hallouminate_install_nightly"
    [ "$status" -eq 0 ]
    grep -q 'npm install -g @paulnsorensen/hallouminate-nightly@latest --allow-scripts=@paulnsorensen/hallouminate-nightly' "$CALLS"
    [[ "$output" == *"1.2.3 installed"* ]]
}

@test "offline without an installed nightly fails instead of claiming success" {
    make_npm "" ""
    run bash -c "source '$LIB' && hallouminate_install_nightly"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no nightly is installed"* ]]
}

@test "plugin sync installs native harnesses and merges decomposed configs without clobbering user entries" {
    make_marketplace
    make_harness claude
    make_harness codex
    make_harness copilot
    mkdir -p "${HALLOUMINATE_OPENCODE_CONFIG%/*}" "${HALLOUMINATE_CURSOR_CONFIG%/*}" "${HALLOUMINATE_CRUSH_CONFIG%/*}"
    printf '{"theme":"user","mcp":{"custom":{"command":["mine"]}}}\n' > "$HALLOUMINATE_OPENCODE_CONFIG"
    printf '{"userKey":true,"mcpServers":{"custom":{"command":"mine"}}}\n' > "$HALLOUMINATE_CURSOR_CONFIG"
    printf '{"options":{"user":true},"mcp":{"custom":{"command":"mine"}}}\n' > "$HALLOUMINATE_CRUSH_CONFIG"

    run bash -c "source '$LIB' && hallouminate_sync_plugins '$CACHE'"
    [ "$status" -eq 0 ]
    grep -q 'claude plugin install hallouminate@hallouminate' "$CALLS"
    grep -q 'codex plugin add hallouminate@hallouminate' "$CALLS"
    grep -q 'copilot plugin install hallouminate@hallouminate' "$CALLS"
    [ "$(jq -r '.theme' "$HALLOUMINATE_OPENCODE_CONFIG")" = "user" ]
    [ "$(jq -r '.mcp.custom.command[0]' "$HALLOUMINATE_OPENCODE_CONFIG")" = "mine" ]
    [ "$(jq -r '.mcp.hallouminate.command | join(" ")' "$HALLOUMINATE_OPENCODE_CONFIG")" = "hallouminate serve" ]
    [ "$(jq -r '.userKey' "$HALLOUMINATE_CURSOR_CONFIG")" = "true" ]
    [ "$(jq -r '.mcpServers.hallouminate.command' "$HALLOUMINATE_CURSOR_CONFIG")" = "hallouminate" ]
    [ "$(jq -r '.options.user' "$HALLOUMINATE_CRUSH_CONFIG")" = "true" ]
    [ "$(jq -r '.mcp.hallouminate.command' "$HALLOUMINATE_CRUSH_CONFIG")" = "hallouminate" ]
    [ -f "$HALLOUMINATE_SHARED_SKILLS/wiki-query/SKILL.md" ]
    [ -f "$HALLOUMINATE_OPENCODE_SKILLS/wiki-query/SKILL.md" ]
}

@test "plugin sync preserves a conflicting user-owned hallouminate entry and existing skill" {
    make_marketplace
    make_harness claude
    make_harness codex
    make_harness copilot
    mkdir -p "${HALLOUMINATE_CURSOR_CONFIG%/*}" "$HALLOUMINATE_SHARED_SKILLS/wiki-query"
    printf '{"mcpServers":{"hallouminate":{"command":"user-wrapper","args":[]}}}\n' > "$HALLOUMINATE_CURSOR_CONFIG"
    printf 'user skill\n' > "$HALLOUMINATE_SHARED_SKILLS/wiki-query/SKILL.md"

    run bash -c "source '$LIB' && hallouminate_sync_plugins '$CACHE'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"user-owned hallouminate MCP entry"* ]]
    [ "$(jq -r '.mcpServers.hallouminate.command' "$HALLOUMINATE_CURSOR_CONFIG")" = "user-wrapper" ]
    [ "$(cat "$HALLOUMINATE_SHARED_SKILLS/wiki-query/SKILL.md")" = "user skill" ]
}

@test "Claude project-scope installs do not satisfy the required user-scope native install" {
    mkdir -p "${HALLOUMINATE_CLAUDE_INSTALLED%/*}"
    printf '{"plugins":{"hallouminate@hallouminate":[{"scope":"project","projectPath":"/tmp/project"}]}}\n' > "$HALLOUMINATE_CLAUDE_INSTALLED"
    make_harness claude

    run bash -c "source '$LIB' && _hallouminate_plugin_present claude"
    [ "$status" -ne 0 ]
}
