#!/usr/bin/env bats
# Integration tests for packages/sync.sh
#
# Runs the real sync script with mocked package managers that record calls
# instead of installing. Verifies YAML parsing, platform filtering,
# exact-pin behavior, cache behavior, and failure propagation.

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
    export SUDO_LOG="$TEST_HOME/sudo.log"
    export CLAUDE_LOG="$TEST_HOME/claude.log"
    export CODEX_LOG="$TEST_HOME/codex.log"
    export OMP_LOG="$TEST_HOME/omp.log"
    export MISE_LOG="$TEST_HOME/mise.log"
    export MISE_CONFIG_FILE="$TEST_HOME/mise-config.toml"
    export MISE_BOOTSTRAP_CONFIG_FILE="$TEST_HOME/missing-bootstrap-config.toml"
    printf '[tools]\n' > "$MISE_CONFIG_FILE"

    write_mock_brew
    write_mock_cargo
    write_mock_gh
    write_mock_npm
    # Mock sudo records its args and no-ops — guarantees the Linux brew-deps
    # bootstrap can never run a real `sudo apt-get` against the test machine.
    write_mock_sudo
    # Mock the native AI harnesses as present-and-recording, so no test ever
    # shells out to the real claude/codex/omp (self-update hits the network /
    # mutates the real install). Install/absence tests override these.
    write_mock_harness claude
    write_mock_harness codex
    write_mock_harness omp
    write_mock_mise
    write_mock_curl
    write_mock_sh
    export PATH="$MOCK_BIN:$PATH"
}

write_mock_sudo() {
    cat > "$MOCK_BIN/sudo" << 'MOCKSUDO'
#!/bin/bash
echo "sudo $*" >> "$SUDO_LOG"
exit 0
MOCKSUDO
    chmod +x "$MOCK_BIN/sudo"
}

# Mock an AI-harness CLI (claude/codex/omp): record args to its log, exit 0.
write_mock_harness() {
    local name="$1" log
    case "$name" in
        claude) log="$CLAUDE_LOG" ;;
        codex)  log="$CODEX_LOG" ;;
        omp)    log="$OMP_LOG" ;;
    esac
    cat > "$MOCK_BIN/$name" << MOCKHARNESS
#!/bin/bash
echo "$name \$*" >> "$log"
exit 0
MOCKHARNESS
    chmod +x "$MOCK_BIN/$name"
}

# Mock curl for native-installer tests: record the URL, emit nothing so the
# downstream `| bash` / `| sh` runs an empty (no-op) script.
write_mock_curl() {
    export CURL_LOG="$TEST_HOME/curl.log"
    cat > "$MOCK_BIN/curl" << 'MOCKCURL'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
exit 0
MOCKCURL
    chmod +x "$MOCK_BIN/curl"
}

# Mock sh for native-installer tests: curl's mock emits nothing, so a
# `curl ... | sh -s -- --ref X` pipeline hands its stdin to this mock instead
# of a real installer script. Records args so a `--ref` pin is assertable.
write_mock_sh() {
    local exit_status="${1:-0}"
    export SH_LOG="$TEST_HOME/sh.log"
    cat > "$MOCK_BIN/sh" << MOCKSH
#!/bin/bash
echo "sh \$*" >> "$SH_LOG"
exit $exit_status
MOCKSH
    chmod +x "$MOCK_BIN/sh"
}

write_mock_uv() {
    export UV_LOG="$TEST_HOME/uv.log"
    cat > "$MOCK_BIN/uv" << 'MOCKUV'
#!/bin/bash
echo "uv $*" >> "$UV_LOG"
[[ "$1 $2" == "tool list" ]] && echo ""
exit 0
MOCKUV
    chmod +x "$MOCK_BIN/uv"
}

write_mock_mise() {
    local exit_status="${1:-0}"
    cat > "$MOCK_BIN/mise" << MOCKMISE
#!/bin/bash
echo "mise \$* config=\${MISE_GLOBAL_CONFIG_FILE:-unset}" >> "$MISE_LOG"
exit $exit_status
MOCKMISE
    chmod +x "$MOCK_BIN/mise"
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
  - tree
  - watch: { source: brew }
  - trash: { platform: mac }
  - xclip: { platform: linux }
  - docker-desktop: { source: cask, dev: true, platform: mac, greedy: false }
  - pyenv: { dev: true }
  - cargo-audit: { source: cargo }
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

@test "mise-migrated tools and redundant taps are absent from packages.yaml" {
    local names
    names=$(
        yq -r '.packages[] | select(kind == "scalar")' "$REAL_DOTFILES_DIR/packages/packages.yaml"
        yq -r '.packages[] | select(kind == "map") | to_entries[0] | .key' "$REAL_DOTFILES_DIR/packages/packages.yaml"
    )
    local migrated=(
        jq yq fzf gh shellcheck bats-core ripgrep fd eza bat glow ast-grep
        git-delta git-lfs tmux prek zoxide atuin bottom dust procs tokei yazi
        difftastic mergiraf lazygit git-town sesh just chezmoi duckdb node bun
        sd vhs opencode crush sccache cargo-nextest protobuf mas uv rustup
        rust-analyzer cargo-llvm-cov rtk bash-language-server yaml-language-server
        pyright gopls oven-sh/bun anomalyco/tap anomalyco/tap/opencode
        joshmedeski/sesh charmbracelet/tap/crush
    )
    local name
    for name in "${migrated[@]}"; do
        if grep -qxF "$name" <<< "$names"; then
            echo "mise-migrated package remains in packages.yaml: $name" >&2
            return 1
        fi
    done
}

# --- Integration: sync installs the right packages ---

@test "sync installs bare-string formulae via brew" {
    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install curl" "$BREW_LOG"
    grep -q "brew install tree" "$BREW_LOG"
}

@test "sync installs map formulae via brew" {
    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install watch" "$BREW_LOG"
}

@test "sync installs mac-only packages on Darwin" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install trash" "$BREW_LOG"
}

@test "sync excludes linux-only packages on Darwin" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    run_sync
    assert_success

    ! grep -q "brew install xclip" "$BREW_LOG"
}

@test "sync installs linux-only packages via brew on Linux" {
    [[ "$(uname)" == "Linux" ]] || skip "Linux only"

    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install xclip" "$BREW_LOG"
}

@test "sync excludes mac-only packages on Linux" {
    [[ "$(uname)" == "Linux" ]] || skip "Linux only"

    write_test_yaml
    run_sync
    assert_success

    # Positive control: the brew path ran and installed a both-platforms formula.
    grep -q "brew install tree" "$BREW_LOG"
    ! grep -q "brew install trash" "$BREW_LOG"
}

@test "sync skips casks entirely on Linux (cask is macOS-only)" {
    [[ "$(uname)" == "Linux" ]] || skip "Linux only"

    # docker-desktop is a dev cask; even with DOTFILES_DEV=true, no
    # `brew install --cask` should run on Linux.
    write_test_yaml
    DOTFILES_DEV=true run_sync
    assert_success

    ! grep -q "brew install --cask" "$BREW_LOG"
}

# A PATH with the C build toolchain (gcc/make/file) absent but every tool
# sync.sh actually needs kept via a stub of symlinks — exercises the brew-deps
# bootstrap's "toolchain missing" branch without touching the test machine.
path_without_buildtools() {
    local stub="$TEST_HOME/nobuild-stub"
    mkdir -p "$stub"
    local -a needed=(bash sh env uname id yq jq shasum sha256sum curl git \
        awk sed grep cut sort tr head tail cat chmod mkdir rm ln mktemp \
        dirname basename tee wc printf find xargs sleep)
    local tool src
    for tool in "${needed[@]}"; do
        src=$(command -v "$tool" 2>/dev/null || true)
        [[ -n "$src" && ! -e "$stub/$tool" ]] && ln -sf "$src" "$stub/$tool"
    done
    echo "$stub"
}

@test "installs Homebrew build deps via apt up front on Linux when toolchain missing" {
    [[ "$(uname)" == "Linux" ]] || skip "Linux only"

    # apt-get + uv are mocked so the apt branch is deterministic and later
    # package phases never touch the test machine.
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/apt-get"; chmod +x "$MOCK_BIN/apt-get"
    write_mock_uv
    write_test_yaml

    PATH="$MOCK_BIN:$(path_without_buildtools)" run_sync
    assert_success

    assert_output_contains "Installing Homebrew build dependencies"
    grep -q "sudo apt-get install -y build-essential procps curl file git" "$SUDO_LOG"
}

@test "skips Homebrew build-dep install when toolchain already present" {
    [[ "$(uname)" == "Linux" ]] || skip "Linux only"

    # Stub the full toolchain so the check passes regardless of host state.
    local t
    for t in gcc make file git curl; do
        printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/$t"; chmod +x "$MOCK_BIN/$t"
    done
    write_test_yaml

    run_sync
    assert_success

    ! grep -q "Installing Homebrew build dependencies" <<< "$output"
    [[ ! -f "$SUDO_LOG" ]]
}

@test "sync processes taps before formulae" {
    write_test_yaml
    run_sync
    assert_success

    local tap_line install_line
    tap_line=$(grep -n "brew tap test/tap-repo" "$BREW_LOG" | head -1 | cut -d: -f1)
    install_line=$(grep -n "brew install " "$BREW_LOG" | head -1 | cut -d: -f1)
    [[ "$tap_line" -lt "$install_line" ]]
}

@test "sync trusts declared taps to satisfy Homebrew tap-trust gate" {
    write_test_yaml
    run_sync
    assert_success

    # Each declared tap must be trusted so fresh formula installs aren't refused.
    grep -q "brew trust test/tap-repo" "$BREW_LOG"
}

@test "sync skips dev packages when DOTFILES_DEV is not set" {
    write_test_yaml
    unset DOTFILES_DEV
    run_sync
    assert_success

    ! grep -q "brew install pyenv" "$BREW_LOG"
    ! grep -q "brew install.*docker" "$BREW_LOG"
}

@test "sync installs dev packages when DOTFILES_DEV=true" {
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
    write_test_yaml
    write_mock_brew "curl"

    run_sync
    assert_success

    ! grep -q "brew install curl" "$BREW_LOG"
    grep -q "brew install tree" "$BREW_LOG"
}

@test "sync skips already-installed tap-qualified packages by short name" {
    [[ "$(uname)" == "Darwin" ]] || skip "fixture package is platform: mac (excluded on Linux)"

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

    grep -q "cargo install cargo-audit" "$CARGO_LOG"
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

@test "UPGRADE_MODE never floats gh extensions" {
    write_test_yaml
    write_mock_gh "github/gh-stack"

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
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

@test "sync saves a composite package-state cache on success" {
    write_test_yaml
    run_sync
    assert_success

    [[ -s "$CACHE_FILE" ]]
}

@test "sync skips all installers when package inputs and pins match the cache" {
    write_test_yaml
    run_sync
    assert_success
    rm -f "$BREW_LOG" "$MISE_LOG" "$CURL_LOG" "$SH_LOG"

    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "unchanged (cached), skipping"
    [[ ! -f "$BREW_LOG" ]]
    [[ ! -f "$MISE_LOG" ]]
    [[ ! -f "$CURL_LOG" ]]
}

@test "a mise config-only change invalidates the package cache and reconverges" {
    write_test_yaml
    run_sync
    assert_success
    local before
    before="$(<"$CACHE_FILE")"
    rm -f "$MISE_LOG"
    printf 'node = "24.0.0"\n' >> "$MISE_CONFIG_FILE"

    run bash "$SYNC_SCRIPT"
    assert_success
    grep -q "mise install" "$MISE_LOG"
    [[ "$(<"$CACHE_FILE")" != "$before" ]]
}

@test "FORCE_PACKAGES bypasses a valid composite cache" {
    write_test_yaml
    run_sync
    assert_success
    rm -f "$BREW_LOG"

    run_sync
    assert_success
    assert_output_contains "Package cache bypassed"
    [[ -f "$BREW_LOG" ]]
}

@test "sync does NOT save cache when brew install fails" {
    write_test_yaml
    write_mock_brew "" "" "tree"

    run_sync

    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]
    assert_output_contains "failed to install"
    assert_output_contains "cache NOT saved"
}

@test "sync retries after previous failure because no cache was written" {
    write_test_yaml
    write_mock_brew "" "" "tree"

    run bash "$SYNC_SCRIPT"
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]

    rm -f "$BREW_LOG"
    write_mock_brew
    run bash "$SYNC_SCRIPT"
    assert_success

    [[ -s "$CACHE_FILE" ]]
    grep -q "brew install tree" "$BREW_LOG"
}

@test "mise install failure exits nonzero and never creates a false cache hit" {
    write_test_yaml
    write_mock_mise 1

    run_sync
    assert_failure
    assert_output_contains "mise install failed"
    assert_output_contains "cache NOT saved"
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]
}

# --- Integration: missing toolchain ---

# Build a curated PATH for "missing toolchain" tests. Keeps real yq/jq/shasum
# (sync.sh needs them) but excludes directories containing cargo or rustup.
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
        filtered+="$entry:"
    done <<< "$(echo "$PATH" | tr ':' '\n')"
    echo "$stub:${filtered%:}"
}

@test "sync errors + fails when cargo is missing after mise convergence" {
    write_test_yaml
    rm -f "$MOCK_BIN/cargo" "$MOCK_BIN/rustup"

    PATH="$MOCK_BIN:$(scrub_toolchain_path)" run_sync

    assert_failure
    assert_output_contains "cargo not found after mise convergence"
    assert_output_contains "cannot install cargo-source packages"
    [[ ! -f "$CACHE_FILE" ]]
}

@test "sync never floats rustup when cargo is missing" {
    write_test_yaml
    rm -f "$MOCK_BIN/cargo"
    export PATH="$MOCK_BIN:$(scrub_toolchain_path)"
    cat > "$MOCK_BIN/rustup" << MOCKRUSTUP
#!/bin/bash
echo "rustup \$*" >> "$CARGO_LOG"
exit 0
MOCKRUSTUP
    chmod +x "$MOCK_BIN/rustup"

    run_sync

    assert_failure
    assert_output_contains "cargo not found after mise convergence"
    if [[ -f "$CARGO_LOG" ]]; then
        ! grep -q "rustup default stable" "$CARGO_LOG"
    fi
    [[ ! -f "$CACHE_FILE" ]]
}

# --- Integration: UPGRADE_MODE ---

@test "UPGRADE_MODE bypasses a valid composite cache" {
    write_test_yaml
    run_sync
    assert_success

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "UPGRADE_MODE set, bypassing cache"
}

@test "UPGRADE_MODE runs brew upgrade after install loop" {
    write_test_yaml
    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    grep -q "brew update" "$BREW_LOG"
    grep -q "brew upgrade" "$BREW_LOG"
}

@test "UPGRADE_MODE plain upgrade is formula-scoped (never touches casks/docker)" {
    # A bare \`brew upgrade\` also upgrades outdated casks, reinstalling a
    # greedy:false cask like docker-desktop and prompting for sudo. The plain
    # pass must be --formula only; all cask upgrades route through the
    # exclusion-aware greedy pass.
    write_test_yaml
    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    grep -q "brew upgrade --formula" "$BREW_LOG"
    ! grep -qE "^brew upgrade\$" "$BREW_LOG"
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

@test "UPGRADE_MODE never invokes floating cargo, npm, or gh upgrade paths" {
    write_test_yaml
    write_mock_gh "github/gh-stack"

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success

    ! grep -q "cargo install-update" "$CARGO_LOG"
    ! grep -q "npm outdated" "$NPM_LOG"
    ! grep -q "gh extension upgrade" "$GH_LOG"
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
    # cargo-audit is not in the empty installed list, so install runs without --force.
    grep -q "cargo install cargo-audit" "$CARGO_LOG"
    ! grep -q "cargo install --force cargo-audit" "$CARGO_LOG"
}

# --- Integration: native harness convergence ---

@test "package sync converges OMP_PIN and never invokes omp update" {
    write_test_yaml

    run_sync
    assert_success
    grep -q "omp.sh/install" "$CURL_LOG"
    grep -q -- "--binary --ref v17.1.3" "$SH_LOG"
    [[ ! -f "$OMP_LOG" ]] || ! grep -q "omp update" "$OMP_LOG"
}

@test "clean cache hit does not reinstall pinned omp" {
    write_test_yaml
    run_sync
    assert_success
    local before
    before=$(wc -l < "$SH_LOG")

    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "unchanged (cached), skipping"
    [[ "$(wc -l < "$SH_LOG")" -eq "$before" ]]
}

@test "UPGRADE_MODE reconverges pinned omp without using its floating updater" {
    write_test_yaml

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    grep -q -- "--binary --ref v17.1.3" "$SH_LOG"
    [[ ! -f "$OMP_LOG" ]] || ! grep -q "omp update" "$OMP_LOG"
}

@test "omp installer failure fails loudly and does not save cache" {
    write_test_yaml
    write_mock_sh 1

    run_sync
    assert_failure
    assert_output_contains "omp native install failed"
    assert_output_contains "cache NOT saved"
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]
}

@test "native harness sync never installs or self-updates mise-managed claude and codex" {
    write_test_yaml
    rm -f "$MOCK_BIN/claude" "$MOCK_BIN/codex"

    run_sync
    assert_success
    ! grep -q "claude.ai/install.sh" "$CURL_LOG"
    ! grep -q "codex" "$CURL_LOG"
    [[ ! -f "$CLAUDE_LOG" ]] || ! grep -q "update" "$CLAUDE_LOG"
    [[ ! -f "$CODEX_LOG" ]] || ! grep -q "update" "$CODEX_LOG"
}

@test "native harness sync never touches codex (mise-managed, no installer or update path here)" {
    write_test_yaml
    rm -f "$MOCK_BIN/codex"
    write_mock_curl

    local clean_path
    clean_path=$(scrub_toolchain_path | tr ':' '\n' | while IFS= read -r d; do [[ -x "$d/codex" ]] || printf '%s:' "$d"; done)
    PATH="$MOCK_BIN:${clean_path%:}" run bash "$SYNC_SCRIPT"
    assert_success

    [[ ! -f "$CURL_LOG" ]] || ! grep -q "codex" "$CURL_LOG"
}

@test "migration: lingering brew claude-code cask and omp formula are uninstalled" {
    write_test_yaml
    # Long lists with the target at the FRONT: grep -qx matches immediately and
    # closes the pipe while the mock is still producing, so a `brew list | grep
    # -qx` pipeline SIGPIPEs the producer and — under set -o pipefail — reports
    # failure on a real match, silently skipping the uninstall. Regression guard
    # for that bug; the migration must fire regardless of list length/position.
    local formulae cask i
    formulae="omp"
    for i in $(seq 1 200); do formulae+=$'\n'"filler-formula-$i"; done
    cask="claude-code"
    for i in $(seq 1 200); do cask+=$'\n'"filler-cask-$i"; done
    write_mock_brew "$formulae" "$cask"

    run_sync
    assert_success

    grep -q "uninstall --cask claude-code" "$BREW_LOG"
    grep -q "uninstall omp" "$BREW_LOG"
}

@test "migration: no brew uninstall when neither brew copy is present" {
    write_test_yaml
    # Default mock brew reports no formulae/casks installed.

    run_sync
    assert_success

    ! grep -q "uninstall" "$BREW_LOG"
}

# --- mise + version/rev-aware installs ---

@test "sync_mise bootstraps mise via brew and converges in the same run" {
    write_test_yaml
    rm -f "$MOCK_BIN/mise"
    cat > "$MOCK_BIN/brew" << MOCKBREW
#!/bin/bash
echo "brew \$*" >> "$BREW_LOG"
if [[ "\$1 \$2" == "install mise" ]]; then
    cat > "$MOCK_BIN/mise" << 'MOCKMISE'
#!/bin/bash
echo "mise \$* config=\${MISE_GLOBAL_CONFIG_FILE:-unset}" >> "$MISE_LOG"
exit 0
MOCKMISE
    chmod +x "$MOCK_BIN/mise"
fi
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"

    run_sync
    assert_success
    grep -q "install mise" "$BREW_LOG"
    grep -q "mise install config=$MISE_CONFIG_FILE" "$MISE_LOG"
}

@test "sync_mise skips the brew bootstrap when mise is already on PATH" {
    write_test_yaml

    run_sync
    assert_success

    ! grep -q "install mise" "$BREW_LOG"
    grep -q "mise install config=$MISE_CONFIG_FILE" "$MISE_LOG"
}

@test "a pinned cargo package installs at its exact version, unconditionally" {
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - cargo-update: { source: cargo, version: "1.2.3" }
YAML
    run_sync
    assert_success

    grep -q -- "--version 1.2.3 cargo-update" "$CARGO_LOG"
}

@test "a pinned npm package installs at its exact version, unconditionally" {
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - markdownlint-cli2: { source: npm, version: "1.2.3" }
YAML
    run_sync
    assert_success

    grep -q "install -g markdownlint-cli2@1.2.3" "$NPM_LOG"
}

@test "a pinned uv package installs at its exact version, unconditionally" {
    write_mock_uv
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - ruff: { source: uv, version: "1.2.3" }
YAML
    run_sync
    assert_success

    grep -q "tool install ruff==1.2.3" "$UV_LOG"
}

@test "UPGRADE_MODE upgrades only the intentionally unpinned uv channel" {
    write_mock_uv
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - ruff: { source: uv, version: "1.2.3" }
  - milknado: { source: uv, pkg: "git+https://github.com/paulnsorensen/milknado@main" }
YAML

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success
    grep -q "tool upgrade milknado" "$UV_LOG"
    ! grep -q "tool upgrade.*ruff" "$UV_LOG"
    ! grep -q "tool upgrade --all" "$UV_LOG"
}

@test "non-upgrade sync never runs the uv floating upgrade path" {
    write_mock_uv
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - ruff: { source: uv, version: "1.2.3" }
  - milknado: { source: uv, pkg: "git+https://github.com/paulnsorensen/milknado@main" }
YAML

    run_sync
    assert_success
    ! grep -q "tool upgrade" "$UV_LOG"
}

@test "a pinned gh-extension installs at its exact tag via --pin, unconditionally" {
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - gh-stack: { source: gh-extension, pkg: "github/gh-stack", version: "1.2.3" }
YAML
    run_sync
    assert_success

    grep -q -- "extension install github/gh-stack --pin 1.2.3" "$GH_LOG"
}

@test "UPGRADE_MODE reconverges a pinned cargo package without floating an unpinned sibling" {
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - cargo-update: { source: cargo, version: "1.2.3" }
  - cargo-audit: { source: cargo }
YAML
    cat > "$MOCK_BIN/cargo" << 'MOCKCARGO'
#!/bin/bash
echo "cargo $*" >> "$CARGO_LOG"
if [[ "$1 $2" == "install --list" ]]; then
    echo "cargo-audit v0.1.0:"
fi
exit 0
MOCKCARGO
    chmod +x "$MOCK_BIN/cargo"

    UPGRADE_MODE=true run bash "$SYNC_SCRIPT"
    assert_success

    grep -q -- "--version 1.2.3 cargo-update" "$CARGO_LOG"
    ! grep -q "cargo install cargo-audit" "$CARGO_LOG"
    ! grep -q "cargo install-update" "$CARGO_LOG"
}

@test "migrate_harness_off_native removes a stale mise-migrated harness binary from ~/.local/bin" {
    write_test_yaml
    mkdir -p "$TEST_HOME/.local/bin"
    touch "$TEST_HOME/.local/bin/claude"

    run_sync
    assert_success

    [[ ! -e "$TEST_HOME/.local/bin/claude" ]]
}