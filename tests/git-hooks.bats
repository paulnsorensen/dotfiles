#!/usr/bin/env bats
# Tests for prek pre-commit hooks
# shellcheck disable=SC2164

load test_helper

setup() {
    setup_test_env

    # Create a test git repository
    export TEST_REPO="$TEST_HOME/test-repo"
    mkdir -p "$TEST_REPO"
    cd "$TEST_REPO" || return
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Check if prek is available
    if ! command -v prek &>/dev/null; then
        export PREK_AVAILABLE=false
        return 0
    fi
    export PREK_AVAILABLE=true

    # Copy prek.toml from dotfiles (without claude-sync check since test repo != dotfiles)
    grep -v 'check-claude-sync' "$REAL_DOTFILES_DIR/prek.toml" > "$TEST_REPO/prek.toml"

    # Install prek hooks (prek auto-detects prek.toml in repo root)
    prek install -f >/dev/null 2>&1
    # Pre-install hook environments so first commit isn't slow
    prek install-hooks >/dev/null 2>&1 || true

    # Initial commit so hooks have something to diff against
    echo "init" > .gitkeep
    git add .gitkeep prek.toml
    git commit --no-verify -m "init" --quiet
}

teardown() {
    cd "$ORIGINAL_HOME" || true
    teardown_test_env
}

@test "prek.toml exists in dotfiles" {
    [[ -f "$REAL_DOTFILES_DIR/prek.toml" ]]
}

@test "prek is installed" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    command -v prek
}

@test "pre-commit hook is installed" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    [[ -f "$TEST_REPO/.git/hooks/pre-commit" ]]
}

@test "pre-commit detects private keys" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    # Write key via printf to avoid embedding literal key in this file
    printf '%s\n%s\n%s\n' \
        '-----BEGIN RSA PRIVATE KEY-----' \
        'MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGPY' \
        '-----END RSA PRIVATE KEY-----' > id_rsa
    git add id_rsa

    run git commit -m "test commit"
    assert_failure
}

@test "pre-commit allows normal files" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    echo "Just a normal file" > README.md
    git add README.md

    run git commit -m "test commit"
    assert_success
}

@test "pre-commit allows valid shell scripts" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    cat > good.sh << 'EOF'
#!/bin/bash
greeting="test"
echo "$greeting"
if [[ -n "$greeting" ]]; then
    echo "good"
fi
EOF
    git add good.sh

    run git commit -m "test commit"
    assert_success
}

@test "pre-commit checks can be bypassed with --no-verify" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    printf '%s\n%s\n%s\n' \
        '-----BEGIN RSA PRIVATE KEY-----' \
        'MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGPY' \
        '-----END RSA PRIVATE KEY-----' > id_rsa
    git add id_rsa

    run git commit --no-verify -m "bypass checks"
    assert_success
}

@test "pre-commit blocks large files" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    # Create a file larger than 1MB
    dd if=/dev/zero of=large.bin bs=1025k count=1 2>/dev/null
    git add large.bin

    run git commit -m "test commit"
    assert_failure
}

@test "pre-commit checks yaml syntax" {
    [[ "$PREK_AVAILABLE" == true ]] || skip "prek not installed"
    echo "valid: yaml" > good.yaml
    git add good.yaml

    run git commit -m "test commit"
    assert_success
}
