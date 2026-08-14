#!/usr/bin/env bats
# Tests for the Pi-native sensitive-file guard extension
# (chezmoi/dot_pi/private_agent/extensions_src/sensitive-file-guard.ts),
# the Pi analogue of agents/lib/sensitive-file-guard.js (see tests/sensitive-file-guard.bats
# for the shared Claude/Codex hook). Pi has no PreToolUse hook; the guard
# hooks pi.on("tool_call") instead, so it's exercised here by importing the
# module's exported pure functions directly via bun (no live Pi process).

load test_helper

GUARD_TS="$REAL_DOTFILES_DIR/chezmoi/dot_pi/private_agent/extensions_src/sensitive-file-guard.ts"

setup() {
    command -v bun >/dev/null 2>&1 || skip "bun not installed"
}

# Feed a tool name + JSON input; echo "block" or "allow".
guard() {
    local tool="$1" input_json="$2"
    run bun run - "$GUARD_TS" "$tool" "$input_json" <<'BUN'
const [modPath, toolName, inputJson] = process.argv.slice(2);
const mod = await import(modPath);
const input = JSON.parse(inputJson);
const hits = mod.blockedTargets(toolName, input);
console.log(hits.length > 0 ? "block" : "allow");
BUN
    [ "$status" -eq 0 ]
    echo "$output"
}

@test "tilth_write targeting .env is blocked" {
    [[ "$(guard tilth_write '{"edits":[{"path":"/proj/.env","ops":[]}]}')" == "block" ]]
}

@test "tilth_write targeting a normal source file is allowed" {
    [[ "$(guard tilth_write '{"edits":[{"path":"/proj/src/lib.rs","ops":[]}]}')" == "allow" ]]
}

@test "tilth_read targeting id_rsa is blocked" {
    [[ "$(guard tilth_read '{"paths":["/home/user/.ssh/id_rsa"]}')" == "block" ]]
}

@test "built-in write tool targeting .env is blocked" {
    [[ "$(guard write '{"path":".env","content":"X=1"}')" == "block" ]]
}

@test "bash tool reading .env via cat is blocked" {
    [[ "$(guard bash '{"command":"cat .env"}')" == "block" ]]
}

@test "built-in read tool targeting .env.example is allowed (safe template)" {
    [[ "$(guard read '{"path":".env.example"}')" == "allow" ]]
}
