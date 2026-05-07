#!/usr/bin/env bats
# Tests for chezmoi/.sync — the chezmoi source-dir wiring that runs during
# dots sync. Covers idempotence (don't clobber user edits to chezmoi.toml)
# and recovery from a stale sourceDir line.

load test_helper

setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
}

teardown() {
    teardown_test_env
}

@test "chezmoi/.sync creates ~/.chezmoi symlink and chezmoi.toml on fresh setup" {
    [[ ! -e "$HOME/.chezmoi" ]]
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run bash "$CHEZMOI_SYNC"
    assert_success

    assert_symlink "$HOME/.chezmoi" "$REAL_DOTFILES_DIR/chezmoi"
    assert_file_exists "$HOME/.config/chezmoi/chezmoi.toml"
    grep -q "sourceDir = \"$HOME/.chezmoi\"" "$HOME/.config/chezmoi/chezmoi.toml"
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

    # User edits still present.
    grep -q "exclude = \[\"scripts\"\]" "$config"
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
    grep -q "sourceDir = \"$HOME/.chezmoi\"" "$config"

    # Old sourceDir line is gone.
    if grep -q "sourceDir = \"/some/old/path\"" "$config"; then
        echo "stale sourceDir line still present" >&2
        return 1
    fi

    # User edits preserved.
    grep -q '\[diff\]' "$config"
    grep -q 'exclude = \["scripts"\]' "$config"
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
