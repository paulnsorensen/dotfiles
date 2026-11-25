#!/usr/bin/env bats
# Tests for the worktree-family skill scripts (skills/*/scripts/).

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SKILLS="$DOTFILES_DIR/skills"
JQ_BIN="$(command -v jq)"
if [[ "$JQ_BIN" == */mise/shims/jq ]]; then
    JQ_BIN="$(mise which jq)"
fi

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

make_min_path() {
    mkdir -p "$TMPROOT/minbin"
    local tool
    for tool in env bash git sed mktemp rm dirname basename date find; do
        ln -s "$(command -v "$tool")" "$TMPROOT/minbin/$tool"
    done
}

# ── wt-find/scripts/find-touching.sh ──────────────────────────

@test "find-touching.sh finds the worktree with an uncommitted touch" {
    make_worktree alpha
    make_worktree beta
    echo change >> "$REPO/.worktrees/alpha/file.txt"

    run "$SKILLS/wt-find/scripts/find-touching.sh" 'file.txt' --root "$DEV"
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

    run "$SKILLS/wt-find/scripts/find-touching.sh" 'docs/*' --root "$DEV"
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

    run "$SKILLS/wt-find/scripts/find-touching.sh" 't*.txt' --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "    t0.txt"
    assert_contains "$output" "(+2 more)"
    assert_not_contains "$output" "t9.txt"
}

@test "find-touching.sh reports no match plainly" {
    make_worktree alpha
    run "$SKILLS/wt-find/scripts/find-touching.sh" 'nope/*' --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "No worktree touches 'nope/*'"
}

# ── wt-find/scripts/find-pr.sh ────────────────────────────────

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

    run "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
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

    run "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "No open PR matches a local worktree"
}

@test "find-pr.sh finds a PR from a copied skill under a reset PATH" {
    make_worktree alpha
    make_min_path
    mkdir -p "$TMPROOT/xdg/mise/shims"
    cat > "$TMPROOT/xdg/mise/shims/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[{"number":7,"headRefName":"worktree/alpha","title":"Fix auth","url":"https://example.test/pr/7"}]'
STUB
    chmod +x "$TMPROOT/xdg/mise/shims/gh"
    ln -s "$JQ_BIN" "$TMPROOT/xdg/mise/shims/jq"
    cp -r "$SKILLS/wt-find" "$TMPROOT/deployed"

    run env PATH="$TMPROOT/minbin:$DOTFILES_DIR/bin" XDG_DATA_HOME="$TMPROOT/xdg" \
        "$TMPROOT/deployed/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "$REPO/.worktrees/alpha"
    assert_contains "$output" $'worktree/alpha\tPR #7\tFix auth\thttps://example.test/pr/7'
}

@test "find-pr.sh reports a missing gh command as an error" {
    make_worktree alpha
    make_min_path
    mkdir -p "$TMPROOT/xdg/mise/shims"
    ln -s "$JQ_BIN" "$TMPROOT/xdg/mise/shims/jq"

    run env PATH="$TMPROOT/minbin:$DOTFILES_DIR/bin" XDG_DATA_HOME="$TMPROOT/xdg" \
        "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -ne 0 ]
    assert_contains "$output" "gh"
    assert_not_contains "$output" "No open PR matches"
}

@test "find-pr.sh reports a missing jq command as an error" {
    make_worktree alpha
    make_min_path
    mkdir -p "$TMPROOT/xdg/mise/shims"
    cat > "$TMPROOT/xdg/mise/shims/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[]'
STUB
    chmod +x "$TMPROOT/xdg/mise/shims/gh"

    run env PATH="$TMPROOT/minbin:$DOTFILES_DIR/bin" XDG_DATA_HOME="$TMPROOT/xdg" \
        "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -ne 0 ]
    assert_contains "$output" "jq"
    assert_not_contains "$output" "No open PR matches"
}

@test "find-pr.sh reports a failed GitHub query as an error" {
    make_worktree alpha
    mkdir -p "$TMPROOT/stub"
    printf '#!/usr/bin/env bash\nexit 23\n' > "$TMPROOT/stub/gh"
    chmod +x "$TMPROOT/stub/gh"

    run env PATH="$TMPROOT/stub:$PATH" "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -ne 0 ]
    assert_contains "$output" "GitHub PR lookup failed"
    assert_not_contains "$output" "No open PR matches"
}

@test "find-pr.sh reports malformed GitHub JSON as an error" {
    make_worktree alpha
    mkdir -p "$TMPROOT/stub"
    cat > "$TMPROOT/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'not-json'
STUB
    chmod +x "$TMPROOT/stub/gh"

    run env PATH="$TMPROOT/stub:$PATH" "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -ne 0 ]
    assert_contains "$output" "Invalid GitHub PR response"
    assert_not_contains "$output" "No open PR matches"
}

@test "find-pr.sh reports failed worktree discovery as an error" {
    mkdir -p "$TMPROOT/stub"
    printf '#!/usr/bin/env bash\nexit 17\n' > "$TMPROOT/stub/wt-find"
    chmod +x "$TMPROOT/stub/wt-find"

    run env PATH="$TMPROOT/stub:$PATH" "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -ne 0 ]
    assert_contains "$output" "Worktree discovery failed"
    assert_not_contains "$output" "No open PR matches"
}

@test "find-pr.sh reports failed jq decoding as an error" {
    make_worktree alpha
    mkdir -p "$TMPROOT/stub"
    cat > "$TMPROOT/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[]'
STUB
    cat > "$TMPROOT/stub/jq" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -r ]]; then
    exit 9
fi
exec "$REAL_JQ" "$@"
STUB
    chmod +x "$TMPROOT/stub/gh" "$TMPROOT/stub/jq"

    run env REAL_JQ="$JQ_BIN" PATH="$TMPROOT/stub:$PATH" \
        "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -ne 0 ]
    assert_contains "$output" "GitHub PR response decode failed"
    assert_not_contains "$output" "No open PR matches"
}

@test "find-pr.sh queries each origin only once" {
    make_worktree alpha
    make_worktree beta
    mkdir -p "$TMPROOT/stub"
    cat > "$TMPROOT/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$TMPROOT/gh-calls"
printf '%s\n' '[]'
STUB
    chmod +x "$TMPROOT/stub/gh"

    run env PATH="$TMPROOT/stub:$PATH" "$SKILLS/wt-find/scripts/find-pr.sh" --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "No open PR matches"
    [ "$(wc -l < "$TMPROOT/gh-calls")" -eq 1 ]
}

# ── wt-triage/scripts/snapshot.sh ─────────────────────────────

@test "snapshot.sh keeps DIRTY rows with reasons and drops SAFE rows" {
    make_worktree alpha
    make_worktree beta
    echo change >> "$REPO/.worktrees/alpha/file.txt"

    run "$SKILLS/wt-triage/scripts/snapshot.sh" --path "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "[DIRTY] alpha"
    assert_contains "$output" "uncommitted changes"
    assert_contains "$output" "repo ("
    assert_contains "$output" "Summary:"
    assert_not_contains "$output" "[SAFE]"
    # no ANSI escapes survive
    assert_not_contains "$output" "$(printf '\033')"
}

# ── wt-triage/scripts/commands.sh ─────────────────────────────

@test "commands.sh archive emits tag + remove + branch -D with the real branch" {
    make_worktree alpha
    run "$SKILLS/wt-triage/scripts/commands.sh" "$REPO/.worktrees/alpha" archive
    [ "$status" -eq 0 ]
    assert_contains "$output" "tag archive/alpha worktree/alpha"
    assert_contains "$output" "worktree remove .worktrees/alpha"
    assert_contains "$output" "branch -D worktree/alpha"
}

@test "commands.sh remove adds --force for a dirty tree and omits it when clean" {
    make_worktree alpha
    run "$SKILLS/wt-triage/scripts/commands.sh" "$REPO/.worktrees/alpha" remove
    [ "$status" -eq 0 ]
    assert_not_contains "$output" "--force"

    echo change >> "$REPO/.worktrees/alpha/file.txt"
    run "$SKILLS/wt-triage/scripts/commands.sh" "$REPO/.worktrees/alpha" remove
    [ "$status" -eq 0 ]
    assert_contains "$output" "worktree remove --force .worktrees/alpha"
}

# Agent shells overwrite PATH, so only the exported DOTFILES_DIR is left.
@test "wt-triage scripts resolve bin via DOTFILES_DIR when PATH lacks it" {
    make_worktree alpha
    PATH=/usr/bin:/bin
    run "$SKILLS/wt-triage/scripts/snapshot.sh" --path "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" "Summary:"

    cp -r "$SKILLS/wt-triage" "$TMPROOT/deployed"
    run "$TMPROOT/deployed/scripts/commands.sh" "$REPO/.worktrees/alpha" remove
    [ "$status" -eq 0 ]
    assert_contains "$output" "worktree remove .worktrees/alpha"
}

@test "wt-find scripts resolve wt-find via DOTFILES_DIR when PATH lacks it" {
    make_worktree alpha
    echo change >> "$REPO/.worktrees/alpha/file.txt"
    PATH=/usr/bin:/bin
    run "$SKILLS/wt-find/scripts/find-touching.sh" file.txt --root "$DEV"
    [ "$status" -eq 0 ]
    assert_contains "$output" ".worktrees/alpha"
}

@test "commands.sh rejects an unknown action" {
    make_worktree alpha
    run "$SKILLS/wt-triage/scripts/commands.sh" "$REPO/.worktrees/alpha" shred
    [ "$status" -eq 2 ]
    assert_contains "$output" "unknown action 'shred'"
}

@test "commands.sh chains the commands and picks a distinct tag on a basename collision" {
    make_worktree alpha
    # Another worktree named alpha was archived earlier, at a different commit.
    git -C "$REPO" tag archive/alpha main
    git -C "$REPO/.worktrees/alpha" commit -q --allow-empty -m "own work"
    local sha8
    sha8="$(git -C "$REPO/.worktrees/alpha" rev-parse --short=8 HEAD)"

    run "$SKILLS/wt-triage/scripts/commands.sh" "$REPO/.worktrees/alpha" archive
    [ "$status" -eq 0 ]
    assert_contains "$output" "tag archive/alpha-${sha8} worktree/alpha && \\"
    assert_contains "$output" "worktree remove .worktrees/alpha && \\"
    assert_contains "$output" "branch -D worktree/alpha"
    assert_not_contains "$output" "tag archive/alpha worktree/alpha"
}

@test "commands.sh targets the bare repo for a worktree of a bare repo" {
    git clone -q --bare "$REPO" "$TMPROOT/bare.git"
    git -C "$TMPROOT/bare.git" worktree add -q "$TMPROOT/bare-wt" -b worktree/bare
    run "$SKILLS/wt-triage/scripts/commands.sh" "$TMPROOT/bare-wt" remove
    [ "$status" -eq 0 ]
    assert_contains "$output" "git -C $TMPROOT/bare.git worktree remove $TMPROOT/bare-wt"
    assert_not_contains "$output" "git -C $TMPROOT worktree"
}

@test "commands.sh takes a worktree outside the repo and uses its absolute path" {
    git -C "$REPO" worktree add -q "$TMPROOT/t3/alpha" -b worktree/far
    run "$SKILLS/wt-triage/scripts/commands.sh" "$TMPROOT/t3/alpha" archive
    [ "$status" -eq 0 ]
    assert_contains "$output" "git -C $REPO tag archive/alpha worktree/far"
    assert_contains "$output" "worktree remove $TMPROOT/t3/alpha"
    assert_contains "$output" "branch -D worktree/far"
}

@test "commands.sh refuses the main checkout" {
    run "$SKILLS/wt-triage/scripts/commands.sh" "$REPO" remove
    [ "$status" -eq 1 ]
    assert_contains "$output" "main checkout"
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
