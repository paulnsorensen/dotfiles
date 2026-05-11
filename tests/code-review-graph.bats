#!/usr/bin/env bats
# Unit tests for code-review-graph/sync-lib.sh
#
# Covers the pure-bash helpers that .sync depends on:
#   - discover_dev_repos: scans ~/Dev/* and emits path\talias for git repos
#   - diff_repo_sets: produces ADD/REMOVE deltas between desired and current
#   - render_plist: substitutes __HOME__ and __CRG_BIN__ into the template

load test_helper

CRG_LIB="$REAL_DOTFILES_DIR/code-review-graph/sync-lib.sh"
PLIST_TMPL="$REAL_DOTFILES_DIR/code-review-graph/com.coderevgraph.daemon.plist.tmpl"

setup() {
    setup_test_env
    DEV="$TEST_HOME/Dev"
    mkdir -p "$DEV"
    # shellcheck source=../code-review-graph/sync-lib.sh
    source "$CRG_LIB"
}

teardown() {
    teardown_test_env
}

# --- discover_dev_repos ---

@test "discover_dev_repos: finds git repos, skips non-git dirs" {
    mkdir -p "$DEV/repo-a/.git" "$DEV/repo-b/.git" "$DEV/not-a-repo"
    run discover_dev_repos "$DEV"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$DEV/repo-a	repo-a"* ]]
    [[ "$output" == *"$DEV/repo-b	repo-b"* ]]
    [[ "$output" != *"not-a-repo"* ]]
}

@test "discover_dev_repos: handles .git as a file (worktree linked)" {
    mkdir -p "$DEV/wt-repo"
    echo "gitdir: /elsewhere/.git/worktrees/foo" > "$DEV/wt-repo/.git"
    run discover_dev_repos "$DEV"
    [[ "$output" == *"$DEV/wt-repo	wt-repo"* ]]
}

@test "discover_dev_repos: skips symlinks" {
    mkdir -p "$DEV/real-repo/.git"
    ln -s "$DEV/real-repo" "$DEV/linked-repo"
    run discover_dev_repos "$DEV"
    [[ "$output" == *"real-repo"* ]]
    [[ "$output" != *"linked-repo"* ]]
}

@test "discover_dev_repos: skips dotfiles (names starting with .)" {
    mkdir -p "$DEV/.worktrees/foo/.git" "$DEV/visible/.git"
    run discover_dev_repos "$DEV"
    [[ "$output" == *"visible"* ]]
    [[ "$output" != *".worktrees"* ]]
}

@test "discover_dev_repos: skips regular files" {
    touch "$DEV/README.md"
    mkdir -p "$DEV/real/.git"
    run discover_dev_repos "$DEV"
    [[ "$output" == *"real"* ]]
    [[ "$output" != *"README.md"* ]]
}

@test "discover_dev_repos: returns empty when root has no git repos" {
    mkdir -p "$DEV/random-stuff"
    run discover_dev_repos "$DEV"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "discover_dev_repos: returns empty when root does not exist" {
    run discover_dev_repos "$TEST_HOME/nonexistent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- diff_repo_sets ---

@test "diff_repo_sets: emits ADD for repos only in desired" {
    desired="$TEST_HOME/d"; current="$TEST_HOME/c"
    printf '%s\t%s\n' "/Dev/a" "a" "/Dev/b" "b" > "$desired"
    printf '%s\t%s\n' "/Dev/a" "a" > "$current"
    run diff_repo_sets "$desired" "$current"
    [[ "$output" == *"ADD	/Dev/b	b"* ]]
    [[ "$output" != *"ADD	/Dev/a"* ]]
    [[ "$output" != *"REMOVE"* ]]
}

@test "diff_repo_sets: emits REMOVE for repos only in current" {
    desired="$TEST_HOME/d"; current="$TEST_HOME/c"
    printf '%s\t%s\n' "/Dev/a" "a" > "$desired"
    printf '%s\t%s\n' "/Dev/a" "a" "/Dev/gone" "gone" > "$current"
    run diff_repo_sets "$desired" "$current"
    [[ "$output" == *"REMOVE	gone"* ]]
    [[ "$output" != *"ADD"* ]]
}

@test "diff_repo_sets: handles both ADD and REMOVE in one pass" {
    desired="$TEST_HOME/d"; current="$TEST_HOME/c"
    printf '%s\t%s\n' "/Dev/new" "new" "/Dev/keep" "keep" > "$desired"
    printf '%s\t%s\n' "/Dev/old" "old" "/Dev/keep" "keep" > "$current"
    run diff_repo_sets "$desired" "$current"
    [[ "$output" == *"ADD	/Dev/new	new"* ]]
    [[ "$output" == *"REMOVE	old"* ]]
    [[ "$output" != *"keep"* ]]
}

@test "diff_repo_sets: empty desired drops everything" {
    desired="$TEST_HOME/d"; current="$TEST_HOME/c"
    : > "$desired"
    printf '%s\t%s\n' "/Dev/x" "x" "/Dev/y" "y" > "$current"
    run diff_repo_sets "$desired" "$current"
    [[ "$output" == *"REMOVE	x"* ]]
    [[ "$output" == *"REMOVE	y"* ]]
}

@test "diff_repo_sets: identical sets yield no output" {
    desired="$TEST_HOME/d"; current="$TEST_HOME/c"
    printf '%s\t%s\n' "/Dev/a" "a" "/Dev/b" "b" > "$desired"
    cp "$desired" "$current"
    run diff_repo_sets "$desired" "$current"
    [ -z "$output" ]
}

# --- render_plist ---

@test "render_plist: substitutes __HOME__ and __CRG_BIN__" {
    out="$TEST_HOME/out.plist"
    run render_plist "$PLIST_TMPL" "$out" "/Users/test" "/opt/fake/crg"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -q "/Users/test/.code-review-graph/logs/launchd.out.log" "$out"
    grep -q "<string>/opt/fake/crg</string>" "$out"
    run grep -c "__HOME__" "$out"
    [ "$output" = "0" ]
    run grep -c "__CRG_BIN__" "$out"
    [ "$output" = "0" ]
}

@test "render_plist: returns 1 when template missing" {
    run render_plist "$TEST_HOME/nope.tmpl" "$TEST_HOME/out.plist" "/Users/x" "/usr/bin/crg"
    [ "$status" -eq 1 ]
}

@test "render_plist: returns 2 when binary cannot be resolved" {
    # Restricted PATH that won't contain code-review-graph + empty explicit binary
    run env PATH="/usr/bin:/bin" bash -c "source '$CRG_LIB'; render_plist '$PLIST_TMPL' '$TEST_HOME/out.plist' '/Users/x' ''"
    [ "$status" -eq 2 ]
}
