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
run = re.search(r"run: (.*)", body).group(1)
assert "${{" not in run, "inline expression in run"
assert 'soak-check --base "$BASE_SHA" --labels "$PR_LABELS" --main-ref origin/main' in run
assert "BASE_SHA: ${{ github.event.pull_request.base.sha }}" in body
assert "PR_LABELS:" in body
needs = re.search(r"^  test:\n(?:.*\n)*?    needs: \[(.*?)\]", text, re.M).group(1)
assert "soak-check" in needs
assert '[ "$SOAK" = success ]' in text
assert "types: [opened, synchronize, reopened, labeled, unlabeled]" in text
PY
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}
