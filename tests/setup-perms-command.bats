#!/usr/bin/env bats

load test_helper

setup() {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    local rendered_dir="$BATS_TEST_TMPDIR/exact_commands"
    _cz_copy_encoded "$REAL_DOTFILES_DIR/claude/commands" "$rendered_dir"
    command_files=(
        "$REAL_DOTFILES_DIR/claude/commands/setup-perms.md"
        "$rendered_dir/setup-perms.md"
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
