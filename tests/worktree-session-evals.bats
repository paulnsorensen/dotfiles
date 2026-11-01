#!/usr/bin/env bats

@test "worktree task scenarios are isolated and observable" {
    run python3 - "$BATS_TEST_DIRNAME/../skills/worktree-session/evals" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
cases = json.loads((root / "evals.json").read_text())["evals"]
tasks = [case for case in cases if case["kind"] == "task"]
assert len(cases) == 24 and len(tasks) == 15
paths = []
for case in tasks:
    assert len(case["files"]) == 1, case["name"]
    relative = case["files"][0]
    assert relative == f"evals/files/{case['name']}.json", case["name"]
    assert relative in case["prompt"], case["name"]
    path = root.parent / relative
    assert path.is_file() and path.stat().st_size > 0, case["name"]
    scenario = json.loads(path.read_text())
    assert scenario["scenario"] == case["name"], case["name"]
    assert scenario["evidence"] == "synthetic", case["name"]
    assert scenario["observations"], case["name"]
    paths.append(relative)
assert len(paths) == len(set(paths))
for name, same in (("task-child", True), ("task-independent-child-base-mismatch", False)):
    case = next(case for case in tasks if case["name"] == name)
    observations = json.loads((root.parent / case["files"][0]).read_text())["observations"]
    parent = observations["git"]["rev-parse HEAD"]
    requested = observations["git"]["rev-parse origin/main"] if not same else observations["request"]["requested_base_commit"]
    assert re.fullmatch(r"[0-9a-f]{40}", parent)
    assert re.fullmatch(r"[0-9a-f]{40}", requested)
    assert (parent == requested) is same
by_name = {case["name"]: case for case in tasks}
def scenario(name):
    return json.loads((root.parent / by_name[name]["files"][0]).read_text())["observations"]
bound = scenario("task-bound-same-destination")
assert bound["parent"]["binding"]["path"] == bound["destination"]["path"]
assert bound["parent"]["binding"]["branch"] == bound["destination"]["branch"]
assert bound["destination"]["write_access"] == "authorized"
mismatch = scenario("task-destination-base-mismatch")
assert mismatch["git"]["rev-parse feature/base"] == mismatch["destination"]["expected_starting_commit"]
assert mismatch["destination"]["starting_commit"] != mismatch["destination"]["expected_starting_commit"]
ambiguous = scenario("task-lost-response-ambiguous")
assert ambiguous["launch"]["threadId"] is None
assert len({item["threadId"] for item in ambiguous["thread_list"]}) == 2
assert all(not item["binding_verified"] for item in ambiguous["thread_list"])
PY
    [ "$status" -eq 0 ]
}
