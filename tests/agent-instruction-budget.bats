#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317

load test_helper

setup() {
    setup_test_env
    HELPER="$REAL_DOTFILES_DIR/tests/helpers/agent_instruction_budget.py"
    CONFIG="$REAL_DOTFILES_DIR/agents/instruction-budgets.toml"
}

teardown() { teardown_test_env; }

run_budget_check() {
    run uv run --project "$REAL_DOTFILES_DIR/agent-profile" --frozen \
        python "$HELPER" "$@"
}

@test "agent instructions stay within both tokenizer budgets" {
    run_budget_check "$CONFIG"
    assert_success
    assert_output_contains "source agent-profile/AGENTS.md:"
    assert_output_contains "stack global_claude:"
    assert_output_contains "stack copilot_coding_max:"
    assert_output_contains "o200k_base="
    assert_output_contains "cl100k_base="
}

@test "agent instruction budget rejects an exceeded ceiling" {
    local constrained="$TEST_HOME/instruction-budgets.toml"
    awk '!changed && /^max_tokens = / {$0 = "max_tokens = 0"; changed = 1} {print}' \
        "$CONFIG" > "$constrained"

    run_budget_check "$constrained" --root "$REAL_DOTFILES_DIR"
    assert_failure
    assert_output_contains "AGENTS.md exceeds o200k_base budget"
    assert_output_contains "AGENTS.md exceeds cl100k_base budget"
}
