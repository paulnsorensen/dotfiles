#!/usr/bin/env bats
# Integration tests for packages/sync.sh
#
# Runs the real sync script with mock brew/cargo that record calls
# instead of installing. Verifies: YAML parsing, platform filtering,
# install decisions, cache behavior, and rust bootstrap.

load test_helper

SYNC_SCRIPT="$REAL_DOTFILES_DIR/packages/sync.sh"

setup() {
    setup_test_env
    export PACKAGES_FILE="$TEST_HOME/packages.yaml"
    export CACHE_DIR="$TEST_HOME/cache"
    export CACHE_FILE="$CACHE_DIR/packages.hash"
    mkdir -p "$CACHE_DIR"

    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"

    export BREW_LOG="$TEST_HOME/brew.log"
    export CARGO_LOG="$TEST_HOME/cargo.log"
    export GH_LOG="$TEST_HOME/gh.log"
    export NPM_LOG="$TEST_HOME/npm.log"

    write_mock_brew
    write_mock_cargo
    write_mock_gh
    write_mock_npm
    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

# --- Mock helpers ---

# Usage: write_mock_brew [installed_formulae] [installed_casks] [fail_pkg] [outdated_greedy_casks]
write_mock_brew() {
    local formulae="${1:-}" casks="${2:-}" fail_pkg="${3:-}" outdated_casks="${4:-}"
    cat > "$MOCK_BIN/brew" << MOCKBREW
#!/bin/bash
echo "brew \$*" >> "$BREW_LOG"
case "\$1" in
    list)
        if [[ "\$2" == "--formulae" ]]; then
            echo "$formulae"
        else
            echo "$casks"
        fi
        ;;
    outdated)
        # Only the greedy-cask probe returns names here; bare \`brew outdated\`
        # in other contexts is unused by sync.sh.
        echo "$outdated_casks"
        ;;
    tap)
        if [[ \$# -eq 1 ]]; then echo ""; fi
        ;;
    install)
        if [[ -n "$fail_pkg" && ("\$2" == "$fail_pkg" || "\$3" == "$fail_pkg") ]]; then
            exit 1
        fi
        ;;
esac
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"
}

write_mock_cargo() {
    cat > "$MOCK_BIN/cargo" << 'MOCKCARGO'
#!/bin/bash
echo "cargo $*" >> "$CARGO_LOG"
case "$1" in
    install)
        if [[ "$2" == "--list" ]]; then echo ""; fi
        ;;
esac
exit 0
MOCKCARGO
    chmod +x "$MOCK_BIN/cargo"
}

write_mock_npm() {
    cat > "$MOCK_BIN/npm" << 'MOCKNPM'
#!/bin/bash
echo "npm $*" >> "$NPM_LOG"
case "$1" in
    ls) echo '{}' ;;
    outdated) echo '{}' ;;
esac
exit 0
MOCKNPM
    chmod +x "$MOCK_BIN/npm"
}

# Usage: write_mock_gh [installed_repos] [fail_repo]
#   installed_repos: newline-separated list of "owner/repo" already installed
#   fail_repo:       exit non-zero when `gh extension install` is asked for this repo
write_mock_gh() {
    local installed="${1:-}" fail_repo="${2:-}"
    cat > "$MOCK_BIN/gh" << MOCKGH
#!/bin/bash
echo "gh \$*" >> "$GH_LOG"
case "\$1" in
    extension)
        case "\$2" in
            list)
                while IFS= read -r repo; do
                    [[ -z "\$repo" ]] && continue
                    printf 'gh %s\t%s\tv0.0.0\n' "\${repo##*/gh-}" "\$repo"
                done <<< "$installed"
                ;;
            install)
                if [[ -n "$fail_repo" && "\$3" == "$fail_repo" ]]; then
                    exit 1
                fi
                ;;
        esac
        ;;
esac
exit 0
MOCKGH
    chmod +x "$MOCK_BIN/gh"
}

write_test_yaml() {
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - test/tap-repo: { source: tap }
  - curl
  - jq
  - fd: { apt: fd-find }
  - node: { apt: nodejs }
  - mas: { platform: mac }
  - xclip: { platform: linux }
  - docker-desktop: { source: cask, dev: true, platform: mac, greedy: false }
  - npm: { platform: linux, dev: true }
  - pyenv: { dev: true }
  - cargo-llvm-cov: { source: cargo }
  - gh-stack: { source: gh-extension, pkg: github/gh-stack }
  - markdownlint-cli2: { source: npm }
  - graphite: { source: npm, pkg: "@withgraphite/graphite-cli", platform: linux }
YAML
}

run_sync() {
    FORCE_PACKAGES=true run bash "$SYNC_SCRIPT"
}

# --- Schema validation (against real packages.yaml) ---

@test "packages.yaml is valid YAML" {
    run yq '.' "$REAL_DOTFILES_DIR/packages/packages.yaml"
    assert_success
}

@test "all platform values are mac or linux" {
    run yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.platform != null) | .value.platform' \
        "$REAL_DOTFILES_DIR/packages/packages.yaml"
    assert_success
    while IFS= read -r platform; do
        [[ -z "$platform" ]] && continue
        [[ "$platform" == "mac" || "$platform" == "linux" ]]
    done <<< "$output"
}

@test "all source values are brew, cask, tap, cargo, npm, uv, or gh-extension" {
    run yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source != null) | .value.source' \
        "$REAL_DOTFILES_DIR/packages/packages.yaml"
    assert_success
    while IFS= read -r source; do
        [[ -z "$source" ]] && continue
        case "$source" in
            brew|cask|tap|cargo|npm|uv|gh-extension) ;;
            *)
                echo "Invalid source value: $source" >&2
                return 1
                ;;
        esac
    done <<< "$output"
}

@test "no duplicate package names" {
    local names
    names=$(
        yq -r '.packages[] | select(kind == "scalar")' "$REAL_DOTFILES_DIR/packages/packages.yaml"
        yq -r '.packages[] | select(kind == "map") | to_entries[0] | .key' "$REAL_DOTFILES_DIR/packages/packages.yaml"
    )
    local dupes
    dupes=$(echo "$names" | sort | uniq -d)
    if [[ -n "$dupes" ]]; then
        echo "Duplicate packages found: $dupes" >&2
        return 1
    fi
}

# --- Integration: sync installs the right packages ---

@test "sync installs bare-string formulae via brew" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install curl" "$BREW_LOG"
    grep -q "brew install jq" "$BREW_LOG"
}

@test "sync installs map formulae (fd, node) via brew" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install fd" "$BREW_LOG"
    grep -q "brew install node" "$BREW_LOG"
}

@test "sync installs mac-only packages on Darwin" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install mas" "$BREW_LOG"
}

@test "sync excludes linux-only packages on Darwin" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    run_sync
    assert_success

    ! grep -q "brew install xclip" "$BREW_LOG"
}

@test "sync processes taps before formulae" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    run_sync
    assert_success

    local tap_line install_line
    tap_line=$(grep -n "brew tap test/tap-repo" "$BREW_LOG" | head -1 | cut -d: -f1)
    install_line=$(grep -n "brew install " "$BREW_LOG" | head -1 | cut -d: -f1)
    [[ "$tap_line" -lt "$install_line" ]]
}

@test "sync skips dev packages when DOTFILES_DEV is not set" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    unset DOTFILES_DEV
    run_sync
    assert_success

    ! grep -q "brew install pyenv" "$BREW_LOG"
    ! grep -q "brew install.*docker" "$BREW_LOG"
}

@test "sync installs dev packages when DOTFILES_DEV=true" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    DOTFILES_DEV=true run_sync
    assert_success

    grep -q "brew install pyenv" "$BREW_LOG"
}

@test "sync installs dev casks when DOTFILES_DEV=true" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    DOTFILES_DEV=true run_sync
    assert_success

    grep -q "brew install --cask docker" "$BREW_LOG"
}

@test "sync skips already-installed packages" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    write_mock_brew "curl"

    run_sync
    assert_success

    ! grep -q "brew install curl" "$BREW_LOG"
    grep -q "brew install jq" "$BREW_LOG"
}

@test "sync skips already-installed tap-qualified packages by short name" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    # brew list --formulae prints short names; the installed-check must
    # compare a tap-qualified key (rjyo/moshi/moshi-hook) by its tail or
    # it reinstalls on every sync.
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - rjyo/moshi/moshi-hook: { platform: mac }
YAML
    write_mock_brew "moshi-hook"

    run_sync
    assert_success

    # Positive control: the entry was considered and skipped as installed,
    # not silently dropped by platform/source filtering.
    assert_output_contains "+ rjyo/moshi/moshi-hook"
    ! grep -q "brew install rjyo/moshi/moshi-hook" "$BREW_LOG"
}

@test "sync installs cargo packages" {
    write_test_yaml
    run_sync
    assert_success

    grep -q "cargo install cargo-llvm-cov" "$CARGO_LOG"
}

@test "sync installs gh extensions" {
    write_test_yaml
    run_sync
    assert_success

    grep -q "gh extension install github/gh-stack" "$GH_LOG"
}

@test "sync skips gh extension that is already installed" {
    write_test_yaml
    write_mock_gh "github/gh-stack"

    run_sync
    assert_success

    ! grep -q "gh extension install" "$GH_LOG"
}

@test "sync records failure when gh extension install fails" {
    write_test_yaml
    write_mock_gh "" "github/gh-stack"

    run_sync

    assert_output_contains "Failed to install github/gh-stack"
    assert_output_contains "cache NOT saved"
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]
}

@test "UPGRADE_MODE runs gh extension upgrade --all" {
    write_test_yaml
    write_mock_gh "github/gh-stack"

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success

    grep -q "gh extension upgrade --all" "$GH_LOG"
}

@test "non-upgrade mode does NOT call gh extension upgrade" {
    write_test_yaml
    write_mock_gh "github/gh-stack"

    run_sync
    assert_success

    ! grep -q "gh extension upgrade" "$GH_LOG"
}

@test "sync installs npm packages" {
    write_test_yaml
    run_sync
    assert_success

    grep -q "npm install -g markdownlint-cli2" "$NPM_LOG"
}

@test "sync excludes linux-only npm packages on Darwin" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    run_sync
    assert_success

    # Positive control: the npm path ran and installed a both-platforms package,
    # so the absence below is real exclusion, not an empty npm phase.
    grep -q "npm install -g markdownlint-cli2" "$NPM_LOG"
    ! grep -q "graphite-cli" "$NPM_LOG"
}

# --- Integration: cache behavior ---

@test "sync saves cache on success" {
    write_test_yaml
    run_sync
    assert_success

    [[ -f "$CACHE_FILE" ]]
    local expected
    expected=$(shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1)
    [[ "$(cat "$CACHE_FILE")" == "$expected" ]]
}

@test "sync skips when cache matches" {
    write_test_yaml
    shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"

    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "unchanged (cached), skipping"

    [[ ! -f "$BREW_LOG" ]]
}

@test "FORCE_PACKAGES bypasses valid cache" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"

    run_sync
    assert_success
    assert_output_contains "bypassing cache"

    [[ -f "$BREW_LOG" ]]
}

@test "sync does NOT save cache when brew install fails" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    write_mock_brew "" "" "jq"

    run_sync

    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]
    assert_output_contains "failed to install"
    assert_output_contains "cache NOT saved"
}

@test "sync retries after previous failure (no cache)" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    write_mock_brew "" "" "jq"

    run bash "$SYNC_SCRIPT"
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]

    # Fix brew and re-run
    rm -f "$BREW_LOG"
    write_mock_brew

    run bash "$SYNC_SCRIPT"
    assert_success

    [[ -f "$CACHE_FILE" ]]
    grep -q "brew install jq" "$BREW_LOG"
}

# --- Integration: missing toolchain ---

# Build a curated PATH for "missing toolchain" tests. Keeps real yq/jq/shasum
# (sync.sh needs them) but excludes any directory that holds an executable
# cargo, rustup, OR cargo-install-update, so `command -v <tool>` actually
# fails on developer machines where those binaries live alongside each
# other under ~/.cargo/bin or /opt/homebrew/bin.
scrub_toolchain_path() {
    local entry filtered=""
    local -a needed=(yq jq shasum sha256sum git awk sed grep cut sort tr head tail)
    local stub="$TEST_HOME/toolchain-stub"
    mkdir -p "$stub"
    for tool in "${needed[@]}"; do
        local src
        src=$(command -v "$tool" 2>/dev/null || true)
        [[ -n "$src" && ! -e "$stub/$tool" ]] && ln -sf "$src" "$stub/$tool"
    done
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        [[ -x "$entry/cargo" ]] && continue
        [[ -x "$entry/rustup" ]] && continue
        [[ -x "$entry/cargo-install-update" ]] && continue
        filtered+="$entry:"
    done <<< "$(echo "$PATH" | tr ':' '\n')"
    echo "$stub:${filtered%:}"
}

@test "sync warns + proceeds when cargo AND rustup are missing" {
    # Behavior change: the linux-bootstrap PR (commit 5369aa3) softened
    # missing-cargo from `log_error + FAILED+=("cargo")` to `log_warning +
    # return 0`. Rationale: a fresh Ubuntu box without rust shouldn't
    # FAIL the whole `dots sync` — the cargo packages just won't install
    # until rustup is set up, while everything else (brew, npm, uv tools)
    # proceeds normally. The cache IS saved on the successful sync.
    write_test_yaml
    rm -f "$MOCK_BIN/cargo" "$MOCK_BIN/rustup"

    PATH="$MOCK_BIN:$(scrub_toolchain_path)" run_sync

    assert_success
    assert_output_contains "cargo not found"
    assert_output_contains "skipping cargo packages"
    # Cache saved because the sync completed without failure.
    [[ -f "$CACHE_FILE" ]]
}

@test "sync bootstraps rust toolchain when rustup exists but cargo missing" {
    write_test_yaml
    rm -f "$MOCK_BIN/cargo"

    # Mock rustup must take precedence over host rustup, AND host cargo
    # must not satisfy the initial `command -v cargo` check.
    export PATH="$MOCK_BIN:$(scrub_toolchain_path)"

    # Mock rustup that creates a mock cargo on "default stable"
    cat > "$MOCK_BIN/rustup" << MOCKRUSTUP
#!/bin/bash
echo "rustup \$*" >> "$CARGO_LOG"
cat > "$MOCK_BIN/cargo" << 'INNERCARGO'
#!/bin/bash
echo "cargo \$*" >> "$CARGO_LOG"
case "\$1" in
    install)
        if [[ "\$2" == "--list" ]]; then echo ""; fi
        ;;
esac
exit 0
INNERCARGO
chmod +x "$MOCK_BIN/cargo"
exit 0
MOCKRUSTUP
    chmod +x "$MOCK_BIN/rustup"

    run_sync
    assert_success

    assert_output_contains "Bootstrapping Rust stable toolchain"
    grep -q "rustup default stable" "$CARGO_LOG"
    grep -q "cargo install cargo-llvm-cov" "$CARGO_LOG"
}

# --- Integration: UPGRADE_MODE ---

@test "UPGRADE_MODE bypasses cache" {
    write_test_yaml
    save_cache_now() {
        shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"
    }
    save_cache_now
    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "UPGRADE_MODE set, bypassing cache"
}

@test "UPGRADE_MODE runs brew upgrade after install loop" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    write_test_yaml
    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    grep -q "brew update" "$BREW_LOG"
    grep -q "brew upgrade" "$BREW_LOG"
}

@test "UPGRADE_MODE excludes greedy:false casks (docker-desktop) from greedy upgrade" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    # Both docker-desktop (greedy:false) and cursor (greedy default) report as
    # greedy-outdated. cursor must be upgraded; docker-desktop must not.
    write_mock_brew "" "docker-desktop" "" $'docker-desktop\ncursor'
    write_test_yaml
    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success

    # No blanket greedy upgrade — the exclusion path enumerates instead.
    ! grep -q "brew upgrade --cask --greedy-auto-updates" "$BREW_LOG"
    # cursor gets upgraded explicitly; docker-desktop is never passed to upgrade.
    grep -q "brew upgrade --cask cursor" "$BREW_LOG"
    ! grep -qE "brew upgrade --cask .*docker-desktop" "$BREW_LOG"
}

@test "UPGRADE_MODE warns + skips greedy cask upgrade when brew outdated fails" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only (sync_brew not invoked on Linux)"

    # brew outdated failing must NOT be silently swallowed as "nothing to
    # upgrade" — emit a warning and skip the pass, like the other brew ops.
    cat > "$MOCK_BIN/brew" << 'MOCKBREW'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
case "$1" in
    list)   [[ "$2" == "--formulae" ]] && echo "" || echo "docker-desktop" ;;
    outdated) exit 1 ;;
    tap)    [[ $# -eq 1 ]] && echo "" ;;
esac
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"

    write_test_yaml
    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "brew outdated --cask failed; skipping greedy cask upgrade"
    # No filtered cask upgrade is attempted when the probe failed.
    ! grep -qE "brew upgrade --cask [a-z]" "$BREW_LOG"
}

@test "UPGRADE_MODE runs cargo-install-update --all --git instead of per-package --force" {
    # New idempotent contract (PR #197): the install pass only handles
    # *missing* packages, and the upgrade pass delegates to
    # cargo-install-update so already-current crates are skipped
    # instead of force-reinstalled every `dots up`.
    write_test_yaml
    cat > "$MOCK_BIN/cargo" << 'MOCKCARGO'
#!/bin/bash
echo "cargo $*" >> "$CARGO_LOG"
case "$1" in
    install)
        if [[ "$2" == "--list" ]]; then
            echo "cargo-llvm-cov v0.1.0:"
            echo "    cargo-llvm-cov"
        fi
        ;;
esac
exit 0
MOCKCARGO
    chmod +x "$MOCK_BIN/cargo"

    # Just needs to exist on PATH so `command -v cargo-install-update`
    # succeeds in sync.sh; the actual `cargo install-update …` call
    # dispatches through the cargo mock above (cargo subcommand
    # resolution happens inside real cargo, not in the test shell).
    cat > "$MOCK_BIN/cargo-install-update" << 'MOCKUPDATE'
#!/bin/bash
exit 0
MOCKUPDATE
    chmod +x "$MOCK_BIN/cargo-install-update"

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    # Install pass skips already-installed crate — no per-package
    # `cargo install cargo-llvm-cov` call at all.
    ! grep -q "cargo install cargo-llvm-cov" "$CARGO_LOG"
    ! grep -q -- "--force" "$CARGO_LOG"
    # Upgrade pass delegates to `cargo install-update --all --git`.
    grep -q "cargo install-update --all --git" "$CARGO_LOG"
    assert_output_contains "Upgrading cargo packages"
}

@test "UPGRADE_MODE warns when cargo-install-update is not installed" {
    # Missing-binary fallback: dots up should keep going with a loud
    # warning instead of silently noop-ing or crashing.
    #
    # Use scrub_toolchain_path so the real cargo-install-update on the
    # developer's PATH (alongside cargo under ~/.cargo/bin or
    # /opt/homebrew/bin) doesn't satisfy the `command -v` check and mask
    # the warning branch the test is locking in.
    write_test_yaml
    cat > "$MOCK_BIN/cargo" << 'MOCKCARGO'
#!/bin/bash
echo "cargo $*" >> "$CARGO_LOG"
case "$1" in
    install)
        if [[ "$2" == "--list" ]]; then
            echo "cargo-llvm-cov v0.1.0:"
            echo "    cargo-llvm-cov"
        fi
        ;;
esac
exit 0
MOCKCARGO
    chmod +x "$MOCK_BIN/cargo"
    # Deliberately do NOT install a cargo-install-update mock.

    UPGRADE_MODE=true PATH="$MOCK_BIN:$(scrub_toolchain_path)" run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "cargo-update not installed"
    # And the install pass still skips the already-installed crate.
    ! grep -q "cargo install cargo-llvm-cov" "$CARGO_LOG"
}

@test "non-upgrade mode does NOT pass --force to cargo install" {
    write_test_yaml
    run_sync
    assert_success
    ! grep -q -- "--force" "$CARGO_LOG"
}

@test "UPGRADE_MODE skips cargo --force when package not yet installed" {
    write_test_yaml
    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    # cargo-llvm-cov is not in the (empty) installed list, so install path runs without --force
    grep -q "cargo install cargo-llvm-cov" "$CARGO_LOG"
    ! grep -q "cargo install --force cargo-llvm-cov" "$CARGO_LOG"
}
