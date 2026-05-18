#!/usr/bin/env bats
#
# Core tests for agent-profile/lib/* (parse, discover, manifest,
# agents_md). Render + CLI tests live in sibling .bats files.

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
    # shellcheck source=../agent-profile/lib/agents_md.sh
    source "$AP_DIR/lib/agents_md.sh"

    # Sandbox lookup roots so PWD/.agent-profiles and the real
    # $DOTFILES_DIR/profiles tree do not bleed into the test.
    PROFILE_ROOT="$TEST_HOME/profiles"
    mkdir -p "$PROFILE_ROOT"
    export AP_EXTRA_SEARCH_PATHS="$PROFILE_ROOT"
    export DOTFILES_DIR="$TEST_HOME"   # forces global root to a known empty path
    cd "$TEST_HOME"
}

teardown() {
    teardown_test_env
}

# Materializes a profile dir under $PROFILE_ROOT/<name>/ with the
# given profile.yaml contents. Optional second arg: AGENTS.md body.
make_profile() {
    local name="$1" yaml="$2" md="${3:-}"
    local dir="$PROFILE_ROOT/$name"
    mkdir -p "$dir"
    printf '%s\n' "$yaml" > "$dir/profile.yaml"
    if [[ -n "$md" ]]; then
        printf '%s\n' "$md" > "$dir/AGENTS.md"
    fi
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

@test "ap_parse_one: AGENTS.md becomes a single block when present" {
    make_profile mdtest "name: mdtest" "# Hello world"
    run ap_parse_one "$PROFILE_ROOT/mdtest"
    assert_success
    [[ $(jq -r '.agents_md_blocks | length'   <<<"$output") == "1" ]]
    [[ $(jq -r '.agents_md_blocks[0].name'    <<<"$output") == "mdtest" ]]
    [[ $(jq -r '.agents_md_blocks[0].content' <<<"$output") == "# Hello world" ]]
}

@test "ap_parse_one: missing AGENTS.md → empty agents_md_blocks" {
    make_profile nomd "name: nomd"
    run ap_parse_one "$PROFILE_ROOT/nomd"
    assert_success
    [[ $(jq -r '.agents_md_blocks | length' <<<"$output") == "0" ]]
}

@test "ap_parse_one: missing name field fails loudly" {
    make_profile nameless "description: noname"
    run ap_parse_one "$PROFILE_ROOT/nameless"
    assert_failure
    assert_output_contains "missing required field 'name'"
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

@test "ap_parse_manifest: AGENTS.md blocks ordered base-first" {
    make_profile base "name: base" "BASE BODY"
    make_profile leaf "name: leaf
include: [base]" "LEAF BODY"
    run ap_parse_manifest "$PROFILE_ROOT/leaf"
    assert_success
    [[ $(jq -r '.agents_md_blocks[0].name'    <<<"$output") == "base" ]]
    [[ $(jq -r '.agents_md_blocks[0].content' <<<"$output") == "BASE BODY" ]]
    [[ $(jq -r '.agents_md_blocks[1].name'    <<<"$output") == "leaf" ]]
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
    cd "$TEST_HOME"
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
    ap_manifest_record_agents_md "$t" rust "AGENTS.md"
    run ap_manifest_files "$t" rust
    assert_success
    assert_output_contains ".claude/foo.md"
    assert_output_contains ".claude/bar.md"
    run ap_manifest_agents_md "$t" rust
    assert_success
    [[ "$output" == "AGENTS.md" ]]
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

# ─── agents_md splice ───────────────────────────────────────────────

@test "ap_splice_agents_md: appends marker block to fresh file" {
    local f="$TEST_HOME/AGENTS.md"
    ap_splice_agents_md "$f" rust "BODY GOES HERE"
    run cat "$f"
    assert_success
    assert_output_contains "<!-- agent-profile:rust:begin -->"
    assert_output_contains "BODY GOES HERE"
    assert_output_contains "<!-- agent-profile:rust:end -->"
}

@test "ap_splice_agents_md: re-splice replaces in place (idempotent)" {
    local f="$TEST_HOME/AGENTS.md"
    echo "# Pre-existing" > "$f"
    ap_splice_agents_md "$f" rust "v1 body"
    ap_splice_agents_md "$f" rust "v2 body"
    run cat "$f"
    assert_success
    assert_output_contains "v2 body"
    assert_output_not_contains "v1 body"
    assert_output_contains "# Pre-existing"
}

@test "ap_splice_agents_md: preserves user content above/below" {
    local f="$TEST_HOME/AGENTS.md"
    cat > "$f" <<EOF
# Project
Hand-written.
EOF
    ap_splice_agents_md "$f" rust "RUST BODY"
    run cat "$f"
    assert_success
    assert_output_contains "Hand-written."
    assert_output_contains "RUST BODY"
}

@test "ap_strip_agents_md: removes only the named profile's block" {
    local f="$TEST_HOME/AGENTS.md"
    echo "# Header" > "$f"
    ap_splice_agents_md "$f" rust "rust body"
    ap_splice_agents_md "$f" go   "go body"
    ap_strip_agents_md  "$f" rust
    run cat "$f"
    assert_success
    assert_output_contains "go body"
    assert_output_not_contains "rust body"
    assert_output_contains "# Header"
}

@test "ap_strip_agents_md: no-op when block not present" {
    local f="$TEST_HOME/AGENTS.md"
    echo "# Just a file" > "$f"
    ap_strip_agents_md "$f" rust
    run cat "$f"
    assert_success
    [[ "$output" == "# Just a file" ]]
}
