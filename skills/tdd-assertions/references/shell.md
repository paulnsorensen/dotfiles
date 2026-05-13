# Shell / Bash (bats) Weak Assertions

## 1. Status-only assertion — no output check

The command succeeded. But did it produce the right output?

```bash
# WEAK
run my_command
[[ $status -eq 0 ]]

# WEAK — bats helper, same problem
run my_command
assert_success

# STRONG — status AND output
run my_command --flag
assert_success
[[ "$output" == "expected output" ]]
```

## 2. Status catch-all

Accepts multiple exit codes — anything passes.

```bash
# WEAK — exit 0 (success) and exit 1 (failure) both pass
run my_command
[[ $status -eq 0 || $status -eq 1 ]]

# STRONG — assert the specific expected status
run my_command
assert_success
[[ "$output" == "expected output" ]]

# STRONG — for error cases, assert the specific failure
run my_command --invalid
assert_failure
[[ "$output" == *"Unknown option: --invalid"* ]]
```

## 3. Absence-of-error as sole assertion

Checking that a specific error string is absent doesn't verify correct behavior.

```bash
# WEAK — any output except "parse error" passes
run parse_config "$input"
assert_not_contains "parse error"

# STRONG — assert the expected output positively
run parse_config "$input"
assert_success
[[ "$output" == "key=value" ]]

# If testing malformed input tolerance, assert the fallback behavior
run parse_config "$malformed"
assert_success
[[ "$output" == "" ]]  # or whatever the expected fallback is
```

## 4. Over-broad substring matching

Matches unrelated strings. `*"s"*` matches almost everything.

```bash
# WEAK — "s" or "m" appears in nearly every string
[[ "$output" == *"s"* || "$output" == *"m"* ]]

# WEAK — "error" matches "no_error", "error_count", etc.
[[ "$output" == *"error"* ]]

# STRONG — specific expected text
[[ "$output" == "30m" ]]
[[ "$output" == "Error: file not found" ]]
```

## 5. File existence without content check

The file was created — is it correct?

```bash
# WEAK
run generate_config
[[ -f result.txt ]]

# STRONG
run generate_config
[[ -f result.txt ]]
[[ "$(cat result.txt)" == "expected content" ]]

# Or for large files, check key content
run generate_config
assert_success
grep -q "^server_name=prod$" result.txt
grep -q "^port=8080$" result.txt
```

## 6. `grep -q` without anchoring

Matches partial lines, leading to false positives.

```bash
# WEAK — "count" matches "count=0", "discount", "account"
grep -q "count" output.txt

# STRONG — anchored match
grep -q "^count=3$" output.txt

# STRONG — exact line match
[[ "$(grep '^count=' output.txt)" == "count=3" ]]
```

## 7. Comparing numbers as strings

Leads to surprising failures with leading zeros or whitespace.

```bash
# WEAK — string comparison, "03" != "3"
[[ "$count" == "3" ]]

# STRONG — arithmetic comparison for numbers
[[ $count -eq 3 ]]

# But for output that should be exact, string comparison IS correct
[[ "$output" == "3 items found" ]]
```

## 8. Missing negative test cases

AI generates only happy-path tests. Error handling goes untested.

```bash
# WEAK — only tests success
@test "parse valid config" {
    run parse_config valid.yaml
    assert_success
}

# STRONG — also test failure modes
@test "parse valid config" {
    run parse_config valid.yaml
    assert_success
    [[ "$output" == "key=value" ]]
}

@test "parse invalid config returns error" {
    run parse_config invalid.yaml
    assert_failure
    [[ "$output" == *"syntax error at line 3"* ]]
}

@test "parse missing file returns error" {
    run parse_config nonexistent.yaml
    assert_failure
    [[ "$output" == *"file not found: nonexistent.yaml"* ]]
}
```

## 9. Not using `run` for testable commands

Calling commands directly instead of through `run` means bats can't capture
status and output.

```bash
# WEAK — if this fails, the whole test aborts (set -e)
my_command arg1
[[ -f output.txt ]]

# STRONG — run captures status and output
run my_command arg1
assert_success
[[ "$output" == "expected" ]]
```
