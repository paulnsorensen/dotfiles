#!/usr/bin/env bats
# Tests for git pre-commit hooks

load test_helper

setup() {
    setup_test_env
    
    # Create a test git repository
    export TEST_REPO="$TEST_HOME/test-repo"
    mkdir -p "$TEST_REPO"
    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Set up the hook - use the REAL dotfiles directory for hooks
    git config core.hooksPath "$REAL_DOTFILES_DIR/githooks"
}

teardown() {
    cd "$ORIGINAL_HOME"
    teardown_test_env
}

@test "pre-commit hook exists and is executable" {
    [[ -x "$REAL_DOTFILES_DIR/githooks/pre-commit" ]]
}

@test "pre-commit blocks files with passwords" {
    echo 'password="secret123"' > test.sh
    git add test.sh
    
    run git commit -m "test commit"
    assert_failure
    assert_output_contains "Potential secret found"
}

@test "pre-commit blocks files with API keys" {
    echo 'api_key="sk-1234567890abcdef"' > config.sh
    git add config.sh
    
    run git commit -m "test commit"
    assert_failure
    assert_output_contains "Potential secret found"
}

@test "pre-commit blocks files with tokens" {
    echo 'github_token="ghp_xxxxxxxxxxxx"' > .env
    git add .env
    
    run git commit -m "test commit"
    assert_failure
    assert_output_contains "Potential secret found"
}

@test "pre-commit allows .example files with secrets" {
    echo 'password="change_me"' > .env.example
    git add .env.example
    
    run git commit -m "test commit"
    assert_success
}

@test "pre-commit validates shell script syntax" {
    # Create a shell script with syntax error
    cat > bad.sh << 'EOF'
#!/bin/bash
echo "test"
if [[ true ] # Missing closing bracket
then
    echo "bad"
fi
EOF
    git add bad.sh
    
    run git commit -m "test commit"
    assert_failure
    assert_output_contains "Syntax error"
}

@test "pre-commit allows valid shell scripts" {
    cat > good.sh << 'EOF'
#!/bin/bash
echo "test"
if [[ true ]]; then
    echo "good"
fi
EOF
    git add good.sh
    
    run git commit -m "test commit"
    assert_success
}

@test "pre-commit detects secret file patterns" {
    touch id_rsa
    git add id_rsa
    
    run git commit -m "test commit"
    assert_failure
    assert_output_contains "Secret file detected"
}

@test "pre-commit allows normal files" {
    echo "Just a normal file" > README.md
    git add README.md
    
    run git commit -m "test commit"
    assert_success
}

@test "pre-commit checks can be bypassed with --no-verify" {
    echo 'password="secret"' > secret.sh
    git add secret.sh
    
    run git commit --no-verify -m "bypass checks"
    assert_success
}