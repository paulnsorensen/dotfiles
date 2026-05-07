#!/usr/bin/env bats
# Tests for chezmoi/.sync — the chezmoi config-file wiring that runs during
# dots sync. Covers first-time setup, idempotence (don't touch an existing
# config), the .chezmoiroot scaffold, and the Phase 0 invariant that
# chezmoiignore=* makes `chezmoi apply` a no-op.

load test_helper

setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
}

teardown() {
    teardown_test_env
}

# ── chezmoi/.sync direct invocation ─────────────────────────────────────

@test "chezmoi/.sync creates chezmoi.toml on fresh setup" {
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run bash "$CHEZMOI_SYNC"
    assert_success

    assert_file_exists "$HOME/.config/chezmoi/chezmoi.toml"
    grep -qF "sourceDir = \"$REAL_DOTFILES_DIR/chezmoi\"" "$HOME/.config/chezmoi/chezmoi.toml"
}

@test "chezmoi/.sync is a no-op when chezmoi.toml already exists" {
    # First run sets up the file.
    run bash "$CHEZMOI_SYNC"
    assert_success

    local config="$HOME/.config/chezmoi/chezmoi.toml"

    # User edits the file freely — adds sections, comments, even changes
    # sourceDir to something else.
    cat > "$config" <<EOF
sourceDir = "/some/user/override"

[diff]
exclude = ["scripts"]

[merge]
command = "vimdiff"
EOF

    local before_hash
    before_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    # Re-run: file exists, script is a no-op.
    run bash "$CHEZMOI_SYNC"
    assert_success

    local after_hash
    after_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    # Idempotent: file content byte-for-byte unchanged.
    [[ "$before_hash" == "$after_hash" ]]

    # User edits all preserved (fixed-string match).
    grep -qF '[diff]' "$config"
    grep -qF 'exclude = ["scripts"]' "$config"
    grep -qF '[merge]' "$config"
    grep -qF 'command = "vimdiff"' "$config"
    grep -qF 'sourceDir = "/some/user/override"' "$config"
}

@test "chezmoi/.sync produces a well-formed chezmoi.toml on success" {
    # Outcome-correctness check: after a successful run the config file
    # exists, is non-empty, contains the expected sourceDir line, and the
    # mktemp scratch file has been cleaned up from the config dir.
    # (Atomicity itself isn't directly testable in bash without fault
    # injection — that property is enforced by mv -f's rename(2) on
    # same-fs sources, which the script ensures by mktemp'ing into the
    # config dir directly.)
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run bash "$CHEZMOI_SYNC"
    assert_success

    assert_file_exists "$HOME/.config/chezmoi/chezmoi.toml"

    local content
    content=$(cat "$HOME/.config/chezmoi/chezmoi.toml")
    [[ -n "$content" ]]
    grep -qF "sourceDir = \"$REAL_DOTFILES_DIR/chezmoi\"" "$HOME/.config/chezmoi/chezmoi.toml"

    # No mktemp scratch file left behind in the config dir.
    if compgen -G "$HOME/.config/chezmoi/chezmoi-toml.*" >/dev/null; then
        echo "leftover mktemp scratch file in config dir" >&2
        return 1
    fi
}

# ── source-tree scaffold invariants ────────────────────────────────────

@test "chezmoi/.chezmoiroot exists at the source tree root" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot"
}

@test "chezmoi/.chezmoiroot is empty (Phase 0 invariant)" {
    [[ ! -s "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot" ]]
}

@test "chezmoi/.chezmoiignore contains the Phase 0 placeholder marker" {
    grep -qF 'REMOVE WHEN PHASE 1 NARROWS THIS' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    grep -qF '.cheese/specs/chezmoi-migration.md' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    grep -qxF '*' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
}

# ── Phase 0 invariant: chezmoi apply is a no-op ────────────────────────

@test "chezmoi apply against the real source tree creates no files in HOME (Phase 0)" {
    # The Phase 0 invariant: chezmoiignore=* means nothing is materialized.
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    # Wire up via the real sync script (writes chezmoi.toml).
    run bash "$CHEZMOI_SYNC"
    assert_success

    # Snapshot $HOME contents (excluding the chezmoi config dir we just made).
    local before
    before=$(find "$HOME" -mindepth 1 -maxdepth 3 \
        -not -path "$HOME/.config" \
        -not -path "$HOME/.config/*" \
        2>/dev/null | sort)

    run chezmoi apply
    assert_success

    local after
    after=$(find "$HOME" -mindepth 1 -maxdepth 3 \
        -not -path "$HOME/.config" \
        -not -path "$HOME/.config/*" \
        2>/dev/null | sort)

    # Phase 0 invariant: nothing materialized.
    if [[ "$before" != "$after" ]]; then
        echo "chezmoi apply created files in HOME during Phase 0" >&2
        echo "diff:" >&2
        diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
        return 1
    fi
}

# ── End-to-end idempotence through dots sync ───────────────────────────

@test "two runs of chezmoi/.sync via dots sync flow leave chezmoi.toml byte-for-byte stable" {
    # Build a minimal fake DOTFILES_DIR that runs the real chezmoi/.sync.
    local fake_dotfiles="$TEST_HOME/fake-dotfiles"
    mkdir -p "$fake_dotfiles/packages" "$fake_dotfiles/bin" "$fake_dotfiles/chezmoi"

    printf '#!/bin/bash\nexit 0\n' > "$fake_dotfiles/packages/sync.sh"
    chmod +x "$fake_dotfiles/packages/sync.sh"

    cat > "$fake_dotfiles/.sync-with-rollback" <<EOF
#!/bin/bash
set -euo pipefail
bash "$REAL_DOTFILES_DIR/chezmoi/.sync"
EOF
    chmod +x "$fake_dotfiles/.sync-with-rollback"

    cp "$REAL_DOTFILES_DIR/bin/dots" "$fake_dotfiles/bin/dots"

    local config="$HOME/.config/chezmoi/chezmoi.toml"

    # First sync creates chezmoi.toml.
    run env DOTFILES_DIR="$fake_dotfiles" PATH="$fake_dotfiles/bin:$PATH" \
        "$fake_dotfiles/bin/dots" sync
    assert_success
    assert_file_exists "$config"

    # User adds custom keys.
    {
        echo ""
        echo "[merge]"
        echo "command = \"vimdiff\""
    } >> "$config"

    local before_hash
    before_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    # Second sync: chezmoi/.sync is a no-op; chezmoi.toml unchanged.
    run env DOTFILES_DIR="$fake_dotfiles" PATH="$fake_dotfiles/bin:$PATH" \
        "$fake_dotfiles/bin/dots" sync
    assert_success

    local after_hash
    after_hash=$(shasum -a 256 "$config" | awk '{print $1}')

    [[ "$before_hash" == "$after_hash" ]]

    grep -qF '[merge]' "$config"
    grep -qF 'command = "vimdiff"' "$config"
}
