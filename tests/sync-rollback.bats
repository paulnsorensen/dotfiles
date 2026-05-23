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
        export SYNC_SCRIPT='$SYNC_SCRIPT'
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
        touch -t "2025010${i}1200" "$base/2025010${i}_120000"
    done

    # call-sync-fn creates an additional backup dir with current timestamp
    # so 5 fixture dirs + 1 from call-sync-fn = 6 total, keep 3 to verify pruning
    run call-sync-fn clean_backups 3
    assert_success
    [ -d "$base/20250105_120000" ]
    [ ! -d "$base/20250101_120000" ]
    [ ! -d "$base/20250102_120000" ]
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


# rollback() restore loop — guard the dotglob fix and the symlink-conflict
# fallthrough on broken symlinks. The restore loop iterates the backup dir
# with the bash default glob, which skips dotfiles unless dotglob is set;
# the symlink restore uses [[ -e || -L ]] so broken symlinks count as
# conflicts. Both are easy to silently regress on.

# Helper: prep a backup dir + manifest, then run rollback non-interactively.
_prep_rollback_backup() {
    local backup_id="$1"
    local bk="$TEST_HOME/.local/state/dotfiles/backups/$backup_id"
    mkdir -p "$bk"
    # metadata.json is required for backup discovery, but not for rollback
    # itself; include it for parity with real backups.
    echo "{}" > "$bk/metadata.json"
    echo "$bk"
}

@test "rollback restores dotfiles (dotglob)" {
    local backup_id="20250101_120000"
    local bk
    bk=$(_prep_rollback_backup "$backup_id")
    # Place a dotfile in the backup — the default bash glob would skip it.
    echo "restored zshrc" > "$bk/.zshrc"
    # Empty manifest so the symlink-restore loop is a no-op.
    : > "$bk/manifest"

    # Pre-existing target with different content — rollback must replace it.
    echo "stale zshrc" > "$TEST_HOME/.zshrc"

    BACKUP_TS="$backup_id" run bash -c "echo y | call-sync-fn rollback $backup_id"
    assert_success
    assert_file_exists "$TEST_HOME/.zshrc"
    run cat "$TEST_HOME/.zshrc"
    assert_output_contains "restored zshrc"
}

@test "rollback flags broken symlinks at conflicting paths" {
    local backup_id="20250101_120001"
    local bk
    bk=$(_prep_rollback_backup "$backup_id")
    # Manifest declares a symlink the rollback should recreate.
    local link="$TEST_HOME/.broken_link"
    local target="$bk/restored-target"
    echo "target" > "$target"
    printf '%s:%s\n' "$link" "$target" > "$bk/manifest"

    # Leave a dangling symlink at the destination — `[[ -e ]]` alone
    # returns false on broken symlinks, so the conflict counter would
    # silently fail to fire without the `-L` guard.
    ln -s "$TEST_HOME/does-not-exist" "$link"

    BACKUP_TS="$backup_id" run bash -c "echo y | call-sync-fn rollback $backup_id"
    assert_success
    assert_output_contains "symlink(s) skipped"
}

@test "rollback replaces directories instead of merging" {
    local backup_id="20250101_120002"
    local bk
    bk=$(_prep_rollback_backup "$backup_id")
    # Backup holds a directory with a single file.
    mkdir -p "$bk/.config"
    echo "from backup" > "$bk/.config/keep.conf"
    : > "$bk/manifest"

    # Pre-existing target dir with a stale file absent from the backup. A
    # merging restore (cp -r without the rm) would leave stale.conf behind;
    # the rm-before-cp replace must delete it. Without this case a regression
    # that drops the `rm` still passes the file-based dotglob test.
    mkdir -p "$TEST_HOME/.config"
    echo "stale" > "$TEST_HOME/.config/stale.conf"

    BACKUP_TS="$backup_id" run bash -c "echo y | call-sync-fn rollback $backup_id"
    assert_success
    assert_file_exists "$TEST_HOME/.config/keep.conf"
    [[ ! -e "$TEST_HOME/.config/stale.conf" ]] || {
        echo "stale.conf survived — restore merged instead of replacing" >&2
        false
    }
}

@test "rollback surfaces and counts restore failures" {
    # Root bypasses the directory-permission bits this test relies on to
    # force `rm` to fail, so the failure branch can't be provoked as root.
    [[ "$(id -u)" -eq 0 ]] && skip "needs non-root to enforce a permission failure"

    local backup_id="20250101_120003"
    local bk
    bk=$(_prep_rollback_backup "$backup_id")
    mkdir -p "$bk/.config"
    echo "from backup" > "$bk/.config/keep.conf"
    : > "$bk/manifest"

    # Pre-existing target dir rollback cannot clear: a child file inside a
    # directory stripped of write permission. `rm -rf` needs write+execute on
    # the dir to unlink its contents, so the rm-before-cp fails → the restore
    # is counted and the "failed to restore" warning fires. This is the PR's
    # headline "surface restore failures" behaviour.
    mkdir -p "$TEST_HOME/.config"
    echo "locked" > "$TEST_HOME/.config/locked.conf"
    chmod 500 "$TEST_HOME/.config"

    BACKUP_TS="$backup_id" run bash -c "echo y | call-sync-fn rollback $backup_id"
    # Restore perms before asserting so a failed assertion can't leave the
    # tree unremovable for teardown.
    chmod 700 "$TEST_HOME/.config"

    # rollback continues past the failure (returns 0) but reports it.
    assert_success
    assert_output_contains "file(s) failed to restore"
}
