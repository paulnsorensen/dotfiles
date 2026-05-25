#!/usr/bin/env bats
#
# Core tests for agent-profile/lib/* (parse, discover, manifest).
# Render + CLI tests live in sibling .bats files.

load test_helper

setup() {
    setup_test_env

    AP_DIR="$REAL_DOTFILES_DIR/agent-profile"
    # shellcheck source=../agent-profile/lib/parse.sh
    source "$AP_DIR/lib/parse.sh"
    # shellcheck source=../agent-profile/lib/discover.sh
    source "$AP_DIR/lib/discover.sh"
    # shellcheck source=../agent-profile/lib/manifest.sh
    source "$AP_DIR/lib/manifest.sh"

    # Sandbox lookup roots so PWD/.agent-profiles and the real
    # $DOTFILES_DIR/profiles tree do not bleed into the test.
    PROFILE_ROOT="$TEST_HOME/profiles"
    mkdir -p "$PROFILE_ROOT"
    export AP_EXTRA_SEARCH_PATHS="$PROFILE_ROOT"
    export DOTFILES_DIR="$TEST_HOME"   # forces global root to a known empty path
    cd "$TEST_HOME" || return
}

teardown() {
    teardown_test_env
}

# Materializes a profile dir under $PROFILE_ROOT/<name>/ with the
# given profile.yaml contents.
make_profile() {
    local name="$1" yaml="$2"
    local dir="$PROFILE_ROOT/$name"
    mkdir -p "$dir"
    printf '%s\n' "$yaml" > "$dir/profile.yaml"
    return 0
}

# ─── ap_parse_one ───────────────────────────────────────────────────

@test "ap_parse_one: defaults all sections to empty arrays/object" {
    make_profile minimal "name: minimal
description: tiny"
    run ap_parse_one "$PROFILE_ROOT/minimal"
    assert_success
    [[ $(jq -r '.name' <<<"$output") == "minimal" ]]
    [[ $(jq -r '.mcps | length' <<<"$output")     == "0" ]]
    [[ $(jq -r '.agents | length' <<<"$output")   == "0" ]]
    [[ $(jq -r '.skills | length' <<<"$output")   == "0" ]]
    [[ $(jq -r '.commands | length' <<<"$output") == "0" ]]
    [[ $(jq -r '.hooks | length' <<<"$output")    == "0" ]]
}

@test "ap_parse_one: injects _source_dir into every item" {
    make_profile srctest "name: srctest
agents:
  - name: foo
    body_path: agents/foo.md
hooks:
  - event: PreToolUse
    script: hooks/x.sh"
    run ap_parse_one "$PROFILE_ROOT/srctest"
    assert_success
    [[ $(jq -r '.agents[0]._source_dir' <<<"$output") == "$PROFILE_ROOT/srctest" ]]
    [[ $(jq -r '.hooks[0]._source_dir'  <<<"$output") == "$PROFILE_ROOT/srctest" ]]
}

@test "ap_parse_one: missing name field fails loudly" {
    make_profile nameless "description: noname"
    run ap_parse_one "$PROFILE_ROOT/nameless"
    assert_failure
    assert_output_contains "missing required field 'name'"
}

# ─── input validation (path traversal / shell-meta guards) ──────────

@test "ap_parse_one: profile name with shell-meta fails loudly" {
    make_profile bad "name: bad\$name"
    run ap_parse_one "$PROFILE_ROOT/bad"
    assert_failure
    assert_output_contains "invalid profile name"
}

@test "ap_parse_one: item name with shell-meta fails loudly" {
    make_profile shellmeta "name: shellmeta
agents:
  - name: 'a;b'
    body_path: agents/a.md"
    run ap_parse_one "$PROFILE_ROOT/shellmeta"
    assert_failure
    assert_output_contains "invalid item name"
}

@test "ap_parse_one: body_path with .. traversal fails loudly" {
    make_profile traverse "name: traverse
agents:
  - name: a
    body_path: ../../etc/passwd"
    run ap_parse_one "$PROFILE_ROOT/traverse"
    assert_failure
    assert_output_contains "invalid body_path"
    assert_output_contains "must not contain '..'"
}

@test "ap_parse_one: absolute body_path fails loudly" {
    make_profile absolute "name: absolute
agents:
  - name: a
    body_path: /etc/passwd"
    run ap_parse_one "$PROFILE_ROOT/absolute"
    assert_failure
    assert_output_contains "invalid body_path"
    assert_output_contains "must be relative"
}

@test "ap_parse_one: hook script with .. traversal fails loudly" {
    make_profile hooktraverse "name: hooktraverse
hooks:
  - event: SessionStart
    script: ../outside.sh"
    run ap_parse_one "$PROFILE_ROOT/hooktraverse"
    assert_failure
    assert_output_contains "invalid script"
    assert_output_contains "must not contain '..'"
}

@test "ap_parse_one: skill path with .. traversal fails loudly" {
    make_profile skilltraverse "name: skilltraverse
skills:
  - name: s
    path: skills/../../escape"
    run ap_parse_one "$PROFILE_ROOT/skilltraverse"
    assert_failure
    assert_output_contains "invalid path"
}

@test "ap_parse_one: dots-only names that aren't '..' still pass" {
    # 'foo..bar' has a '..' substring but no '..' path component — must
    # be accepted so legitimate names like 'a..b' (allowed by the regex)
    # round-trip cleanly.
    make_profile dots "name: dots
agents:
  - name: a..b
    body_path: agents/a..b.md"
    run ap_parse_one "$PROFILE_ROOT/dots"
    assert_success
}

@test "ap_parse_one: bare '..' name is rejected (escapes plugin root)" {
    # The regex accepts '..' (two allowed chars). We also reject the
    # literal so a profile or item name can't resolve to a parent dir
    # component at mkdir/cp time.
    make_profile dotdot "name: '..'"
    run ap_parse_one "$PROFILE_ROOT/dotdot"
    assert_failure
    assert_output_contains "must not be '.' or '..'"
}

@test "ap_parse_one: bare '.' item name is rejected" {
    make_profile dot "name: dot
agents:
  - name: '.'
    body_path: agents/x.md"
    run ap_parse_one "$PROFILE_ROOT/dot"
    assert_failure
    assert_output_contains "must not be '.' or '..'"
}

# ─── ap_parse_manifest (includes) ───────────────────────────────────

@test "ap_parse_manifest: include concatenates arrays (includes first)" {
    make_profile base "name: base
agents:
  - name: a
settings:
  permissions_allow: [base-perm]"
    make_profile leaf "name: leaf
include: [base]
agents:
  - name: b
settings:
  permissions_allow: [leaf-perm]"

    run ap_parse_manifest "$PROFILE_ROOT/leaf"
    assert_success
    [[ $(jq -r '.name' <<<"$output") == "leaf" ]]
    [[ $(jq -r '.agents[0].name' <<<"$output") == "a" ]]
    [[ $(jq -r '.agents[1].name' <<<"$output") == "b" ]]
    [[ $(jq -r '.settings.permissions_allow | length' <<<"$output") == "2" ]]
}

@test "ap_parse_manifest: permissions de-dup via unique" {
    make_profile base "name: base
settings:
  permissions_allow: [a, b]"
    make_profile leaf "name: leaf
include: [base]
settings:
  permissions_allow: [b, c]"
    run ap_parse_manifest "$PROFILE_ROOT/leaf"
    assert_success
    [[ $(jq -r '.settings.permissions_allow | length' <<<"$output") == "3" ]]
}

@test "ap_parse_manifest: include cycle errors out cleanly" {
    make_profile a "name: a
include: [b]"
    make_profile b "name: b
include: [a]"
    run ap_parse_manifest "$PROFILE_ROOT/a"
    assert_failure
    assert_output_contains "cycle detected"
}

@test "ap_parse_manifest: diamond DAG (A→{B,C}, B→D, C→D) is allowed" {
    # Regression for Copilot's claim that _AP_VISITED would falsely
    # report a cycle on the second branch sharing D. It doesn't:
    # recursive calls run via \$(...) subshells, so _AP_VISITED
    # modifications are scoped to each subshell. The current-stack
    # semantics fall out for free; the global accumulator concern is
    # cosmetic. Locks the behaviour so a refactor away from subshell
    # recursion can't silently regress it.
    make_profile dag_a "name: dag_a
include: [dag_b, dag_c]"
    make_profile dag_b "name: dag_b
include: [dag_d]"
    make_profile dag_c "name: dag_c
include: [dag_d]"
    make_profile dag_d "name: dag_d
description: shared base"
    run ap_parse_manifest "$PROFILE_ROOT/dag_a"
    assert_success
    [[ $(jq -r '.name' <<<"$output") == "dag_a" ]]
}

@test "ap_parse_manifest: missing include errors with profile name" {
    make_profile orphan "name: orphan
include: [nonexistent]"
    run ap_parse_manifest "$PROFILE_ROOT/orphan"
    assert_failure
    assert_output_contains "include 'nonexistent' not found"
}

# ─── ap_find_profile_dir / discover ─────────────────────────────────

@test "ap_find_profile_dir: returns the matching directory" {
    make_profile foo "name: foo"
    run ap_find_profile_dir foo
    assert_success
    [[ "$output" == "$PROFILE_ROOT/foo" ]]
}

@test "ap_find_profile_dir: missing profile returns nonzero" {
    run ap_find_profile_dir notthere
    assert_failure
}

@test "ap_find_profile_dir: per-repo .agent-profiles wins over global" {
    mkdir -p "$PROFILE_ROOT/dup"
    cat > "$PROFILE_ROOT/dup/profile.yaml" <<EOF
name: dup
description: global
EOF
    mkdir -p "$TEST_HOME/.agent-profiles/dup"
    cat > "$TEST_HOME/.agent-profiles/dup/profile.yaml" <<EOF
name: dup
description: local
EOF
    unset AP_EXTRA_SEARCH_PATHS
    export DOTFILES_DIR="$TEST_HOME/global-root"
    mkdir -p "$DOTFILES_DIR/profiles"
    cp -R "$PROFILE_ROOT/dup" "$DOTFILES_DIR/profiles/"
    cd "$TEST_HOME" || return
    run ap_find_profile_dir dup
    assert_success
    [[ "$output" == "$TEST_HOME/.agent-profiles/dup" ]]
}

@test "ap_list_profiles: emits one row per discoverable profile" {
    make_profile a "name: a"
    make_profile b "name: b"
    run ap_list_profiles
    assert_success
    [[ $(grep -c '^a	' <<<"$output") == "1" ]]
    [[ $(grep -c '^b	' <<<"$output") == "1" ]]
}

# ─── manifest ───────────────────────────────────────────────────────

@test "manifest: record/list/clear round-trip" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t"
    ap_manifest_record_file "$t" rust ".claude/foo.md"
    ap_manifest_record_file "$t" rust ".claude/bar.md"
    run ap_manifest_files "$t" rust
    assert_success
    assert_output_contains ".claude/foo.md"
    assert_output_contains ".claude/bar.md"
    ap_manifest_clear "$t" rust
    run ap_manifest_files "$t" rust
    assert_success
    [[ -z "$output" ]]
}

@test "manifest: merged_json persists and round-trips" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t"
    ap_manifest_record_merged_json "$t" rust '{"name":"rust","mcps":[]}'
    run ap_manifest_merged_json "$t" rust
    assert_success
    [[ $(jq -r '.name' <<<"$output") == "rust" ]]
}

# ─── manifest correctness: ref-counting (Bug 1) ─────────────────────

@test "manifest: ap_manifest_other_profiles_claim_file: true when shared" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t"
    # Both profiles A and B record the same shared file.
    ap_manifest_record_file "$t" alpha ".mcp.json"
    ap_manifest_record_file "$t" beta  ".mcp.json"
    # When uninstalling alpha, beta still claims `.mcp.json`.
    run ap_manifest_other_profiles_claim_file "$t" alpha ".mcp.json"
    assert_success
}

@test "manifest: ap_manifest_other_profiles_claim_file: false when no other claimant" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t"
    ap_manifest_record_file "$t" alpha ".mcp.json"
    # Only alpha claims it.
    run ap_manifest_other_profiles_claim_file "$t" alpha ".mcp.json"
    assert_failure
}

@test "manifest: ap_manifest_other_profiles_claim_file: false when current profile is the only listed" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t"
    ap_manifest_record_file "$t" alpha ".claude/agents/shared.md"
    ap_manifest_record_file "$t" beta  ".something-else.md"
    # alpha claims `.claude/agents/shared.md`; beta does not.
    run ap_manifest_other_profiles_claim_file "$t" alpha ".claude/agents/shared.md"
    assert_failure
}

@test "manifest: ref-counting proves shared .mcp.json survives one-profile uninstall" {
    # End-to-end shape: install A (writes .mcp.json), install B (writes
    # .mcp.json), uninstall A using the ref-counted decision — the file
    # stays because B still claims it.
    local t="$TEST_HOME/tgt"
    mkdir -p "$t"
    # Simulate renderers writing the shared file.
    echo '{"mcpServers":{"x":{"command":"a"}}}' > "$t/.mcp.json"
    ap_manifest_record_file "$t" alpha ".mcp.json"
    # B overwrites with merged content (mimicking renderer merge).
    echo '{"mcpServers":{"x":{"command":"b"}}}' > "$t/.mcp.json"
    ap_manifest_record_file "$t" beta ".mcp.json"

    # Mimic the cmd_uninstall decision: only rm if no other claimant.
    local f abs
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ap_manifest_other_profiles_claim_file "$t" alpha "$f"; then
            continue
        fi
        abs="$t/$f"
        [[ -e "$abs" || -L "$abs" ]] && rm -rf -- "$abs"
    done < <(ap_manifest_files "$t" alpha)
    ap_manifest_clear "$t" alpha

    [[ -f "$t/.mcp.json" ]]
    # Beta's content still on disk.
    run cat "$t/.mcp.json"
    assert_output_contains '"command":"b"'
}

# ─── manifest correctness: orphan cleanup on re-install (Bug 2) ─────

@test "manifest: ap_manifest_diff_and_clean: removes dropped files from disk" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.claude"
    # Initial install: profile owns two files.
    touch "$t/.claude/foo.md" "$t/.claude/bar.md"
    ap_manifest_record_file "$t" rust ".claude/foo.md"
    ap_manifest_record_file "$t" rust ".claude/bar.md"

    # Re-install emits only foo.md now → bar.md is orphaned.
    ap_manifest_diff_and_clean "$t" rust '[".claude/foo.md"]'

    [[ -f "$t/.claude/foo.md" ]]
    [[ ! -e "$t/.claude/bar.md" ]]
}

@test "manifest: ap_manifest_diff_and_clean: keeps dropped file if another profile claims it" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t"
    touch "$t/shared.json"
    ap_manifest_record_file "$t" alpha "shared.json"
    ap_manifest_record_file "$t" beta  "shared.json"

    # Re-install of alpha drops shared.json, but beta still owns it.
    ap_manifest_diff_and_clean "$t" alpha '[]'

    [[ -f "$t/shared.json" ]]
}

@test "manifest: ap_manifest_diff_and_clean: no-op when nothing dropped" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.claude"
    touch "$t/.claude/foo.md"
    ap_manifest_record_file "$t" rust ".claude/foo.md"

    # Re-install emits same file → no diff.
    ap_manifest_diff_and_clean "$t" rust '[".claude/foo.md"]'

    [[ -f "$t/.claude/foo.md" ]]
}

@test "manifest: re-install orphan cleanup end-to-end (file Y dropped)" {
    # Install profile A emitting file Y → modify A to drop Y → reinstall A
    # → Y is gone.
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.claude"
    touch "$t/.claude/keep.md" "$t/.claude/dropme.md"
    ap_manifest_record_file "$t" rust ".claude/keep.md"
    ap_manifest_record_file "$t" rust ".claude/dropme.md"

    # Simulate re-install: renderers re-emit only keep.md.
    ap_manifest_diff_and_clean "$t" rust '[".claude/keep.md"]'

    [[ -f "$t/.claude/keep.md" ]]
    [[ ! -e "$t/.claude/dropme.md" ]]
}

# ─── manifest correctness: corrupt manifest (Bug 3) ─────────────────

@test "manifest: corrupt JSON in manifest fails loudly on read" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.agent-profile"
    # Truncate / write garbage.
    printf 'not-valid-json{' > "$t/.agent-profile/manifest.json"

    run ap_manifest_files "$t" rust
    assert_failure
    [[ "$status" -eq 1 ]]
    assert_output_contains "manifest"
    assert_output_contains "corrupt"
}

@test "manifest: corrupt non-object top level fails loudly" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.agent-profile"
    # Valid JSON but wrong shape.
    printf '["not-an-object"]' > "$t/.agent-profile/manifest.json"

    run ap_manifest_files "$t" rust
    assert_failure
    [[ "$status" -eq 1 ]]
    assert_output_contains "manifest"
    assert_output_contains "corrupt"
}

@test "manifest: corrupt per-profile entry (non-object) fails loudly" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.agent-profile"
    # Top-level object, but a profile entry is a string.
    printf '{"rust":"oops"}' > "$t/.agent-profile/manifest.json"

    run ap_manifest_files "$t" rust
    assert_failure
    [[ "$status" -eq 1 ]]
    assert_output_contains "manifest"
    assert_output_contains "corrupt"
}

@test "manifest: corrupt manifest also fails on merged_json read" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.agent-profile"
    printf 'garbage' > "$t/.agent-profile/manifest.json"

    run ap_manifest_merged_json "$t" rust
    assert_failure
    assert_output_contains "corrupt"
}

@test "manifest: corrupt manifest fails on profiles listing" {
    local t="$TEST_HOME/tgt"
    mkdir -p "$t/.agent-profile"
    printf '][' > "$t/.agent-profile/manifest.json"

    run ap_manifest_profiles "$t"
    assert_failure
    assert_output_contains "corrupt"
}
