#!/usr/bin/env bats
# shellcheck disable=SC2012
# Tests for .sync — the main dotfiles sync orchestrator
#
# Unit tests source functions via call-sync-fn helper.
# Integration tests run the full script against a fake dotfiles directory.

load test_helper

SYNC_SCRIPT="$REAL_DOTFILES_DIR/.sync"

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

    # Mock bootstrap/runtime commands — no-ops
    for cmd in brew prek uv tmux yq omp chezmoi; do
        printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/$cmd"
        chmod +x "$MOCK_BIN/$cmd"
    done

    # Mock packages/sync.sh
    mkdir -p "$FAKE_DOTFILES/packages"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/packages/sync.sh"
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    # Mock chezmoi/.chezmoidata/omp.yaml registry — empty plugin set
    mkdir -p "$FAKE_DOTFILES/chezmoi/.chezmoidata"
    printf 'omp:\n  plugins: {}\n' > "$FAKE_DOTFILES/chezmoi/.chezmoidata/omp.yaml"

    export PATH="$MOCK_BIN:$PATH"

    # Helper script: sources sync functions and calls a named function
    cat > "$MOCK_BIN/call-sync-fn" << HELPER
#!/bin/bash
set -euo pipefail
export HOME="$TEST_HOME"
export DOTFILES_STATE_DIR="$TEST_HOME/.local/state/dotfiles"
export SYNC_SCRIPT="$SYNC_SCRIPT"
eval "\$(awk '/^########## Main\$/{exit} {print}' "$SYNC_SCRIPT")"
if [[ -n "\${FAKE_DIR:-}" ]]; then
    dir="\$FAKE_DIR"
    cd "\$FAKE_DIR"
fi
"\$@"
HELPER
    chmod +x "$MOCK_BIN/call-sync-fn"
}

teardown() {
    teardown_test_env
}


@test "record_sync_time writes timestamp" {
    run call-sync-fn record_sync_time
    assert_success
    assert_file_exists "$TEST_HOME/.local/state/dotfiles/last_sync"
    local ts
    ts=$(cat "$TEST_HOME/.local/state/dotfiles/last_sync")
    [[ "$ts" =~ ^[0-9]+$ ]]
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

# cursor is skipped so ~/.cursor stays a real dir owned by chezmoi's
# install-cursor-plugin.sh — a whole-dir symlink leaked Cursor's runtime
# state back into the dotfiles repo.
@test "cursor directory is not symlinked into ~/.cursor" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/cursor"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/.cursor" ]]
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

@test "package sync runs after chezmoi applies the mise manifest" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi-apply\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    run bash "$SYNC_SCRIPT"
    assert_success
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply\npackages-sync' ]]
}

@test "fresh machine bootstraps mise tools before chezmoi then converges packages" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    rm -f "$MOCK_BIN/chezmoi"
    mkdir -p "$FAKE_DOTFILES/chezmoi/dot_config/mise"
    printf '[tools]\n' > "$FAKE_DOTFILES/chezmoi/dot_config/mise/config.toml"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi-apply\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
if [[ "${PACKAGES_BOOTSTRAP_ONLY:-false}" == "true" ]]; then
    printf 'packages-bootstrap\n' >> "$SYNC_EVENTS"
    cat > "$MOCK_BIN/chezmoi" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/chezmoi"
else
    printf 'packages-sync\n' >> "$SYNC_EVENTS"
fi
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    # A real fresh machine has no chezmoi anywhere. Removing only the MOCK_BIN
    # copy is not enough when a host chezmoi is on PATH (dev machines, and CI
    # installs one to /usr/local/bin) — that satisfies `command -v chezmoi` and
    # skips the bootstrap branch. Strip every PATH dir holding a chezmoi binary
    # so the fresh-machine bootstrap fires deterministically.
    local clean_path
    clean_path=$(tr ':' '\n' <<<"$PATH" | while IFS= read -r d; do
        [[ -x "$d/chezmoi" ]] || printf '%s:' "$d"
    done)
    PATH="${clean_path%:}" run bash "$SYNC_SCRIPT"
    assert_success
    run cat "$SYNC_EVENTS"
    local bootstrap_line apply_line sync_line
    bootstrap_line=$(printf '%s\n' "$output" | awk '/packages-bootstrap/{print NR; exit}')
    apply_line=$(printf '%s\n' "$output" | awk '/chezmoi-apply/{print NR; exit}')
    sync_line=$(printf '%s\n' "$output" | awk '/packages-sync/{print NR; exit}')
    [[ -n "$bootstrap_line" && -n "$apply_line" && -n "$sync_line" ]]
    [[ "$bootstrap_line" -lt "$apply_line" ]]
    [[ "$apply_line" -lt "$sync_line" ]]
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
