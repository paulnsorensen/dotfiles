#!/usr/bin/env bats
# Tests for git-file-risk

load test_helper

setup() {
    setup_test_env
    export REAL_BIN="$REAL_DOTFILES_DIR/bin"

    # Create a git repo with controlled history
    REPO_DIR="$TEST_HOME/repo"
    mkdir -p "$REPO_DIR"
    cd "$REPO_DIR" || exit
    git init --quiet
    git config user.email "alice@example.com"
    git config user.name "Alice"
}

teardown() {
    teardown_test_env
}

# --- Usage ---

@test "git-file-risk: exits 1 with usage when no args" {
    run "$REAL_BIN/git-file-risk"
    assert_failure
    assert_output_contains "Usage: git-file-risk"
}

# --- Single file, basic output ---

@test "git-file-risk: outputs valid JSON array for one file" {
    cd "$REPO_DIR"
    echo "hello" > foo.txt
    git add foo.txt
    git commit -m "add foo" --quiet

    run "$REAL_BIN/git-file-risk" foo.txt
    assert_success
    # Validate JSON with jq
    echo "$output" | jq . >/dev/null 2>&1
}

@test "git-file-risk: reports correct author count" {
    cd "$REPO_DIR"
    echo "v1" > multi.txt
    git add multi.txt
    git commit -m "alice adds" --quiet

    git config user.name "Bob"
    git config user.email "bob@example.com"
    echo "v2" >> multi.txt
    git add multi.txt
    git commit -m "bob edits" --quiet

    git config user.name "Carol"
    git config user.email "carol@example.com"
    echo "v3" >> multi.txt
    git add multi.txt
    git commit -m "carol edits" --quiet

    run "$REAL_BIN/git-file-risk" multi.txt
    assert_success
    local authors
    authors=$(echo "$output" | jq '.[0].authors_90d')
    [[ "$authors" -eq 3 ]]
}

@test "git-file-risk: reports correct change count" {
    cd "$REPO_DIR"
    echo "v1" > freq.txt
    git add freq.txt
    git commit -m "c1" --quiet

    for i in 2 3 4 5; do
        echo "v$i" >> freq.txt
        git add freq.txt
        git commit -m "c$i" --quiet
    done

    run "$REAL_BIN/git-file-risk" freq.txt
    assert_success
    local changes
    changes=$(echo "$output" | jq '.[0].changes_90d')
    [[ "$changes" -eq 5 ]]
}

# --- Revert detection ---

@test "git-file-risk: detects revert commits" {
    cd "$REPO_DIR"
    echo "original" > revert.txt
    git add revert.txt
    git commit -m "add revert.txt" --quiet

    echo "bad change" > revert.txt
    git add revert.txt
    git commit -m "break it" --quiet

    echo "original" > revert.txt
    git add revert.txt
    git commit -m "Revert \"break it\"" --quiet

    run "$REAL_BIN/git-file-risk" revert.txt
    assert_success
    local reverts
    reverts=$(echo "$output" | jq '.[0].reverts')
    [[ "$reverts" -ge 1 ]]
}

@test "git-file-risk: reverts is 0 when no reverts exist" {
    cd "$REPO_DIR"
    echo "clean" > clean.txt
    git add clean.txt
    git commit -m "add clean" --quiet

    run "$REAL_BIN/git-file-risk" clean.txt
    assert_success
    local reverts
    reverts=$(echo "$output" | jq '.[0].reverts')
    [[ "$reverts" -eq 0 ]]
}

# --- Staleness ---

@test "git-file-risk: last_change_days is small for fresh commit" {
    cd "$REPO_DIR"
    echo "fresh" > fresh.txt
    git add fresh.txt
    git commit -m "just now" --quiet

    run "$REAL_BIN/git-file-risk" fresh.txt
    assert_success
    local days
    days=$(echo "$output" | jq '.[0].last_change_days')
    [[ "$days" -le 1 ]]
}

@test "git-file-risk: staleness field is populated" {
    cd "$REPO_DIR"
    echo "stale" > stale.txt
    git add stale.txt
    git commit -m "add stale" --quiet

    run "$REAL_BIN/git-file-risk" stale.txt
    assert_success
    local staleness
    staleness=$(echo "$output" | jq -r '.[0].staleness')
    [[ -n "$staleness" ]]
    [[ "$staleness" != "null" ]]
}

# --- Multiple files ---

@test "git-file-risk: handles multiple files" {
    cd "$REPO_DIR"
    echo "a" > a.txt
    echo "b" > b.txt
    git add a.txt b.txt
    git commit -m "add both" --quiet

    run "$REAL_BIN/git-file-risk" a.txt b.txt
    assert_success
    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 2 ]]

    local file1 file2
    file1=$(echo "$output" | jq -r '.[0].file')
    file2=$(echo "$output" | jq -r '.[1].file')
    [[ "$file1" == "a.txt" ]]
    [[ "$file2" == "b.txt" ]]
}

# --- Untracked file ---

@test "git-file-risk: reports error for untracked file" {
    cd "$REPO_DIR"
    # Need at least one commit for the repo to be valid
    echo "init" > init.txt
    git add init.txt
    git commit -m "init" --quiet

    run "$REAL_BIN/git-file-risk" nonexistent.txt
    assert_success
    local err
    err=$(echo "$output" | jq -r '.[0].error')
    [[ "$err" == "not tracked" ]]
}

# --- Hotspot detection (integration) ---

@test "git-file-risk: hotspot file has high author and change counts" {
    cd "$REPO_DIR"
    echo "v1" > hot.txt
    git add hot.txt
    git commit -m "init" --quiet

    for name in Bob Carol Dave Eve; do
        git config user.name "$name"
        git config user.email "${name}@example.com"
        echo "edit by $name" >> hot.txt
        git add hot.txt
        git commit -m "$name edits" --quiet
    done

    run "$REAL_BIN/git-file-risk" hot.txt
    assert_success
    local authors changes
    authors=$(echo "$output" | jq '.[0].authors_90d')
    changes=$(echo "$output" | jq '.[0].changes_90d')
    [[ "$authors" -ge 4 ]]
    [[ "$changes" -ge 5 ]]
}
