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
export SYNC_SCRIPT="$SYNC_SCRIPT"
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

@test "refresh argument sets FORCE_PACKAGES=true" {
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT" refresh
    assert_success
    assert_output_contains "Setting force_packages=true"
}


@test "package sync failure is non-fatal — symlinks still run, failure reported" {
    # A failing package sync must NOT abort the whole run (set -e used to stop
    # here, leaving symlinks + chezmoi un-applied). It should be recorded and
    # reported, while the rest of the sync proceeds.
    printf '#!/bin/bash\nexit 1\n' > "$FAKE_DOTFILES/packages/sync.sh"
    echo "alias foo=bar" > "$FAKE_DOTFILES/myaliases"
    cd "$FAKE_DOTFILES"
    run bash "$SYNC_SCRIPT"
    assert_failure
    assert_output_contains "FAILURES in: packages"
    assert_output_not_contains "Sync completed successfully"
    # Proof the symlink step ran despite the package failure.
    local resolved_home
    resolved_home=$(cd "$TEST_HOME" && pwd -P)
    [[ -L "$resolved_home/.myaliases" ]]
}

@test ".git directory is not symlinked" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/.git"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/.git" ]]
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
    # The sync script resolves pwd, so check for symlink existence
    # using resolved paths (macOS: /tmp -> /private/tmp)
    local resolved_home
    resolved_home=$(cd "$TEST_HOME" && pwd -P)
    [[ -L "$resolved_home/.myaliases" ]]
    # Verify symlink points to a file containing our content
    [[ -f "$resolved_home/.myaliases" ]]
    grep -q "alias foo=bar" "$resolved_home/.myaliases"
}


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

@test "hidden .copilot .sync runs after visible sync scripts" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/mysubdir" "$FAKE_DOTFILES/.copilot"
    cat > "$FAKE_DOTFILES/mysubdir/.sync" << 'SCRIPT'
#!/bin/bash
printf 'VISIBLE_SYNC_RAN\n'
SCRIPT
    chmod +x "$FAKE_DOTFILES/mysubdir/.sync"
    cat > "$FAKE_DOTFILES/.copilot/.sync" << 'SCRIPT'
#!/bin/bash
printf 'COPILOT_SYNC_RAN\n'
SCRIPT
    chmod +x "$FAKE_DOTFILES/.copilot/.sync"

    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "Running .sync for mysubdir"
    assert_output_contains "Running .sync for .copilot"

    local clean_output
    clean_output=$(strip_colors "$output")

    local visible_line
    visible_line=$(printf '%s\n' "$clean_output" | awk '/VISIBLE_SYNC_RAN/{print NR; exit}')

    local copilot_line
    copilot_line=$(printf '%s\n' "$clean_output" | awk '/COPILOT_SYNC_RAN/{print NR; exit}')

    [[ -n "$visible_line" ]]
    [[ -n "$copilot_line" ]]
    [[ "$visible_line" -lt "$copilot_line" ]]
}
