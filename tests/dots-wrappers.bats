#!/usr/bin/env bats
# The bin/dots* wrappers replace each harness's native system prompt with
# agents/preamble.md. T3 Code launches them through providerInstances
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
    export CLAUDE_BIN="$TEST_HOME/fakebin/harness"
    export CODEX_BIN="$TEST_HOME/fakebin/harness"
    export OPENCODE_BIN="$TEST_HOME/fakebin/harness"
    # No cc-env-exec here, so dotsclaude execs the harness directly.
    export DOTFILES_DIR="$TEST_HOME/no-dotfiles"
    unset OPENCODE_CONFIG_CONTENT
}

teardown() { teardown_test_env; }

config_of() { sed -n 's/^CONFIG=//p' <<<"$1"; }

@test "dotsclaude replaces the system prompt with the preamble" {
    run "$REAL_DOTFILES_DIR/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$AGENTS_DOTFILES/preamble.md" ]
    [ "${lines[2]}" = "-p" ]
    [ "${lines[3]}" = "hi" ]
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
    mkdir -p "$clone/bin" "$clone/agents"
    cp "$REAL_DOTFILES_DIR/bin/dotsclaude" "$clone/bin/"
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
            dots_codex_instructions_override "$home/missing.md" || echo "codex:none"
            dots_opencode_preamble_path "$home/nowhere" || echo "opencode:none"
            dots_opencode_config p "[1]" || echo "config:rejected"
            dots_opencode_config p "" | jq -r ".instructions[0]"
        }
        caller
        echo after
    ' _ "$REAL_DOTFILES_DIR" "$TEST_HOME"
    [ "$status" -eq 0 ]
    [ "$output" = $'codex:none\nopencode:none\nconfig:rejected\np\nafter' ]
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
