#!/usr/bin/env bats
# shellcheck disable=SC2012
# Tests for .sync-with-rollback — the main dotfiles sync orchestrator
#
# Unit tests source functions via call-sync-fn helper.
# Integration tests run the full script against a fake dotfiles directory.

load test_helper

SYNC_SCRIPT="$REAL_DOTFILES_DIR/.sync-with-rollback"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    export FAKE_DOTFILES="$TEST_HOME/dotfiles"
    mkdir -p "$MOCK_BIN" "$FAKE_DOTFILES"

    # Mock git — canned output; clone creates fake TPM dir structure
    cat > "$MOCK_BIN/git" << 'MOCK'
#!/bin/bash
case "$1" in
    rev-parse) echo "abc123" ;;
    branch) echo "main" ;;
    config) exit 0 ;;
    clone)
        target="${@: -1}"
        mkdir -p "$target/bin"
        printf '#!/bin/bash\nexit 0\n' > "$target/bin/install_plugins"
        chmod +x "$target/bin/install_plugins"
        ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$MOCK_BIN/git"

    # Mock brew, prek, uv, tmux, yq — no-ops
    for cmd in brew prek uv tmux yq; do
        printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/$cmd"
        chmod +x "$MOCK_BIN/$cmd"
    done

    # Mock packages/sync.sh
    mkdir -p "$FAKE_DOTFILES/packages"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/packages/sync.sh"
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    export PATH="$MOCK_BIN:$PATH"

    # Helper script: sources sync functions and calls a named function
    cat > "$MOCK_BIN/call-sync-fn" << HELPER
#!/bin/bash
set -euo pipefail
export HOME="$TEST_HOME"
export DOTFILES_STATE_DIR="$TEST_HOME/.local/state/dotfiles"
export BACKUP_DIR="\$DOTFILES_STATE_DIR/backups/\${BACKUP_TS:-\$(date +%Y%m%d_%H%M%S)}"
export MANIFEST_FILE="\$DOTFILES_STATE_DIR/current.manifest"
export ROLLBACK_LOG="\$DOTFILES_STATE_DIR/rollback.log"
eval "\$(awk '/^########## Main\$/{exit} {print}' "$SYNC_SCRIPT")"
if [[ -n "\${FAKE_DIR:-}" ]]; then
    dir="\$FAKE_DIR"
    cd "\$FAKE_DIR"
fi
mkdir -p "\$BACKUP_DIR"
"\$@"
HELPER
    chmod +x "$MOCK_BIN/call-sync-fn"
}

teardown() {
    teardown_test_env
}

# --- State management ---

@test "init_state creates state directories and writes timestamp" {
    run call-sync-fn init_state
    assert_success
    assert_dir_exists "$TEST_HOME/.local/state/dotfiles/backups"
    assert_file_exists "$TEST_HOME/.local/state/dotfiles/last_sync"
    local ts
    ts=$(cat "$TEST_HOME/.local/state/dotfiles/last_sync")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "create_manifest finds dotfile symlinks and writes manifest file" {
    export FAKE_DIR="$FAKE_DOTFILES"
    run call-sync-fn init_state
    assert_success

    echo "test" > "$FAKE_DOTFILES/somefile"
    ln -s "$FAKE_DOTFILES/somefile" "$TEST_HOME/.somefile"

    run call-sync-fn create_manifest
    assert_success
    assert_file_exists "$TEST_HOME/.local/state/dotfiles/current.manifest"
    run cat "$TEST_HOME/.local/state/dotfiles/current.manifest"
    assert_output_contains "$TEST_HOME/.somefile:$FAKE_DOTFILES/somefile"
    unset FAKE_DIR
}

@test "backup_current_state copies manifest and writes metadata.json" {
    export FAKE_DIR="$FAKE_DOTFILES"
    local bkbase="$TEST_HOME/.local/state/dotfiles/backups"
    mkdir -p "$TEST_HOME/.local/state/dotfiles"
    echo "/home/.foo:/dotfiles/foo" > "$TEST_HOME/.local/state/dotfiles/current.manifest"
    echo "content" > "$TEST_HOME/.testcfg"
    echo "content" > "$FAKE_DOTFILES/testcfg"

    run call-sync-fn backup_current_state
    assert_success

    local bkdir
    bkdir=$(ls -dt "$bkbase"/*/ | head -1)
    assert_file_exists "$bkdir/manifest"
    assert_file_exists "$bkdir/metadata.json"
    run cat "$bkdir/metadata.json"
    assert_output_contains '"timestamp"'
    assert_output_contains '"git_commit"'
    unset FAKE_DIR
}

@test "list_backups lists backup dirs with timestamps" {
    local bk="$TEST_HOME/.local/state/dotfiles/backups/20250101_120000"
    mkdir -p "$bk"
    cat > "$bk/metadata.json" << 'JSON'
{
    "timestamp": "2025-01-01T12:00:00Z",
    "directory": "/dotfiles",
    "git_commit": "abc123",
    "git_branch": "main"
}
JSON
    run call-sync-fn list_backups
    assert_success
    assert_output_contains "20250101_120000"
    assert_output_contains "2025-01-01T12:00:00Z"
}

@test "list_backups returns 1 when no backups exist" {
    rm -rf "$TEST_HOME/.local/state/dotfiles/backups"
    # Inline source to avoid call-sync-fn's mkdir which recreates backups/
    run bash -c "
        export HOME='$TEST_HOME'
        export DOTFILES_STATE_DIR='$TEST_HOME/.local/state/dotfiles'
        export BACKUP_DIR='\$DOTFILES_STATE_DIR/backups/dummy'
        export MANIFEST_FILE='\$DOTFILES_STATE_DIR/current.manifest'
        export ROLLBACK_LOG='\$DOTFILES_STATE_DIR/rollback.log'
        eval \"\$(awk '/^########## Main\$/{exit} {print}' '$SYNC_SCRIPT')\"
        list_backups
    "
    assert_failure
    assert_output_contains "No backups found"
}

@test "clean_backups keeps N recent and deletes older ones" {
    local base="$TEST_HOME/.local/state/dotfiles/backups"
    mkdir -p "$base"
    for i in 1 2 3 4 5; do
        mkdir -p "$base/2025010${i}_120000"
        echo "{}" > "$base/2025010${i}_120000/metadata.json"
    done
    # Touch with 1s gaps so ls -t sorts correctly (oldest first)
    for i in 1 2 3 4 5; do
        touch "$base/2025010${i}_120000"
        [[ $i -lt 5 ]] && sleep 1
    done

    run call-sync-fn clean_backups 2
    assert_success
    local remaining
    remaining=$(ls -d "$base"/*/ 2>/dev/null | wc -l | tr -d ' ')
    [[ "$remaining" -eq 2 ]]
}

# --- Argument parsing ---

@test "no args runs default sync" {
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "Sync completed successfully"
}

@test "dev argument sets DOTFILES_DEV=true" {
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT" dev
    assert_success
    assert_output_contains "Setting dev=true"
}

@test "q argument sets QUICK_SYNC=true" {
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT" q
    assert_success
    assert_output_contains "Setting quick_sync=true"
}

@test "refresh argument sets FORCE_PACKAGES=true" {
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT" refresh
    assert_success
    assert_output_contains "Setting force_packages=true"
}

# --- Skip list ---

@test ".git directory is not symlinked" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/.git"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/..git" ]]
}

@test "reference directory is not symlinked" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/reference"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/.reference" ]]
}

@test "packages directory is not symlinked" {
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/.packages" ]]
}

@test "regular dotfiles ARE processed as symlinks" {
    cd "$FAKE_DOTFILES"
    echo "alias foo=bar" > "$FAKE_DOTFILES/myaliases"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ -L "$TEST_HOME/.myaliases" ]]
    local target
    target=$(readlink "$TEST_HOME/.myaliases")
    [[ "$target" == "$FAKE_DOTFILES/myaliases" ]]
}

# --- Script delegation ---

@test ".sync scripts in subdirectories are executed" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/mysubdir"
    cat > "$FAKE_DOTFILES/mysubdir/.sync" << 'SCRIPT'
#!/bin/bash
echo "SUBDIR_SYNC_RAN"
SCRIPT
    chmod +x "$FAKE_DOTFILES/mysubdir/.sync"
    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "Running .sync for mysubdir"
}

@test "QUICK_SYNC skips quick-skippable operations" {
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT" q
    assert_success
    assert_output_contains "Setting quick_sync=true"
    assert_output_contains "Sync completed successfully"
}
