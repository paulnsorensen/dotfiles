#!/usr/bin/env bats
# Unit tests for packages/bootstrap-linux.sh
#
# Sources the script (main is guarded behind BASH_SOURCE==$0) and exercises the
# registry-derivation + toolchain-detection functions directly. Network/sudo
# paths (the actual brew/rustup installs) are not exercised here. The reused
# helpers (bootstrap_brew_deps_linux / linuxbrew_shellenv / bootstrap_yq_linux)
# live in packages/lib-linux-bootstrap.sh and are covered by packages.bats.

load test_helper

BOOTSTRAP="$REAL_DOTFILES_DIR/packages/bootstrap-linux.sh"

setup() {
    setup_test_env
    export PACKAGES_FILE="$TEST_HOME/packages.yaml"
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    # shellcheck disable=SC1090
    source "$BOOTSTRAP"
}

teardown() {
    teardown_test_env
}

write_test_yaml() {
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - some/tap-repo: { source: tap }
  - jq
  - taf2/tap/mdvi
  - fd: { apt: fd-find }
  - xclip: { platform: linux }
  - mas: { platform: mac }
  - docker: { source: cask, platform: mac }
  - cargo-llvm-cov: { source: cargo }
  - markdownlint-cli2: { source: npm }
  - ralphify: { source: uv }
  - gh-stack: { source: gh-extension, pkg: github/gh-stack }
  - pyenv: { dev: true }
YAML
}

@test "get_bootstrap_brew_pkgs returns brew formulae by their key" {
    write_test_yaml
    run get_bootstrap_brew_pkgs
    assert_success
    assert_output_contains "jq"
    assert_output_contains "fd"            # uses .key, NOT the apt 'fd-find' name
    assert_output_contains "taf2/tap/mdvi" # bare scalar with a tap-qualified name
    assert_output_contains "xclip"         # linux-only brew formula is included
}

@test "get_bootstrap_brew_pkgs excludes cask/tap/cargo/npm/uv/gh-extension/dev/mac" {
    write_test_yaml
    run get_bootstrap_brew_pkgs
    assert_success
    assert_output_not_contains "fd-find"          # apt name must not leak
    assert_output_not_contains "mas"              # mac-only
    assert_output_not_contains "docker"           # cask + mac-only
    assert_output_not_contains "some/tap-repo"    # tap
    assert_output_not_contains "cargo-llvm-cov"   # cargo
    assert_output_not_contains "markdownlint-cli2" # npm
    assert_output_not_contains "ralphify"         # uv
    assert_output_not_contains "gh-stack"         # gh-extension
    assert_output_not_contains "pyenv"            # dev-gated
}

@test "get_bootstrap_taps returns only tap sources" {
    write_test_yaml
    run get_bootstrap_taps
    assert_success
    assert_output_contains "some/tap-repo"
    assert_output_not_contains "jq"
    assert_output_not_contains "docker"
}

@test "bootstrap_brew is a no-op when brew is already on PATH" {
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/brew"
    chmod +x "$MOCK_BIN/brew"
    PATH="$MOCK_BIN:$PATH" run bootstrap_brew
    assert_success
    assert_output_contains "already installed"
}

@test "bootstrap_rustup is a no-op when cargo is already on PATH" {
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/cargo"
    chmod +x "$MOCK_BIN/cargo"
    PATH="$MOCK_BIN:$PATH" run bootstrap_rustup
    assert_success
    assert_output_contains "already present"
}

@test "real packages.yaml: bootstrap brew list excludes mac-only and non-brew sources" {
    export PACKAGES_FILE="$REAL_DOTFILES_DIR/packages/packages.yaml"
    run get_bootstrap_brew_pkgs
    assert_success
    # Spot-check a few known entries from the real registry.
    assert_output_contains "ripgrep"
    assert_output_contains "node"
    assert_output_not_contains "skhd"        # mac-only (koekeishiya tap)
    assert_output_not_contains "claude-code" # cask, mac-only
    assert_output_not_contains "rtk"         # cargo (git-sourced)
}

# Stub the toolchain externals and yq so main reaches install_brew_packages and
# the sync handoff. yq is mocked to emit one formula so `brew install` runs.
stub_main_env() {
    export PLATFORM="Linux"
    printf '#!/bin/bash\necho jq\n' > "$MOCK_BIN/yq"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/cargo"
    chmod +x "$MOCK_BIN/yq" "$MOCK_BIN/cargo"
    # Capture the sync.sh handoff: main runs `bash "$SCRIPT_DIR/sync.sh"`, so a
    # PATH-shadowing bash records FORCE_PACKAGES and the script it was handed.
    cat > "$MOCK_BIN/bash" << EOF
#!/bin/bash
echo "handoff force=\${FORCE_PACKAGES:-unset} script=\$1" > "$TEST_HOME/handoff.log"
exit 0
EOF
    chmod +x "$MOCK_BIN/bash"
    # apt/sudo toolchain step is out of scope for these unit tests.
    bootstrap_brew_deps_linux() { :; }
    export PATH="$MOCK_BIN:$PATH"
}

@test "main hands off to sync.sh with FORCE_PACKAGES=true" {
    write_test_yaml
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/brew"
    chmod +x "$MOCK_BIN/brew"
    stub_main_env
    run main
    assert_success
    run cat "$TEST_HOME/handoff.log"
    assert_output_contains "force=true"
    assert_output_contains "sync.sh"
}

@test "main exits non-zero when a brew formula install fails" {
    write_test_yaml
    # brew is present (no-ops the install step) but `brew install` fails, so the
    # FAILED array gains an entry and main must propagate a non-zero exit.
    cat > "$MOCK_BIN/brew" << 'EOF'
#!/bin/bash
case "$1" in install) exit 1;; *) exit 0;; esac
EOF
    chmod +x "$MOCK_BIN/brew"
    stub_main_env
    run main
    assert_failure
    assert_output_contains "finished with failures"
    assert_output_contains "brew-install"
}
