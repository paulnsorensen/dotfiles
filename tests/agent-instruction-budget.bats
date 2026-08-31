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

write_family_config() {
    # $1 = config path, $2 = family max_tokens, $3 = optional overrides table body
    cat > "$1" <<EOF
version = 1
encodings = ["o200k_base", "cl100k_base"]

[[family]]
glob = "skills/*/SKILL.md"
max_tokens = $2
${3:+
[family.overrides]
$3}
EOF
}

@test "agent instructions stay within both tokenizer budgets" {
    run_budget_check "$CONFIG"
    assert_success
    assert_output_contains "source agent-profile/AGENTS.md:"
    assert_output_contains "stack global_claude:"
    assert_output_contains "stack copilot_coding_max:"
    # The xray override is live: without it the family cap fails this run.
    assert_output_contains "family skills/*/SKILL.md skills/xray/SKILL.md:"
    assert_output_contains "o200k_base="
    assert_output_contains "cl100k_base="
}

@test "Claude/Codex and OMP system prompts share the writing standard" {
    local source rule
    for source in \
        "$REAL_DOTFILES_DIR/agents/preamble.md" \
        "$REAL_DOTFILES_DIR/chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md"; do
        for rule in \
            'Simplified Technical English (ASD-STE100)' \
            'one instruction per sentence' \
            'procedural sentences to 20 words' \
            'comments, commits, and specifications'; do
            run grep -Fq "$rule" "$source"
            assert_success
        done
    done
}

@test "OMP prompt keeps the current concise confidence and checkpoint rules" {
    local append="$REAL_DOTFILES_DIR/chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md"

    run grep -Fq 'Checkpoint after each significant step' "$append"
    assert_failure
    run grep -Fq "Calibrate every claim: \`<certain>\`" "$append"
    assert_failure
    run grep -Fq 'Checkpoint only when context risk or a handoff requires it.' "$append"
    assert_success
    run grep -Fq 'Do not tag obvious facts.' "$append"
    assert_success
}

@test "family budget passes an under-cap skill" {
    mkdir -p "$TEST_HOME/famroot/skills/tiny"
    echo "one short skill body" > "$TEST_HOME/famroot/skills/tiny/SKILL.md"
    write_family_config "$TEST_HOME/family.toml" 5000

    run_budget_check "$TEST_HOME/family.toml" --root "$TEST_HOME/famroot"
    assert_success
    assert_output_contains "family skills/*/SKILL.md skills/tiny/SKILL.md:"
}

@test "family budget rejects an over-cap skill without an override" {
    mkdir -p "$TEST_HOME/famroot/skills/bloated"
    yes "family budget filler words for the oversized skill body" | head -3000 \
        > "$TEST_HOME/famroot/skills/bloated/SKILL.md"
    write_family_config "$TEST_HOME/family.toml" 5000

    run_budget_check "$TEST_HOME/family.toml" --root "$TEST_HOME/famroot"
    assert_failure
    assert_output_contains "skills/bloated/SKILL.md exceeds o200k_base budget"
    assert_output_contains "skills/bloated/SKILL.md exceeds cl100k_base budget"
}

@test "family override exempts a named skill at its own ceiling" {
    mkdir -p "$TEST_HOME/famroot/skills/bloated"
    yes "family budget filler words for the oversized skill body" | head -3000 \
        > "$TEST_HOME/famroot/skills/bloated/SKILL.md"
    write_family_config "$TEST_HOME/family.toml" 5000 \
        '"skills/bloated/SKILL.md" = 50000'

    run_budget_check "$TEST_HOME/family.toml" --root "$TEST_HOME/famroot"
    assert_success
    assert_output_contains "family skills/*/SKILL.md skills/bloated/SKILL.md:"
    assert_output_contains "max=50000"
}

@test "family budget ignores a deleted skill, even an overridden one" {
    mkdir -p "$TEST_HOME/famroot/skills/tiny"
    echo "one short skill body" > "$TEST_HOME/famroot/skills/tiny/SKILL.md"
    write_family_config "$TEST_HOME/family.toml" 5000 \
        '"skills/deleted/SKILL.md" = 5800'

    run_budget_check "$TEST_HOME/family.toml" --root "$TEST_HOME/famroot"
    assert_success
    assert_output_contains "family skills/*/SKILL.md skills/tiny/SKILL.md:"
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
