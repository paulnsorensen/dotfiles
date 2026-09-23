#!/usr/bin/env bats
# Tests for bin/gh-bootstrap and bin/lib/gh-bootstrap.sh.
# A mock gh logs each call and answers the ruleset lookup from $RULESET_ID.

load test_helper

setup() {
    setup_test_env
    mkdir -p "$TEST_HOME/bin" "$TEST_HOME/repo"
    export GH_LOG="$TEST_HOME/gh.log"
    cat >"$TEST_HOME/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$*" in
    "repo view"*) echo "acme/widget" ;;
    "api repos/acme/widget/rulesets --jq"*) [[ -n "${RULESET_ID:-}" ]] && echo "$RULESET_ID" ;;
    "api repos/acme/widget --jq .default_branch") echo main ;;
    "api repos/acme/widget/commits/main --jq .sha") echo abc123 ;;
    "api repos/acme/widget/commits/abc123/check-runs"*) printf 'test\nlint\ntest\n' ;;
    "api repos/acme/widget --jq"*) echo '{"squash":true}' ;;
esac
exit 0
MOCK
    chmod +x "$TEST_HOME/bin/gh"
    export PATH="$TEST_HOME/bin:$PATH"
    # shellcheck source=bin/lib/gh-bootstrap.sh
    source "$REAL_DOTFILES_DIR/bin/lib/gh-bootstrap.sh"
}

teardown() {
    teardown_test_env
}

@test "render_ruleset: one context per check, squash only, no queue by default" {
    run ghb_render_ruleset 0 0 test lint
    assert_success
    [[ "$(jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context]' <<<"$output")" == '["test","lint"]' ]]
    [[ "$(jq -c '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods' <<<"$output")" == '["squash"]' ]]
    [[ "$(jq '[.rules[] | select(.type=="merge_queue")] | length' <<<"$output")" == 0 ]]
    [[ "$(jq '.rules[] | select(.type=="pull_request") | .parameters.required_review_thread_resolution' <<<"$output")" == false ]]
}

@test "render_ruleset: --queue adds a squash merge queue and reviews tighten PR rules" {
    run ghb_render_ruleset 1 1 ci
    assert_success
    [[ "$(jq -r '.rules[] | select(.type=="merge_queue") | .parameters.merge_method' <<<"$output")" == SQUASH ]]
    [[ "$(jq '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' <<<"$output")" == 1 ]]
    [[ "$(jq '.rules[] | select(.type=="pull_request") | .parameters.dismiss_stale_reviews_on_push' <<<"$output")" == true ]]
}

@test "render_ruleset: rejects no checks and a non-integer review count" {
    run ghb_render_ruleset 0 0
    assert_failure
    run ghb_render_ruleset abc 0 ci
    assert_failure
}

@test "upsert_ruleset: POSTs when no ruleset has the name" {
    echo '{}' >"$TEST_HOME/r.json"
    run ghb_upsert_ruleset acme/widget "$TEST_HOME/r.json"
    assert_success
    assert_output_contains "created"
    grep -q '^api -X POST repos/acme/widget/rulesets --input' "$GH_LOG"
}

@test "upsert_ruleset: PUTs to the existing id instead of duplicating" {
    echo '{}' >"$TEST_HOME/r.json"
    RULESET_ID=42 run ghb_upsert_ruleset acme/widget "$TEST_HOME/r.json"
    assert_success
    assert_output_contains "updated 42"
    grep -q '^api -X PUT repos/acme/widget/rulesets/42 --input' "$GH_LOG"
    run grep -q -- '-X POST' "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "scaffold: creates, then reports unchanged, then refuses to clobber an edit" {
    cd "$TEST_HOME/repo"
    run ghb_scaffold .github/release.yml ghb_render_release_notes
    assert_success
    assert_output_contains "created"
    run ghb_scaffold .github/release.yml ghb_render_release_notes
    assert_success
    assert_output_contains "unchanged"
    echo "# local edit" >>.github/release.yml
    run ghb_scaffold .github/release.yml ghb_render_release_notes
    [ "$status" -eq 2 ]
    assert_output_contains "differs"
    tail -n1 .github/release.yml | grep -q "local edit"
}

@test "scaffold templates are valid YAML" {
    ghb_render_release_notes | yq -e '.changelog.categories[-1].labels[0] == "*"' >/dev/null
    ghb_render_release_workflow | yq -e '.on.push.tags[0] == "v[0-9]*"' >/dev/null
}

@test "cli: without --check, applies merge defaults and lists check names" {
    cd "$TEST_HOME/repo"
    run "$REAL_DOTFILES_DIR/bin/gh-bootstrap"
    assert_success
    assert_output_contains "skipped: pass --check NAME"
    assert_output_contains "  lint"
    grep -q '^api -X PATCH repos/acme/widget -F allow_squash_merge=true' "$GH_LOG"
    run grep -q 'rulesets --input' "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "cli: --dry-run changes nothing" {
    run "$REAL_DOTFILES_DIR/bin/gh-bootstrap" --repo acme/widget --check ci --dry-run
    assert_success
    assert_output_contains '"context": "ci"'
    run grep -q -- '-X ' "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "cli: rejects an unknown flag" {
    run "$REAL_DOTFILES_DIR/bin/gh-bootstrap" --bogus
    assert_failure
    assert_output_contains "unknown argument"
}
