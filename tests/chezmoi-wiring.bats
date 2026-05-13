#!/usr/bin/env bats
# Tests for chezmoi/.sync — first-time wiring, idempotence, and the
# run_onchange installer script that copies dotfiles-owned skills into
# ~/.claude/skills via skills-install/install-local.sh.

load test_helper

setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
    export INSTALLER_TMPL="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_install-claude-skills.sh.tmpl"
}

teardown() { teardown_test_env; }

# ── chezmoi/.sync wiring ────────────────────────────────────────────────

@test "chezmoi/.sync creates chezmoi.toml on fresh setup" {
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run bash "$CHEZMOI_SYNC"
    assert_success

    assert_file_exists "$HOME/.config/chezmoi/chezmoi.toml"
    grep -qF "sourceDir = \"$REAL_DOTFILES_DIR/chezmoi\"" "$HOME/.config/chezmoi/chezmoi.toml"
}

@test "chezmoi/.sync is a no-op when chezmoi.toml already exists (preserves user edits)" {
    run bash "$CHEZMOI_SYNC"
    assert_success

    local config="$HOME/.config/chezmoi/chezmoi.toml"
    cat > "$config" <<EOF
sourceDir = "/some/user/override"

[diff]
exclude = ["scripts"]

[merge]
command = "vimdiff"
EOF

    local before
    before=$(shasum -a 256 "$config" | awk '{print $1}')

    run bash "$CHEZMOI_SYNC"
    assert_success

    local after
    after=$(shasum -a 256 "$config" | awk '{print $1}')
    [[ "$before" == "$after" ]]

    grep -qF '[diff]' "$config"
    grep -qF '[merge]' "$config"
    grep -qF 'sourceDir = "/some/user/override"' "$config"
}

@test "chezmoi/.sync cleans up its mktemp scratch file" {
    run bash "$CHEZMOI_SYNC"
    assert_success

    if compgen -G "$HOME/.config/chezmoi/chezmoi-toml.*" >/dev/null; then
        echo "leftover mktemp scratch file in config dir" >&2
        return 1
    fi
}

# ── source-tree scaffold ────────────────────────────────────────────────

@test "chezmoi/.chezmoiroot exists" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot"
}

@test "chezmoi/run_onchange template references install-local.sh" {
    assert_file_exists "$INSTALLER_TMPL"
    grep -qF 'skills-install/install-local.sh' "$INSTALLER_TMPL"
    # shellcheck disable=SC2016 # literal text in the template, not a shell expansion
    grep -qF '$DOTFILES_ROOT/skills' "$INSTALLER_TMPL"
    grep -qF '.claude/skills' "$INSTALLER_TMPL"
}

@test "chezmoi/run_onchange template embeds a content hash so chezmoi re-runs on changes" {
    grep -qF 'Skills tree hash:' "$INSTALLER_TMPL"
    grep -qF 'output' "$INSTALLER_TMPL"
}

@test "chezmoi/run_onchange template hashes the same tree it installs from" {
    # Locks PR #1's flatten: hash-line tree path and installer source arg
    # must agree. Reverting one without the other would silently de-sync
    # the run_onchange trigger from the install source.
    grep -qF '/../skills -type f' "$INSTALLER_TMPL"
    # And the old nested path must be gone from both the hash and the exec line.
    if grep -qF '/../claude/skills' "$INSTALLER_TMPL"; then
        echo "template still references the pre-flatten claude/skills tree" >&2
        return 1
    fi
}

# ── end-to-end: chezmoi apply runs the installer ───────────────────────

@test "chezmoi apply triggers the skill installer (real files in ~/.claude/skills)" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    run bash "$CHEZMOI_SYNC"
    assert_success

    # The installer reads from the real dotfiles claude/skills tree.
    # We just need to assert that chezmoi apply triggers the run_onchange
    # script, which exec's install-local.sh. After apply, at least one
    # known dotfiles-owned skill should land at ~/.claude/skills/ as a real
    # directory and the manifest should list it.
    run chezmoi apply --force
    assert_success

    assert_file_exists "$HOME/.claude/skills/.dotfiles-managed"
    [[ -s "$HOME/.claude/skills/.dotfiles-managed" ]]

    # Pick the first managed skill from the manifest and assert it exists
    # as a real directory (not a symlink).
    local first
    first=$(head -1 "$HOME/.claude/skills/.dotfiles-managed")
    [[ -n "$first" ]]
    [[ -d "$HOME/.claude/skills/$first" && ! -L "$HOME/.claude/skills/$first" ]]
}
