#!/usr/bin/env bats
# Behavioural tests for chezmoi/dot_omp/private_agent/modify_config.yml — the
# modify_ script that makes ~/.omp/agent/config.yml repo-authoritative on every
# apply, mirroring the claude wholesale-authoring recipe.
#
# The script reads the live file on stdin and emits the desired document
# composed from the `omp.config` subtree of
# $CHEZMOI_SOURCE_DIR/.chezmoidata/omp.yaml. Live drift on managed keys is
# WIPED; setupVersion (machine state) is preserved; unknown live keys halt.
# These tests drive it directly (no real chezmoi) by setting
# CHEZMOI_SOURCE_DIR to the repo's chezmoi dir.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export SCRIPT="$REAL_DOTFILES_DIR/chezmoi/dot_omp/private_agent/modify_config.yml"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    OUT="$TEST_HOME/out.yml"
    export OUT
}

teardown() { teardown_test_env; }

# Run modify_config.yml with $1 as stdin; stdout → $OUT, stderr → $output.
run_modify() {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' <<'STDIN' >'$OUT'
$1
STDIN"
}

@test "omp-config: empty stdin emits the desired document (fresh machine)" {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    [ "$(yq '.symbolPreset' "$OUT")" = "nerd" ]
    [ "$(yq '.disabledProviders | length' "$OUT")" = "1" ]
    [ "$(yq '.disabledProviders | .[0]' "$OUT")" = "claude" ]
    # setupVersion is machine state — never authored on a fresh machine.
    [ "$(yq 'has("setupVersion")' "$OUT")" = "false" ]
}

@test "omp-config: managed-key drift is wiped, setupVersion preserved" {
    # In-app symbolPreset change + a hand-edited (emptied) disabledProviders
    # list must be driven back to the registry values; setupVersion survives.
    run_modify 'symbolPreset: ascii
disabledProviders: []
setupVersion: 1'
    [ "$status" -eq 0 ]
    [ "$(yq '.symbolPreset' "$OUT")" = "nerd" ]
    [ "$(yq '.disabledProviders | length' "$OUT")" = "1" ]
    [ "$(yq '.disabledProviders | .[0]' "$OUT")" = "claude" ]
    [ "$(yq '.setupVersion' "$OUT")" = "1" ]
}

@test "omp-config: unknown key halts (non-zero, no write, key + registry named on stderr)" {
    run_modify 'symbolPreset: nerd
theme: dark'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]                                   # live left unmodified (nothing written)
    [[ "$output" == *"theme"* ]]                      # offending key surfaced
    [[ "$output" == *".chezmoidata/omp.yaml"* ]]      # registry path named
}

@test "omp-config: corrupt (non-map) live file halts with guidance" {
    run_modify '[1, 2, 3]'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]
    [[ "$output" == *"not a YAML map"* ]]
}

@test "omp-config: unparseable live file halts with guidance" {
    run_modify 'foo: [bar'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]
    [[ "$output" == *"not a YAML map"* ]]
}

@test "omp-config: missing yq passes the live file through unchanged" {
    # Restrict PATH to a bin dir without yq/jq; symlink only the externals the
    # passthrough branch needs (bash, cat). printf/[ are bash builtins.
    local fakebin="$TEST_HOME/noyq-bin"
    mkdir -p "$fakebin"
    ln -s "$(command -v bash)" "$fakebin/bash"
    ln -s "$(command -v cat)"  "$fakebin/cat"
    local live='symbolPreset: ascii'
    run bash -c "PATH='$fakebin' CHEZMOI_SOURCE_DIR='$CZ_SRC' '$fakebin/bash' '$SCRIPT' <<'STDIN' >'$OUT'
$live
STDIN"
    [ "$status" -eq 0 ]
    # Unchanged: still the live ascii value, no enforcement applied.
    [ "$(cat "$OUT")" = "symbolPreset: ascii" ]
    # Skipped enforcement is signalled on stderr, not silent.
    [[ "$output" == *"yq missing"* ]]
}

@test "omp-config: missing registry file halts non-zero" {
    local tmpsrc="$TEST_HOME/no-reg"
    mkdir -p "$tmpsrc/.chezmoidata"   # exists, but omp.yaml absent
    run bash -c "CHEZMOI_SOURCE_DIR='$tmpsrc' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"registry missing"* ]]
}

@test "omp-config: registry lacking .omp.config halts (schema error names registry)" {
    # Registry file present but the omp.config subtree is absent → yq yields
    # `null`. Without validation the script would write the literal `null`
    # document (fresh machine) or misattribute the null merge to the user's
    # keys (existing machine). It must halt with a registry/schema error.
    local tmpsrc="$TEST_HOME/no-config"
    mkdir -p "$tmpsrc/.chezmoidata"
    printf 'omp:\n  other: value\n' >"$tmpsrc/.chezmoidata/omp.yaml"
    run bash -c "CHEZMOI_SOURCE_DIR='$tmpsrc' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]                                   # nothing written
    [[ "$output" == *".omp.config"* ]]                # the missing key named
    [[ "$output" == *".chezmoidata/omp.yaml"* ]]      # registry path named
}
