#!/usr/bin/env bats
# Tests for doc-drift-scan

load test_helper

setup() {
    setup_test_env
    export REAL_BIN="$REAL_DOTFILES_DIR/bin"

    # Mock npm + gh so version resolution is deterministic. Each reads a
    # `<key>=<version>` db file; an absent key echoes nothing (→ unresolved).
    MOCK_BIN="$TEST_HOME/mockbin"
    mkdir -p "$MOCK_BIN"
    export MOCK_NPM_DB="$TEST_HOME/npm-db"
    export MOCK_GH_DB="$TEST_HOME/gh-db"
    : > "$MOCK_NPM_DB"
    : > "$MOCK_GH_DB"

    cat > "$MOCK_BIN/npm" <<'EOF'
#!/usr/bin/env bash
# mock: npm view <pkg> version
[[ "$1" == "view" && "$3" == "version" ]] || exit 0
awk -F= -v k="$2" '$1==k{print $2; found=1} END{exit !found}' "$MOCK_NPM_DB"
EOF
    cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# mock: gh api repos/<owner/repo>/releases/latest --jq .tag_name
repo="${2#repos/}"; repo="${repo%/releases/latest}"
awk -F= -v k="$repo" '$1==k{print $2; found=1} END{exit !found}' "$MOCK_GH_DB"
EOF
    chmod +x "$MOCK_BIN/npm" "$MOCK_BIN/gh"
    export PATH="$MOCK_BIN:$PATH"

    FIXTURE="$TEST_HOME/sources.yaml"
}

teardown() {
    teardown_test_env
}

# --- Errors ---

@test "doc-drift-scan: exits 1 when sources file is missing" {
    run "$REAL_BIN/doc-drift-scan" "$TEST_HOME/nope.yaml"
    assert_failure
    assert_output_contains "sources file not found"
}

@test "doc-drift-scan: exits 1 on unknown signal type" {
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: weird
    signal: { type: rss, ref: example.com/feed }
    reconciled: "1.0.0"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_failure
    assert_output_contains "unknown signal type"
}

@test "doc-drift-scan: exits 1 when yq is not Mike Farah's Go yq" {
    cat > "$MOCK_BIN/yq" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "yq (https://github.com/kislyuk/yq/) 3.2.3"; exit 0; }
exit 1
EOF
    chmod +x "$MOCK_BIN/yq"
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: foo
    signal: { type: npm, ref: foo }
    reconciled: "1.0.0"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_failure
    assert_output_contains "mikefarah"
}

@test "doc-drift-scan: warns on stderr when gh is absent for a gh_release source, preserving unresolved status" {
    NOGH_BIN="$TEST_HOME/nogh-bin"
    mkdir -p "$NOGH_BIN"
    ln -s "$(command -v yq)" "$NOGH_BIN/yq"
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: chezmoi
    signal: { type: gh_release, ref: twpayne/chezmoi }
    reconciled: "v2.70.5"
EOF
    PATH="$NOGH_BIN:/bin:/usr/bin" run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_success
    assert_output_contains "gh binary not found"
    json="$(echo "$output" | sed -n '/^\[/,$p')"
    [[ "$(echo "$json" | jq -r '.[0].status')" == "unresolved" ]]
}

# --- Output shape ---

@test "doc-drift-scan: emits a valid JSON array" {
    echo "foo=1.0.0" > "$MOCK_NPM_DB"
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: foo
    signal: { type: npm, ref: foo }
    reconciled: "1.0.0"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_success
    echo "$output" | jq . >/dev/null
}

# --- No drift ---

@test "doc-drift-scan: current version marks status=current, drifted=false" {
    echo "foo=1.0.0" > "$MOCK_NPM_DB"
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: foo
    signal: { type: npm, ref: foo }
    reconciled: "1.0.0"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].status')" == "current" ]]
    [[ "$(echo "$output" | jq '.[0].drifted')" == "false" ]]
}

# --- Drift ---

@test "doc-drift-scan: newer upstream version marks status=drifted, drifted=true" {
    echo "foo=1.2.0" > "$MOCK_NPM_DB"
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: foo
    signal: { type: npm, ref: foo }
    reconciled: "1.0.0"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq '.[0].drifted')" == "true" ]]
    [[ "$(echo "$output" | jq -r '.[0].status')" == "drifted" ]]
    [[ "$(echo "$output" | jq -r '.[0].current')" == "1.2.0" ]]
    [[ "$(echo "$output" | jq -r '.[0].reconciled')" == "1.0.0" ]]
}

# --- Unresolved ---

@test "doc-drift-scan: unresolvable upstream marks status=unresolved, current=null" {
    : > "$MOCK_NPM_DB"   # no entry for foo
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: foo
    signal: { type: npm, ref: foo }
    reconciled: "1.0.0"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].status')" == "unresolved" ]]
    [[ "$(echo "$output" | jq '.[0].drifted')" == "false" ]]
    [[ "$(echo "$output" | jq '.[0].current')" == "null" ]]
}

# --- gh_release path ---

@test "doc-drift-scan: resolves a gh_release source via the gh mock" {
    echo "twpayne/chezmoi=v2.99.0" > "$MOCK_GH_DB"
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: chezmoi
    signal: { type: gh_release, ref: twpayne/chezmoi }
    reconciled: "v2.70.5"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].current')" == "v2.99.0" ]]
    [[ "$(echo "$output" | jq '.[0].drifted')" == "true" ]]
}

# --- Multiple sources, mixed states ---

@test "doc-drift-scan: reports each source independently" {
    printf 'foo=1.0.0\nbar=2.5.0\n' > "$MOCK_NPM_DB"
    cat > "$FIXTURE" <<'EOF'
sources:
  - id: foo
    signal: { type: npm, ref: foo }
    reconciled: "1.0.0"
  - id: bar
    signal: { type: npm, ref: bar }
    reconciled: "2.0.0"
EOF
    run "$REAL_BIN/doc-drift-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq 'length')" == "2" ]]
    [[ "$(echo "$output" | jq -r '.[] | select(.id=="foo").status')" == "current" ]]
    [[ "$(echo "$output" | jq -r '.[] | select(.id=="bar").status')" == "drifted" ]]
}
