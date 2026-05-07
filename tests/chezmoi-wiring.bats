#!/usr/bin/env bats
# Tests for chezmoi/.sync — the chezmoi source-dir wiring that runs during
# dots sync. Covers idempotence (don't clobber user edits to chezmoi.toml),
# recovery from a stale sourceDir line, the .chezmoiroot scaffold, and
# the Phase 0 invariant that chezmoiignore=* makes `chezmoi apply` a no-op.

load test_helper

setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
}

teardown() {
    teardown_test_env
}

# ── chezmoi/.sync direct invocation ─────────────────────────────────────

@test "chezmoi/.sync creates ~/.chezmoi symlink and chezmoi.toml on fresh setup" {
    [[ ! -e "$HOME/.chezmoi" ]]
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run bash "$CHEZMOI_SYNC"
    assert_success

    assert_symlink "$HOME/.chezmoi" "$REAL_DOTFILES_DIR/chezmoi"
    assert_file_exists "$HOME/.config/chezmoi/chezmoi.toml"
    grep -qF "sourceDir = \"$HOME/.chezmoi\"" "$HOME/.config/chezmoi/chezmoi.toml"
}

@test "chezmoi/.sync preserves user edits when chezmoi.toml is already correct" {
    run bash "$CHEZMOI_SYNC"
    assert_success

    local config="$HOME/.config/chezmoi/chezmoi.toml"

    # User adds a custom section after the generated sourceDir line.
    {
        echo ""
        echo "[diff]"
        echo "exclude = [\"scripts\"]"
    } >> "$config"

    local before_hash
    before_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    run bash "$CHEZMOI_SYNC"
    assert_success

    local after_hash
    after_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    # Idempotent: file content byte-for-byte unchanged on re-run.
    [[ "$before_hash" == "$after_hash" ]]

    # User edits still present (fixed-string match — no escaping ambiguity).
    grep -qF 'exclude = ["scripts"]' "$config"
    grep -qF '[diff]' "$config"
}

@test "chezmoi/.sync rewrites stale sourceDir while preserving user edits" {
    local config_dir="$HOME/.config/chezmoi"
    local config="$config_dir/chezmoi.toml"
    mkdir -p "$config_dir"

    # Pre-existing config with outdated sourceDir + user-added section.
    cat > "$config" <<EOF
sourceDir = "/some/old/path"

[diff]
exclude = ["scripts"]
EOF

    run bash "$CHEZMOI_SYNC"
    assert_success

    # sourceDir is updated to the symlink target.
    grep -qF "sourceDir = \"$HOME/.chezmoi\"" "$config"

    # Old sourceDir line is gone.
    if grep -qF 'sourceDir = "/some/old/path"' "$config"; then
        echo "stale sourceDir line still present" >&2
        return 1
    fi

    # User edits preserved (fixed-string match).
    grep -qF '[diff]' "$config"
    grep -qF 'exclude = ["scripts"]' "$config"
}

@test "chezmoi/.sync refuses to replace a non-symlink at ~/.chezmoi" {
    mkdir -p "$HOME/.chezmoi"
    echo "user-content" > "$HOME/.chezmoi/preexisting"

    run bash "$CHEZMOI_SYNC"
    assert_failure
    assert_output_contains "Refusing to replace existing"

    # User content untouched.
    assert_file_exists "$HOME/.chezmoi/preexisting"
}

# ── source-tree scaffold invariants ────────────────────────────────────

@test "chezmoi/.chezmoiroot exists at the source tree root" {
    # The .chezmoiroot file marks the chezmoi source root explicitly so
    # chezmoi doesn't have to resolve through the ~/.chezmoi symlink.
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot"
}

@test "chezmoi/.chezmoiroot is empty (Phase 0 invariant)" {
    # An empty .chezmoiroot signals 'this dir is the root' without further
    # config. Future phases may add content; for Phase 0 it must be empty.
    [[ ! -s "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot" ]]
}

@test "chezmoi/.chezmoiignore contains the Phase 0 placeholder marker" {
    # Comment block must flag the wildcard as intentional and point at
    # the migration spec so future work knows where to narrow it.
    grep -qF 'REMOVE WHEN PHASE 1 NARROWS THIS' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    grep -qF '.cheese/specs/chezmoi-migration.md' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"

    # The wildcard itself is present and uncommented.
    grep -qxF '*' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
}

# ── Phase 0 invariant: chezmoi apply is a no-op ────────────────────────

@test "chezmoi apply against the real source tree creates no files in HOME (Phase 0)" {
    # The Phase 0 invariant: chezmoiignore=* means nothing is materialized.
    # If chezmoi isn't installed locally, skip — this is the only test that
    # exercises the real binary and we don't want CI to fail on missing tool.
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    # Wire up via the real sync script first (creates ~/.chezmoi symlink
    # and chezmoi.toml).
    run bash "$CHEZMOI_SYNC"
    assert_success

    # Snapshot $HOME contents (excluding the chezmoi config dir we just made).
    local before
    before=$(find "$HOME" -mindepth 1 -maxdepth 3 \
        -not -path "$HOME/.config" \
        -not -path "$HOME/.config/*" \
        -not -path "$HOME/.chezmoi" \
        2>/dev/null | sort)

    # Run chezmoi apply; should be a no-op.
    run chezmoi apply
    assert_success

    local after
    after=$(find "$HOME" -mindepth 1 -maxdepth 3 \
        -not -path "$HOME/.config" \
        -not -path "$HOME/.config/*" \
        -not -path "$HOME/.chezmoi" \
        2>/dev/null | sort)

    # Phase 0 invariant: nothing materialized.
    if [[ "$before" != "$after" ]]; then
        echo "chezmoi apply created files in HOME during Phase 0" >&2
        echo "diff:" >&2
        diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
        return 1
    fi
}

# ── End-to-end idempotence through the real chezmoi/.sync ──────────────

@test "two runs of chezmoi/.sync via dots sync flow leave chezmoi.toml byte-for-byte stable" {
    # Build a minimal fake DOTFILES_DIR that contains a real symlink to the
    # actual chezmoi/ subtree (so the real chezmoi/.sync runs, not a mock).
    local fake_dotfiles="$TEST_HOME/fake-dotfiles"
    mkdir -p "$fake_dotfiles/packages" "$fake_dotfiles/bin"

    # Stub package sync (not under test here).
    printf '#!/bin/bash\nexit 0\n' > "$fake_dotfiles/packages/sync.sh"
    chmod +x "$fake_dotfiles/packages/sync.sh"

    # Stub .sync-with-rollback that invokes the real chezmoi/.sync via the
    # same path-resolution dance as the real .sync-lib.sh sync_entry.
    cat > "$fake_dotfiles/.sync-with-rollback" <<EOF
#!/bin/bash
set -euo pipefail
bash "$REAL_DOTFILES_DIR/chezmoi/.sync"
EOF
    chmod +x "$fake_dotfiles/.sync-with-rollback"

    # Real bin/dots from the source tree.
    cp "$REAL_DOTFILES_DIR/bin/dots" "$fake_dotfiles/bin/dots"

    local config="$HOME/.config/chezmoi/chezmoi.toml"

    # First sync: creates everything.
    run env DOTFILES_DIR="$fake_dotfiles" PATH="$fake_dotfiles/bin:$PATH" \
        "$fake_dotfiles/bin/dots" sync
    assert_success
    assert_file_exists "$config"

    # User adds a custom key.
    {
        echo ""
        echo "[merge]"
        echo "command = \"vimdiff\""
    } >> "$config"

    local before_hash
    before_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    # Second sync: must not touch chezmoi.toml.
    run env DOTFILES_DIR="$fake_dotfiles" PATH="$fake_dotfiles/bin:$PATH" \
        "$fake_dotfiles/bin/dots" sync
    assert_success

    local after_hash
    after_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    [[ "$before_hash" == "$after_hash" ]]

    # User customization survives the round-trip.
    grep -qF '[merge]' "$config"
    grep -qF 'command = "vimdiff"' "$config"
}
