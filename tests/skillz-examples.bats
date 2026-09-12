#!/usr/bin/env bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
HOOKS_CATALOG="$REPO_ROOT/skills/skillz/references/hooks-catalog.md"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

extract_example() {
    local marker="$1"
    local destination="$2"
    awk -v marker="$marker" '
        /^```javascript$/ {
            in_block = 1
            block = ""
            next
        }
        in_block && $0 == "```" {
            if (index(block, marker)) {
                printf "%s", block
                exit
            }
            in_block = 0
            next
        }
        in_block {
            block = block $0 ORS
        }
    ' "$HOOKS_CATALOG" > "$destination"
}

run_hook() {
    local payload="$1"
    local script="$2"
    printf "%s" "$payload" | node "$script"
}

@test "hook examples read stdin JSON and preserve absent-field defaults" {
    local prompt_script="$TEST_TMPDIR/prompt.js"
    local output_script="$TEST_TMPDIR/output.js"
    local preprocess_source_script="$TEST_TMPDIR/preprocess-source.js"
    local preprocess_script="$TEST_TMPDIR/preprocess.js"
    local banned_script="$TEST_TMPDIR/banned.js"
    local source_file="$TEST_TMPDIR/example.ts"
    local log_file="$TEST_TMPDIR/example.log"
    local filtered_file="$TEST_TMPDIR/preprocessed-example.log"
    local expected_banned

    extract_example 'const prompt =' "$prompt_script"
    run run_hook '{"prompt":"deploy this change"}' "$prompt_script"
    [ "$status" -eq 0 ]
    [ "$output" = "MANDATORY: Evaluate installed skills before proceeding." ]

    run run_hook '{}' "$prompt_script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run run_hook '{' "$prompt_script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"JSON"* || "$output" == *"Unexpected"* ]]

    extract_example '// .claude/hooks/validate-output.js' "$output_script"
    run run_hook '{"tool_input":{"path":"'"$source_file"'"}}' "$output_script"
    [ "$status" -eq 0 ]
    [ "$output" = "WARNING: $source_file written without a test file." ]

    run run_hook '{"tool_input":{"file_path":"'"$source_file"'"}}' "$output_script"
    [ "$status" -eq 0 ]
    [ "$output" = "WARNING: $source_file written without a test file." ]

    run run_hook '{}' "$output_script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]


    printf 'WARN: cache is stale\nINFO: keep this line\n' > "$log_file"
    extract_example '// .claude/hooks/preprocess-context.js' "$preprocess_source_script"
    sed "s|path.join('/tmp',|path.join('$TEST_TMPDIR',|" "$preprocess_source_script" > "$preprocess_script"
    run run_hook '{"tool_input":{"path":"'"$log_file"'"}}' "$preprocess_script"
    [ "$status" -eq 0 ]
    [ "$output" = "Filtered $log_file: 3 → 1 lines. See $filtered_file" ]
    actual="$(<"$filtered_file")"
    [ "$actual" = $'[3 lines → 1]\n\nWARN: cache is stale' ]

    run run_hook '{"tool_input":{"file_path":"'"$log_file"'"}}' "$preprocess_script"
    [ "$status" -eq 0 ]
    [ "$output" = "Filtered $log_file: 3 → 1 lines. See $filtered_file" ]
    actual="$(<"$filtered_file")"
    [ "$actual" = $'[3 lines → 1]\n\nWARN: cache is stale' ]

    run run_hook '{}' "$preprocess_script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    printf 'console.log("bad");\n' > "$source_file"
    extract_example '// .claude/hooks/banned-patterns.js' "$banned_script"
    run run_hook '{"tool_input":{"path":"'"$source_file"'"}}' "$banned_script"
    [ "$status" -eq 0 ]
    expected_banned=$'Pattern violations in '
    expected_banned+="$source_file"
    expected_banned+=$':\n  Use project logger instead of console.log (1x)'
    [ "$output" = "$expected_banned" ]

    run run_hook '{"tool_input":{"file_path":"'"$source_file"'"}}' "$banned_script"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected_banned" ]

    run run_hook '{}' "$banned_script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "prompt counter initializes, increments, and fails without overwriting state" {
    local source_script="$TEST_TMPDIR/counter-source.js"
    local counter_script="$TEST_TMPDIR/counter.js"
    local counter_file="$TEST_TMPDIR/counter.json"
    local counter_directory="$TEST_TMPDIR/counter-directory"
    local original actual

    extract_example '// .claude/hooks/token-budget-check.js' "$source_script"
    sed "s|/tmp/claude-prompt-counter.json|$counter_file|" "$source_script" > "$counter_script"

    run node "$counter_script"
    [ "$status" -eq 0 ]
    run node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).count))' "$counter_file"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    printf '{"count":19,"lastCompact":123}' > "$counter_file"
    run node "$counter_script"
    [ "$status" -eq 0 ]
    run node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).count))' "$counter_file"
    [ "$status" -eq 0 ]
    [ "$output" = "20" ]

    printf '{not-json' > "$counter_file"
    original="$(<"$counter_file")"
    run node "$counter_script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"JSON"* || "$output" == *"Unexpected"* ]]
    actual="$(<"$counter_file")"
    [ "$actual" = "$original" ]

    mkdir "$counter_directory"
    sed "s|/tmp/claude-prompt-counter.json|$counter_directory|" "$source_script" > "$counter_script"
    run node "$counter_script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"EISDIR"* || "$output" == *"directory"* ]]
}
