#!/usr/bin/env bats
# Tests for gh-pr-batch and gh-pr-checks-batch

load test_helper

setup() {
    setup_test_env
    export REAL_BIN="$REAL_DOTFILES_DIR/bin"
    # Create mock gh command
    mkdir -p "$TEST_HOME/bin"
    export PATH="$TEST_HOME/bin:$REAL_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

# --- gh-pr-batch ---

@test "gh-pr-batch: exits 1 with usage when no args" {
    run "$REAL_BIN/gh-pr-batch"
    assert_failure
    assert_output_contains "Usage: gh-pr-batch"
}

@test "gh-pr-batch: outputs separator per PR" {
    cat > "$TEST_HOME/bin/gh" << 'MOCK'
#!/usr/bin/env bash
echo '{"number":42,"title":"feat: test","state":"OPEN","mergeable":"MERGEABLE","branch":"feat/test","base":"main","additions":10,"deletions":2,"totalCommits":1,"updatedAt":"2026-03-22T00:00:00Z","reviewDecision":"APPROVED","approvals":2,"files":["src/foo.ts"]}'
MOCK
    chmod +x "$TEST_HOME/bin/gh"

    run "$REAL_BIN/gh-pr-batch" 42 99
    assert_success
    assert_output_contains "=== PR #42 ==="
    assert_output_contains "=== PR #99 ==="
}

@test "gh-pr-batch: output includes approvals field" {
    cat > "$TEST_HOME/bin/gh" << 'MOCK'
#!/usr/bin/env bash
# Simulate gh pr view --json ... --jq ...
# The real script pipes through jq, so mock the final output
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    PR_NUM="$3"
    cat << EOF
{
  "number": $PR_NUM,
  "title": "feat: test",
  "state": "OPEN",
  "mergeable": "MERGEABLE",
  "branch": "feat/test",
  "base": "main",
  "additions": 10,
  "deletions": 2,
  "totalCommits": 1,
  "updatedAt": "2026-03-22T00:00:00Z",
  "reviewDecision": "APPROVED",
  "approvals": 2,
  "files": ["src/foo.ts"]
}
EOF
fi
MOCK
    chmod +x "$TEST_HOME/bin/gh"

    run "$REAL_BIN/gh-pr-batch" 42
    assert_success
    assert_output_contains '"approvals"'
    assert_output_contains '"reviewDecision"'
}

@test "gh-pr-batch: handles zero approvals" {
    cat > "$TEST_HOME/bin/gh" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    PR_NUM="$3"
    cat << EOF
{
  "number": $PR_NUM,
  "title": "feat: wip",
  "state": "OPEN",
  "mergeable": "MERGEABLE",
  "branch": "feat/wip",
  "base": "main",
  "additions": 5,
  "deletions": 0,
  "totalCommits": 1,
  "updatedAt": "2026-03-22T00:00:00Z",
  "reviewDecision": "",
  "approvals": 0,
  "files": ["src/bar.ts"]
}
EOF
fi
MOCK
    chmod +x "$TEST_HOME/bin/gh"

    run "$REAL_BIN/gh-pr-batch" 55
    assert_success
    assert_output_contains '"approvals": 0'
}

@test "gh-pr-batch: multiple PRs produce separate blocks" {
    cat > "$TEST_HOME/bin/gh" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    PR_NUM="$3"
    cat << EOF
{
  "number": $PR_NUM,
  "title": "pr $PR_NUM",
  "state": "OPEN",
  "mergeable": "MERGEABLE",
  "branch": "branch-$PR_NUM",
  "base": "main",
  "additions": 1,
  "deletions": 0,
  "totalCommits": 1,
  "updatedAt": "2026-03-22T00:00:00Z",
  "reviewDecision": "",
  "approvals": 0,
  "files": ["file-$PR_NUM.ts"]
}
EOF
fi
MOCK
    chmod +x "$TEST_HOME/bin/gh"

    run "$REAL_BIN/gh-pr-batch" 10 20 30
    assert_success
    assert_output_contains "=== PR #10 ==="
    assert_output_contains "=== PR #20 ==="
    assert_output_contains "=== PR #30 ==="
    assert_output_contains '"number": 10'
    assert_output_contains '"number": 20'
    assert_output_contains '"number": 30'
}

# --- gh-pr-checks-batch ---

@test "gh-pr-checks-batch: exits 1 with usage when no args" {
    run "$REAL_BIN/gh-pr-checks-batch"
    assert_failure
    assert_output_contains "Usage: gh-pr-checks-batch"
}

@test "gh-pr-checks-batch: outputs separator per PR" {
    cat > "$TEST_HOME/bin/gh" << 'MOCK'
#!/usr/bin/env bash
echo "pass  test  1m  https://example.com"
MOCK
    chmod +x "$TEST_HOME/bin/gh"

    run "$REAL_BIN/gh-pr-checks-batch" 42 99
    assert_success
    assert_output_contains "=== PR #42 CHECKS ==="
    assert_output_contains "=== PR #99 CHECKS ==="
}

@test "gh-pr-checks-batch: handles no checks gracefully" {
    cat > "$TEST_HOME/bin/gh" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$TEST_HOME/bin/gh"

    run "$REAL_BIN/gh-pr-checks-batch" 42
    assert_success
    assert_output_contains "(no checks)"
}
