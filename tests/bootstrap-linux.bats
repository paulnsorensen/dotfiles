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

@test "get_bootstrap_brew_pkgs excludes entries with apt_install (opt-out marker)" {
    # Entries carrying apt_install opt out of the brew bootstrap on Linux —
    # they install via their own apt source (e.g. tailscale uses Tailscale's
    # installer for systemd integration). Without this filter, dots bootstrap
    # would brew-install AND sync surface the custom-source installer for the
    # same package.
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - jq
  - tailscale: { platform: linux, apt_install: "curl -fsSL https://tailscale.com/install.sh | sh" }
YAML
    run get_bootstrap_brew_pkgs
    assert_success
    assert_output_contains "jq"
    assert_output_not_contains "tailscale"
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
