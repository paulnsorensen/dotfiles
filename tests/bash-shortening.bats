#!/usr/bin/env bats
#
# Tests for skills/bash-shortening/scripts/bash-shorten.py.
#
# Three layers:
#   1. CLI surface  — flag/arg parsing, error paths, --list, --explain.
#   2. Engine       — dry-run vs --apply, stdin/stdout, no-op handling.
#   3. Per-rule end-to-end — every rule fires on a positive fixture
#      through the real CLI (complements the in-process --self-test
#      with subprocess-level coverage).
#
# This whole file is fixture data — literal bash strings the rewriter is meant
# to transform in-test, not a script to optimize. Opt the entire file out so a
# stray `bash-shorten --apply` over it can't rewrite the fixtures (issue #59).
# bash-shorten: disable
# Fixtures are literal Bash, so single-quoted $ and backticks are intended.
# shellcheck disable=SC2016

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/skills/bash-shortening/scripts/bash-shorten.py"
    FIXTURE="$BATS_TEST_TMPDIR/sample.sh"
}

# Pipe `$1` through the script in stdin mode and assert the stdout
# contains `$2` verbatim. Bats' `run` clobbers pipes, so we capture
# manually and use a printf+grep idiom.
assert_rewrite() {
    local input="$1" expected="$2" got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" - 2>/dev/null)"
    if [[ "$got" != *"$expected"* ]]; then
        printf 'input:    %s\nexpected: %s\ngot:      %s\n' \
            "$input" "$expected" "$got" >&2
        return 1
    fi
}

# -- CLI surface -------------------------------------------------------------

@test "--self-test exits 0 with all embedded fixtures green" {
    run python3 "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
    # Asserts no FAIL lines leaked through.
    [[ "$output" != *"FAIL"* ]]
}

@test "--list emits every documented rule id" {
    run python3 "$SCRIPT" --list
    [ "$status" -eq 0 ]
    for rule in sed-replace-first sed-replace-all \
                echo-wc-c cut-c-substring \
                expr-arith-vars expr-increment expr-arith-literal \
                combined-tests test-numeric empty-default \
                mkdir-guard for-range-expansion \
                backticks legacy-null-check empty-string-eq \
                find-exec-rm-delete cat-file-pipe-grep \
                sed-replace-to-sd grep-fixed-to-rg find-name-to-fd; do
        [[ "$output" == *"$rule"* ]] || {
            echo "missing rule in --list output: $rule" >&2
            return 1
        }
    done
}

@test "--explain prints id, description, pattern, examples for known rule" {
    run python3 "$SCRIPT" --explain test-numeric
    [ "$status" -eq 0 ]
    [[ "$output" == *"id:"* ]]
    [[ "$output" == *"description:"* ]]
    [[ "$output" == *"pattern:"* ]]
    [[ "$output" == *"examples:"* ]]
}

@test "--explain unknown rule exits 1 with diagnostic" {
    run python3 "$SCRIPT" --explain bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown rule: bogus"* ]]
}

@test "missing file argument exits 2 (argparse error)" {
    run python3 "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"file is required"* ]]
}

@test "non-existent file exits 1 with diagnostic" {
    run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/does-not-exist.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a file"* ]]
}

@test "--apply with stdin is rejected" {
    run bash -c "echo x | python3 \"$SCRIPT\" --apply -"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--apply is incompatible with stdin"* ]]
}

@test "--rules referencing unknown id exits 1" {
    printf 'V=`pwd`\n' > "$FIXTURE"
    run python3 "$SCRIPT" --rules backticks,bogus "$FIXTURE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown rules: bogus"* ]]
}

@test "--skip referencing unknown id exits 1" {
    printf 'echo hi\n' > "$FIXTURE"
    run python3 "$SCRIPT" --skip bogus "$FIXTURE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown rules: bogus"* ]]
}

# -- Engine behavior --------------------------------------------------------

@test "dry-run emits unified diff but leaves the file untouched" {
    printf 'V=`pwd`\n' > "$FIXTURE"
    local before_hash
    before_hash="$(shasum "$FIXTURE" | awk '{print $1}')"

    run python3 "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"---"* ]]
    [[ "$output" == *"+++"* ]]
    [[ "$output" == *"-V="* ]]
    [[ "$output" == *'+V=$(pwd)'* ]]

    local after_hash
    after_hash="$(shasum "$FIXTURE" | awk '{print $1}')"
    [ "$before_hash" = "$after_hash" ]
}

@test "no-op file reports 'no rewrites applicable' and exits 0" {
    printf 'echo hello\nls -la\n' > "$FIXTURE"
    run python3 "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no rewrites applicable"* ]]
}

@test "--apply rewrites the file in place and leaves no temp files" {
    printf 'V=`pwd`\n' > "$FIXTURE"
    run python3 "$SCRIPT" --apply "$FIXTURE"
    [ "$status" -eq 0 ]
    grep -qF 'V=$(pwd)' "$FIXTURE"
    # Asserts the public contract (atomic write, no leftover temp siblings)
    # without coupling to the private temp-file naming convention.
    local fixture_dir leftovers
    fixture_dir="$(dirname "$FIXTURE")"
    leftovers="$(find "$fixture_dir" -maxdepth 1 -name '*.tmp' -not -path "$FIXTURE")"
    [ -z "$leftovers" ]
}

@test "--apply preserves the executable bit on rewritten scripts" {
    printf '#!/usr/bin/env bash\nV=`pwd`\n' > "$FIXTURE"
    chmod +x "$FIXTURE"
    run python3 "$SCRIPT" --apply "$FIXTURE"
    [ "$status" -eq 0 ]
    [ -x "$FIXTURE" ]
}

@test "--apply on no-op file does not rewrite" {
    printf 'echo hello\n' > "$FIXTURE"
    local before_hash
    before_hash="$(shasum "$FIXTURE" | awk '{print $1}')"
    run python3 "$SCRIPT" --apply "$FIXTURE"
    [ "$status" -eq 0 ]
    local after_hash
    after_hash="$(shasum "$FIXTURE" | awk '{print $1}')"
    [ "$before_hash" = "$after_hash" ]
}

@test "stdin mode writes rewritten content to stdout" {
    local got
    got="$(printf 'V=`pwd`\n' | python3 "$SCRIPT" -)"
    [[ "$got" == *'V=$(pwd)'* ]]
}

# -- Rule selection ---------------------------------------------------------

@test "--rules subset only fires named rules" {
    printf 'V=`pwd`\nLEN=$(echo -n "$S" | wc -c)\n' > "$FIXTURE"
    run python3 "$SCRIPT" --rules backticks --apply "$FIXTURE"
    [ "$status" -eq 0 ]
    grep -qF 'V=$(pwd)' "$FIXTURE"
    # echo-wc-c must remain untouched
    grep -qF 'LEN=$(echo -n "$S" | wc -c)' "$FIXTURE"
}

@test "--skip excludes a rule even when its pattern matches" {
    printf 'V=`pwd`\nLEN=$(echo -n "$S" | wc -c)\n' > "$FIXTURE"
    run python3 "$SCRIPT" --skip echo-wc-c --apply "$FIXTURE"
    [ "$status" -eq 0 ]
    grep -qF 'V=$(pwd)' "$FIXTURE"
    grep -qF 'LEN=$(echo -n "$S" | wc -c)' "$FIXTURE"
}

# -- Per-rule end-to-end via stdin (one positive fixture per rule) ---------
#
# These overlap the in-process --self-test by design: this layer proves the
# rules also fire when invoked through the real CLI (env, encoding, argv
# handling). If any of these regress while --self-test still passes, the
# regression is in the CLI plumbing, not the rules.

@test "rule sed-replace-first rewrites literal patterns" {
    assert_rewrite "X=\$(echo \"\$S\" | sed 's/foo/bar/')" 'X=${S/foo/bar}'
}

@test "rule sed-replace-first SKIPS regex metacharacters" {
    # Negative case: regex metachar must leave the input untouched.
    local input="X=\$(echo \"\$S\" | sed 's/.*/x/')"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    # Strip trailing newline from stdin echo for stable comparison.
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule sed-replace-all rewrites global literal patterns" {
    assert_rewrite "X=\$(echo \"\$S\" | sed 's/old/new/g')" 'X=${S//old/new}'
}

@test "rule echo-wc-c rewrites length idiom" {
    assert_rewrite 'LEN=$(echo -n "$S" | wc -c)' 'LEN=${#S}'
}

@test "rule expr-arith-vars rewrites numeric expr" {
    assert_rewrite 'R=$(expr $A + $B)' 'R=$((A + B))'
}

@test "rule expr-arith-vars handles escaped multiplication" {
    assert_rewrite 'R=$(expr $A \* $B)' 'R=$((A * B))'
}

@test "rule expr-arith-literal rewrites VAR + INT" {
    assert_rewrite 'R=$(expr $A + 1)' 'R=$((A + 1))'
}

@test "rule expr-increment rewrites matched-name self-increment" {
    # expr-increment must claim COUNT=$(expr $COUNT + 1) before
    # expr-arith-literal does (which would emit C=$((C + 1))).
    assert_rewrite 'COUNT=$(expr $COUNT + 1)' 'COUNT=$((COUNT + 1))'
}

@test "rule expr-increment SKIPS mismatched names" {
    # different vars on each side — falls through to expr-arith-literal.
    assert_rewrite 'TOTAL=$(expr $A + 1)' 'TOTAL=$((A + 1))'
}

@test "rule cut-c-substring rewrites cut -c1-N to substring" {
    assert_rewrite 'PRE=$(echo "$NAME" | cut -c1-5)' 'PRE=${NAME:0:5}'
}

@test "rule for-range-expansion collapses consecutive integers" {
    assert_rewrite 'for i in 1 2 3 4 5; do echo $i; done' \
                   'for i in {1..5}; do echo $i; done'
}

@test "rule for-range-expansion SKIPS non-consecutive sequences" {
    local input='for i in 1 3 5; do echo $i; done'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule for-range-expansion SKIPS zero-padded literals" {
    local input='for i in 01 02 03; do echo $i; done'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule combined-tests fuses paired single-bracket tests" {
    assert_rewrite 'if [ -f "$F" ] && [ -r "$F" ]; then' \
                   'if [[ -f "$F" && -r "$F" ]]; then'
}

@test "rule combined-tests SKIPS when nested brackets present" {
    local input='[ "${arr[0]}" = "x" ] && [ "$Y" = "y" ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule combined-tests SKIPS when a side has -a/-o" {
    local input='[ -f "$F" -o -r "$F" ] && [ -w "$G" ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule combined-tests SKIPS when a side has an unquoted RHS" {
    local input='[ "$A" = x ] && [ "$B" = "y" ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule combined-tests SKIPS when a side has \\< or \\>" {
    local input='[ "$a" \< "$b" ] && [ -f "$c" ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule combined-tests SKIPS when a side has a quoted \"<\" or \">\"" {
    local input='[ "$a" "<" "$b" ] && [ -f "$c" ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule combined-tests SKIPS when a side has escaped parens" {
    local input='[ \( -f "$F" \) ] && [ -w "$G" ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule test-numeric maps -gt to >" {
    assert_rewrite 'if [ $X -gt 100 ]; then' 'if (( X > 100 )); then'
}

@test "rule test-numeric maps -lt to <" {
    assert_rewrite 'while [ $i -lt 10 ]; do' 'while (( i < 10 )); do'
}

@test "rule test-numeric maps -eq to ==" {
    assert_rewrite '[ $x -eq 5 ]' '(( x == 5 ))'
}

@test "rule test-numeric maps -ne to !=" {
    assert_rewrite '[ $x -ne 5 ]' '(( x != 5 ))'
}

@test "rule test-numeric maps -le to <=" {
    assert_rewrite '[ $x -le 5 ]' '(( x <= 5 ))'
}

@test "rule test-numeric maps -ge to >=" {
    assert_rewrite '[ $x -ge 5 ]' '(( x >= 5 ))'
}

@test "rule test-numeric SKIPS positional parameter operand" {
    local input='[ $1 -eq 0 ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule test-numeric SKIPS left-hand literal" {
    local input='[ 10 -lt $count ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule test-numeric SKIPS array-length expansion" {
    local input='[ ${#a[@]} -eq 3 ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule test-numeric SKIPS octal-looking operand" {
    local input='[ $x -eq 08 ]'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule empty-default collapses if/then/fi guard" {
    assert_rewrite 'if [ -z "$ENV" ]; then ENV="dev"; fi' 'ENV=${ENV:-"dev"}'
}

@test "rule mkdir-guard collapses redundant directory check" {
    assert_rewrite 'if [ ! -d "$DIR" ]; then mkdir -p "$DIR"; fi' \
                   'mkdir -p "${DIR}"'
}

@test "rule mkdir-guard SKIPS when vars don't match" {
    local input='if [ ! -d "$A" ]; then mkdir -p "$B"; fi'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule backticks rewrites to dollar-paren" {
    assert_rewrite 'VER=`git rev-parse HEAD`' 'VER=$(git rev-parse HEAD)'
}

@test "rule legacy-null-check maps x-prefix idiom to -z" {
    assert_rewrite '[ "x$VAR" = "x" ]' '[ -z "$VAR" ]'
}

@test "rule legacy-null-check maps not-equal x-prefix idiom to -n" {
    assert_rewrite '[ "x$VAR" != "x" ]' '[ -n "$VAR" ]'
}

@test "rule empty-string-eq maps explicit empty compare to -z" {
    assert_rewrite '[ "$X" = "" ]' '[ -z "$X" ]'
}

@test "rule find-exec-rm-delete swaps -exec rm for -delete" {
    assert_rewrite 'find /tmp -type f -name "*.bak" -exec rm {} \;' \
                   'find /tmp -type f -name "*.bak" -delete'
}

@test "rule find-exec-rm-delete SKIPS when -type f is absent" {
    local input='find /tmp -name "*.bak" -exec rm {} \;'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule find-exec-rm-delete SKIPS when -prune is present" {
    local input='find . -type f -prune -exec rm {} \;'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule find-exec-rm-delete SKIPS when -type f is negated with !" {
    local input='find . ! -type f -exec rm {} \;'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule find-exec-rm-delete SKIPS when -type f is negated with -not" {
    local input='find . -not -type f -exec rm {} \;'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule find-exec-rm-delete SKIPS when -o/-or is present" {
    local input='find . -type f -o -name "*.tmp" -exec rm {} \;'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule find-exec-rm-delete SKIPS when -type f is negated with \\!" {
    local input='find . \! -type f -exec rm {} \;'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule find-exec-rm-delete SKIPS when -type f is negated with '!'" {
    local input="find . '!' -type f -exec rm {} \;"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test 'rule find-exec-rm-delete SKIPS when -type f is negated with "!"' {
    local input='find . "!" -type f -exec rm {} \;'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule cat-file-pipe-grep drops the useless cat" {
    assert_rewrite 'cat /etc/hosts | grep localhost' 'grep localhost /etc/hosts'
}

@test "rule cat-file-pipe-grep preserves quoted file argument" {
    assert_rewrite 'cat "$LOG" | grep -i error' 'grep -i error "$LOG"'
}

@test "rule cat-file-pipe-grep stops at an unquoted close-paren" {
    assert_rewrite 'X=$(cat f | grep foo)' 'X=$(grep foo f)'
}

@test "rule cat-file-pipe-grep keeps a trailing comment as a comment" {
    assert_rewrite 'cat f | grep foo # note' 'grep foo f # note'
}

@test "rule cat-file-pipe-grep preserves a quoted pipe in the pattern" {
    assert_rewrite 'cat f | grep -E "a|b"' 'grep -E "a|b" f'
}

@test "rule cat-file-pipe-grep SKIPS when followed by an unquoted redirection" {
    local input='cat f | grep foo 2>&1 | wc -l'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule cat-file-pipe-grep rewrites a multi-line single-quoted pattern" {
    local input=$'cat f | grep \'foo\nbar\''
    local expected=$'grep \'foo\nbar\' f'
    assert_rewrite "$input" "$expected"
}

@test "rule cat-file-pipe-grep keeps a trailing comment with an apostrophe as a comment" {
    assert_rewrite "cat f | grep foo # don't touch" "grep foo f # don't touch"
}

@test "rule cat-file-pipe-grep SKIPS on an unquoted backslash before a pipe" {
    local input='cat f | grep foo\|bar'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule cat-file-pipe-grep SKIPS on an unquoted backslash before a paren" {
    local input='cat f | grep foo\)'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

# -- Multi-rule integration -------------------------------------------------
#
# A miniature script exercising several rules at once. Catches regressions
# where rule ordering or partial matches corrupt subsequent passes.

@test "applies multiple rules to the same file in one pass" {
    cat > "$FIXTURE" <<'SH'
#!/usr/bin/env bash
DIR=`pwd`
LEN=$(echo -n "$FILENAME" | wc -c)
if [ -z "$ENV" ]; then ENV="dev"; fi
if [ ! -d "$DIR" ]; then mkdir -p "$DIR"; fi
[ "x$USER" = "x" ] && exit 1
SH
    run python3 "$SCRIPT" --apply "$FIXTURE"
    [ "$status" -eq 0 ]
    grep -qF 'DIR=$(pwd)' "$FIXTURE"
    grep -q 'LEN=${#FILENAME}' "$FIXTURE"
    grep -q 'ENV=${ENV:-"dev"}' "$FIXTURE"
    grep -q 'mkdir -p "${DIR}"' "$FIXTURE"
    grep -qF '[ -z "$USER" ]' "$FIXTURE"
}

# -- Modernize group: opt-in via --include modernize -----------------------

@test "modernize group is OFF by default — sed→sd does not fire without --include" {
    local input="echo \"\$LINE\" | sed 's/foo/bar/g'"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "modernize group ON — sed→sd fires with --include modernize" {
    local got
    got="$(printf 'echo "$LINE" | sed '"'"'s/foo/bar/g'"'"'\n' \
        | python3 "$SCRIPT" --include modernize -)"
    [[ "$got" == *"sd -F 'foo' 'bar' <<< \"\$LINE\""* ]]
}

@test "modernize group ON — grep -F → rg -F fires" {
    local got
    got="$(printf 'grep -F localhost /etc/hosts\n' \
        | python3 "$SCRIPT" --include modernize -)"
    [[ "$got" == *"rg -F localhost /etc/hosts"* ]]
}

@test "modernize group ON — find -name → fd fires" {
    local got
    got="$(printf 'find . -type f -name "*.py"\n' \
        | python3 "$SCRIPT" --include modernize -)"
    [[ "$got" == *'fd -H -t f -g "*.py"'* ]]
}

@test "modernize: plain grep (no -F) is NOT migrated to rg (regex flavors differ)" {
    local input='grep PAT /etc/hosts'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" --include modernize -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "--include rejects unknown group with diagnostic" {
    printf 'echo hi\n' > "$FIXTURE"
    run python3 "$SCRIPT" --include bogus "$FIXTURE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown groups: bogus"* ]]
}

@test "--list shows group tags and group summary" {
    run python3 "$SCRIPT" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"(modernize)"* ]]
    [[ "$output" == *"Groups:"* ]]
    [[ "$output" == *"core ("* ]]
    [[ "$output" == *"modernize ("* ]]
}

# -- ast-grep engine ------------------------------------------------------
#
# `sg` (ast-grep) is a hard requirement. The suite asserts the dispatch
# fires on its sg-handled rules and that the missing-sg path produces a
# friendly diagnostic.

@test "non-sg-handled rules still fire (echo-wc-c via regex path)" {
    local got
    got="$(printf 'LEN=$(echo -n "$S" | wc -c)\n' | python3 "$SCRIPT" -)"
    [[ "$got" == *'LEN=${#S}'* ]]
}

@test "backticks rule rewrites legit command substitution" {
    local got
    got="$(printf 'COUNT=`wc -l < file`\n' | python3 "$SCRIPT" -)"
    [[ "$got" == *'COUNT=$(wc -l < file)'* ]]
}

@test "backticks skips markdown spans in # comments (issue #16)" {
    local input='# Run `bash --help` for help.'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "backticks skips quoted heredoc bodies (issue #16)" {
    local input
    input="$(printf "cat <<'EOF'\nliteral \`backticks\`\nEOF\n")"
    local got
    got="$(printf '%s' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "${input%$'\n'}" ]
}

@test "report includes rule id and count" {
    local err
    err="$(printf 'V=`pwd`\n' \
        | python3 "$SCRIPT" - 2>&1 >/dev/null)"
    # stdin-mode report format is "# applied <rid>: <n>" (see _run_stdin).
    [[ "$err" == *"applied backticks: 1"* ]]
}

@test "missing sg exits with friendly diagnostic" {
    # Run with an empty PATH that excludes sg. Use `env -i` to clear,
    # then add /usr/bin so python3 still resolves.
    local out
    out="$(env -i PATH=/usr/bin:/bin python3 "$SCRIPT" /etc/hosts 2>&1 || true)"
    [[ "$out" == *"requires ast-grep"* ]]
    [[ "$out" == *"bash-shortening"* ]]
}

# -- Real-world regression fixtures ----------------------------------------
# Surfaced by dogfooding the rewriter on ~/Dev/dotfiles. Both issues
# are now fixed by the ast-grep engine: tree-sitter-bash distinguishes
# [[ ]] (conditional_expression) from [ ] (test_command) so the rule
# only matches single-bracket form. The skips on these tests have been
# removed — they're real gates now.

@test "rule test-numeric leaves [[ ... ]] form untouched (issue #18)" {
    local input='if [[ $V -eq 0 ]]; then :; fi'
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [ "${got%$'\n'}" = "$input" ]
}

@test "rule test-numeric rewrites single-bracket [ \$V -OP N ] to ((V OP N)) via sg" {
    local got
    got="$(printf 'if [ $X -gt 100 ]; then echo big; fi\n' | python3 "$SCRIPT" -)"
    [[ "$got" == *"if (( X > 100 )); then"* ]]
}

# -- Opt-out directive (issue #59) -----------------------------------------
# `# bash-shorten: disable` / `enable` and `# bash-shorten: skip` opt regions
# out of EVERY rule, enforced in the engine apply path so it covers both the
# sg pass and the regex pass uniformly.

@test "directive disable/enable leaves the enclosed block verbatim (issue #59)" {
    local input
    input="$(printf '%s\n' \
        'V=`pwd`' \
        '# bash-shorten: disable' \
        'W=`whoami`' \
        '# bash-shorten: enable' \
        'X=`date`')"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    # Chained so every assertion is required (Bats fails only on the last
    # command's status). Outside the span rewritten; inside verbatim.
    [[ "$got" == *'V=$(pwd)'* ]] \
        && [[ "$got" == *'X=$(date)'* ]] \
        && [[ "$got" == *'W=`whoami`'* ]]
}

@test "directive disable protects BOTH sg-handled and regex rules (issue #59)" {
    local input
    input="$(printf '%s\n' \
        '# bash-shorten: disable' \
        'V=`pwd`' \
        'LEN=$(echo -n "$S" | wc -c)' \
        '# bash-shorten: enable')"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    # backticks (sg-handled) and echo-wc-c (regex path) both untouched.
    [[ "$got" == *'V=`pwd`'* ]] \
        && [[ "$got" == *'LEN=$(echo -n "$S" | wc -c)'* ]] \
        && [[ "$got" != *'LEN=${#S}'* ]]
}

@test "directive skip no-ops only the following line (issue #59)" {
    local input
    input="$(printf '%s\n' \
        '# bash-shorten: skip' \
        'W=`whoami`' \
        'X=`date`')"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    # Skipped line untouched; the line after still rewritten. Both required.
    [[ "$got" == *'W=`whoami`'* ]] \
        && [[ "$got" == *'X=$(date)'* ]]
}

@test "no directive present — behavior is unchanged (issue #59 backward-compat)" {
    local got
    got="$(printf 'V=`pwd`\n' | python3 "$SCRIPT" -)"
    [[ "$got" == *'V=$(pwd)'* ]]
}

@test "directive disable without enable protects to EOF (issue #59)" {
    # This is the mechanism the .bats file's own whole-file opt-out relies on.
    local input
    input="$(printf '%s\n' \
        'V=`pwd`' \
        '# bash-shorten: disable' \
        'W=`whoami`' \
        'X=`date`')"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    # First line (before disable) rewritten; everything after stays verbatim.
    [[ "$got" == *'V=$(pwd)'* ]] \
        && [[ "$got" == *'W=`whoami`'* ]] \
        && [[ "$got" == *'X=`date`'* ]]
}

@test "directive with trailing tokens is NOT honoured (issue #59)" {
    # Strict whole-comment match guards against accidental over-protection:
    # '# bash-shorten: disable foo' is an ordinary comment, so the next line
    # is still rewritten.
    local input
    input="$(printf '%s\n' \
        '# bash-shorten: disable foo' \
        'V=`pwd`')"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [[ "$got" == *'V=$(pwd)'* ]]
}

@test "indented directive is honoured (issue #59)" {
    local input
    input="$(printf '%s\n' \
        'if true; then' \
        '    # bash-shorten: disable' \
        '    W=`whoami`' \
        '    # bash-shorten: enable' \
        'fi')"
    local got
    got="$(printf '%s\n' "$input" | python3 "$SCRIPT" -)"
    [[ "$got" == *'W=`whoami`'* ]]
}

@test "--apply leaves a disabled block byte-for-byte unchanged (issue #59)" {
    printf '%s\n' \
        'A=`pwd`' \
        '# bash-shorten: disable' \
        'B=`whoami`' \
        '# bash-shorten: enable' > "$FIXTURE"
    run python3 "$SCRIPT" --apply "$FIXTURE"
    [ "$status" -eq 0 ]
    # Outside the span got written; the protected line kept its backticks.
    grep -qF 'A=$(pwd)' "$FIXTURE" \
        && grep -qF 'B=`whoami`' "$FIXTURE"
}
