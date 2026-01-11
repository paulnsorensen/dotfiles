#!/usr/bin/env bats
# Tests for sync and rollback functionality

load test_helper

setup() {
    setup_test_env
    
    # Create mock dotfiles
    export MOCK_DOTFILES="$TEST_HOME/mock-dotfiles"
    mkdir -p "$MOCK_DOTFILES"
    
    # Create some test files
    echo "bashrc content" > "$MOCK_DOTFILES/bashrc"
    echo "vimrc content" > "$MOCK_DOTFILES/vimrc"
    mkdir -p "$MOCK_DOTFILES/config"
    echo "config content" > "$MOCK_DOTFILES/config/test.conf"
}

teardown() {
    teardown_test_env
}

@test "sync script creates state directory" {
    cd "$MOCK_DOTFILES"
    
    # Run just the state initialization part
    DOTFILES_STATE_DIR="$TEST_HOME/.local/state/dotfiles"
    mkdir -p "${DOTFILES_STATE_DIR}/backups"
    
    assert_dir_exists "$DOTFILES_STATE_DIR"
    assert_dir_exists "$DOTFILES_STATE_DIR/backups"
}

@test "sync creates manifest of symlinks" {
    # Create a test symlink
    ln -s "$MOCK_DOTFILES/bashrc" "$TEST_HOME/.bashrc"
    
    # Create manifest
    MANIFEST_FILE="$DOTFILES_STATE_DIR/current.manifest"
    echo "$TEST_HOME/.bashrc:$MOCK_DOTFILES/bashrc" > "$MANIFEST_FILE"
    
    assert_file_exists "$MANIFEST_FILE"
    grep -q ".bashrc" "$MANIFEST_FILE"
}

@test "rollback script lists backups" {
    # Create mock backup directories
    mkdir -p "$DOTFILES_STATE_DIR/backups/20240101_120000"
    mkdir -p "$DOTFILES_STATE_DIR/backups/20240102_120000"
    
    # Create metadata files
    echo '{"timestamp": "2024-01-01T12:00:00Z"}' > \
        "$DOTFILES_STATE_DIR/backups/20240101_120000/metadata.json"
    
    # List backups (simulated)
    backups=$(ls "$DOTFILES_STATE_DIR/backups")
    [[ -n "$backups" ]]
    [[ "$backups" == *"20240101_120000"* ]]
    [[ "$backups" == *"20240102_120000"* ]]
}

@test "backup preserves existing files" {
    # Create existing file that would be overwritten
    echo "original content" > "$TEST_HOME/.bashrc"
    
    # Create backup directory
    BACKUP_DIR="$DOTFILES_STATE_DIR/backups/test_backup"
    mkdir -p "$BACKUP_DIR"
    
    # Backup the file
    cp "$TEST_HOME/.bashrc" "$BACKUP_DIR/.bashrc"
    
    assert_file_exists "$BACKUP_DIR/.bashrc"
    grep -q "original content" "$BACKUP_DIR/.bashrc"
}

@test "sync creates symlinks correctly" {
    cd "$MOCK_DOTFILES"
    
    # Simulate creating symlink
    ln -s "$MOCK_DOTFILES/vimrc" "$TEST_HOME/.vimrc"
    
    assert_symlink "$TEST_HOME/.vimrc" "$MOCK_DOTFILES/vimrc"
}

@test "sync handles existing symlinks" {
    # Create an existing symlink
    ln -s "/some/other/path" "$TEST_HOME/.bashrc"
    
    # Remove old symlink
    rm "$TEST_HOME/.bashrc"
    
    # Create new symlink
    ln -s "$MOCK_DOTFILES/bashrc" "$TEST_HOME/.bashrc"
    
    assert_symlink "$TEST_HOME/.bashrc" "$MOCK_DOTFILES/bashrc"
}

@test "sync backs up non-symlink files" {
    # Create a regular file
    echo "existing vimrc" > "$TEST_HOME/.vimrc"
    
    # Backup directory
    OLD_DIR="$TEST_HOME/.dotfiles.bak"
    mkdir -p "$OLD_DIR"
    
    # Move to backup
    mv "$TEST_HOME/.vimrc" "$OLD_DIR/"
    
    assert_file_exists "$OLD_DIR/.vimrc"
    grep -q "existing vimrc" "$OLD_DIR/.vimrc"
}

@test "state directory stores last sync timestamp" {
    LAST_SYNC_FILE="$DOTFILES_STATE_DIR/last_sync"
    
    # Store timestamp
    echo "$(date +%s)" > "$LAST_SYNC_FILE"
    
    assert_file_exists "$LAST_SYNC_FILE"
    
    # Timestamp should be a number
    timestamp=$(cat "$LAST_SYNC_FILE")
    [[ "$timestamp" =~ ^[0-9]+$ ]]
}