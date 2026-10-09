#!/usr/bin/env bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
SKILL="$REPO_ROOT/skills/harness-climb/SKILL.md"
WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"

@test "harness-climb unittest suite passes through the Bats gate" {
    run python3 -m unittest discover -s "$REPO_ROOT/tests/harness_climb" -t "$REPO_ROOT/tests" -p 'test_*.py'
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "skill layout" {
    head -n 5 "$SKILL" | grep -qx 'name: harness-climb'
    grep -qE '^1\. ' "$SKILL"
    grep -qE '^9\. ' "$SKILL"
    [ -f "$REPO_ROOT/skills/harness-climb/scripts/harness_climb.py" ]
    [ -f "$REPO_ROOT/harness-climb/gates/.gitkeep" ]
    grep -qxE '[[:space:]]+- harness-climb' "$REPO_ROOT/chezmoi/.chezmoidata/claude.yaml"
    grep -qx '\.harness-climb/' "$REPO_ROOT/.gitignore"
    run git -C "$REPO_ROOT" check-ignore -q .harness-climb/t1/STOP
    [ "$status" -eq 0 ]
}

@test "skill resolves its script from the skill directory" {
    # shellcheck disable=SC2016 # literal backticks in the expected SKILL.md text
    grep -q 'Resolve `HC` from the directory of the loaded `SKILL.md`' "$SKILL"
    run grep -n 'show-toplevel' "$SKILL"
    [ "$status" -eq 1 ] || { echo "$output" >&2; false; }
}

@test "skill drives the field gate through ledger pending" {
    grep -q 'ledger pending' "$SKILL"
    grep -q 'candidate=n/a' "$SKILL"
}

@test "no merge" {
    grep -q '/plate' "$SKILL"
    run grep -nE 'gh pr merge|git merge|git revert|dots sync|--admin|--auto([^a-z]|$)' "$SKILL"
    [ "$status" -eq 1 ] || { echo "$output" >&2; false; }
}

@test "soak-check workflow" {
    run python3 - "$WORKFLOW" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
job = re.search(r"^  soak-check:\n(.*?)(?=^  \S|\Z)", text, re.S | re.M)
assert job, "no soak-check job"
body = job.group(1)
assert "fetch-depth: 0" in body
assert "persist-credentials: false" in body
pin = re.search(r"actions/checkout@([0-9a-f]{40})", text).group(1)
assert f"actions/checkout@{pin}" in body, "checkout pin differs"
run = re.search(r"run: \|\n(.*?)(?=^  \S|\Z|^    - )", body, re.S | re.M).group(1)
assert "${{" not in run, "inline expression in run"
assert 'gh pr view "$PR_NUMBER" --repo "$REPO" --json labels' in run, "labels must come from the API"
assert 'soak-check --base "$BASE_SHA" --labels "$PR_LABELS" --main-ref origin/main' in run
assert "exit 1" in run, "gh failure must fail closed"
assert "BASE_SHA: ${{ github.event.pull_request.base.sha }}" in body
assert "PR_NUMBER: ${{ github.event.pull_request.number }}" in body
assert "REPO: ${{ github.repository }}" in body
assert "GH_TOKEN: ${{ github.token }}" in body
assert "pull-requests: read" in body and "contents: read" in body
assert "github.event.pull_request.labels" not in text, "labels must not come from the event payload"
needs = re.search(r"^  test:\n(?:.*\n)*?    needs: \[(.*?)\]", text, re.M).group(1)
assert "soak-check" in needs
assert 'SOAK" = success ]' in text
assert "labeled" not in text, "label actions must not trigger or skip CI"
assert "types:" not in text
assert "if: github.event_name == 'pull_request'" in body, "soak-check must skip on push"
conc = re.search(r"^concurrency:\n(.*?)(?=^\S)", text, re.S | re.M)
assert conc, "no concurrency block"
assert "group: ci-${{ github.event.pull_request.number || github.ref }}\n" in conc.group(1)
assert "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in conc.group(1)
agg = re.search(r"^  test:\n(.*?)(?=^  \S|\Z)", text, re.S | re.M).group(1)
assert "if: always()" in agg
assert "EVENT: ${{ github.event_name }}" in agg
assert "ACTION" not in agg, "aggregate has no label branch"
run = agg.split("run: |", 1)[1]
assert "${{" not in run, "inline expression in aggregate run"
push, normal = run.split("else", 1)
assert 'SHARDS" = success ]' in push and 'EXTRAS" = success ]' in push
assert 'SHARDS" = skipped' not in run and 'EXTRAS" = skipped' not in run
assert 'SOAK" = skipped' in push
assert "skipped" not in normal
for name in ("lint", "test-shard", "test-extras"):
    heavy = re.search(rf"^  {name}:\n(.*?)(?=^  \S|\Z)", text, re.S | re.M).group(1)
    assert "if:" not in heavy.split("steps:")[0], f"{name} must not skip"
PY
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}
