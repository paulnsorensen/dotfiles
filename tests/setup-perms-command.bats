#!/usr/bin/env bats

load test_helper

setup() {
    command_files=(
        "$REAL_DOTFILES_DIR/chezmoi/dot_claude/exact_commands/setup-perms.md"
        "$REAL_DOTFILES_DIR/claude/commands/setup-perms.md"
    )
}

@test "setup-perms commands use the supported cheese profile permissions surface" {
    for command_file in "${command_files[@]}"; do
        run grep -F "cheese profile permissions --project-root \"\$(pwd)\"" "$command_file"
        assert_success

        run grep -F "cheese profile permissions --local --project-root \"\$(pwd)\"" "$command_file"
        assert_success

        run grep -F -- "--target \"\$(pwd)\"" "$command_file"
        assert_failure

        run grep -F 'ap perms' "$command_file"
        assert_failure
    done
}
