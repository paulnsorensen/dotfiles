#!/usr/bin/env bats
# The bin/dots* wrappers replace each harness's native system prompt with the
# tilth preamble plus agents/preamble.md, or agents/preamble.md alone when
# tilth cannot join them. T3 Code launches them through providerInstances
# binaryPath (chezmoi/.chezmoidata/t3.yaml). A fake harness binary prints its
# argv and the OpenCode config variable, so each test checks the launch line.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    export AGENTS_DOTFILES="$TEST_HOME/agents"
    mkdir -p "$AGENTS_DOTFILES" "$TEST_HOME/fakebin"
    printf '# Execution preamble\n' > "$AGENTS_DOTFILES/preamble.md"
    cat > "$TEST_HOME/fakebin/harness" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
printf 'CONFIG=%s\n' "${OPENCODE_CONFIG_CONTENT-<unset>}"
SH
    chmod +x "$TEST_HOME/fakebin/harness"
    # Fake tilth with `preamble --append FILE [--path]` (tilth#475).
    cat > "$TEST_HOME/fakebin/tilth" <<'SH'
#!/bin/sh
[ "$1" = preamble ] && [ "$2" = --append ] || exit 2
{ printf '# tilth agent preamble\n\n'; cat "$3"; } > "$FAKE_TILTH_OUT"
if [ "${4-}" = --path ]; then printf '%s\n' "$FAKE_TILTH_OUT"; else cat "$FAKE_TILTH_OUT"; fi
SH
    # Fake tilth from before --append: clap rejects the unknown flag.
    printf '#!/bin/sh\necho "error: unexpected argument" >&2\nexit 2\n' > "$TEST_HOME/fakebin/old-tilth"
    chmod +x "$TEST_HOME/fakebin/tilth" "$TEST_HOME/fakebin/old-tilth"
    export FAKE_TILTH_OUT="$TEST_HOME/cache/tilth-preamble-joined.md"
    mkdir -p "$TEST_HOME/cache"
    # Default: no tilth, so the launch lines name agents/preamble.md.
    export TILTH_BIN="$TEST_HOME/fakebin/no-tilth"
    export CLAUDE_BIN="$TEST_HOME/fakebin/harness"
    export CODEX_BIN="$TEST_HOME/fakebin/harness"
    export OPENCODE_BIN="$TEST_HOME/fakebin/harness"
    # No cc-env-exec here, so dotsclaude execs the harness directly.
    export DOTFILES_DIR="$TEST_HOME/no-dotfiles"
    unset OPENCODE_CONFIG_CONTENT GEMINI_HOME
}

teardown() { teardown_test_env; }

config_of() { sed -n 's/^CONFIG=//p' <<<"$1"; }

# A clone at $TEST_HOME: cc runs its bin/dotsclaude with CLAUDE_BIN=claude,
# and the fake harness is the `claude` on PATH. _cc_base names the session
# before it checks TMUX. Without cc-env-exec, dotsclaude execs claude directly.
_cc_fixture() {
    export DOTFILES_DIR="$TEST_HOME"
    mkdir -p "$DOTFILES_DIR/bin/lib"
    cp "$REAL_DOTFILES_DIR"/bin/{cc-session-name,dotsclaude} "$DOTFILES_DIR/bin/"
    cp "$REAL_DOTFILES_DIR/bin/lib/preamble-wrappers.sh" "$DOTFILES_DIR/bin/lib/"
    ln -s "$TEST_HOME/fakebin/harness" "$TEST_HOME/fakebin/claude"
    export PATH="$TEST_HOME/fakebin:$PATH"
}

@test "dotsclaude replaces the system prompt with the preamble" {
    run "$REAL_DOTFILES_DIR/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$AGENTS_DOTFILES/preamble.md" ]
    [ "${lines[2]}" = "-p" ]
    [ "${lines[3]}" = "hi" ]
}

@test "dotsclaude passes the tilth preamble joined with the agents preamble" {
    export TILTH_BIN="$TEST_HOME/fakebin/tilth"
    run "$REAL_DOTFILES_DIR/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$FAKE_TILTH_OUT" ]
    [ "${lines[2]}" = "-p" ]
    [ "$(head -n1 "$FAKE_TILTH_OUT")" = "# tilth agent preamble" ]
    [ "$(tail -n1 "$FAKE_TILTH_OUT")" = "# Execution preamble" ]
}

@test "dotsclaude falls back to the agents preamble when tilth lacks --append" {
    export TILTH_BIN="$TEST_HOME/fakebin/old-tilth"
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "$AGENTS_DOTFILES/preamble.md" ]
    [ -z "$stderr" ]
}

@test "dotscodex points model_instructions_file at the joined tilth preamble" {
    export TILTH_BIN="$TEST_HOME/fakebin/tilth"
    run "$REAL_DOTFILES_DIR/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "model_instructions_file=\"$FAKE_TILTH_OUT\"" ]
    [ "${lines[2]}" = "exec" ]
}

@test "dotsopencode falls back to the joined tilth preamble from the clone" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export TILTH_BIN="$TEST_HOME/fakebin/tilth"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$FAKE_TILTH_OUT" '.instructions == [$p]' <<<"$(config_of "$output")"
}

@test "cc passes the joined tilth preamble to claude" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    export TILTH_BIN="$TEST_HOME/fakebin/tilth"
    _cc_fixture
    # TMUX set and no --new: _cc_base runs dotsclaude in place.
    run zsh -fc 'export TMUX=x; source "$1"; cc -p hi' _ "$REAL_DOTFILES_DIR/zsh/claude.zsh"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$FAKE_TILTH_OUT" ]
    [ "${lines[2]}" = "-p" ]
}

@test "cc falls back to the agents preamble when tilth lacks --append" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    export TILTH_BIN="$TEST_HOME/fakebin/old-tilth"
    _cc_fixture
    run zsh -fc 'export TMUX=x; source "$1"; cc -p hi' _ "$REAL_DOTFILES_DIR/zsh/claude.zsh"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$AGENTS_DOTFILES/preamble.md" ]
}

@test "dotscodex sets model_instructions_file before the subcommand" {
    run "$REAL_DOTFILES_DIR/bin/dotscodex" app-server --listen stdio
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-c" ]
    [ "${lines[1]}" = "model_instructions_file=\"$AGENTS_DOTFILES/preamble.md\"" ]
    [ "${lines[2]}" = "app-server" ]
    [ "${lines[3]}" = "--listen" ]
    [ "${lines[4]}" = "stdio" ]
}

@test "dotscodex escapes the preamble path as a TOML string" {
    export AGENTS_DOTFILES="$TEST_HOME"'/odd "dir"\x'
    mkdir -p "$AGENTS_DOTFILES"
    printf 'p\n' > "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = 'model_instructions_file="'"$TEST_HOME"'/odd \"dir\"\\x/preamble.md"' ]
}

@test "dotscodex passes arguments through when the preamble is missing" {
    rm "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotscodex" exec hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "exec" ]
    [ "${lines[1]}" = "hi" ]
}

@test "dotsopencode prompts match the opencode registry" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "serve" ]
    local config registry
    config=$(config_of "$output")
    registry=$(yq -o=json '.opencode.config.agent' "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/opencode.yaml" \
        | jq -c '{build, plan, general, explore} | map_values({prompt})')
    jq -e --argjson want "$registry" '.agent == $want' <<<"$config"
}

@test "dotsopencode uses the installed preamble path that the global config lists" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    mkdir -p "$HOME/.config/opencode"
    printf 'p\n' > "$HOME/.config/opencode/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e '.instructions == ["~/.config/opencode/preamble.md"]' <<<"$(config_of "$output")"
    run yq -o=json '.opencode.config.instructions' "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/opencode.yaml"
    jq -e '. == ["~/.config/opencode/preamble.md"]' <<<"$output"
}

@test "dotsopencode falls back to the clone preamble" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$AGENTS_DOTFILES/preamble.md" '.instructions == [$p]' <<<"$(config_of "$output")"
}

@test "dotsopencode merges into the caller config and lets caller keys win" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export OPENCODE_CONFIG_CONTENT='{"share":"disabled","agent":{"build":{"prompt":"caller"}}}'
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e '.share == "disabled" and .agent.build.prompt == "caller" and (.agent.plan.prompt | contains("Plan only."))' \
        <<<"$(config_of "$output")"
}

@test "dotsopencode keeps the preamble when the caller config has instructions" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    local p="$AGENTS_DOTFILES/preamble.md"
    OPENCODE_CONFIG_CONTENT=$(jq -cn --arg p "$p" '{instructions: ["extra.md", $p, "extra.md"]}')
    export OPENCODE_CONFIG_CONTENT
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$p" '.instructions == [$p, "extra.md"]' <<<"$(config_of "$output")"
}

@test "dotsopencode leaves the config unchanged when jq is missing" {
    local nojq="$TEST_HOME/nojq"
    mkdir -p "$nojq"
    ln -s "$(command -v bash)" "$nojq/bash"
    ln -s "$(command -v dirname)" "$nojq/dirname"
    export OPENCODE_CONFIG_CONTENT='{"share":"disabled"}'
    # env is an absolute path, so only the wrapper sees the jq-free PATH.
    run --separate-stderr /usr/bin/env PATH="$nojq" "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "serve" ]
    [ "$(config_of "$output")" = '{"share":"disabled"}' ]
    [[ "$stderr" == *"jq missing"* ]]
}

@test "wrappers find the preamble in a clone outside ~/Dev" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    local clone="$TEST_HOME/code/my dots"
    mkdir -p "$clone/bin/lib" "$clone/agents"
    # The wrappers resolve their clone with `cd -P`; macOS TMPDIR sits behind
    # the /var -> /private/var symlink, so compare against the physical path.
    clone="$(cd -P "$clone" && pwd)"
    cp "$REAL_DOTFILES_DIR"/bin/dots{claude,codex,opencode} "$clone/bin/"
    cp "$REAL_DOTFILES_DIR/bin/lib/preamble-wrappers.sh" "$clone/bin/lib/"
    printf 'p\n' > "$clone/agents/preamble.md"
    unset AGENTS_DOTFILES DOTFILES_DIR
    run "$clone/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "$clone/agents/preamble.md" ]
    run "$clone/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "model_instructions_file=\"$clone/agents/preamble.md\"" ]
    run "$clone/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$clone/agents/preamble.md" '.instructions == [$p]' <<<"$(config_of "$output")"
}

@test "dotsclaude passes the real clone to cc-env-exec through a symlinked bin" {
    local clone="$TEST_HOME/code/my dots"
    mkdir -p "$clone/bin/lib" "$clone/agents"
    cp "$REAL_DOTFILES_DIR/bin/dotsclaude" "$clone/bin/"
    cp "$REAL_DOTFILES_DIR/bin/lib/preamble-wrappers.sh" "$clone/bin/lib/"
    cat > "$clone/bin/cc-env-exec" <<'SH'
#!/bin/sh
printf 'DOTFILES_DIR=%s\n' "$DOTFILES_DIR"
SH
    chmod +x "$clone/bin/cc-env-exec"
    printf 'p\n' > "$clone/agents/preamble.md"
    ln -s "$clone/bin" "$TEST_HOME/linkbin"
    local real
    real=$(cd -P "$clone" && pwd)
    unset AGENTS_DOTFILES DOTFILES_DIR
    run "$TEST_HOME/linkbin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "$output" = "DOTFILES_DIR=$real" ]
}

@test "preamble library functions keep the caller shell usable under strict mode" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run bash -c '
        set -euo pipefail
        source "$1/bin/lib/preamble-wrappers.sh"
        home=$2
        caller() {
            dots_preamble_file "$home/missing.md" || echo "preamble:none"
            dots_codex_instructions_override "$home/missing.md" || echo "codex:none"
            dots_opencode_preamble_path "$home/nowhere" || echo "opencode:none"
            dots_opencode_config p "[1]" || echo "config:rejected"
            dots_opencode_config p "" | jq -r ".instructions[0]"
        }
        caller
        echo after
    ' _ "$REAL_DOTFILES_DIR" "$TEST_HOME"
    [ "$status" -eq 0 ]
    [ "$output" = $'preamble:none\ncodex:none\nopencode:none\nconfig:rejected\np\nafter' ]
}

@test "dotsopencode leaves a malformed caller config unchanged" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export OPENCODE_CONFIG_CONTENT='[1,2]'
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "$(config_of "$output")" = '[1,2]' ]
    [[ "$stderr" == *"not a JSON object"* ]]
}

@test "dotsopencode passes through when no preamble exists" {
    rm "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "$(config_of "$output")" = "<unset>" ]
}

# ── bin/dotsagy/agy (Antigravity ACP wrapper) ───────────────────────────────

_agy_fixture() {
    export AGY_BIN="$TEST_HOME/fakebin/harness"
    export AGY_USER_GEMINI_DIR="$TEST_HOME/user-gemini"
    export AGY_PROFILE="$TEST_HOME/t3-profile"
    mkdir -p "$AGY_USER_GEMINI_DIR/antigravity-cli" \
        "$AGY_USER_GEMINI_DIR/config/plugins/milknado" \
        "$AGY_PROFILE/antigravity-acp" \
        "$AGY_PROFILE/config"
    cat > "$AGY_USER_GEMINI_DIR/antigravity-cli/settings.json" <<'JSON'
{
  "agentMode": "auto",
  "enableTerminalSandbox": true,
  "toolPermission": "proceed-in-sandbox",
  "permissions": {
    "allow": ["mcp(tilth/*)", "command(git)"],
    "ask": ["command(git push)"],
    "deny": ["command(sudo)"]
  }
}
JSON
    printf '{"mcpServers":{"tilth":{"command":"tilth"}}}\n' > "$AGY_USER_GEMINI_DIR/config/mcp_config.json"
    printf '# Global rules\n' > "$AGY_USER_GEMINI_DIR/config/AGENTS.md"
    printf '{"name":"milknado"}\n' > "$AGY_USER_GEMINI_DIR/config/plugins/milknado/plugin.json"
    printf '{"auth":{"type":"oauth-personal"},"gcp":{"project":"p1"}}\n' > "$AGY_PROFILE/antigravity-acp/settings.json"
    # agy seeds a 0-byte mcp_config.json on first boot.
    : > "$AGY_PROFILE/config/mcp_config.json"
}

@test "dotsagy merges managed settings, preserves T3 auth/gcp, and links user config" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture

    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "${lines[0]}" = "acp" ]
    [ "${lines[1]}" = "--gemini-dir" ]
    [ "${lines[2]}" = "$AGY_PROFILE" ]
    [ "${lines[3]}" = "--app-data-dir" ]
    [ "${lines[4]}" = "antigravity-acp" ]

    # T3 auth/gcp preserved; enableTerminalSandbox and permissions merged;
    # toolPermission and agentMode intentionally not copied.
    run jq -e '
        .auth.type == "oauth-personal"
        and .gcp.project == "p1"
        and .enableTerminalSandbox == true
        and (has("toolPermission") | not)
        and (has("agentMode") | not)
        and .permissions.allow == ["mcp(tilth/*)", "command(git)", "mcp(t3-code/*)"]
        and .permissions.ask == ["command(git push)"]
        and .permissions.deny == ["command(sudo)"]
    ' "$AGY_PROFILE/antigravity-acp/settings.json"
    [ "$status" -eq 0 ]

    # Links replace the 0-byte mcp_config.json and populate plugins + AGENTS.md.
    [[ -L "$AGY_PROFILE/config/mcp_config.json" ]]
    [ "$(readlink "$AGY_PROFILE/config/mcp_config.json")" = "$AGY_USER_GEMINI_DIR/config/mcp_config.json" ]
    [[ -L "$AGY_PROFILE/config/plugins" ]]
    [ "$(readlink "$AGY_PROFILE/config/plugins")" = "$AGY_USER_GEMINI_DIR/config/plugins" ]
    [[ -L "$AGY_PROFILE/config/AGENTS.md" ]]
    [ "$(readlink "$AGY_PROFILE/config/AGENTS.md")" = "$AGY_USER_GEMINI_DIR/config/AGENTS.md" ]
}

@test "dotsagy does not duplicate mcp(t3-code/*) across repeated launches" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture

    run "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir="$AGY_PROFILE" --app-data-dir=antigravity-acp
    [ "$status" -eq 0 ]
    run "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini_dir "$AGY_PROFILE" --app_data_dir antigravity-acp
    [ "$status" -eq 0 ]

    run jq -e '[.permissions.allow[] | select(. == "mcp(t3-code/*)")] | length == 1' \
        "$AGY_PROFILE/antigravity-acp/settings.json"
    [ "$status" -eq 0 ]
}

@test "dotsagy preserves non-empty profile config files and directories" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture
    printf '{"mcpServers":{"custom":{"command":"custom"}}}\n' > "$AGY_PROFILE/config/mcp_config.json"
    mkdir -p "$AGY_PROFILE/config/plugins/local-only"
    printf '{"name":"local-only"}\n' > "$AGY_PROFILE/config/plugins/local-only/plugin.json"

    run "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [[ ! -L "$AGY_PROFILE/config/mcp_config.json" ]]
    [[ ! -L "$AGY_PROFILE/config/plugins" ]]
    grep -q '"custom"' "$AGY_PROFILE/config/mcp_config.json"
    [ -f "$AGY_PROFILE/config/plugins/local-only/plugin.json" ]
}

@test "dotsagy replaces an empty plugins dir and cleans stale symlinks when source disappears" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture
    mkdir -p "$AGY_PROFILE/config/plugins"

    run "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [[ -L "$AGY_PROFILE/config/plugins" ]]

    rm "$AGY_USER_GEMINI_DIR/config/mcp_config.json"
    rm -rf "$AGY_USER_GEMINI_DIR/config/plugins"
    run "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [ ! -L "$AGY_PROFILE/config/mcp_config.json" ]
    [ ! -L "$AGY_PROFILE/config/plugins" ]
}

@test "dotsagy passes through non-acp calls and skips self-linking when profile equals user dir" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture

    run "$REAL_DOTFILES_DIR/bin/dotsagy/agy" --version
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--version" ]
    [[ ! -L "$AGY_PROFILE/config/mcp_config.json" ]]

    run "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir "$AGY_USER_GEMINI_DIR" --app-data-dir antigravity-cli
    [ "$status" -eq 0 ]
    [[ ! -L "$AGY_USER_GEMINI_DIR/config/mcp_config.json" ]]
    [[ ! -L "$AGY_USER_GEMINI_DIR/config/plugins" ]]
    [[ ! -L "$AGY_USER_GEMINI_DIR/config/AGENTS.md" ]]
}

@test "dotsagy still links config and execs cleanly when jq is missing or JSON is malformed" {
    _agy_fixture
    local nojq="$TEST_HOME/nojq"
    mkdir -p "$nojq"
    for cmd in bash dirname basename mkdir ln rm readlink mv mktemp cat; do
        ln -s "$(command -v "$cmd")" "$nojq/$cmd"
    done
    # Isolate XDG_DATA_HOME so the mise shim fallback is also absent.
    run --separate-stderr /usr/bin/env PATH="$nojq" HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_HOME/empty-xdg" \
        AGY_BIN="$AGY_BIN" AGY_USER_GEMINI_DIR="$AGY_USER_GEMINI_DIR" \
        "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "acp" ]
    [[ "$stderr" == *"jq missing"* ]]
    [[ -L "$AGY_PROFILE/config/mcp_config.json" ]]
    [[ -L "$AGY_PROFILE/config/plugins" ]]
    [[ -L "$AGY_PROFILE/config/AGENTS.md" ]]

    command -v jq >/dev/null 2>&1 || return 0
    printf '{bad\n' > "$AGY_PROFILE/antigravity-acp/settings.json"
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "acp" ]
    [[ "$stderr" == *"not a JSON object"* ]]
    [ "$(cat "$AGY_PROFILE/antigravity-acp/settings.json")" = "{bad" ]
}

@test "dotsagy resolves its library through a symlinked bin directory" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture
    local clone="$TEST_HOME/code/my dots"
    mkdir -p "$clone/bin/dotsagy" "$clone/bin/lib"
    cp "$REAL_DOTFILES_DIR/bin/dotsagy/agy" "$clone/bin/dotsagy/agy"
    cp "$REAL_DOTFILES_DIR/bin/lib/agy-wrapper.sh" "$clone/bin/lib/agy-wrapper.sh"
    ln -s "$clone/bin" "$TEST_HOME/linkbin"

    run --separate-stderr "$TEST_HOME/linkbin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ -L "$AGY_PROFILE/config/mcp_config.json" ]]
    run jq -e '.enableTerminalSandbox == true' "$AGY_PROFILE/antigravity-acp/settings.json"
    [ "$status" -eq 0 ]
}

@test "agy-wrapper library functions keep the caller shell usable under strict mode" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run bash -c '
        set -euo pipefail
        unset GEMINI_HOME
        source "$1/bin/lib/agy-wrapper.sh"
        dots_agy_parse_acp_args --version || echo "non-acp"
        dots_agy_parse_acp_args acp || echo "no-profile"
        dots_agy_parse_acp_args acp --gemini-dir --app-data-dir antigravity-acp || echo "flag-rejected"
        GEMINI_HOME="$2/prof" dots_agy_parse_acp_args acp --app-data-dir ""
        printf "%s|%s\n" "$DOTS_AGY_PROFILE_DIR" "$DOTS_AGY_APP_DATA_DIR"
    ' _ "$REAL_DOTFILES_DIR" "$TEST_HOME"
    [ "$status" -eq 0 ]
    [ "$output" = $'non-acp\nno-profile\nflag-rejected\n'"$TEST_HOME/prof|antigravity-cli" ]
}

@test "dotsagy handles zero arguments, whitespace-only settings, multi-doc JSON, and 0600 mode" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture

    # Zero-argument invocation passes through cleanly under strict mode.
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]

    # Whitespace-only profile settings.json is treated as {} and written 0600.
    printf '  \n\t\n' > "$AGY_PROFILE/antigravity-acp/settings.json"
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    run jq -e '.enableTerminalSandbox == true and (.permissions.allow | index("mcp(t3-code/*)") != null)' \
        "$AGY_PROFILE/antigravity-acp/settings.json"
    [ "$status" -eq 0 ]
    local mode
    mode="$(stat -c '%a' "$AGY_PROFILE/antigravity-acp/settings.json" 2>/dev/null \
        || stat -f '%Lp' "$AGY_PROFILE/antigravity-acp/settings.json")"
    [ "$mode" = "600" ]

    # Multi-document JSON is rejected rather than corrupting profile settings.
    printf '{"a":1}{"b":2}\n' > "$AGY_PROFILE/antigravity-acp/settings.json"
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"not a JSON object"* ]]
    [ "$(cat "$AGY_PROFILE/antigravity-acp/settings.json")" = '{"a":1}{"b":2}' ]
}

@test "dotsagy respects existing boolean enableTerminalSandbox, false values, and permissions without allow" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture
    cat > "$AGY_USER_GEMINI_DIR/antigravity-cli/settings.json" <<'JSON'
{
  "enableTerminalSandbox": false,
  "permissions": {
    "deny": ["command(sudo)"]
  }
}
JSON
    printf '{"auth":{"type":"oauth-personal"},"enableTerminalSandbox":null}\n' \
        > "$AGY_PROFILE/antigravity-acp/settings.json"
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    run jq -e '
        .enableTerminalSandbox == false
        and .permissions.allow == ["mcp(t3-code/*)"]
        and .permissions.deny == ["command(sudo)"]
    ' "$AGY_PROFILE/antigravity-acp/settings.json"
    [ "$status" -eq 0 ]

    # Existing boolean enableTerminalSandbox in profile wins over user setting.
    cat > "$AGY_USER_GEMINI_DIR/antigravity-cli/settings.json" <<'JSON'
{"enableTerminalSandbox": true}
JSON
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir antigravity-acp
    [ "$status" -eq 0 ]
    run jq -e '.enableTerminalSandbox == false' "$AGY_PROFILE/antigravity-acp/settings.json"
    [ "$status" -eq 0 ]
}

@test "dotsagy supports absolute app-data-dir, retargets stale links, and survives concurrent launches" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    _agy_fixture
    local abs_app="$TEST_HOME/abs-app-data"
    mkdir -p "$abs_app"
    printf '{"auth":{"type":"oauth-personal"}}\n' > "$abs_app/settings.json"

    # Point existing symlinks at a stale target; dotsagy must retarget both.
    ln -sfn "$TEST_HOME/old-mcp.json" "$AGY_PROFILE/config/mcp_config.json"
    ln -sfn "$TEST_HOME/old-plugins" "$AGY_PROFILE/config/plugins"

    # Reject root app-data-dir without touching /settings.json; honor real absolute path.
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir /
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$(readlink "$AGY_PROFILE/config/mcp_config.json")" = "$AGY_USER_GEMINI_DIR/config/mcp_config.json" ]
    [ "$(readlink "$AGY_PROFILE/config/plugins")" = "$AGY_USER_GEMINI_DIR/config/plugins" ]

    run --separate-stderr env CDPATH=".:$TEST_HOME" "$REAL_DOTFILES_DIR/bin/dotsagy/agy" \
        acp --gemini-dir "$AGY_PROFILE" --app-data-dir "$abs_app"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    run jq -e '.auth.type == "oauth-personal" and .enableTerminalSandbox == true' "$abs_app/settings.json"
    [ "$status" -eq 0 ]

    # Concurrent spawns on a fresh profile must both exit 0 with clean stderr.
    local race_prof="$TEST_HOME/race-profile"
    mkdir -p "$race_prof/antigravity-acp" "$race_prof/config"
    printf '{"auth":{"type":"oauth-personal"}}\n' > "$race_prof/antigravity-acp/settings.json"
    : > "$race_prof/config/mcp_config.json"
    local err1="$TEST_HOME/race1.err" err2="$TEST_HOME/race2.err"
    "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir "$race_prof" --app-data-dir antigravity-acp >/dev/null 2>"$err1" &
    local p1=$!
    "$REAL_DOTFILES_DIR/bin/dotsagy/agy" acp --gemini-dir "$race_prof" --app-data-dir antigravity-acp >/dev/null 2>"$err2" &
    local p2=$!
    wait "$p1"
    wait "$p2"
    [ ! -s "$err1" ]
    [ ! -s "$err2" ]
    [[ -L "$race_prof/config/mcp_config.json" ]]
    [[ -L "$race_prof/config/plugins" ]]
    run jq -e '.auth.type == "oauth-personal" and .enableTerminalSandbox == true' \
        "$race_prof/antigravity-acp/settings.json"
    [ "$status" -eq 0 ]
}
