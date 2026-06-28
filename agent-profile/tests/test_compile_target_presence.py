from __future__ import annotations

from agent_profile.cli import main
from tests.conftest import write_profile


def test_compile_rejects_profile_without_compile_targets(
    tmp_path, monkeypatch, capsys
):
    profiles = tmp_path / "profiles"
    write_profile(
        profiles,
        "missing-targets",
        "name: missing-targets
description: lacks compile targets
",
    )
    monkeypatch.setenv("AP_EXTRA_SEARCH_PATHS", str(profiles))

    assert main(["compile", "missing-targets"]) == 1

    err = capsys.readouterr().err
    assert "ap compile:" in err
    assert "missing-targets" in err
    assert "compile_targets" in err
