from __future__ import annotations

from agent_profile import cli
from agent_profile.install_command import INSTALL_MIGRATION_GUIDANCE


def test_install_exits_nonzero_with_migration_guidance(capsys):
    assert cli.main(["install", "base"]) == 1

    err = capsys.readouterr().err
    assert err == f"{INSTALL_MIGRATION_GUIDANCE}\n"
