#!/usr/bin/env bats
# Tests for dep-harvest-scan

load test_helper

setup() {
    setup_test_env
    export REAL_BIN="$REAL_DOTFILES_DIR/bin"

    # Mock gh so PR listing is deterministic. `gh pr list --repo <r> ...`
    # reads a `<repo>=<json array>` db file; a repo missing from the db
    # simulates a gh failure (unreachable repo).
    MOCK_BIN="$TEST_HOME/mockbin"
    mkdir -p "$MOCK_BIN"
    export MOCK_GH_DB="$TEST_HOME/gh-pr-db"
    : > "$MOCK_GH_DB"

    cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# mock: gh pr list --repo <owner/name> --state open --limit 100 --json ...
[[ "$1" == "pr" && "$2" == "list" ]] || exit 1
repo=""
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == "--repo" ]]; then
        j=$((i + 1))
        repo="${!j}"
    fi
done
line=$(grep -F "${repo}=" "$MOCK_GH_DB" || true)
[[ -n "$line" ]] || exit 1
value="${line#*=}"
# A "STDERR:<text>" value simulates a gh failure that writes <text> to
# stderr, so the scanner's failure classification can be exercised.
if [[ "$value" == STDERR:* ]]; then
    printf '%s\n' "${value#STDERR:}" >&2
    exit 1
fi
printf '%s\n' "$value"
EOF
    chmod +x "$MOCK_BIN/gh"
    export PATH="$MOCK_BIN:$PATH"

    FIXTURE="$TEST_HOME/sources.yaml"
}

teardown() {
    teardown_test_env
}

# Registers a repo's PR list in the mock gh db as one JSON-array line.
mock_prs() {
    local repo="$1" json="$2"
    printf '%s=%s\n' "$repo" "$json" >> "$MOCK_GH_DB"
}

single_repo_fixture() {
    cat > "$FIXTURE" <<EOF
sources:
  - name: repo
    owner: owner
    clone: https://example.com/owner/repo
    category: test
EOF
}

# --- Errors ---

@test "dep-harvest-scan: exits 1 when sources file is missing" {
    run "$REAL_BIN/dep-harvest-scan" "$TEST_HOME/nope.yaml"
    assert_failure
    assert_output_contains "sources file not found"
}

@test "dep-harvest-scan: exits 1 when yq is not Mike Farah's Go yq" {
    cat > "$MOCK_BIN/yq" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "yq (https://github.com/kislyuk/yq/) 3.2.3"; exit 0; }
exit 1
EOF
    chmod +x "$MOCK_BIN/yq"
    single_repo_fixture
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_failure
    assert_output_contains "mikefarah"
}

@test "dep-harvest-scan: exits 1 when gh is absent" {
    NOGH_BIN="$TEST_HOME/nogh-bin"
    mkdir -p "$NOGH_BIN"
    for t in bash yq grep jq; do ln -s "$(command -v "$t")" "$NOGH_BIN/$t"; done
    single_repo_fixture
    saved_path="$PATH"
    PATH="$NOGH_BIN"
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    PATH="$saved_path"
    assert_failure
    assert_output_contains "gh binary not found"
}

@test "dep-harvest-scan: exits 1 when jq is absent" {
    NOJQ_BIN="$TEST_HOME/nojq-bin"
    mkdir -p "$NOJQ_BIN"
    for t in bash yq grep; do ln -s "$(command -v "$t")" "$NOJQ_BIN/$t"; done
    ln -s "$MOCK_BIN/gh" "$NOJQ_BIN/gh"
    single_repo_fixture
    saved_path="$PATH"
    PATH="$NOJQ_BIN"
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    PATH="$saved_path"
    assert_failure
    assert_output_contains "jq binary not found"
}

# --- Title parsing + bump classification ---

@test "dep-harvest-scan: parses Dependabot title and classifies patch bump" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump lodash from 4.17.20 to 4.17.21","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].package')" == "lodash" ]]
    [[ "$(echo "$output" | jq -r '.[0].from_version')" == "4.17.20" ]]
    [[ "$(echo "$output" | jq -r '.[0].to_version')" == "4.17.21" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "patch" ]]
}

@test "dep-harvest-scan: parses the build(deps) bump title variant" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"build(deps): bump lodash from 4.17.20 to 4.17.21","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].package')" == "lodash" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "patch" ]]
}

@test "dep-harvest-scan: parses a Renovate range-form title with only the target version, classifies unknown" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":2,"title":"chore(deps): update dependency x to v2.0.0","url":"https://x/2","author":{"login":"app/renovate"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].package')" == "x" ]]
    [[ "$(echo "$output" | jq '.[0].from_version')" == "null" ]]
    [[ "$(echo "$output" | jq -r '.[0].to_version')" == "2.0.0" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "unknown" ]]
}

@test "dep-harvest-scan: classifies a minor bump" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.2.0 to 1.3.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "minor" ]]
}

@test "dep-harvest-scan: classifies a major bump" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.2.0 to 2.0.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "major" ]]
}

@test "dep-harvest-scan: classifies an unparseable title as unknown with null package and versions" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Totally unparseable title","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq '.[0].package')" == "null" ]]
    [[ "$(echo "$output" | jq '.[0].from_version')" == "null" ]]
    [[ "$(echo "$output" | jq '.[0].to_version')" == "null" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "unknown" ]]
}

@test "dep-harvest-scan: classifies a downgrade as unknown" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 2.0.0 to 1.5.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "unknown" ]]
}

# --- CI rollup precedence ---

@test "dep-harvest-scan: a red rollup entry beats a pending entry" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"PENDING"},{"state":"FAILURE"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "red" ]]
}

@test "dep-harvest-scan: a pending rollup entry beats an all-green rollup" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"},{"state":"PENDING"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "pending" ]]
}

@test "dep-harvest-scan: an all-green rollup classifies as green" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"},{"state":"SKIPPED"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "green" ]]
}

@test "dep-harvest-scan: an empty rollup classifies as none" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "none" ]]
}

# --- Verdicts ---

@test "dep-harvest-scan: patch + green CI + mergeable + not-draft verdicts auto-merge" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "auto-merge" ]]
}

@test "dep-harvest-scan: patch bump with red CI verdicts repair-candidate" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"FAILURE"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "repair-candidate" ]]
}

@test "dep-harvest-scan: patch bump with a conflicting mergeable state verdicts repair-candidate" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"CONFLICTING","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "repair-candidate" ]]
}

@test "dep-harvest-scan: a major bump with green CI still verdicts hold" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 2.0.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: a draft PR with green CI verdicts hold" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":true,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: pending CI verdicts hold" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"PENDING"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

# --- Author filtering ---

@test "dep-harvest-scan: excludes non-bot-authored PRs" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":2,"title":"A human PR","url":"https://x/2","author":{"login":"paulnsorensen"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq 'length')" == "1" ]]
    [[ "$(echo "$output" | jq -r '.[0].number')" == "1" ]]
}

# --- Page-limit truncation ---

@test "dep-harvest-scan: warns on stderr when a repo fills the whole PR page" {
    single_repo_fixture
    full_page=$(jq -nc '[range(1;101) | {number: ., title: "Bump foo from 1.0.0 to 1.0.1",
        url: "https://x/\(.)", author: {login: "dependabot[bot]"},
        isDraft: false, mergeable: "MERGEABLE", statusCheckRollup: []}]')
    mock_prs "owner/repo" "$full_page"
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    assert_output_contains "were NOT scanned"
}

@test "dep-harvest-scan: does not warn about truncation on a partial PR page" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$output" != *"were NOT scanned"* ]]
}

# --- Unreachable repos ---

@test "dep-harvest-scan: a repo whose gh call fails emits an unreachable status and the scan continues" {
    cat > "$FIXTURE" <<EOF
sources:
  - name: bad
    owner: owner
    clone: https://example.com/owner/bad
    category: test
  - name: repo
    owner: owner
    clone: https://example.com/owner/repo
    category: test
EOF
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq 'length')" == "2" ]]
    [[ "$(echo "$output" | jq -r '.[] | select(.repo=="owner/bad").status')" == "unreachable" ]]
    [[ "$(echo "$output" | jq -r '.[] | select(.repo=="owner/repo").number')" == "1" ]]
}

@test "dep-harvest-scan: an unreachable repo carries a classified reason field" {
    single_repo_fixture
    mock_prs "owner/repo" 'STDERR:HTTP 403: API rate limit exceeded for user'
    DEP_HARVEST_RETRY_SLEEP=0 run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].status')" == "unreachable" ]]
    [[ "$(echo "$output" | jq -r '.[0].reason')" == rate-limited:* ]]
}

@test "dep-harvest-scan: a permissions failure classifies as not-authorized, not rate-limited" {
    single_repo_fixture
    mock_prs "owner/repo" 'STDERR:HTTP 401: Bad credentials'
    DEP_HARVEST_RETRY_SLEEP=0 run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].reason')" == not-authorized:* ]]
}

# --- CheckRun rollup shape (GitHub Actions) ---

# Emits a one-PR patch-bump fixture whose rollup is the given JSON array.
mock_rollup() {
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":'"$1"'}]'
}

@test "dep-harvest-scan: CheckRun conclusion FAILURE is red and holds" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "red" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "repair-candidate" ]]
}

@test "dep-harvest-scan: CheckRun conclusion STARTUP_FAILURE is red, never green" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"STARTUP_FAILURE"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "red" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" != "auto-merge" ]]
}

@test "dep-harvest-scan: CheckRun conclusion STALE is red, never green" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"STALE"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "red" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" != "auto-merge" ]]
}

@test "dep-harvest-scan: CheckRun status IN_PROGRESS is pending and holds" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "pending" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: CheckRun status WAITING is pending, never green" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"WAITING","conclusion":null}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "pending" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: CheckRun status REQUESTED is pending, never green" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"REQUESTED","conclusion":null}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "pending" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: a COMPLETED CheckRun with SUCCESS conclusion is green and auto-merges" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "green" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "auto-merge" ]]
}

@test "dep-harvest-scan: a COMPLETED CheckRun with an unrecognized conclusion is pending, not green" {
    single_repo_fixture
    mock_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SOMETHING_NEW"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "pending" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: a mixed StatusContext and CheckRun rollup resolves to the worst state" {
    single_repo_fixture
    mock_rollup '[{"__typename":"StatusContext","state":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "red" ]]
}

@test "dep-harvest-scan: a null statusCheckRollup classifies as none and holds" {
    single_repo_fixture
    mock_rollup 'null'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].ci')" == "none" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

# --- Renovate body-recovered from_version ---

@test "dep-harvest-scan: recovers from_version from a Renovate PR body version table" {
    single_repo_fixture
    # shellcheck disable=SC2016 # backticks are literal JSON fixture data
    mock_prs "owner/repo" '[{"number":1,"title":"chore(deps): update dependency foo to v1.2.4","url":"https://x/1","author":{"login":"renovate[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}],"body":"| [foo](https://x) | dependencies | patch | [`1.2.3` -> `1.2.4`] |"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].from_version')" == "1.2.3" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "patch" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "auto-merge" ]]
}

@test "dep-harvest-scan: recovers a v-prefixed unicode-arrow Renovate body pair" {
    single_repo_fixture
    # shellcheck disable=SC2016 # backticks are literal JSON fixture data
    mock_prs "owner/repo" '[{"number":1,"title":"chore(deps): update dependency foo to v2.0.0","url":"https://x/1","author":{"login":"renovate[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}],"body":"| foo | deps | major | [`v1.9.0` → `v2.0.0`] |"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].from_version')" == "1.9.0" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "major" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: a Renovate body with no version table leaves from_version null and holds" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"chore(deps): update dependency foo to v1.2.4","url":"https://x/1","author":{"login":"renovate[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}],"body":"no table here"}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].from_version')" == "null" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "unknown" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

# --- Already-automerging coordination ---

@test "dep-harvest-scan: a PR with auto-merge already enabled verdicts already-automerging" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"renovate[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}],"autoMergeRequest":{"enabledAt":"2026-08-09T00:00:00Z"}}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "already-automerging" ]]
}

@test "dep-harvest-scan: already-automerging takes precedence over a red-CI repair candidate" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"renovate[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"FAILURE"}],"autoMergeRequest":{"enabledAt":"2026-08-09T00:00:00Z"}}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "already-automerging" ]]
}

# --- Bump-classification regressions ---

@test "dep-harvest-scan: 1.9.0 to 1.10.0 is minor, not a string comparison" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.9.0 to 1.10.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "minor" ]]
}

@test "dep-harvest-scan: a zero-padded minor is not misread as octal or as a patch" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.08.0 to 1.09.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "minor" ]]
    [[ "$output" != *"value too great for base"* ]]
}

@test "dep-harvest-scan: a zero-padded major is never classified as a patch" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 08.1.2 to 09.1.2","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "major" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: a calendar-versioned bump classifies without a bash arithmetic error" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 2024.09.1 to 2024.10.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "minor" ]]
    [[ "$output" != *"value too great for base"* ]]
}

@test "dep-harvest-scan: an identical from and to version classifies unknown and holds" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.0","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "unknown" ]]
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

@test "dep-harvest-scan: a leading-v title parses both versions" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from v1.2.3 to v1.2.4","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].from_version')" == "1.2.3" ]]
    [[ "$(echo "$output" | jq -r '.[0].to_version')" == "1.2.4" ]]
    [[ "$(echo "$output" | jq -r '.[0].bump')" == "patch" ]]
}

@test "dep-harvest-scan: mergeable UNKNOWN holds rather than auto-merging" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"UNKNOWN","statusCheckRollup":[{"state":"SUCCESS"}]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq -r '.[0].verdict')" == "hold" ]]
}

# --- Author filtering, remaining login forms ---

@test "dep-harvest-scan: recognizes the app/dependabot and app/renovate login forms" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"app/dependabot"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":2,"title":"Bump bar from 1.0.0 to 1.0.1","url":"https://x/2","author":{"login":"app/renovate"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq 'length')" == "2" ]]
}

@test "dep-harvest-scan: logs a skip for an unrecognized bot login but stays silent for a human" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":7,"title":"Bump foo from 1.0.0 to 1.0.1","url":"https://x/7","author":{"login":"dependabot-preview[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":8,"title":"A human PR","url":"https://x/8","author":{"login":"paulnsorensen"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    assert_output_contains "unrecognized bot login 'dependabot-preview[bot]'"
    [[ "$output" != *"paulnsorensen"* ]]
}

# --- JSON escaping ---

@test "dep-harvest-scan: a title with quotes, a backslash, and a newline round-trips as valid JSON" {
    single_repo_fixture
    mock_prs "owner/repo" '[{"number":1,"title":"Bump \"foo\\\\bar\"\nbaz from 1.0.0 to 1.0.1","url":"https://x/1","author":{"login":"dependabot[bot]"},"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[]}]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    echo "$output" | jq -e . >/dev/null
    [[ "$(echo "$output" | jq -r '.[0].from_version')" == "1.0.0" ]]
    [[ "$(echo "$output" | jq -r '.[0].to_version')" == "1.0.1" ]]
}

# --- Output shape ---

@test "dep-harvest-scan: emits a valid JSON array, empty when no repo has open bot PRs" {
    single_repo_fixture
    mock_prs "owner/repo" '[]'
    run "$REAL_BIN/dep-harvest-scan" "$FIXTURE"
    assert_success
    [[ "$(echo "$output" | jq 'length')" == "0" ]]
}
