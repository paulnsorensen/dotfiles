#!/usr/bin/env bats
# Behavioural test for reconcile_claude_mcps() in .sync-lib.sh — the
# unconditional MCP reconcile that runs as the FINAL write of every `dots sync`,
# healing the tilth ~/.claude.json entry after `tilth install claude-code`
# clobbers it (drops the registry-authored --edit / env). Because the chezmoi
# run_onchange reconcile is hash-gated (only fires when the registry mcps block
# changes), it cannot undo that clobber; this function does, every sync.
#
# The `claude` CLI is mocked with a recorder that also applies add-json / remove
# mutations to the fixture ~/.claude.json, so the reconcile flow behaves like
# the real CLI (same pattern as tests/claude-mcp-reconcile.bats).

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"

    export LIB="$REAL_DOTFILES_DIR/.sync-lib.sh"
    export CJ="$TEST_HOME/.claude.json"
    export MANIFEST="$TEST_HOME/.claude/.chezmoi-mcp-manifest"
    export CALLS="$TEST_HOME/claude-calls.log"

    # Mock claude CLI: records argv; applies add-json/remove to $CJ.
    local fake_bin="$TEST_HOME/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
    "mcp add-json")
        name="$3"; json="$4"
        jq --arg n "$name" --argjson v "$json" '.mcpServers[$n] = $v' "$CJ" > "$CJ.tmp" \
            && mv "$CJ.tmp" "$CJ"
        ;;
    "mcp remove")
        name="$3"
        jq --arg n "$name" 'del(.mcpServers[$n])' "$CJ" > "$CJ.tmp" && mv "$CJ.tmp" "$CJ"
        ;;
esac
exit 0
SH
    chmod +x "$fake_bin/claude"
    export PATH="$fake_bin:$PATH"

    # Fixture dotfiles root the function reads via $dir: the real reconcile lib
    # plus a minimal claude registry whose tilth entry carries --edit.
    export FIX="$TEST_HOME/fixture-dotfiles"
    mkdir -p "$FIX/chezmoi/lib" "$FIX/chezmoi/.chezmoidata"
    cp "$REAL_DOTFILES_DIR/chezmoi/lib/claude-mcp-reconcile.sh" "$FIX/chezmoi/lib/"
    cat > "$FIX/chezmoi/.chezmoidata/claude.yaml" <<'YAML'
claude:
  mcps:
    tilth:
      command: tilth
      args: ["--mcp", "--edit"]
      env:
        TILTH_MCP_CWD_HOOK_INJECTED: "1"
YAML
}

teardown() { teardown_test_env; }

@test "reconcile_claude_mcps: restores --edit after a tilth install clobber" {
    # Clobbered shape: tilth entry as `tilth install claude-code` rewrites it —
    # no --edit, no env, absolute command path.
    jq -n '{mcpServers: {tilth: {type:"stdio", command:"/usr/local/bin/tilth", args:["--mcp"], env:{}}}}' > "$CJ"
    mkdir -p "${MANIFEST%/*}"
    printf 'tilth\n' > "$MANIFEST"

    run bash -c "dir='$FIX'; source '$LIB'; reconcile_claude_mcps"
    [ "$status" -eq 0 ]

    # Drift detected → registry shape re-applied: --edit is back.
    jq -e '.mcpServers.tilth.args | index("--edit")' "$CJ" >/dev/null
    [ "$(jq -r '.mcpServers.tilth.command' "$CJ")" = "tilth" ]
    [ "$(jq -r '.mcpServers.tilth.env.TILTH_MCP_CWD_HOOK_INJECTED' "$CJ")" = "1" ]
    grep -q "mcp add-json tilth" "$CALLS"
}

@test "reconcile_claude_mcps: no-ops when the tilth entry already matches the registry" {
    # Already-correct shape (env keys sorted as jq stores them): reconcile must
    # not remove/re-add — idempotent final write.
    jq -n '{mcpServers: {tilth: {type:"stdio", command:"tilth", args:["--mcp","--edit"], env:{TILTH_MCP_CWD_HOOK_INJECTED:"1"}}}}' > "$CJ"
    mkdir -p "${MANIFEST%/*}"
    printf 'tilth\n' > "$MANIFEST"

    run bash -c "dir='$FIX'; source '$LIB'; reconcile_claude_mcps"
    [ "$status" -eq 0 ]
    ! grep -q "mcp add-json tilth" "$CALLS"
    ! grep -q "mcp remove tilth" "$CALLS"
}

@test "reconcile_claude_mcps: skips (returns 0) when claude CLI is missing" {
    jq -n '{mcpServers: {tilth: {type:"stdio", command:"/usr/local/bin/tilth", args:["--mcp"], env:{}}}}' > "$CJ"
    # PATH with the tools the function needs EXCEPT claude, so its guard trips.
    local minimal="$TEST_HOME/minimal-bin"
    mkdir -p "$minimal"
    for t in bash yq jq sed; do
        ln -s "$(command -v $t)" "$minimal/$t" 2>/dev/null || true
    done
    run bash -c "PATH='$minimal' bash -c \"dir='$FIX'; source '$LIB'; reconcile_claude_mcps\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping claude MCP reconcile"* ]]
}
