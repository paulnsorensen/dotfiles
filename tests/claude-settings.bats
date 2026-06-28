#!/usr/bin/env bats
# Behavioural tests for chezmoi/dot_claude/modify_settings.json — the modify_
# script that makes ~/.claude/settings.json repo-authoritative on every apply.
#
# The script reads the live file on stdin, reads the committed authoritative
# source from $CHEZMOI_SOURCE_DIR/lib/claude-settings-authoritative.json, and
# writes the merged result to stdout. These tests drive it directly (no real
# chezmoi) by setting CHEZMOI_SOURCE_DIR to the repo's chezmoi dir.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export SCRIPT="$REAL_DOTFILES_DIR/chezmoi/dot_claude/modify_settings.json"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export AUTH="$CZ_SRC/lib/claude-settings-authoritative.json"
    OUT="$TEST_HOME/out.json"
    export OUT
}

teardown() { teardown_test_env; }

# Run modify_settings.json with $1 as stdin; stdout → $OUT, stderr → $output.
run_modify() {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' bash '$SCRIPT' <<'STDIN' >'$OUT'
$1
STDIN"
}

@test "modify_settings: empty stdin emits the authoritative source (fresh machine)" {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' bash '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    # Repo defaults present, incl. opus and the seeded official plugins.
    [ "$(jq -r '.model' "$OUT")" = "opus" ]
    [ "$(jq -r '.effortLevel' "$OUT")" = "medium" ]
    jq -e '.enabledPlugins["claude-md-management@claude-plugins-official"]' "$OUT" >/dev/null
    # Equivalent (modulo formatting) to the committed authoritative source.
    diff <(jq -S . "$AUTH") <(jq -S . "$OUT")
}

@test "modify_settings: class-a drift is overwritten from source" {
    # In-app /model + theme change must be discarded on the next apply.
    run_modify '{"model":"sonnet","theme":"light","effortLevel":"high"}'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.model' "$OUT")" = "opus" ]
    [ "$(jq -r '.theme' "$OUT")" = "dark-daltonized" ]
    [ "$(jq -r '.effortLevel' "$OUT")" = "medium" ]
}

@test "modify_settings: ap-managed keys are preserved from live, not reset to source" {
    # global@local + local marketplace + permissions.allow/deny are written by
    # `ap install global` into the live file; they must survive the apply.
    local live='{
      "model":"sonnet",
      "permissions":{"defaultMode":"plan","allow":["Bash(ls:*)"],"deny":["Bash(rm:*)"]},
      "enabledPlugins":{"global@local":true},
      "extraKnownMarketplaces":{"local":{"source":{"source":"directory","path":"/x"}}}
    }'
    run_modify "$live"
    [ "$status" -eq 0 ]
    # ap values retained
    [ "$(jq -r '.permissions.allow[0]' "$OUT")" = "Bash(ls:*)" ]
    [ "$(jq -r '.permissions.deny[0]' "$OUT")" = "Bash(rm:*)" ]
    jq -e '.enabledPlugins["global@local"]' "$OUT" >/dev/null
    jq -e '.extraKnownMarketplaces["local"]' "$OUT" >/dev/null
    # class-a still authoritative: defaultMode + model overwritten, seed plugins kept
    [ "$(jq -r '.permissions.defaultMode' "$OUT")" = "auto" ]
    [ "$(jq -r '.model' "$OUT")" = "opus" ]
    jq -e '.enabledPlugins["claude-md-management@claude-plugins-official"]' "$OUT" >/dev/null
}

@test "modify_settings: a value change to a known key is NOT treated as unknown" {
    run_modify '{"model":"sonnet"}'
    [ "$status" -eq 0 ]
}

@test "modify_settings: extra permissions.allow entries are NOT treated as unknown" {
    run_modify '{"permissions":{"allow":["A","B","C"]}}'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.permissions.allow | length' "$OUT")" = "3" ]
}

@test "modify_settings: unknown top-level key halts (non-zero, no write, named on stderr)" {
    run_modify '{"model":"opus","someNewClaudeKey":"x"}'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]                          # live left unmodified (nothing written)
    [[ "$output" == *"someNewClaudeKey"* ]]
}

@test "modify_settings: unknown nested key under a known object halts" {
    run_modify '{"permissions":{"defaultMode":"auto","newSubKey":true}}'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]
    [[ "$output" == *"permissions.newSubKey"* ]]
}

@test "modify_settings: unknown key with empty-object/array/null value still halts" {
    # Regression: a future Claude Code feature key defaulting to {}/[]/null
    # must be surfaced, not silently dropped by the merge.
    for v in '{}' '[]' 'null'; do
        run_modify "{\"model\":\"opus\",\"newFeature\":$v}"
        [ "$status" -ne 0 ] || { echo "value $v did not halt"; return 1; }
        [ ! -s "$OUT" ]
        [[ "$output" == *"newFeature"* ]]
    done
}

@test "modify_settings: empty value on a KNOWN/ap key does not falsely halt" {
    # ap may legitimately write an empty permissions.allow; must not trip the gate.
    run_modify '{"permissions":{"allow":[]}}'
    [ "$status" -eq 0 ]
}

@test "modify_settings: folding the new key into the source makes the sync pass again" {
    # Simulate the fix: a source dir whose authoritative file already carries
    # the once-unknown key. The same live input now validates and writes.
    local tmpsrc="$TEST_HOME/cz"
    mkdir -p "$tmpsrc/lib"
    jq '. + {someNewClaudeKey:"default"}' "$AUTH" > "$tmpsrc/lib/claude-settings-authoritative.json"
    run bash -c "CHEZMOI_SOURCE_DIR='$tmpsrc' bash '$SCRIPT' <<'STDIN' >'$OUT'
{\"someNewClaudeKey\":\"x\"}
STDIN"
    [ "$status" -eq 0 ]
    # Now class-a authoritative: the sync no longer halts, and the source value
    # wins (live's "x" is discarded like any other repo-owned key).
    [ "$(jq -r '.someNewClaudeKey' "$OUT")" = "default" ]
}

@test "modify_settings: missing jq passes the live file through unchanged" {
    # Restrict PATH to a bin dir without jq; symlink only the externals the
    # passthrough branch needs (bash, cat). printf/[ are bash builtins.
    local fakebin="$TEST_HOME/nojq-bin"
    mkdir -p "$fakebin"
    ln -s "$(command -v bash)" "$fakebin/bash"
    ln -s "$(command -v cat)"  "$fakebin/cat"
    local live='{"model":"sonnet","appOnly":"keepme"}'
    run bash -c "PATH='$fakebin' CHEZMOI_SOURCE_DIR='$CZ_SRC' '$fakebin/bash' '$SCRIPT' <<'STDIN' >'$OUT'
$live
STDIN"
    [ "$status" -eq 0 ]
    # Unchanged: still sonnet, still carries the app-only key (no enforcement).
    [ "$(jq -r '.model' "$OUT")" = "sonnet" ]
    [ "$(jq -r '.appOnly' "$OUT")" = "keepme" ]
}
