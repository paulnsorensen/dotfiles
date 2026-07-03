from __future__ import annotations

import pytest

from agent_profile import cli
from agent_profile.parse import parse_manifest

from .compile_fixtures import write_live_profile, write_minimal_includes


def _write_targets(env, compile_targets: dict) -> None:
    write_minimal_includes(env.profiles)
    write_live_profile(env.profiles, compile_targets=compile_targets)


def _describe(capsys) -> str:
    rc = cli.main(["describe", "live"])
    captured = capsys.readouterr()
    assert rc == 1
    return captured.err


def test_valid_compile_targets_resolve_to_absolute_roots(env, monkeypatch):
    monkeypatch.setenv("HOME", str(env.tmp / "home"))
    _write_targets(
        env,
        {
            "home": {"target_root": "$HOME", "harnesses": ["claude", "codex"]},
            "opencode": {
                "target_root": "${HOME}/.config/opencode",
                "harnesses": ["opencode"],
            },
        },
    )

    manifest = parse_manifest(env.profiles / "live")

    assert [target.name for target in manifest.compile_targets] == ["home", "opencode"]
    assert manifest.compile_targets[0].resolved_root == env.tmp / "home"
    assert manifest.compile_targets[1].resolved_root == env.tmp / "home/.config/opencode"


@pytest.mark.parametrize(
    ("target_name", "compile_targets", "expected"),
    [
        (
            "home",
            {"home": {"target_root": "$HOME", "harnesses": ["claude", "whey"]}},
            "unknown harness 'whey'",
        ),
        (
            "codex",
            {
                "home": {"target_root": "$HOME", "harnesses": ["codex"]},
                "codex": {"target_root": "$HOME/.codex", "harnesses": ["codex"]},
            },
            "duplicates harness 'codex'",
        ),
        (
            "home",
            {"home": {"harnesses": ["claude"]}},
            "missing required field 'target_root'",
        ),
        (
            "home",
            {"home": {"target_root": "$HOME"}},
            "missing required field 'harnesses'",
        ),
        (
            "home",
            {"home": {"target_root": "relative/path", "harnesses": ["claude"]}},
            "target_root must resolve absolute",
        ),
        (
            "home",
            {"home": {"target_root": "$AP_TEST_MISSING/root", "harnesses": ["claude"]}},
            "unresolved env var '$AP_TEST_MISSING'",
        ),
    ],
)
def test_invalid_compile_targets_exit_nonzero_with_target_name(
    env, capsys, monkeypatch, target_name, compile_targets, expected
):
    monkeypatch.setenv("HOME", str(env.tmp / "home"))
    monkeypatch.delenv("AP_TEST_MISSING", raising=False)
    _write_targets(env, compile_targets)

    err = _describe(capsys)

    assert f"compile target '{target_name}'" in err
    assert expected in err
