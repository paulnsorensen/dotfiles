#!/usr/bin/env bats
# shellcheck disable=SC2012
# Tests for .sync — the main dotfiles sync orchestrator
#
# Unit tests source functions via call-sync-fn helper.
# Integration tests run the full script against a fake dotfiles directory.

load test_helper

export SYNC_SCRIPT="$REAL_DOTFILES_DIR/.sync"

setup_file() {
    export MOCK_BIN="$BATS_FILE_TMPDIR/sync-mocks"
    mkdir -p "$MOCK_BIN"

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
    cat > "$MOCK_BIN/omp" << 'MOCK'
#!/bin/bash
[[ "$1" == "--version" ]] && printf 'omp/17.2.4\n'
MOCK
    chmod +x "$MOCK_BIN/omp"
    cat > "$MOCK_BIN/codex" << 'MOCK'
#!/bin/bash
[[ "$1" == "--version" ]] && printf 'codex-cli 0.146.0\n'
MOCK
    chmod +x "$MOCK_BIN/codex"

    # Helper script: sources sync functions and calls a named function.
    # Quoted heredoc — no write-time substitution — so $TEST_HOME and
    # $SYNC_SCRIPT resolve from the environment at runtime, letting this
    # master executable be shared (symlinked) across every test.
    cat > "$MOCK_BIN/call-sync-fn" << 'HELPER'
#!/bin/bash
set -euo pipefail
export HOME="$TEST_HOME"
export DOTFILES_STATE_DIR="$TEST_HOME/.local/state/dotfiles"
eval "$(awk '/^########## Main$/{exit} {print}' "$SYNC_SCRIPT")"
if [[ -n "${FAKE_DIR:-}" ]]; then
    dir="$FAKE_DIR"
    cd "$FAKE_DIR"
fi
"$@"
HELPER
    chmod +x "$MOCK_BIN/call-sync-fn"

    # Mock packages/sync.sh — no-op default, symlinked into each test's
    # fake dotfiles tree; tests that override its content rm -f first.
    export FAKE_DOTFILES_MASTER="$BATS_FILE_TMPDIR/sync-fixtures"
    mkdir -p "$FAKE_DOTFILES_MASTER/packages"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES_MASTER/packages/sync.sh"
    chmod +x "$FAKE_DOTFILES_MASTER/packages/sync.sh"
}

setup() {
    setup_test_env
    export MOCK_BIN_MASTER="$BATS_FILE_TMPDIR/sync-mocks"
    export FAKE_DOTFILES_MASTER="$BATS_FILE_TMPDIR/sync-fixtures"
    export MOCK_BIN="$TEST_HOME/bin"
    export FAKE_DOTFILES="$TEST_HOME/dotfiles"
    mkdir -p "$MOCK_BIN" "$FAKE_DOTFILES"

    # Symlink (not copy) the mocks generated once in setup_file(): macOS
    # syspolicyd assesses every NEW executable inode on first exec, so
    # sharing inodes across tests pays that tax once per suite run instead
    # of once per test. Any test that rewrites a mock's content must rm -f
    # the symlink first so it never truncates the shared master.
    local f
    for f in "$MOCK_BIN_MASTER/"*; do
        ln -s "$f" "$MOCK_BIN/$(basename "$f")"
    done

    mkdir -p "$FAKE_DOTFILES/packages"
    ln -s "$FAKE_DOTFILES_MASTER/packages/sync.sh" "$FAKE_DOTFILES/packages/sync.sh"

    # Mock chezmoi/.chezmoidata/omp.yaml registry — empty plugin set
    mkdir -p "$FAKE_DOTFILES/chezmoi/.chezmoidata"
    printf 'omp:\n  plugins: {}\n' > "$FAKE_DOTFILES/chezmoi/.chezmoidata/omp.yaml"

    export PATH="$MOCK_BIN:$PATH"
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
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "Sync completed successfully"
}

@test "dev argument sets DOTFILES_DEV=true" {
    cd "$FAKE_DOTFILES"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
    run bash "$SYNC_SCRIPT" dev
    assert_success
    assert_output_contains "Setting dev=true"
}

@test "refresh argument sets FORCE_PACKAGES=true" {
    cd "$FAKE_DOTFILES"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
    run bash "$SYNC_SCRIPT" refresh
    assert_success
    assert_output_contains "Setting force_packages=true"
}


@test ".git directory is not symlinked" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/.git"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/.git" ]]
}

@test "reference directory is not symlinked" {
    cd "$FAKE_DOTFILES"
    mkdir -p "$FAKE_DOTFILES/reference"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/.reference" ]]
}

@test "packages directory is not symlinked" {
    cd "$FAKE_DOTFILES"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
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
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
    run bash "$SYNC_SCRIPT"
    assert_success
    [[ ! -L "$TEST_HOME/.cursor" ]]
}

@test "regular dotfiles ARE processed as symlinks" {
    cd "$FAKE_DOTFILES"
    echo "alias foo=bar" > "$FAKE_DOTFILES/myaliases"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
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
printf 'SUBDIR_SYNC_PHASE=%s\n' "${CHEZMOI_SYNC_PHASE:-unset}"
SCRIPT
    chmod +x "$FAKE_DOTFILES/mysubdir/.sync"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"
    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "Running .sync for mysubdir"
    assert_output_contains "SUBDIR_SYNC_PHASE=unset"
}

@test "package sync, pre-apply probes, final chezmoi apply, and post-apply probes run in order" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi/dot_config/mise"
    printf '[tools]\n' > "$FAKE_DOTFILES/chezmoi/dot_config/mise/config.toml"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
case "${CHEZMOI_SYNC_PHASE:-default}" in
    prepare) printf 'chezmoi-prepare\n' >> "$SYNC_EVENTS" ;;
    final) printf 'chezmoi-final-apply\n' >> "$SYNC_EVENTS" ;;
    *)
        printf 'unexpected-chezmoi-phase=%s\n' "${CHEZMOI_SYNC_PHASE:-default}" >> "$SYNC_EVENTS"
        exit 64
        ;;
esac
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
[[ "$MISE_CONFIG_FILE" == "$PWD/chezmoi/dot_config/mise/config.toml" ]] || exit 65
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"
    rm -f "$MOCK_BIN/omp"
    cat > "$MOCK_BIN/omp" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    version='omp/17.2.4'
    printf 'omp-version=%s\n' "$version" >> "$SYNC_EVENTS"
    printf '%s\n' "$version"
fi
SCRIPT
    chmod +x "$MOCK_BIN/omp"
    rm -f "$MOCK_BIN/codex"
    cat > "$MOCK_BIN/codex" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    version='codex-cli 0.146.0'
    printf 'codex-version=%s\n' "$version" >> "$SYNC_EVENTS"
    printf '%s\n' "$version"
fi
SCRIPT
    chmod +x "$MOCK_BIN/codex"


    run bash "$SYNC_SCRIPT"
    assert_success
    run cat "$SYNC_EVENTS"
    local expected_events
    expected_events='chezmoi-prepare
packages-sync
omp-version=omp/17.2.4
codex-version=codex-cli 0.146.0
chezmoi-final-apply
omp-version=omp/17.2.4
codex-version=codex-cli 0.146.0'
    [[ "$output" == "$expected_events" ]]
}
@test "post-apply harness version failure retains upgraded package state and reports failure" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
count_file="$TEST_HOME/chezmoi-apply-count"
count=0
[[ -f "$count_file" ]] && count=$(<"$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [[ "$count" -eq 2 ]]; then
    printf 'chezmoi-final-apply-complete\n' >> "$SYNC_EVENTS"
else
    printf 'chezmoi-apply-%s\n' "$count" >> "$SYNC_EVENTS"
fi
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.2.4 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"
    rm -f "$MOCK_BIN/omp"
    cat > "$MOCK_BIN/omp" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    count_file="$TEST_HOME/omp-probe-count"
    count=0
    [[ -f "$count_file" ]] && count=$(<"$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [[ "$count" -eq 2 ]]; then
        version='omp/17.1.3'
    else
        version='omp/17.2.4'
    fi
    printf 'omp-version=%s\n' "$version" >> "$SYNC_EVENTS"
    printf '%s\n' "$version"
fi
SCRIPT
    chmod +x "$MOCK_BIN/omp"
    rm -f "$MOCK_BIN/codex"
    cat > "$MOCK_BIN/codex" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    version='codex-cli 0.146.0'
    printf 'codex-version=%s\n' "$version" >> "$SYNC_EVENTS"
    printf '%s\n' "$version"
fi
SCRIPT
    chmod +x "$MOCK_BIN/codex"

    run bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply-1\npackages-sync\nomp-version=omp/17.2.4\ncodex-version=codex-cli 0.146.0\nchezmoi-final-apply-complete\nomp-version=omp/17.1.3' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.2.4 codex=0.146.0" ]]
    [[ "$sync_output" == *"omp version mismatch after final chezmoi apply"* ]]
    [[ "$sync_output" == *"harness-versions"* ]]
}

@test "final chezmoi apply failure retains upgraded package state and reports failure" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
case "${CHEZMOI_SYNC_PHASE:-default}" in
    prepare)
        printf 'chezmoi-prepare\n' >> "$SYNC_EVENTS"
        ;;
    final)
        printf 'chezmoi-final-apply-failed\n' >> "$SYNC_EVENTS"
        exit 1
        ;;
    *)
        printf 'unexpected-chezmoi-phase=%s\n' "${CHEZMOI_SYNC_PHASE:-default}" >> "$SYNC_EVENTS"
        exit 64
        ;;
esac
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.2.4 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"
    rm -f "$MOCK_BIN/omp"
    cat > "$MOCK_BIN/omp" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    printf 'omp-version=omp/17.2.4\n' >> "$SYNC_EVENTS"
    printf 'omp/17.2.4\n'
fi
SCRIPT
    chmod +x "$MOCK_BIN/omp"
    rm -f "$MOCK_BIN/codex"
    cat > "$MOCK_BIN/codex" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    printf 'codex-version=codex-cli 0.146.0\n' >> "$SYNC_EVENTS"
    printf 'codex-cli 0.146.0\n'
fi
SCRIPT
    chmod +x "$MOCK_BIN/codex"

    run bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    local sync_stderr="$stderr"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-prepare\npackages-sync\nomp-version=omp/17.2.4\ncodex-version=codex-cli 0.146.0\nchezmoi-final-apply-failed' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.2.4 codex=0.146.0" ]]
    [[ "$sync_output" == *"Sync completed with FAILURES in: chezmoi"* ||
        "$sync_stderr" == *"Sync completed with FAILURES in: chezmoi"* ]]
}

@test "missing final chezmoi runner fails closed with its expected path" {
    cd "$FAKE_DOTFILES"
    rm -f "$FAKE_DOTFILES/chezmoi/.sync"

    run bash "$SYNC_SCRIPT"
    assert_failure
    [[ "$output" == *"final chezmoi runner missing: $FAKE_DOTFILES/chezmoi/.sync"* ]]
    [[ "$output" == *"Sync completed with FAILURES in: chezmoi"* ]]
}
@test "harness version mismatch fails closed before final chezmoi apply" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
count_file="$TEST_HOME/chezmoi-apply-count"
count=0
[[ -f "$count_file" ]] && count=$(<"$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf 'chezmoi-apply-%s\n' "$count" >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.2.4 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"
    rm -f "$MOCK_BIN/omp"
    cat > "$MOCK_BIN/omp" << 'SCRIPT'
#!/bin/bash
[[ "$1" == "--version" ]] && printf 'omp/17.2.4\n'
SCRIPT
    chmod +x "$MOCK_BIN/omp"
    rm -f "$MOCK_BIN/codex"
    cat > "$MOCK_BIN/codex" << 'SCRIPT'
#!/bin/bash
[[ "$1" == "--version" ]] && printf 'codex-cli 0.145.0\n'
SCRIPT
    chmod +x "$MOCK_BIN/codex"

    run bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply-1\npackages-sync' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.2.4 codex=0.146.0" ]]
    [[ "$sync_output" == *"codex version mismatch"* ]]
}
@test "final harness verification prefers the post-package mise shim" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi" "$TEST_HOME/stale-bin"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
[[ "${CHEZMOI_SYNC_PHASE:-}" == "final" ]] || exit 0
printf 'final-codex=%s %s\n' "$(command -v codex)" "$(codex --version)" >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"

    cat > "$TEST_HOME/stale-bin/codex" << 'SCRIPT'
#!/bin/bash
[[ "$1" == "--version" ]] && printf 'codex-cli 0.145.0\n'
SCRIPT
    chmod +x "$TEST_HOME/stale-bin/codex"

    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
shim_dir="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
mkdir -p "$shim_dir"
cat > "$shim_dir/codex" << 'SHIM'
#!/bin/bash
[[ "$1" == "--version" ]] && printf 'codex-cli 0.146.0\n'
SHIM
chmod +x "$shim_dir/codex"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    PATH="$TEST_HOME/stale-bin:$PATH" run bash "$SYNC_SCRIPT"
    assert_success

    run cat "$SYNC_EVENTS"
    [[ "$output" == "packages-sync"$'\nfinal-codex='"$TEST_HOME/.local/share/mise/shims/codex codex-cli 0.146.0" ]]
}

@test "missing OMP after package convergence fails closed before final apply" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi-apply\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.2.4 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    local clean_path codex_only
    clean_path=$(tr ':' '\n' <<<"$PATH" | while IFS= read -r d; do
        [[ -x "$d/omp" ]] || printf '%s:' "$d"
    done)
    codex_only="$TEST_HOME/codex-only"
    mkdir -p "$codex_only"
    ln -s "$MOCK_BIN/codex" "$codex_only/codex"
    PATH="$codex_only:${clean_path%:}" run bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply\npackages-sync' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.2.4 codex=0.146.0" ]]
    [[ "$sync_output" == *"omp unavailable after package convergence"* ]]
}

@test "OMP version command failure fails closed before final apply" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi-apply\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.2.4 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"
    rm -f "$MOCK_BIN/omp"
    cat > "$MOCK_BIN/omp" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    printf 'omp probe exploded: fixture diagnostic\n' >&2
    exit 7
fi
SCRIPT
    chmod +x "$MOCK_BIN/omp"

    run --separate-stderr bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    local sync_stderr="$stderr"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply\npackages-sync' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.2.4 codex=0.146.0" ]]
    [[ "$sync_output" == *"omp --version failed after package convergence"* ]]
    [[ "$sync_stderr" == *"omp probe exploded: fixture diagnostic"* ]]
}
@test "OMP version mismatch fails closed before final apply" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi-apply\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.1.3 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"
    rm -f "$MOCK_BIN/omp"
    cat > "$MOCK_BIN/omp" << 'SCRIPT'
#!/bin/bash
[[ "$1" == "--version" ]] && printf 'omp/17.1.3\n'
SCRIPT
    chmod +x "$MOCK_BIN/omp"

    run bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply\npackages-sync' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.1.3 codex=0.146.0" ]]
    [[ "$sync_output" == *"omp version mismatch"* ]]
}

@test "missing Codex after package convergence fails closed before final apply" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi-apply\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.2.4 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    local clean_path omp_only
    clean_path=$(tr ':' '\n' <<<"$PATH" | while IFS= read -r d; do
        [[ -x "$d/codex" ]] || printf '%s:' "$d"
    done)
    omp_only="$TEST_HOME/omp-only"
    mkdir -p "$omp_only"
    ln -s "$MOCK_BIN/omp" "$omp_only/omp"
    PATH="$omp_only:${clean_path%:}" run bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply\npackages-sync' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.2.4 codex=0.146.0" ]]
    [[ "$sync_output" == *"codex unavailable after package convergence"* ]]
}

@test "Codex version command failure fails closed before final apply" {
    cd "$FAKE_DOTFILES"
    export SYNC_EVENTS="$TEST_HOME/sync-events.log"
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$FAKE_DOTFILES/chezmoi/.sync" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi-apply\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/chezmoi/.sync"
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'omp=17.2.4 codex=0.146.0\n' > "$TEST_HOME/upgraded-binaries"
printf 'packages-sync\n' >> "$SYNC_EVENTS"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"
    rm -f "$MOCK_BIN/codex"
    cat > "$MOCK_BIN/codex" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    printf 'codex probe exploded: fixture diagnostic\n' >&2
    exit 7
fi
SCRIPT
    chmod +x "$MOCK_BIN/codex"

    run --separate-stderr bash "$SYNC_SCRIPT"
    assert_failure
    local sync_output="$output"
    local sync_stderr="$stderr"
    run cat "$SYNC_EVENTS"
    [[ "$output" == $'chezmoi-apply\npackages-sync' ]]
    [[ "$(<"$TEST_HOME/upgraded-binaries")" == "omp=17.2.4 codex=0.146.0" ]]
    [[ "$sync_output" == *"codex --version failed after package convergence"* ]]
    [[ "$sync_stderr" == *"codex probe exploded: fixture diagnostic"* ]]
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
    rm -f "$FAKE_DOTFILES/packages/sync.sh"
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
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_DOTFILES/chezmoi/.sync"

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
