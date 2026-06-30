from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile.compiled_types import DriftRecord
from agent_profile.drift import (
    DriftError,
    FileComparison,
    compute_drift,
    format_drift,
)
from tests.compile_fixtures import write_json, write_text


def _comparison(
    tmp_path: Path,
    *,
    target: str = "home",
    relative_path: str = ".claude/settings.json",
    baseline: object | None = None,
    live: object | None = None,
    compiled: object | None = None,
) -> FileComparison:
    """Materialize three settings files and pair them as one comparison.

    ``None`` means the source file is absent. JSON-suffixed relative paths get
    JSON bodies; anything else is written as raw text.
    """
    is_json = relative_path.endswith(".json")

    def _write(slot: str, value: object | None) -> Path | None:
        if value is None:
            return None
        path = tmp_path / slot / relative_path
        return write_json(path, value) if is_json else write_text(path, value)  # type: ignore[arg-type]

    return FileComparison(
        target=target,
        relative_path=relative_path,
        baseline=_write("baseline", baseline),
        live=_write("live", live),
        compiled=_write("compiled", compiled),
    )


def _by_path(records: list[DriftRecord]) -> dict[str, DriftRecord]:
    return {r.path: r for r in records}


def test_no_drift_when_all_three_identical(tmp_path):
    settings = {"env": {"FOO": "1"}, "permissions": {"allow": ["a"]}}
    records = compute_drift(
        [_comparison(tmp_path, baseline=settings, live=settings, compiled=settings)]
    )
    assert records == []
    assert format_drift(records) == ""


def test_reports_key_where_live_diverges_from_baseline_and_compiled(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"env": {"FOO": "1"}},
                live={"env": {"FOO": "2"}},
                compiled={"env": {"FOO": "1"}},
            )
        ]
    )
    assert len(records) == 1
    rec = records[0]
    assert rec.target == "home"
    assert rec.relative_path == ".claude/settings.json"
    assert rec.path == "env.FOO"
    assert (rec.baseline, rec.live, rec.compiled) == ("1", "2", "1")


def test_reports_compiled_change_against_unmodified_live(tmp_path):
    # Live still matches baseline; compile wants to add a managed key. The
    # three disagree, so the pending change is surfaced for conscious review.
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"model": "opus"},
                live={"model": "opus"},
                compiled={"model": "opus", "hooks": {"PreToolUse": "x"}},
            )
        ]
    )
    rec = _by_path(records)["hooks.PreToolUse"]
    assert (rec.baseline, rec.live, rec.compiled) == (None, None, "x")


def test_lists_compared_as_whole_leaf_values(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"permissions": {"allow": ["a"]}},
                live={"permissions": {"allow": ["a", "b"]}},
                compiled={"permissions": {"allow": ["a"]}},
            )
        ]
    )
    assert len(records) == 1
    rec = records[0]
    assert rec.path == "permissions.allow"
    assert rec.baseline == ["a"]
    assert rec.live == ["a", "b"]
    assert rec.compiled == ["a"]


def test_nested_keys_flatten_to_dotted_paths(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"a": {"b": {"c": 1}}},
                live={"a": {"b": {"c": 2}}},
                compiled={"a": {"b": {"c": 1}}},
            )
        ]
    )
    assert [r.path for r in records] == ["a.b.c"]


def test_absent_live_file_is_a_clean_create_not_drift(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"env": {"FOO": "1"}},
                live=None,
                compiled={"env": {"FOO": "1"}},
            )
        ]
    )
    assert records == []


def test_baseline_absent_but_live_present_is_reported(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline=None,
                live={"env": {"FOO": "local"}},
                compiled={"env": {"FOO": "managed"}},
            )
        ]
    )
    rec = _by_path(records)["env.FOO"]
    assert rec.baseline is None
    assert rec.live == "local"
    assert rec.compiled == "managed"


def test_key_removed_in_compiled_is_reported(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"keep": 1, "drop": 2},
                live={"keep": 1, "drop": 2},
                compiled={"keep": 1},
            )
        ]
    )
    rec = _by_path(records)["drop"]
    assert (rec.baseline, rec.live, rec.compiled) == (2, 2, None)


def test_non_json_file_compared_as_whole_text(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                relative_path="AGENTS.md",
                baseline="seed body\n",
                live="locally edited body\n",
                compiled="seed body\n",
            )
        ]
    )
    assert len(records) == 1
    rec = records[0]
    assert rec.path == ""
    assert rec.baseline == "seed body\n"
    assert rec.live == "locally edited body\n"
    assert rec.compiled == "seed body\n"


def test_identical_non_json_file_yields_no_drift(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                relative_path="AGENTS.md",
                baseline="same\n",
                live="same\n",
                compiled="same\n",
            )
        ]
    )
    assert records == []


def test_malformed_live_json_fails_loud(tmp_path):
    path = write_text(tmp_path / "live" / ".claude" / "settings.json", "{not json")
    comparison = FileComparison(
        target="home",
        relative_path=".claude/settings.json",
        baseline=None,
        live=path,
        compiled=None,
    )
    with pytest.raises(DriftError) as excinfo:
        compute_drift([comparison])
    assert str(path) in str(excinfo.value)


def test_malformed_baseline_json_fails_loud(tmp_path):
    baseline = write_text(
        tmp_path / "baseline" / ".claude" / "settings.json", "{not json"
    )
    live = write_json(tmp_path / "live" / ".claude" / "settings.json", {"k": 1})
    comparison = FileComparison(
        target="home",
        relative_path=".claude/settings.json",
        baseline=baseline,
        live=live,
        compiled=None,
    )
    with pytest.raises(DriftError) as excinfo:
        compute_drift([comparison])
    assert str(baseline) in str(excinfo.value)


def test_absent_live_short_circuits_before_reading_other_sources(tmp_path):
    # Live absent must return [] before any baseline/compiled read, so a corrupt
    # baseline that would otherwise raise is never touched.
    baseline = write_text(
        tmp_path / "baseline" / ".claude" / "settings.json", "{not json"
    )
    comparison = FileComparison(
        target="home",
        relative_path=".claude/settings.json",
        baseline=baseline,
        live=None,
        compiled=None,
    )
    assert compute_drift([comparison]) == []


def test_compiled_absent_but_baseline_and_live_present_reported(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"k": 1},
                live={"k": 2},
                compiled=None,
            )
        ]
    )
    rec = _by_path(records)["k"]
    assert (rec.baseline, rec.live, rec.compiled) == (1, 2, None)


def test_baseline_drift_reported_when_live_matches_compiled(tmp_path):
    # Acceptance: live differs from the baseline (even though it already equals
    # compiled, i.e. apply is a no-op) is still surfaced for conscious review.
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"k": "seed"},
                live={"k": "managed"},
                compiled={"k": "managed"},
            )
        ]
    )
    rec = _by_path(records)["k"]
    assert (rec.baseline, rec.live, rec.compiled) == ("seed", "managed", "managed")


def test_identical_empty_dict_values_are_no_drift(tmp_path):
    settings = {"hooks": {}}
    records = compute_drift(
        [_comparison(tmp_path, baseline=settings, live=settings, compiled=settings)]
    )
    assert records == []


def test_populating_an_empty_dict_reports_the_new_leaf(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"hooks": {}},
                live={"hooks": {"PreToolUse": "x"}},
                compiled={"hooks": {}},
            )
        ]
    )
    assert "hooks.PreToolUse" in {r.path for r in records}


def test_records_sorted_by_target_file_then_path(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                target="opencode",
                relative_path="opencode.json",
                baseline={"z": 1, "a": 1},
                live={"z": 2, "a": 2},
                compiled={"z": 1, "a": 1},
            ),
            _comparison(
                tmp_path,
                target="home",
                relative_path=".claude/settings.json",
                baseline={"k": 1},
                live={"k": 2},
                compiled={"k": 1},
            ),
        ]
    )
    keys = [(r.target, r.relative_path, r.path) for r in records]
    assert keys == [
        ("home", ".claude/settings.json", "k"),
        ("opencode", "opencode.json", "a"),
        ("opencode", "opencode.json", "z"),
    ]


def test_format_groups_by_target_then_file_then_key(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                target="home",
                relative_path=".claude/settings.json",
                baseline={"env": {"FOO": "1"}, "permissions": {"allow": ["a"]}},
                live={"env": {"FOO": "2"}, "permissions": {"allow": ["a", "b"]}},
                compiled={"env": {"FOO": "1"}, "permissions": {"allow": ["a"]}},
            ),
            _comparison(
                tmp_path,
                target="opencode",
                relative_path="opencode.json",
                baseline={"theme": "dark"},
                live={"theme": "light"},
                compiled={"theme": "dark"},
            ),
        ]
    )
    text = format_drift(records)
    assert text == (
        "home  .claude/settings.json\n"
        "  env.FOO\n"
        '    baseline: "1"\n'
        '    live:     "2"\n'
        '    compiled: "1"\n'
        "  permissions.allow\n"
        '    baseline: ["a"]\n'
        '    live:     ["a", "b"]\n'
        '    compiled: ["a"]\n'
        "\n"
        "opencode  opencode.json\n"
        "  theme\n"
        '    baseline: "dark"\n'
        '    live:     "light"\n'
        '    compiled: "dark"\n'
    )


def test_format_renders_absent_value_and_whole_file_label(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                relative_path="AGENTS.md",
                baseline=None,
                live="local\n",
                compiled="managed\n",
            )
        ]
    )
    text = format_drift(records)
    assert "  (whole file)\n" in text
    assert "    baseline: null\n" in text


def test_records_are_json_serializable_for_json_caller(tmp_path):
    records = compute_drift(
        [
            _comparison(
                tmp_path,
                baseline={"env": {"FOO": "1"}, "list": [1, 2]},
                live={"env": {"FOO": "2"}, "list": [1, 2, 3]},
                compiled={"env": {"FOO": "1"}, "list": [1, 2]},
            )
        ]
    )
    payload = json.dumps([r.to_dict() for r in records])
    restored = json.loads(payload)
    assert {r["path"] for r in restored} == {"env.FOO", "list"}
    foo = next(r for r in restored if r["path"] == "env.FOO")
    assert foo == {
        "target": "home",
        "relative_path": ".claude/settings.json",
        "path": "env.FOO",
        "baseline": "1",
        "live": "2",
        "compiled": "1",
    }
