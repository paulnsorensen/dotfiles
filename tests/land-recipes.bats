#!/usr/bin/env bats

ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
RECIPES="$ROOT/skills/land/references/gh-recipes.md"

setup() {
    export TEST_TMP="${BATS_TEST_TMPDIR}/land"
    export MOCK_BIN="$TEST_TMP/bin"
    export GH_LOG="$TEST_TMP/gh.log"
    export GH_COUNT="$TEST_TMP/gh-count"
    mkdir -p "$MOCK_BIN"
    : > "$GH_LOG"
    printf '0\n' > "$GH_COUNT"
    cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[[ "$*" == *"--arg"* ]] && exit 98
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
    if [[ "${GH_MODE:-}" == graphql-pagination ]]; then
        printf '%s\n' '{"id":"thread-1"}' '{"id":"thread-2"}'
    elif [[ "${GH_MODE:-}" == graphql-api-error ]]; then
        exit 42
    fi
    exit 0
fi
if [[ "$1" == "api" && "$*" == *"/reviews"* ]]; then
    case "${GH_MODE:-}" in
        review-api-error) exit 42 ;;
        review-success) printf '%s\n' '2026-09-12T00:01:00Z' ;;
        review-summary) ;;
        review-generic) ;;
        review-timeout) ;;
    esac
    exit 0
fi
if [[ "$1" == "api" && "$*" == *"/comments"* ]]; then
    case "${GH_MODE:-}" in
        review-comments-api-error) exit 42 ;;
        review-summary) [[ "$*" == *"Actionable comments posted:"* ]] && printf '%s\n' '2026-09-12T00:01:00Z' ;;
        review-success|review-timeout) ;;
        review-generic) [[ "$*" == *"Actionable comments posted:"* ]] || printf '%s\n' '2026-09-12T00:01:00Z' ;;
    esac
    exit 0
fi
if [[ "$1" == repo && "$2" == view ]]; then
    printf '%s\n' "${GH_ALLOWED_METHOD:-squash}"
    exit 0
fi
if [[ "$1" == pr && "$2" == merge ]]; then
    [[ "${GH_MODE:-}" == merge-failure ]] && exit 23
    exit 0
fi
if [[ "$1" == pr && "$2" == view ]]; then
    [[ "${GH_MODE:-}" == merge-api-error ]] && exit 42
    count="$(<"$GH_COUNT")"
    printf '%s\n' "$((count + 1))" > "$GH_COUNT"
    case "${GH_MODE:-}" in
        merge-success) [[ "$count" -gt 0 ]] && printf '%s\n' 'MERGED CLEAN' || printf '%s\n' 'OPEN CLEAN' ;;
        merge-dirty) printf '%s\n' 'OPEN DIRTY' ;;
        merge-blocked) printf '%s\n' 'OPEN BLOCKED' ;;
        merge-closed) printf '%s\n' 'CLOSED CLEAN' ;;
        merge-timeout) printf '%s\n' 'OPEN CLEAN' ;;
    esac
    exit 0
fi
exit 99
MOCK
    chmod +x "$MOCK_BIN/gh"
    cat > "$MOCK_BIN/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/sleep"
    cat > "$MOCK_BIN/date" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '2026-09-12T00:00:00Z'
MOCK
    chmod +x "$MOCK_BIN/date"
    export PATH="$MOCK_BIN:$PATH"
}

extract_example() {
    local marker="$1"
    awk -v marker="$marker" '
        substr($0, 1, 3) == sprintf("%c%c%c", 96, 96, 96) && substr($0, 4) == "bash" {
            in_block=1
            found=0
            body=""
            next
        }
        in_block && substr($0, 1, 3) == sprintf("%c%c%c", 96, 96, 96) {
            if (found) printf "%s", body
            in_block=0
            next
        }
        in_block {
            if (index($0, marker)) found=1
            body=body $0 "\n"
        }
    ' "$RECIPES"
}

run_example() {
    local marker="$1" mode="$2"
    export GH_MODE="$mode"
    local script
    script="$(extract_example "$marker")"
    script="$(printf '%s\n' "$script" | sed \
        -e 's#<n>#42#g' \
        -e 's#{o}#acme#g' \
        -e 's#{r}#dotfiles#g' \
        -e 's#<sha>#HEADSHA#g')"
    eval "$script"
}

@test "review poll accepts a newer bot review" {
    export REQUESTED_AT="2026-09-12T00:00:00Z"
    run run_example "# TEST: review-completion-poll" review-success
    [ "$status" -eq 0 ]
    [[ "$output" == *"completed"* ]]
}

@test "pending review initializes its timestamp before polling" {
    unset REQUESTED_AT
    run run_example "# TEST: review-completion-poll" review-success
    [ "$status" -eq 0 ]
    [[ "$output" == *"completed"* ]]
}

@test "review poll accepts a newer actionable summary comment" {
    export REQUESTED_AT="2026-09-12T00:00:00Z"
    run run_example "# TEST: review-completion-poll" review-summary
    [ "$status" -eq 0 ]
    [[ "$output" == *"completed"* ]]
}

@test "review poll rejects a generic bot acknowledgement" {
    export REQUESTED_AT="2026-09-12T00:00:00Z"
    run run_example "# TEST: review-completion-poll" review-generic
    [ "$status" -eq 1 ]
    [[ "$output" == *"timed out"* ]]
    [ "$(awk 'END { print NR }' "$GH_LOG")" -eq 80 ]
}

@test "review poll fails on API errors" {
    export REQUESTED_AT="2026-09-12T00:00:00Z"
    run run_example "# TEST: review-completion-poll" review-api-error
    [ "$status" -eq 1 ]
    [[ "$output" == *"API error"* ]]
}

@test "review poll times out after 40 polls" {
    export REQUESTED_AT="2026-09-12T00:00:00Z"
    run run_example "# TEST: review-completion-poll" review-timeout
    [ "$status" -eq 1 ]
    [[ "$output" == *"review timed out"* ]]
    [ "$(awk 'END { print NR }' "$GH_LOG")" -eq 80 ]
}

@test "review thread query paginates after the first page" {
    run run_example "# TEST: review-thread-pagination" graphql-pagination
    [ "$status" -eq 0 ]
    [[ "$output" == *'thread-1'* ]]
    [[ "$output" == *'thread-2'* ]]
    grep -Fq -- '--paginate' "$GH_LOG"
    grep -Fq "after:\$endCursor" "$GH_LOG"
    grep -Fq "query(\$o:String!,\$r:String!,\$n:Int!,\$endCursor:String)" "$RECIPES"
    grep -Fq 'pageInfo{ hasNextPage endCursor }' "$RECIPES"
    grep -Fq 'hasNextPage' "$RECIPES"
    grep -Fq 'endCursor' "$RECIPES"
    grep -Fq -- '-f o={o} -f r={r} -F n=<n>' "$RECIPES"
}

@test "review thread pagination fails on API errors" {
    run run_example "# TEST: review-thread-pagination" graphql-api-error
    [ "$status" -eq 1 ]
    [[ "$output" == *"API error"* ]]
}

@test "merge command selects an allowed fallback before no-merge stop" {
    export HEAD_SHA=HEADSHA NO_MERGE=true GH_ALLOWED_METHOD=merge
    run run_example "# TEST: merge-command" merge-noop
    [ "$status" -eq 0 ]
    [[ "$output" == *"--merge"* ]]
    [[ "$output" == *"--match-head-commit HEADSHA"* ]]
    grep -Fq 'Set NO_MERGE=true for --no-merge.' "$RECIPES"
    grep -Fq 'Set USE_AUTO=true for protected branches or merge queues.' "$RECIPES"
    ! grep -Fq 'pr merge' "$GH_LOG"
}

@test "merge command accepts each supported method" {
    local method
    for method in squash merge rebase; do
        export HEAD_SHA=HEADSHA NO_MERGE=true GH_ALLOWED_METHOD="$method"
        run run_example "# TEST: merge-command" merge-noop
        [ "$status" -eq 0 ]
        [[ "$output" == *"--$method"* ]]
    done
}

@test "merge command failure returns failure" {
    export HEAD_SHA=HEADSHA NO_MERGE=false GH_ALLOWED_METHOD=squash
    run run_example "# TEST: merge-command" merge-failure
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge command failed"* ]]
}

@test "merge watcher reports MERGED success" {
    run run_example "# TEST: merge-watcher" merge-success
    [ "$status" -eq 0 ]
    [[ "$output" == *"MERGED"* ]]
}

@test "merge watcher rejects DIRTY" {
    run run_example "# TEST: merge-watcher" merge-dirty
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts detected; route to /melt"* ]]
    [ "$(awk 'END { print NR }' "$GH_LOG")" -eq 1 ]
}

@test "merge watcher rejects BLOCKED" {
    run run_example "# TEST: merge-watcher" merge-blocked
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge blocked by a requirement"* ]]
    [ "$(awk 'END { print NR }' "$GH_LOG")" -eq 1 ]
}

@test "merge watcher rejects CLOSED" {
    run run_example "# TEST: merge-watcher" merge-closed
    [ "$status" -eq 1 ]
    [[ "$output" == *"pull request closed"* ]]
    [ "$(awk 'END { print NR }' "$GH_LOG")" -eq 1 ]
}

@test "merge watcher fails on API errors" {
    run run_example "# TEST: merge-watcher" merge-api-error
    [ "$status" -eq 1 ]
    [[ "$output" == *"API error while polling merge state"* ]]
    [ "$(awk 'END { print NR }' "$GH_LOG")" -eq 1 ]
}

@test "merge watcher times out after 60 polls" {
    run run_example "# TEST: merge-watcher" merge-timeout
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge timed out"* ]]
    [ "$(awk 'END { print NR }' "$GH_LOG")" -eq 60 ]
}
