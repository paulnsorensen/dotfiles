#!/usr/bin/env bats
# Tests for the worktree-family skill scripts (skills/*/scripts/).

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SKILLS="$DOTFILES_DIR/skills"

setup() {
    TMPROOT="$(mktemp -d)"
    TMPROOT="$(cd "$TMPROOT" && pwd -P)"   # canonicalize /var -> /private/var on macOS
    HOME="$TMPROOT/home"
    DEV="$TMPROOT/dev"
    REPO="$DEV/repo"
    export HOME DOTFILES_DIR TMPROOT
    PATH="$DOTFILES_DIR/bin:$PATH"
    export PATH
    mkdir -p "$REPO" "$HOME"

    git -C "$REPO" init -b main -q
    git -C "$REPO" config user.email t@t.test
    git -C "$REPO" config user.name tester
    echo one > "$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -q -m init

    local origin="$TMPROOT/origin.git"
    git init --bare -b main -q "$origin"
    git -C "$REPO" remote add origin "$origin"
    git -C "$REPO" push -q origin main
    git -C "$REPO" remote set-head origin main
}

teardown() {
    rm -rf "$TMPROOT"
}

# make_worktree <slug> — worktree at $REPO/.worktrees/<slug> on worktree/<slug>
make_worktree() {
    git -C "$REPO" worktree add -q "$REPO/.worktrees/$1" -b "worktree/$1"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || {
        echo "expected to contain: $2" >&2
        echo "actual: $1" >&2
        return 1
    }
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || {
        echo "expected NOT to contain: $2" >&2
        echo "actual: $1" >&2
        return 1
    }
}

# ── worktree/scripts/create.sh ──────────────────────────────────────

@test "create.sh creates a worktree and reports path, branch, base" {
    cd "$REPO"
    run "$SKILLS/worktree/scripts/create.sh" -m feature
    [ "$status" -eq 0 ]
    assert_contains "$output" "Worktree ready: $REPO/.worktrees/feature"
    assert_contains "$output" "Branch: worktree/feature"
    assert_contains "$output" "Base: "
    [ -d "$REPO/.worktrees/feature" ]
}

@test "create.sh resumes an existing worktree" {
    cd "$REPO"
    run "$SKILLS/worktree/scripts/create.sh" -m feature
    [ "$status" -eq 0 ]
    run "$SKILLS/worktree/scripts/create.sh" -m feature
    [ "$status" -eq 0 ]
    assert_contains "$output" "Worktree resumed: $REPO/.worktrees/feature"
}

# ── worktree-find/scripts/find-touching.sh ──────────────────────────

@test "find-touching.sh finds the worktree with an uncommitted touch" {
    make_worktree alpha
    make_worktree beta
    echo change >> "$REPO/.worktrees/alpha/file.txt"

    run "$SKILLS/worktree-find/scripts/find-touching.sh" 'file.txt' --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" ".worktrees/alpha"
    assert_contains "$output" "    file.txt"
    assert_not_contains "$output" ".worktrees/beta"
}

@test "find-touching.sh finds the worktree with a committed touch" {
    make_worktree alpha
    make_worktree beta
    mkdir -p "$REPO/.worktrees/beta/docs"
    echo doc > "$REPO/.worktrees/beta/docs/x.md"
    git -C "$REPO/.worktrees/beta" add docs/x.md
    git -C "$REPO/.worktrees/beta" commit -q -m "docs: add x"

    run "$SKILLS/worktree-find/scripts/find-touching.sh" 'docs/*' --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" ".worktrees/beta"
    assert_contains "$output" "    docs/x.md"
    assert_not_contains "$output" ".worktrees/alpha"
}

@test "find-touching.sh marks truncation beyond 8 files" {
    make_worktree alpha
    for i in 0 1 2 3 4 5 6 7 8 9; do
        echo x > "$REPO/.worktrees/alpha/t$i.txt"
    done
    git -C "$REPO/.worktrees/alpha" add .
    git -C "$REPO/.worktrees/alpha" commit -qm "test files"

    run "$SKILLS/worktree-find/scripts/find-touching.sh" 't*.txt' --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "    t0.txt"
    assert_contains "$output" "(+2 more)"
    assert_not_contains "$output" "t9.txt"
}

@test "find-touching.sh reports no match plainly" {
    make_worktree alpha
    run "$SKILLS/worktree-find/scripts/find-touching.sh" 'nope/*' --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "No worktree touches 'nope/*'"
}

# ── worktree-find/scripts/find-pr.sh ────────────────────────────────

@test "find-pr.sh joins an open PR to its worktree via stubbed gh" {
    make_worktree alpha
    make_worktree beta

    mkdir -p "$TMPROOT/stub"
    cat > "$TMPROOT/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo '[{"number":7,"headRefName":"worktree/alpha","title":"Fix auth","url":"https://example.test/pr/7"}]'
STUB
    chmod +x "$TMPROOT/stub/gh"
    PATH="$TMPROOT/stub:$PATH"

    run "$SKILLS/worktree-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" ".worktrees/alpha"
    assert_contains "$output" "PR #7"
    assert_contains "$output" "Fix auth"
    assert_not_contains "$output" ".worktrees/beta"
}

@test "find-pr.sh reports no match when no PR head matches" {
    make_worktree alpha

    mkdir -p "$TMPROOT/stub"
    printf '#!/usr/bin/env bash\necho "[]"\n' > "$TMPROOT/stub/gh"
    chmod +x "$TMPROOT/stub/gh"
    PATH="$TMPROOT/stub:$PATH"

    run "$SKILLS/worktree-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "No open PR matches a local worktree"
}

# ── worktree-triage/scripts/snapshot.sh ─────────────────────────────

@test "snapshot.sh keeps DIRTY rows with reasons and drops SAFE rows" {
    make_worktree alpha
    make_worktree beta
    echo change >> "$REPO/.worktrees/alpha/file.txt"

    run "$SKILLS/worktree-triage/scripts/snapshot.sh" --path "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "[DIRTY] alpha"
    assert_contains "$output" "uncommitted changes"
    assert_contains "$output" "repo ("
    assert_contains "$output" "Summary:"
    assert_not_contains "$output" "[SAFE]"
    # no ANSI escapes survive
    assert_not_contains "$output" "$(printf '\033')"
}

# ── worktree-triage/scripts/commands.sh ─────────────────────────────

@test "commands.sh archive emits tag + remove + branch -D with the real branch" {
    make_worktree alpha
    run "$SKILLS/worktree-triage/scripts/commands.sh" "$REPO" alpha archive
    [ "$status" -eq 0 ]
    assert_contains "$output" "tag archive/alpha worktree/alpha"
    assert_contains "$output" "worktree remove .worktrees/alpha"
    assert_contains "$output" "branch -D worktree/alpha"
}

@test "commands.sh remove adds --force for a dirty tree and omits it when clean" {
    make_worktree alpha
    run "$SKILLS/worktree-triage/scripts/commands.sh" "$REPO" alpha remove
    [ "$status" -eq 0 ]
    assert_not_contains "$output" "--force"

    echo change >> "$REPO/.worktrees/alpha/file.txt"
    run "$SKILLS/worktree-triage/scripts/commands.sh" "$REPO" alpha remove
    [ "$status" -eq 0 ]
    assert_contains "$output" "worktree remove --force .worktrees/alpha"
}

@test "commands.sh rejects an unknown action" {
    make_worktree alpha
    run "$SKILLS/worktree-triage/scripts/commands.sh" "$REPO" alpha shred
    [ "$status" -eq 2 ]
}

# ── wt-git/scripts/pr-create.sh ─────────────────────────────────────

@test "pr-create.sh pushes HEAD and passes title, body file, and flags to gh" {
    make_worktree alpha
    echo change >> "$REPO/.worktrees/alpha/file.txt"
    git -C "$REPO/.worktrees/alpha" commit -aqm "feat: change"

    mkdir -p "$TMPROOT/stub"
    cat > "$TMPROOT/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TMPROOT/gh-args"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body-file" ]]; then cp "$2" "$TMPROOT/gh-body"; fi
    shift
done
STUB
    chmod +x "$TMPROOT/stub/gh"
    PATH="$TMPROOT/stub:$PATH"

    run bash -c "echo '## Summary' | '$SKILLS/wt-git/scripts/pr-create.sh' '$REPO/.worktrees/alpha' 'feat: change' --base main"
    [ "$status" -eq 0 ]

    run git -C "$TMPROOT/origin.git" show-ref --verify --quiet refs/heads/worktree/alpha
    [ "$status" -eq 0 ]

    args="$(cat "$TMPROOT/gh-args")"
    assert_contains "$args" "feat: change"
    assert_contains "$args" "--base"
    body="$(cat "$TMPROOT/gh-body")"
    assert_contains "$body" "## Summary"
}
