"""test_copilot_native_plugins.py — Copilot-native plugin pass (CLI-driven).

Copilot CLI exposes `copilot plugin marketplace add <dir>` + `copilot plugin
install <name>@<marketplace>` and reads `.claude-plugin/{plugin,marketplace}.json`
for Claude-Code compatibility (research: copilot-cli-plugin-system). The
declarative `enabledPlugins` settings key does NOT auto-install on startup
(upstream bug github/copilot-cli#2249), so — like the codex renderer, and unlike
claude's settings-write — the copilot native pass drives the CLI directly rather
than hand-writing ~/.copilot/settings.json (whose `directory` source object shape
is also unconfirmed).

Covers:
- Renderer: `copilot plugin marketplace add` uses the marketplace root.
- Renderer: `copilot plugin install` uses <name>@<marketplace_name>.
- Renderer: a non-copilot-native descriptor is NOT installed by copilot.
- Renderer: _write_skills / _write_agents skip _from_copilot_native_plugin items.
- Renderer: a claude-native (copilot-decomposed) item is still rendered by copilot.
- clean(): uninstall + marketplace remove for copilot-native plugins.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch, MagicMock

from agent_profile.parse import Manifest
from agent_profile.renderers.copilot import CopilotRenderer


def _native_descriptor(market_root: Path, *, copilot_native: bool = True, name: str = "milknado") -> dict:
    return {
        "name": name,
        "claude_native": False,
        "codex_native": False,
        "copilot_native": copilot_native,
        "marketplace_root": str(market_root),
        "marketplace_name": name,
        "description": "Mikado engine",
    }


def _argv_calls(mock_run) -> list[list[str]]:
    return [call.args[0] for call in mock_run.call_args_list if call.args]


# ── native install pass ───────────────────────────────────────────────────────


def test_copilot_marketplace_add_uses_marketplace_root(tmp_path):
    """`copilot plugin marketplace add` is called with the marketplace root."""
    market_root = tmp_path / "mkt" / "milknado"
    market_root.mkdir(parents=True)
    manifest = Manifest(name="base", native_plugins=[_native_descriptor(market_root)])

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        CopilotRenderer().render(manifest, tmp_path / "home")

    calls = _argv_calls(mock_run)
    assert ["copilot", "plugin", "marketplace", "add", str(market_root)] in calls, calls


def test_copilot_install_uses_marketplace_name(tmp_path):
    """`copilot plugin install` is called with <name>@<marketplace_name>."""
    market_root = tmp_path / "mkt" / "milknado"
    market_root.mkdir(parents=True)
    manifest = Manifest(name="base", native_plugins=[_native_descriptor(market_root)])

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        CopilotRenderer().render(manifest, tmp_path / "home")

    calls = _argv_calls(mock_run)
    assert ["copilot", "plugin", "install", "milknado@milknado"] in calls, calls


def test_copilot_skips_non_copilot_native_descriptor(tmp_path):
    """A claude-only-native descriptor (copilot_native False) is not installed."""
    market_root = tmp_path / "mkt" / "halloum"
    market_root.mkdir(parents=True)
    manifest = Manifest(
        name="base",
        native_plugins=[_native_descriptor(market_root, copilot_native=False, name="halloum")],
    )

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        CopilotRenderer().render(manifest, tmp_path / "home")

    assert _argv_calls(mock_run) == [], "copilot must not touch a non-copilot-native plugin"


def test_copilot_marketplace_add_nonzero_exit_does_not_crash(tmp_path):
    """A re-run where `marketplace add` exits nonzero ("already exists") must be
    tolerated, not fatal — and install still runs."""
    market_root = tmp_path / "mkt" / "milknado"
    market_root.mkdir(parents=True)
    manifest = Manifest(name="base", native_plugins=[_native_descriptor(market_root)])

    def fake_run(argv, **kwargs):
        if argv[:4] == ["copilot", "plugin", "marketplace", "add"]:
            return MagicMock(returncode=1, stdout="", stderr="marketplace already exists")
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run) as mock_run:
        CopilotRenderer().render(manifest, tmp_path / "home")  # must not raise

    calls = _argv_calls(mock_run)
    assert ["copilot", "plugin", "install", "milknado@milknado"] in calls, calls


def test_copilot_missing_cli_is_noop(tmp_path):
    """No copilot binary → FileNotFoundError is swallowed, render succeeds."""
    market_root = tmp_path / "mkt" / "milknado"
    market_root.mkdir(parents=True)
    manifest = Manifest(name="base", native_plugins=[_native_descriptor(market_root)])

    with patch("subprocess.run", side_effect=FileNotFoundError()):
        CopilotRenderer().render(manifest, tmp_path / "home")  # must not raise


# ── decomposed-path skips ─────────────────────────────────────────────────────


def test_copilot_skips_native_plugin_skills(tmp_path):
    """_write_skills skips skills carrying _from_copilot_native_plugin."""
    payload = tmp_path / "payload"
    skill_src = payload / "skills" / "wiki-init"
    skill_src.mkdir(parents=True)
    (skill_src / "SKILL.md").write_text("skill content")

    manifest = Manifest(
        name="base",
        skills=[{
            "name": "wiki-init",
            "path": "skills/wiki-init",
            "_source_dir": str(payload),
            "harnesses": ["copilot"],
            "_from_copilot_native_plugin": True,
        }],
    )
    base = tmp_path / "home"

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        CopilotRenderer().render(manifest, base)

    assert not (base / ".github" / "skills" / "wiki-init").exists()


def test_copilot_skips_native_plugin_agents(tmp_path):
    """_write_agents skips agents carrying _from_copilot_native_plugin."""
    payload = tmp_path / "payload"
    payload.mkdir()
    (payload / "worker.md").write_text("---\nname: worker\n---\nbody\n")

    manifest = Manifest(
        name="base",
        agents=[{
            "name": "worker",
            "description": "W",
            "body_path": "worker.md",
            "_source_dir": str(payload),
            "harnesses": ["copilot"],
            "_from_copilot_native_plugin": True,
        }],
    )
    base = tmp_path / "home"

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        CopilotRenderer().render(manifest, base)

    assert not (base / ".github" / "agents" / "worker.agent.md").exists()


def test_copilot_renders_other_harness_native_skill(tmp_path):
    """Marker independence: a claude-native (copilot-decomposed) skill IS rendered.

    Carrying _from_native_plugin (claude's marker) must NOT make the copilot
    renderer skip the skill — copilot is decomposed for that plugin.
    """
    payload = tmp_path / "payload"
    skill_src = payload / "skills" / "harvest"
    skill_src.mkdir(parents=True)
    (skill_src / "SKILL.md").write_text("skill content")

    manifest = Manifest(
        name="base",
        skills=[{
            "name": "harvest",
            "path": "skills/harvest",
            "_source_dir": str(payload),
            "harnesses": ["copilot"],
            "_from_native_plugin": True,  # claude's marker, not copilot's
        }],
    )
    base = tmp_path / "home"

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        CopilotRenderer().render(manifest, base)

    assert (base / ".github" / "skills" / "harvest").is_dir()


# ── clean ─────────────────────────────────────────────────────────────────────


def test_copilot_clean_uninstalls_native_plugin(tmp_path):
    """clean() uninstalls the plugin and removes the marketplace."""
    market_root = tmp_path / "mkt" / "milknado"
    market_root.mkdir(parents=True)
    manifest = Manifest(name="base", native_plugins=[_native_descriptor(market_root)])

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        CopilotRenderer().clean(manifest, tmp_path / "home")

    calls = _argv_calls(mock_run)
    assert ["copilot", "plugin", "uninstall", "milknado@milknado"] in calls, calls
    assert ["copilot", "plugin", "marketplace", "remove", "milknado", "--force"] in calls, calls
