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
if [[ "$1" == api && "$2" == graphql ]]; then
    if [[ "$*" == *reviewThreads* ]]; then
        [[ "${GH_MODE:-}" == graphql-api-error ]] && exit 42
        printf '%s\n' '{"id":"thread-1"}' '{"id":"thread-2"}'
        exit 0
    fi
    [[ "${GH_MODE:-}" == merge-api-error ]] && exit 42
    count="$(<"$GH_COUNT")"
    printf '%s\n' "$((count + 1))" > "$GH_COUNT"
    case "${GH_MODE:-}" in
        merge-success) ((count)) && printf '%s\n' 'MERGED|2026-09-12T00:01:00Z|MERGESHA|main|HEADSHA|CLEAN|disabled|-|-' || printf '%s\n' 'OPEN|-|-|main|HEADSHA|CLEAN|enabled|-|-' ;;
        merge-queued-success) ((count)) && printf '%s\n' 'MERGED|2026-09-12T00:01:00Z|MERGESHA|main|HEADSHA|CLEAN|disabled|-|-' || printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|QSHA' ;;
        merge-dirty) printf '%s\n' 'OPEN|-|-|main|HEADSHA|DIRTY|enabled|-|-' ;;
        merge-blocked) printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|-|-' ;;
        merge-queue-failed|merge-queue-page2|merge-queue-api-error) printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|QSHA' ;;
        merge-queue-no-head) printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|-' ;;
        merge-queue-late-head) ((count >= 2)) && printf '%s\n' 'MERGED|2026-09-12T00:01:00Z|MERGESHA|main|HEADSHA|CLEAN|disabled|-|-' || { ((count)) && printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|QSHA' || printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|-'; } ;;
        merge-queue-new-entry) ((count >= 2)) && printf '%s\n' 'MERGED|2026-09-12T00:01:00Z|MERGESHA|main|HEADSHA|CLEAN|disabled|-|-' || { ((count)) && printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|NEXT|-' || printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|QSHA'; } ;;
        merge-queue-head-gap) ((count >= 2)) && printf '%s\n' 'MERGED|2026-09-12T00:01:00Z|MERGESHA|main|HEADSHA|CLEAN|disabled|-|-' || { ((count)) && printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|-' || printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|QSHA'; } ;;
        merge-queue-disappeared-no-head) ((count)) && printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|disabled|-|-' || printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|-' ;;
        merge-queue-disappeared) ((count)) && printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|disabled|-|-' || printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|enabled|QUEUE|QSHA' ;;
        merge-auto-disabled) printf '%s\n' 'OPEN|-|-|main|HEADSHA|BLOCKED|disabled|-|-' ;;
        merge-head-drift) printf '%s\n' 'OPEN|-|-|main|NEWSHA|CLEAN|enabled|-|-' ;;
        merge-wrong-base) printf '%s\n' 'OPEN|-|-|release|HEADSHA|CLEAN|enabled|-|-' ;;
        merge-closed) printf '%s\n' 'CLOSED|-|-|main|HEADSHA|CLEAN|disabled|-|-' ;;
        merge-malformed) printf '%s\n' '' ;;
        merge-incomplete) printf '%s\n' 'MERGED|-|-|main|HEADSHA|CLEAN|disabled|-|-' ;;
        merge-timeout) printf '%s\n' 'OPEN|-|-|main|HEADSHA|CLEAN|enabled|-|-' ;;
    esac
    exit 0
fi
if [[ "$1" == api && "$*" == *"/reviews"* ]]; then
    [[ "${GH_MODE:-}" == review-api-error || "${GH_MODE:-}" == inventory-review-error ]] && exit 42
    case "${GH_MODE:-}" in
        review-success) printf '%s\n' '2026-09-12T00:01:00Z HEADSHA' ;;
        review-wrong-sha) printf '%s\n' '2026-09-12T00:01:00Z OLDSHA' ;;
        inventory-success) printf '%s\n' '{"id":2,"login":"other[bot]","body":"finding"}' ;;
    esac
    exit 0
fi
if [[ "$1" == api && "$*" == *"/issues/"* && "$*" == *"/comments"* ]]; then
    [[ "${GH_MODE:-}" == inventory-issue-error ]] && exit 42
    [[ "${GH_MODE:-}" == inventory-success ]] && printf '%s\n' '{"id":1,"login":"app","body":"finding"}'
    exit 0
fi
if [[ "$1" == api && "$*" == *"/check-runs"* ]]; then
    [[ "${GH_MODE:-}" == merge-queue-api-error ]] && exit 42
    case "${GH_MODE:-}" in
        merge-queue-failed) printf '123\n' ;;
        merge-queue-page2) [[ "$*" == *--paginate* ]] && printf '\n777\n' ;;
    esac
    exit 0
fi
if [[ "$1" == api && "$*" == *"/compare/"* ]]; then
    [[ "${GH_MODE:-}" == main-api-error ]] && exit 42
    printf '%s\n' "${GH_COMPARE_STATUS:-ahead}"
    exit 0
fi
if [[ "$1" == pr && "$2" == comment ]]; then
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
[[ "$1" == +%s ]] && printf '1000\n' || printf '2026-09-12T00:00:00Z\n'
MOCK
    chmod +x "$MOCK_BIN/date"
    export PATH="$MOCK_BIN:$PATH"
    export HEAD_SHA=HEADSHA WATCH_DEADLINE=2800
    unset SAVED_QUEUE_ID SAVED_QUEUE_HEAD GH_COMPARE_STATUS
}

extract_example() {
    local marker="$1"
    awk -v marker="$marker" '
        substr($0, 1, 3) == sprintf("%c%c%c", 96, 96, 96) && substr($0, 4) == "bash" {
            in_block=1; found=0; body=""; next
        }
        in_block && substr($0, 1, 3) == sprintf("%c%c%c", 96, 96, 96) {
            if (found) printf "%s", body
            in_block=0; next
        }
        in_block {
            if (index($0, marker)) found=1
            body=body $0 "\n"
        }
    ' "$RECIPES"
}

run_example() {
    local marker="$1" mode="$2" script
    export GH_MODE="$mode"
    script="$(extract_example "$marker")"
    script="$(printf '%s\n' "$script" | sed \
        -e 's#<n>#42#g' \
        -e 's#{o}#acme#g' \
        -e 's#{r}#dotfiles#g' \
        -e 's#<sha>#HEADSHA#g')"
    eval "$script"
}

@test "inventory requests all bot issue comments and reviews without truncation" {
    run run_example "# TEST: all-bot-inventory" inventory-success
    [ "$status" -eq 0 ]
    [[ "$output" == *'"id":1'* && "$output" == *'"id":2'* ]]
    grep -Fq '.user.type=="Bot"' "$GH_LOG"
    grep -Fq 'endswith("[bot]")' "$GH_LOG"
    ! grep -Eq '\[0:[0-9]+\]' "$GH_LOG"
    [ "$(awk 'END {print NR}' "$GH_LOG")" -eq 2 ]
}

@test "inventory fails closed on either API error" {
    run run_example "# TEST: all-bot-inventory" inventory-issue-error
    [ "$status" -eq 1 ]
    [[ "$output" == *'issue comments'* ]]
    [ "$(awk 'END {print NR}' "$GH_LOG")" -eq 1 ]
    run run_example "# TEST: all-bot-inventory" inventory-review-error
    [ "$status" -eq 1 ]
    [[ "$output" == *'fetching reviews'* ]]
}

@test "review poll requires newer review on validated SHA" {
    export REQUESTED_AT=2026-09-12T00:00:00Z
    run run_example "# TEST: review-completion-poll" review-success
    [ "$status" -eq 0 ]
    [[ "$output" == *'validated head'* ]]
}

@test "review poll initializes request time" {
    unset REQUESTED_AT
    run run_example "# TEST: review-completion-poll" review-success
    [ "$status" -eq 0 ]
}

@test "review poll rejects another SHA and summary-only signal" {
    export REQUESTED_AT=2026-09-12T00:00:00Z
    run run_example "# TEST: review-completion-poll" review-wrong-sha
    [ "$status" -eq 1 ]
    [[ "$output" == *'another SHA'* ]]
    [ "$(awk 'END {print NR}' "$GH_LOG")" -eq 40 ]
    run run_example "# TEST: review-completion-poll" review-summary
    [ "$status" -eq 1 ]
    [[ "$output" == *'timed out'* ]]
}

@test "review poll bounds API error and timeout" {
    run run_example "# TEST: review-completion-poll" review-api-error
    [ "$status" -eq 1 ]
    [[ "$output" == *'API error'* ]]
    run run_example "# TEST: review-completion-poll" review-timeout
    [ "$status" -eq 1 ]
    [[ "$output" == *'timed out'* ]]
}

@test "review threads paginate without first-comment author filter" {
    run run_example "# TEST: review-thread-pagination" graphql-pagination
    [ "$status" -eq 0 ]
    [[ "$output" == *'thread-1'* && "$output" == *'thread-2'* ]]
    grep -Fq -- '--paginate' "$GH_LOG"
    grep -Fq "after:\$endCursor" "$GH_LOG"
    ! grep -Fq 'select(.comments.nodes[]?.author' "$GH_LOG"
    grep -Fq 'comments(first:100)' "$RECIPES"
    grep -Fq 'pageInfo{ hasNextPage endCursor }' "$RECIPES"
}

@test "review thread pagination fails on API error" {
    run run_example "# TEST: review-thread-pagination" graphql-api-error
    [ "$status" -eq 1 ]
    [[ "$output" == *'API error'* ]]
}

@test "merge command selects allowed method and no-merge avoids merge" {
    export NO_MERGE=true GH_ALLOWED_METHOD=merge
    run run_example "# TEST: merge-command" merge-noop
    [ "$status" -eq 0 ]
    [[ "$output" == *'ready; not merged'* && "$output" == *'--merge'* ]]
    [[ "$output" == *'--match-head-commit HEADSHA'* ]]
    ! grep -Fq 'pr merge' "$GH_LOG"
}

@test "merge command supports all methods and fails closed" {
    local method
    for method in squash merge rebase; do
        export NO_MERGE=true GH_ALLOWED_METHOD="$method"
        run run_example "# TEST: merge-command" merge-noop
        [ "$status" -eq 0 ]
        [[ "$output" == *"--$method"* ]]
    done
    export NO_MERGE=false
    run run_example "# TEST: merge-command" merge-failure
    [ "$status" -eq 1 ]
    [[ "$output" == *'merge command failed'* ]]
}

@test "watcher reports readiness only with merge metadata" {
    run run_example "# TEST: merge-watcher" merge-success
    [ "$status" -eq 0 ]
    [[ "$output" == *'ready-for-main-verification:MERGESHA'* ]]
    run run_example "# TEST: merge-watcher" merge-incomplete
    [ "$status" -eq 1 ]
    [[ "$output" == *'metadata incomplete'* ]]
}

@test "watcher waits through pending BLOCKED and active queue" {
    run run_example "# TEST: merge-watcher" merge-blocked
    [ "$status" -eq 1 ]
    [[ "$output" == *'merge timed out'* ]]
    [ "$(awk 'END {print NR}' "$GH_LOG")" -eq 60 ]
    printf '0\n' > "$GH_COUNT"
    run run_example "# TEST: merge-watcher" merge-queued-success
    [ "$status" -eq 0 ]
    [[ "$output" == *'ready-for-main-verification'* ]]
    grep -Fq '/commits/QSHA/check-runs' "$GH_LOG"
}

@test "watcher diagnoses queue failure and disappearance" {
    run run_example "# TEST: merge-watcher" merge-queue-failed
    [ "$status" -eq 2 ]
    [[ "$output" == *'merge-group checks failed on QSHA'* ]]
    printf '0\n' > "$GH_COUNT"
    run run_example "# TEST: merge-watcher" merge-queue-disappeared
    [ "$status" -eq 2 ]
    [[ "$output" == *'queue entry disappeared from QSHA'* ]]
}

@test "watcher waits when queue head is temporarily unavailable" {
    run run_example "# TEST: merge-watcher" merge-queue-no-head
    [ "$status" -eq 1 ]
    [[ "$output" == *'merge timed out'* ]]
    ! grep -Fq '/commits/-/check-runs' "$GH_LOG"
    printf '0\n' > "$GH_COUNT"
    run run_example "# TEST: merge-watcher" merge-queue-late-head
    [ "$status" -eq 0 ]
    grep -Fq '/commits/QSHA/check-runs' "$GH_LOG"
}

@test "watcher reuses known head only for the same queue entry" {
    run run_example "# TEST: merge-watcher" merge-queue-head-gap
    [ "$status" -eq 0 ]
    [ "$(grep -Fc '/commits/QSHA/check-runs' "$GH_LOG")" -eq 2 ]
}

@test "watcher does not reuse a saved head for a different queue entry" {
    run run_example "# TEST: merge-watcher" merge-queue-new-entry
    [ "$status" -eq 0 ]
    [ "$(grep -Fc '/commits/QSHA/check-runs' "$GH_LOG")" -eq 1 ]
    ! grep -Fq '/commits/-/check-runs' "$GH_LOG"
}

@test "watcher detects disappearance after queue entry without head" {
    run run_example "# TEST: merge-watcher" merge-queue-disappeared-no-head
    [ "$status" -eq 2 ]
    [[ "$output" == *'queue entry disappeared from QUEUE'* ]]
}

@test "watcher catches check failure on a later API page" {
    run run_example "# TEST: merge-watcher" merge-queue-page2
    [ "$status" -eq 2 ]
    [[ "$output" == *'merge-group checks failed on QSHA'* ]]
    grep -Fq -- '--paginate' "$GH_LOG"
}

@test "watcher reports auto-disabled, head drift, and conflicts for recovery" {
    local mode reason
    for mode in merge-auto-disabled merge-head-drift merge-dirty; do
        case "$mode" in
            merge-auto-disabled) reason='auto-merge disabled' ;;
            merge-head-drift) reason='head changed' ;;
            merge-dirty) reason='merge conflicts' ;;
        esac
        run run_example "# TEST: merge-watcher" "$mode"
        [ "$status" -eq 2 ]
        [[ "$output" == *"recover:$reason"* ]]
    done
}

@test "watcher halts on wrong base, closed PR, malformed data, and API error" {
    local mode reason
    for mode in merge-wrong-base merge-closed merge-malformed merge-api-error; do
        case "$mode" in
            merge-wrong-base) reason='base changed' ;;
            merge-closed) reason='closed without merge' ;;
            merge-malformed) reason='malformed PR snapshot' ;;
            merge-api-error) reason='API error' ;;
        esac
        run run_example "# TEST: merge-watcher" "$mode"
        [ "$status" -eq 1 ]
        [[ "$output" == *"$reason"* ]]
    done
}

@test "watcher honors existing deadline" {
    export WATCH_DEADLINE=999
    run run_example "# TEST: merge-watcher" merge-timeout
    [ "$status" -eq 1 ]
    [[ "$output" == *'merge timed out'* ]]
    [ "$(awk 'END {print NR}' "$GH_LOG")" -eq 0 ]
}

@test "main ancestry accepts identical and ahead, not divergent or behind" {
    export MERGE_SHA=MERGESHA
    local relation
    for relation in identical ahead; do
        export GH_COMPARE_STATUS="$relation"
        run run_example "# TEST: main-ancestry" main-compare
        [ "$status" -eq 0 ]
        [[ "$output" == *'merged into main'* ]]
    done
    for relation in diverged behind; do
        export GH_COMPARE_STATUS="$relation"
        run run_example "# TEST: main-ancestry" main-compare
        [ "$status" -eq 1 ]
        [[ "$output" == *'not in main'* ]]
    done
    grep -Fq '/compare/MERGESHA...main' "$GH_LOG"
}

@test "main ancestry fails on API error" {
    export MERGE_SHA=MERGESHA
    run run_example "# TEST: main-ancestry" main-api-error
    [ "$status" -eq 1 ]
    [[ "$output" == *'API error'* ]]
}

@test "top-level bot findings get a linked signed PR reply" {
    export SOURCE_URL=https://example.test/findings/7 RESPONSE='Fixed in HEADSHA' RESPOND_GH_HANDLE=paul
    run run_example "# TEST: top-level-reply" reply-success
    [ "$status" -eq 0 ]
    grep -Fq 'Regarding https://example.test/findings/7: Fixed in HEADSHA.' "$GH_LOG"
    grep -Fq 'agent on behalf of paul' "$GH_LOG"
}

@test "top-level reply rejects missing source link" {
    unset SOURCE_URL
    export RESPONSE='Not applied' RESPOND_GH_HANDLE=paul
    run run_example "# TEST: top-level-reply" reply-success
    [ "$status" -ne 0 ]
    ! grep -Fq 'pr comment' "$GH_LOG"
}

@test "watcher fails on merge-group API error and missing head" {
    run run_example "# TEST: merge-watcher" merge-queue-api-error
    [ "$status" -eq 1 ]
    [[ "$output" == *'API error while checking merge group'* ]]
    unset HEAD_SHA
    run run_example "# TEST: merge-watcher" merge-success
    [ "$status" -ne 0 ]
    [[ "$output" == *'set validated head SHA'* ]]
}

@test "watcher refuses a missing original deadline" {
    unset WATCH_DEADLINE
    run run_example "# TEST: merge-watcher" merge-success
    [ "$status" -ne 0 ]
    [[ "$output" == *'set original watch deadline'* ]]
    [ "$(awk 'END {print NR}' "$GH_LOG")" -eq 0 ]
}
