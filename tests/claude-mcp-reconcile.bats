#!/usr/bin/env bats
# Behavioural tests for chezmoi/lib/claude-mcp-reconcile.sh — the
# manifest-tracked reconcile of ~/.claude.json user-scope MCPs against the
# claude registry (spec: chezmoi-authoritative-claude, decision C2).
#
# The `claude` CLI is mocked with a recorder that also applies add-json /
# remove mutations to the fixture ~/.claude.json, so multi-step flows behave
# like the real CLI.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export LIB="$REAL_DOTFILES_DIR/chezmoi/lib/claude-mcp-reconcile.sh"
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

    # Literal JSON string; the single quotes and ${BETA_KEY} are intentional
    # (env passthrough is stored verbatim), so the quote-expansion warnings
    # do not apply.
    # shellcheck disable=SC2016,SC2089
    REG='{
      "alpha": {"command": "alpha-bin", "args": ["--mcp"]},
      "beta":  {"command": "npx", "args": ["-y", "beta"], "env": {"BETA_KEY": "${BETA_KEY}"}}
    }'
    # shellcheck disable=SC2090
    export REG
}

teardown() { teardown_test_env; }

run_reconcile() {
    run bash -c "source '$LIB' && claude_mcp_reconcile '$REG' '$CJ' '$MANIFEST'"
}

live() { jq -r '.mcpServers | keys | join(",")' "$CJ"; }

@test "reconcile: adds all registry MCPs to an empty live file and writes the manifest" {
    echo '{}' > "$CJ"
    run_reconcile
    [ "$status" -eq 0 ]
    [ "$(live)" = "alpha,beta" ]
    # Canonical shape: type/args/env always present; env passthrough literal.
    [ "$(jq -r '.mcpServers.alpha.type' "$CJ")" = "stdio" ]
    # shellcheck disable=SC2016  # asserting the literal ${BETA_KEY} passthrough was stored verbatim
    [ "$(jq -r '.mcpServers.beta.env.BETA_KEY' "$CJ")" = '${BETA_KEY}' ]
    diff <(printf 'alpha\nbeta\n') "$MANIFEST"
}

@test "reconcile: first run adopts matching live entries without re-adding" {
    jq -n '{mcpServers: {alpha: {type:"stdio", command:"alpha-bin", args:["--mcp"], env:{}}}}' > "$CJ"
    run_reconcile
    [ "$status" -eq 0 ]
    [[ "$output" == *"Adopted existing MCP: alpha"* ]]
    # alpha untouched (no add/remove call for it); beta added.
    ! grep -q "mcp add-json alpha" "$CALLS"
    grep -q "mcp add-json beta" "$CALLS"
    diff <(printf 'alpha\nbeta\n') "$MANIFEST"
}

@test "reconcile: removes a manifest-tracked MCP that left the registry" {
    jq -n '{mcpServers: {
        alpha: {type:"stdio", command:"alpha-bin", args:["--mcp"], env:{}},
        beta:  {type:"stdio", command:"npx", args:["-y","beta"], env:{BETA_KEY:"${BETA_KEY}"}},
        gone:  {type:"stdio", command:"gone-bin", args:[], env:{}}
    }}' > "$CJ"
    mkdir -p "${MANIFEST%/*}"
    printf 'alpha\nbeta\ngone\n' > "$MANIFEST"
    run_reconcile
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removing retired MCP: gone"* ]]
    [ "$(live)" = "alpha,beta" ]
    diff <(printf 'alpha\nbeta\n') "$MANIFEST"
}

@test "reconcile: never touches a hand-added live MCP outside registry and manifest" {
    jq -n '{mcpServers: {
        handmade: {type:"stdio", command:"my-thing", args:[], env:{}}
    }}' > "$CJ"
    mkdir -p "${MANIFEST%/*}"
    printf 'alpha\n' > "$MANIFEST"
    run_reconcile
    [ "$status" -eq 0 ]
    jq -e '.mcpServers.handmade' "$CJ" >/dev/null
    ! grep -q "mcp remove handmade" "$CALLS"
    [[ "$output" == *"hand-added"* ]]
    [[ "$output" == *"handmade"* ]]
}

@test "reconcile: re-adds a manifest-tracked MCP whose live config drifted" {
    jq -n '{mcpServers: {
        alpha: {type:"stdio", command:"WRONG", args:[], env:{}},
        beta:  {type:"stdio", command:"npx", args:["-y","beta"], env:{BETA_KEY:"${BETA_KEY}"}}
    }}' > "$CJ"
    mkdir -p "${MANIFEST%/*}"
    printf 'alpha\nbeta\n' > "$MANIFEST"
    run_reconcile
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updating MCP: alpha"* ]]
    grep -q "mcp remove alpha" "$CALLS"
    grep -q "mcp add-json alpha" "$CALLS"
    [ "$(jq -r '.mcpServers.alpha.command' "$CJ")" = "alpha-bin" ]
    # beta matched — untouched.
    ! grep -q "add-json beta" "$CALLS"
}

@test "reconcile: idempotent — second run performs no mutations" {
    echo '{}' > "$CJ"
    run_reconcile
    [ "$status" -eq 0 ]
    : > "$CALLS"
    run_reconcile
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}

@test "reconcile: missing claude CLI fails loud without touching anything" {
    # Exit 0 here would let chezmoi record the run_onchange as done for the
    # current mcps hash — reconcile would silently never run until the
    # registry mcps block next changes (fresh-bootstrap ordering: the claude
    # CLI may not be installed when dots sync first applies).
    echo '{"mcpServers":{}}' > "$CJ"
    local minimal="$TEST_HOME/minimal-bin"
    mkdir -p "$minimal"
    for t in bash jq dirname mkdir sort; do
        ln -s "$(command -v $t)" "$minimal/$t" 2>/dev/null || true
    done
    run bash -c "PATH='$minimal' bash -c \"source '$LIB' && claude_mcp_reconcile '$REG' '$CJ' '$MANIFEST'\""
    [ "$status" -ne 0 ]
    [[ "$output" == *"claude CLI not found"* ]]
    [ ! -f "$MANIFEST" ]
    [ "$(cat "$CJ")" = '{"mcpServers":{}}' ]
}

@test "reconcile: a failed claude mcp call leaves the manifest unchanged and exits non-zero" {
    echo '{}' > "$CJ"
    # Replace the mock with an always-failing claude.
    cat > "$TEST_HOME/fake-bin/claude" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$TEST_HOME/fake-bin/claude"
    run_reconcile
    [ "$status" -ne 0 ]
    [ ! -f "$MANIFEST" ]
    [[ "$output" == *"manifest left unchanged"* ]]
}

@test "reconcile: emptying the registry removes every manifest-tracked MCP (run_onchange shell)" {
    # The extreme deletion-propagation case: registry mcps block emptied.
    # Must run under the exact shell settings of the run_onchange script —
    # /bin/bash (3.2 on macOS) + set -euo pipefail — where an unguarded
    # empty-array expansion is an unbound-variable crash that would leave the
    # retired MCP live forever and halt chezmoi apply.
    jq -n '{mcpServers: {
        alpha: {type:"stdio", command:"alpha-bin", args:["--mcp"], env:{}}
    }}' > "$CJ"
    mkdir -p "${MANIFEST%/*}"
    printf 'alpha\n' > "$MANIFEST"
    run /bin/bash -c "set -euo pipefail; source '$LIB' && claude_mcp_reconcile '{}' '$CJ' '$MANIFEST'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removing retired MCP: alpha"* ]]
    [ "$(jq -r '.mcpServers | length' "$CJ")" = "0" ]
    # Manifest rewritten to empty (no stale names, no blank-line ghosts).
    [ -z "$(grep -v '^$' "$MANIFEST" || true)" ]
}

@test "reconcile: runs under /bin/bash 3.2 (macOS chezmoi script shell)" {
    echo '{}' > "$CJ"
    run /bin/bash -c "source '$LIB' && claude_mcp_reconcile '$REG' '$CJ' '$MANIFEST'"
    [ "$status" -eq 0 ]
    [ "$(live)" = "alpha,beta" ]
}
