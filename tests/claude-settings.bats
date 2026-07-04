#!/usr/bin/env bats
# Behavioural tests for chezmoi/dot_claude/modify_settings.json — the modify_
# script that makes ~/.claude/settings.json FULLY repo-authoritative on every
# apply (spec: chezmoi-authoritative-claude, decision H1).
#
# The script reads the live file on stdin and composes the desired document
# from $CHEZMOI_SOURCE_DIR/lib/claude-settings-authoritative.json (static
# keys) + $CHEZMOI_SOURCE_DIR/.chezmoidata/claude.yaml (registry-authored
# hooks / enabledPlugins / extraKnownMarketplaces / permissions lists). Live
# drift on managed keys is WIPED; unknown live keys halt. These tests drive it
# directly (no real chezmoi) by setting CHEZMOI_SOURCE_DIR to the repo's
# chezmoi dir.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export SCRIPT="$REAL_DOTFILES_DIR/chezmoi/dot_claude/modify_settings.json"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export AUTH="$CZ_SRC/lib/claude-settings-authoritative.json"
    OUT="$TEST_HOME/out.json"
    export OUT
}

teardown() { teardown_test_env; }

# Run modify_settings.json with $1 as stdin; stdout → $OUT, stderr → $output.
run_modify() {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' <<'STDIN' >'$OUT'
$1
STDIN"
}

@test "modify_settings: empty stdin emits the composed desired document (fresh machine)" {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    # Static authoritative keys present.
    [ "$(jq -r '.model' "$OUT")" = "opus" ]
    [ "$(jq -r '.effortLevel' "$OUT")" = "medium" ]
    # Registry-authored keys composed in.
    jq -e '.enabledPlugins | has("plugin-dev@claude-plugins-official")' "$OUT" >/dev/null
    jq -e '.hooks.PreToolUse | length > 0' "$OUT" >/dev/null
    jq -e '.permissions.allow | length > 0' "$OUT" >/dev/null
    jq -e '.permissions.deny | index("Bash(sudo:*)")' "$OUT" >/dev/null
    # (${HOME} expansion in registry marketplace paths is covered by the
    # dedicated test below, now that the committed base ships no marketplace.)
}

@test "modify_settings: idempotent — feeding its own output back reproduces it" {
    bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' <'$OUT' >'$OUT.2'"
    [ "$status" -eq 0 ]
    diff <(jq -S . "$OUT") <(jq -S . "$OUT.2")
}

@test "modify_settings: class-a drift is overwritten from source" {
    # In-app /model + theme change must be discarded on the next apply.
    run_modify '{"model":"sonnet","theme":"light","effortLevel":"high"}'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.model' "$OUT")" = "opus" ]
    [ "$(jq -r '.theme' "$OUT")" = "dark-daltonized" ]
    [ "$(jq -r '.effortLevel' "$OUT")" = "medium" ]
}

@test "modify_settings: formerly-ap keys are registry-authored — live drift is WIPED" {
    # Session-granted permissions, in-app plugin enables, and stray
    # marketplaces are discarded on apply unless promoted to the registry
    # (H1). The gate does NOT halt on them (dynamic-key subtrees + array
    # entries), it wipes them.
    local live='{
      "model":"sonnet",
      "permissions":{"defaultMode":"plan","allow":["Bash(evil:*)"],"deny":[]},
      "enabledPlugins":{"global@local":true},
      "extraKnownMarketplaces":{"local":{"source":{"source":"directory","path":"/x"}}}
    }'
    run_modify "$live"
    [ "$status" -eq 0 ]
    # live drift gone
    run jq -e '.permissions.allow | index("Bash(evil:*)")' "$OUT"
    [ "$status" -ne 0 ]
    run jq -e '.enabledPlugins["global@local"]' "$OUT"
    [ "$status" -ne 0 ]
    run jq -e '.extraKnownMarketplaces["local"]' "$OUT"
    [ "$status" -ne 0 ]
    # registry values authored in
    [ "$(jq -r '.permissions.defaultMode' "$OUT")" = "auto" ]
    [ "$(jq -r '.model' "$OUT")" = "opus" ]
    jq -e '.enabledPlugins | has("plugin-dev@claude-plugins-official")' "$OUT" >/dev/null
    jq -e '.permissions.deny | length > 0' "$OUT" >/dev/null
}

@test "modify_settings: a value change to a known key is NOT treated as unknown" {
    run_modify '{"model":"sonnet"}'
    [ "$status" -eq 0 ]
}

@test "modify_settings: extra permissions.allow entries do not halt (but are wiped)" {
    run_modify '{"permissions":{"allow":["A","B","C"]}}'
    [ "$status" -eq 0 ]
    # Output is the registry list, not the live one.
    run jq -e '.permissions.allow | index("A")' "$OUT"
    [ "$status" -ne 0 ]
    jq -e '.permissions.allow | length > 3' "$OUT" >/dev/null
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
    mkdir -p "$tmpsrc/lib" "$tmpsrc/.chezmoidata"
    cp "$CZ_SRC/.chezmoidata/claude.yaml" "$tmpsrc/.chezmoidata/claude.yaml"
    jq '. + {someNewClaudeKey:"default"}' "$AUTH" > "$tmpsrc/lib/claude-settings-authoritative.json"
    run bash -c "CHEZMOI_SOURCE_DIR='$tmpsrc' sh '$SCRIPT' <<'STDIN' >'$OUT'
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
    # Skipped enforcement is signalled on stderr, not silent — a no-op sync must
    # not look identical to an enforced one.
    [[ "$output" == *"jq missing"* ]]
}

# ── real-chezmoi integration: the safety guarantee ──────────────────────────
# The unit tests above prove the script exits non-zero on an unknown key. These
# prove chezmoi HONOURS that exit — it halts apply and leaves the live target
# untouched (does not write the script's empty stdout over the file). That
# coupling is the whole point of the unknown-key gate, and chezmoi's contract
# for modify_ scripts, so it gets locked end-to-end.

# Build a minimal chezmoi source (modify_ script + authoritative file) and dest,
# echo the apply command via $output through a config file. Sets CZ_APPLY.
setup_chezmoi_apply_env() {
    CZ_INT_SRC="$TEST_HOME/int-src"
    CZ_INT_DEST="$TEST_HOME/int-dest"
    mkdir -p "$CZ_INT_SRC/dot_claude" "$CZ_INT_SRC/lib" "$CZ_INT_SRC/.chezmoidata" "$CZ_INT_DEST/.claude" "$TEST_HOME/int-cfg"
    cp "$SCRIPT" "$CZ_INT_SRC/dot_claude/modify_settings.json"
    cp "$AUTH"   "$CZ_INT_SRC/lib/claude-settings-authoritative.json"
    cp "$CZ_SRC/.chezmoidata/claude.yaml" "$CZ_INT_SRC/.chezmoidata/claude.yaml"
    printf 'lib/\n' > "$CZ_INT_SRC/.chezmoiignore"
    cat > "$TEST_HOME/int-cfg/chezmoi.toml" <<TOML
sourceDir = "$CZ_INT_SRC"
destDir = "$CZ_INT_DEST"
TOML
    SETTINGS="$CZ_INT_DEST/.claude/settings.json"
}

cz_apply() {
    run chezmoi apply --config "$TEST_HOME/int-cfg/chezmoi.toml" \
        --destination "$CZ_INT_DEST" --no-tty
}

@test "modify_settings (chezmoi apply): fresh machine writes the authoritative source" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    setup_chezmoi_apply_env
    cz_apply
    [ "$status" -eq 0 ]
    [ "$(jq -r .model "$SETTINGS")" = "opus" ]
    # lib/ is .chezmoiignore'd — the authoritative source is never deployed.
    [ ! -e "$CZ_INT_DEST/lib" ]
}

@test "modify_settings (chezmoi apply): unknown key HALTS apply and leaves the live file untouched" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    setup_chezmoi_apply_env
    # seed a valid live file, then inject an app key the repo does not know
    printf '%s\n' '{"model":"opus","appAddedUnknown":"x"}' > "$SETTINGS"
    local before; before=$(cat "$SETTINGS")
    cz_apply
    [ "$status" -ne 0 ]                                   # chezmoi apply failed
    [ "$(cat "$SETTINGS")" = "$before" ]                  # live file NOT clobbered
    [[ "$output" == *"appAddedUnknown"* ]]                # offending key surfaced
}

# ── post-apply schema validator ─────────────────────────────────────────────
# Prove the run_after validator actually REJECTS a bad live file (not just that
# the script exists + mentions check-jsonschema). Locks that a regression which
# neuters the check — wrong flag, swallowed exit — turns the suite red.

@test "validate-claude-settings: rejects a type-invalid live settings.json, accepts a valid one" {
    command -v check-jsonschema >/dev/null 2>&1 || skip "check-jsonschema not installed"
    local validator="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_after_validate-claude-settings.sh"
    mkdir -p "$TEST_HOME/.claude"

    # Gross type error: the schema root is an object, not an array — must reject.
    printf '%s\n' '[]' > "$TEST_HOME/.claude/settings.json"
    run env HOME="$TEST_HOME" bash "$validator"
    [ "$status" -ne 0 ]

    # Control: the committed authoritative source is valid and must pass. A
    # schema-fetch/network failure trips this branch loudly, so the negative
    # case above can't pass for the wrong reason.
    cp "$AUTH" "$TEST_HOME/.claude/settings.json"
    run env HOME="$TEST_HOME" bash "$validator"
    [ "$status" -eq 0 ]
}

@test "modify_settings: permissions.ask/additionalDirectories do not halt but are registry-authored" {
    # Both buckets exist in the registry (possibly empty), so live entries are
    # legitimate key-paths (no halt) — and are wiped like allow/deny drift.
    run_modify '{"permissions":{"ask":["Bash(rm:*)"],"additionalDirectories":["/tmp"]}}'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.permissions.ask | length' "$OUT")" = "0" ]
    [ "$(jq -r '.permissions.additionalDirectories | length' "$OUT")" = "0" ]
    # class-a still authoritative
    [ "$(jq -r '.permissions.defaultMode' "$OUT")" = "auto" ]
}

# ── plugin-registry overlay composition ─────────────────────────────────────
# modify_settings.json is the single writer of enabledPlugins /
# extraKnownMarketplaces: claude.yaml base + a gate-filtered overlay derived
# from claude/plugins/registry.yaml. These lock the overlay behaviour.

# Run modify_ with a controlled gate environment (all three local gates cleared
# first, then $1 applied verbatim as `env` assignments). Uses the REAL repo
# registry via $CZ_SRC/../claude/plugins/registry.yaml.
run_modify_gated() {
    run bash -c "env -u TODOIST -u CHEESE_FLOW -u VAUDEVILLE $1 \
        CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
}

@test "modify_settings: gate-open overlays todoist-flow into enabledPlugins + its marketplace" {
    run_modify_gated 'TODOIST=true'
    [ "$status" -eq 0 ]
    # enabledPlugins gains the gated plugin with its registry `load` value.
    [ "$(jq -r '.enabledPlugins["todoist-flow@todoist-flow"]' "$OUT")" = "true" ]
    # extraKnownMarketplaces gains its directory source, path resolved to the
    # repo-relative source dir (registry path: claude/plugins/local/todoist-flow).
    [ "$(jq -r '.extraKnownMarketplaces["todoist-flow"].source.source' "$OUT")" = "directory" ]
    run jq -r '.extraKnownMarketplaces["todoist-flow"].source.path' "$OUT"
    [[ "$output" == */claude/plugins/local/todoist-flow ]]
    # Official plugins are registry-overlaid with load: false (profile-scoped).
    [ "$(jq -r '.enabledPlugins["skill-creator@claude-plugins-official"]' "$OUT")" = "false" ]
    # (native marketplaces — milknado, hallouminate — are covered by the native
    # overlay tests below; they warn+skip here since no cache exists in the sandbox.)
}

@test "modify_settings: gate-closed excludes the gated plugin from both keys" {
    run_modify_gated ''
    [ "$status" -eq 0 ]
    run jq -e '.enabledPlugins["todoist-flow@todoist-flow"]' "$OUT"
    [ "$status" -ne 0 ]
    run jq -e '.extraKnownMarketplaces["todoist-flow"]' "$OUT"
    [ "$status" -ne 0 ]
    # Official plugins remain, disabled (load: false — profile-scoped).
    [ "$(jq -r '.enabledPlugins["skill-creator@claude-plugins-official"]' "$OUT")" = "false" ]
}

# Build a custom CHEZMOI_SOURCE_DIR at $TEST_HOME/root/chezmoi with a sibling
# claude/plugins/registry.yaml holding $1 as its plugins: body. Sets CUSTOM_SRC.
setup_custom_registry() {
    local root="$TEST_HOME/root"
    CUSTOM_SRC="$root/chezmoi"
    mkdir -p "$CUSTOM_SRC/lib" "$CUSTOM_SRC/.chezmoidata" "$root/claude/plugins"
    cp "$AUTH" "$CUSTOM_SRC/lib/claude-settings-authoritative.json"
    cp "$CZ_SRC/.chezmoidata/claude.yaml" "$CUSTOM_SRC/.chezmoidata/claude.yaml"
    printf 'plugins:\n%s\n' "$1" > "$root/claude/plugins/registry.yaml"
}

@test "modify_settings: '~/' marketplace path resolves against HOME" {
    mkdir -p "$TEST_HOME/mymkt"
    setup_custom_registry '  mymkt@mymkt:
    load: true
    path: ~/mymkt
    gate: MYGATE'
    run bash -c "env -u TODOIST MYGATE=true \
        CHEZMOI_SOURCE_DIR='$CUSTOM_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.extraKnownMarketplaces["mymkt"].source.path' "$OUT")" = "$TEST_HOME/mymkt" ]
}

@test "modify_settings: marketplace with a nonexistent path is skipped with a warning" {
    setup_custom_registry '  ghost@ghost:
    load: true
    path: ~/does-not-exist
    gate: MYGATE'
    run bash -c "env -u TODOIST MYGATE=true \
        CHEZMOI_SOURCE_DIR='$CUSTOM_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    # The skip is announced on stderr (checked before any `run jq`, which would
    # overwrite $output).
    [[ "$output" == *"path not found"* ]]
    # enabledPlugins still gains the entry (no path check there) …
    [ "$(jq -r '.enabledPlugins["ghost@ghost"]' "$OUT")" = "true" ]
    # … but the marketplace is skipped.
    run jq -e '.extraKnownMarketplaces["ghost"]' "$OUT"
    [ "$status" -ne 0 ]
}

@test "modify_settings: missing plugin registry falls back to claude.yaml-only with a warning" {
    local root="$TEST_HOME/noreg"
    local src="$root/chezmoi"
    mkdir -p "$src/lib" "$src/.chezmoidata"
    cp "$AUTH" "$src/lib/claude-settings-authoritative.json"
    cp "$CZ_SRC/.chezmoidata/claude.yaml" "$src/.chezmoidata/claude.yaml"
    # No $root/claude/plugins/registry.yaml.
    run bash -c "env -u TODOIST CHEZMOI_SOURCE_DIR='$src' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"plugin registry not found"* ]]
    # claude.yaml base is empty — no official plugins without the registry.
    run jq -e '.enabledPlugins["skill-creator@claude-plugins-official"]' "$OUT"
    [ "$status" -ne 0 ]
    run jq -e '.enabledPlugins["todoist-flow@todoist-flow"]' "$OUT"
    [ "$status" -ne 0 ]
}

@test "modify_settings: malformed (non-JSON) live file halts with guidance, not an opaque jq error" {
    run_modify '[ this is not json'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]
    [[ "$output" == *"not a JSON object"* ]]
}

@test "modify_settings: a non-object JSON live file (top-level array) halts with guidance" {
    run_modify '[]'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]
    [[ "$output" == *"not a JSON object"* ]]
}

# ── native-plugin overlay (agents/plugins/registry.yaml) ────────────────────
# modify_settings.json overlays native-claude entries onto enabledPlugins /
# extraKnownMarketplaces, keyed by each marketplace.json .name. These lock the
# native-set resolution, the marketplace-name keying, and the warn+skip path.

# Build a CHEZMOI_SOURCE_DIR at $TEST_HOME/nroot/chezmoi with a sibling
# agents/plugins/registry.yaml holding $1 as its plugins: body. Sets NSRC.
setup_native_registry() {
    local root="$TEST_HOME/nroot"
    NSRC="$root/chezmoi"
    mkdir -p "$NSRC/lib" "$NSRC/.chezmoidata" "$root/agents/plugins"
    cp "$AUTH" "$NSRC/lib/claude-settings-authoritative.json"
    cp "$CZ_SRC/.chezmoidata/claude.yaml" "$NSRC/.chezmoidata/claude.yaml"
    printf 'plugins:\n%s\n' "$1" > "$root/agents/plugins/registry.yaml"
}

# mk_git_cache <key> <marketplace-name>: a git-style cache under
# ~/.cache/ap/plugins/<key> (HOME is the sandbox) with a marketplace.json.
mk_git_cache() {
    local dir="$HOME/.cache/ap/plugins/$1/.claude-plugin"
    mkdir -p "$dir"
    printf '{"name": "%s"}\n' "$2" > "$dir/marketplace.json"
}

run_native() {
    run bash -c "env -u TODOIST CHEZMOI_SOURCE_DIR='$NSRC' sh '$SCRIPT' </dev/null >'$OUT'"
}

@test "modify_settings: native git plugin overlays both keys, keyed by marketplace.json name (key≠name)" {
    mk_git_cache widget acme
    setup_native_registry '  widget:
    git: https://example.com/widget
    harnesses: [claude, codex]
    native: true'
    run_native
    [ "$status" -eq 0 ]
    # enabledPlugins keyed <key>@<name>; marketplace keyed by <name>.
    [ "$(jq -r '.enabledPlugins["widget@acme"]' "$OUT")" = "true" ]
    [ "$(jq -r '.extraKnownMarketplaces["acme"].source.source' "$OUT")" = "directory" ]
    [ "$(jq -r '.extraKnownMarketplaces["acme"].source.path' "$OUT")" = "$HOME/.cache/ap/plugins/widget" ]
    # The YAML key is NOT used as the marketplace name.
    run jq -e '.extraKnownMarketplaces["widget"]' "$OUT"
    [ "$status" -ne 0 ]
}

@test "modify_settings: native-set resolution — true∩harnesses, list-without-claude, deprecated alias" {
    mk_git_cache alpha alpha
    mk_git_cache delta delta
    mk_git_cache beta beta
    setup_native_registry '  alpha:
    git: https://example.com/alpha
    harnesses: [claude, codex]
    native: true
  beta:
    git: https://example.com/beta
    harnesses: [claude, copilot]
    native: [copilot]
  delta:
    git: https://example.com/delta
    harnesses: [codex]
    claude_native: true'
    run_native
    [ "$status" -eq 0 ]
    # native: true → claude ∈ (harnesses ∩ drivable) → overlaid.
    [ "$(jq -r '.enabledPlugins["alpha@alpha"]' "$OUT")" = "true" ]
    # deprecated claude_native: true → claude OR'd in → overlaid.
    [ "$(jq -r '.enabledPlugins["delta@delta"]' "$OUT")" = "true" ]
    # native: [copilot] (claude absent) → NOT overlaid, on either key.
    run jq -e '.enabledPlugins["beta@beta"]' "$OUT"
    [ "$status" -ne 0 ]
    run jq -e '.extraKnownMarketplaces["beta"]' "$OUT"
    [ "$status" -ne 0 ]
}

@test "modify_settings: native plugin with a missing cache warns, skips, leaves valid JSON, other entries intact" {
    mk_git_cache present present
    setup_native_registry '  present:
    git: https://example.com/present
    harnesses: [claude]
    native: true
  absent:
    git: https://example.com/absent
    harnesses: [claude]
    native: true'
    run_native
    [ "$status" -eq 0 ]
    # The missing entry warns on stderr and is skipped.
    [[ "$output" == *"skipping native plugin absent"* ]]
    [[ "$output" == *"marketplace.json not found"* ]]
    # Output is still valid JSON; the present entry is overlaid, the absent one not.
    jq -e . "$OUT" >/dev/null
    [ "$(jq -r '.enabledPlugins["present@present"]' "$OUT")" = "true" ]
    run jq -e '.enabledPlugins["absent@absent"]' "$OUT"
    [ "$status" -ne 0 ]
}

@test "modify_settings: \${HOME} token in a claude.yaml marketplace path is expanded" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    local src="$TEST_HOME/hz/chezmoi"
    mkdir -p "$src/lib" "$src/.chezmoidata"
    cp "$AUTH" "$src/lib/claude-settings-authoritative.json"
    # shellcheck disable=SC2016  # literal ${HOME} token, expanded by modify_settings, not the shell
    yq '.claude.extraKnownMarketplaces.tok.source.source = "directory"
        | .claude.extraKnownMarketplaces.tok.source.path = "${HOME}/tok"' \
        "$CZ_SRC/.chezmoidata/claude.yaml" > "$src/.chezmoidata/claude.yaml"
    run bash -c "env -u TODOIST CHEZMOI_SOURCE_DIR='$src' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    # The literal \${HOME} token is expanded to the real HOME by the expand walk.
    [ "$(jq -r '.extraKnownMarketplaces["tok"].source.path' "$OUT")" = "$HOME/tok" ]
}

@test "modify_settings: SSL_CERT_FILE dropped from desired on Linux; live copy wiped without halting" {
    [ "$(uname -s)" = "Darwin" ] && skip "macOS keeps the pin"
    # Live file carrying the old pin must not trip the unknown-key gate.
    run_modify '{"env":{"ENABLE_TOOL_SEARCH":"true","SSL_CERT_FILE":"/etc/ssl/cert.pem"}}'
    [ "$status" -eq 0 ]
    jq -e '.env | has("SSL_CERT_FILE") | not' "$OUT" >/dev/null
}

@test "modify_settings: SSL_CERT_FILE kept on macOS" {
    [ "$(uname -s)" != "Darwin" ] && skip "Linux drops the pin"
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.env.SSL_CERT_FILE' "$OUT")" = "/etc/ssl/cert.pem" ]
}
