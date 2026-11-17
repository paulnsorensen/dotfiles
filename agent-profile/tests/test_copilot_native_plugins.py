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
from unittest.mock import MagicMock, patch

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


def _profile_with_cached_plugin(tmp_path, monkeypatch, metadata, *, local=False):
    import json

    import yaml
    from agent_profile.parse import parse_manifest

    repo = tmp_path / "repo"
    repo.mkdir(parents=True)
    registry = repo / "agents" / "plugins" / "registry.yaml"
    registry.parent.mkdir(parents=True)
    source = {"path": str(tmp_path / "marketplace")} if local else {
        "git": "https://example.invalid/milknado.git"
    }
    registry.write_text(yaml.safe_dump({"plugins": {"milknado": {
        **source,
        "gate": "MILKNADO_ENABLED",
        "harnesses": ["copilot"],
        "native": ["copilot"],
    }}}))
    root = tmp_path / "marketplace" if local else tmp_path / ".cache" / "ap" / "plugins" / "milknado"
    cache = root / ".claude-plugin"
    if metadata is not None:
        cache.mkdir(parents=True)
        (cache / "marketplace.json").write_text(
            json.dumps(metadata) if isinstance(metadata, dict) else metadata
        )
    profiles = repo / "profiles"
    base = profiles / "base"
    base.mkdir(parents=True)
    (base / "profile.yaml").write_text(
        "name: base\nregistries:\n  plugins: agents/plugins/registry.yaml\n"
    )
    outer = profiles / "outer"
    outer.mkdir()
    (outer / "profile.yaml").write_text("name: outer\ninclude: [base]\n")
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("DOTFILES_DIR", str(repo))

    def parse():
        return parse_manifest(outer, lambda name: profiles / name)

    return parse


def test_disabled_cached_plugin_retires_exact_id_through_include(tmp_path, monkeypatch):
    metadata = {"name": "cached-market", "plugins": [
        {"name": "milknado", "source": "./plugins/milknado"},
        {"name": "other", "source": "./plugins/other"},
    ]}
    parse = _profile_with_cached_plugin(tmp_path, monkeypatch, metadata)
    monkeypatch.delenv("MILKNADO_ENABLED", raising=False)
    installed = {"milknado@cached-market", "other@cached-market"}

    def fake_cli(argv, **kwargs):
        assert argv[:2] == ["copilot", "plugin"]
        assert argv[2] == "uninstall"
        installed.discard(argv[3])
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("agent_profile.ingest._resolve_git_plugin") as fetch, patch(
        "subprocess.run", side_effect=fake_cli
    ) as cli:
        manifest = parse()
        assert manifest.native_plugins == []
        CopilotRenderer().render(manifest, tmp_path / "home")
    fetch.assert_not_called()
    assert _argv_calls(cli) == [["copilot", "plugin", "uninstall", "milknado@cached-market"]]
    assert installed == {"other@cached-market"}


def test_disabled_plugin_without_valid_metadata_does_not_guess(tmp_path, monkeypatch, capsys):
    for metadata in (
        None,
        "not json",
        {"plugins": [{"name": "milknado"}]},
        {"name": "bad@market", "plugins": [{"name": "milknado"}]},
        {"name": "cached-market", "plugins": []},
    ):
        parse = _profile_with_cached_plugin(tmp_path / str(metadata is None) / str(len(str(metadata))), monkeypatch, metadata)
        monkeypatch.delenv("MILKNADO_ENABLED", raising=False)
        with patch("agent_profile.ingest._resolve_git_plugin") as fetch, patch("subprocess.run") as cli:
            manifest = parse()
            CopilotRenderer().render(manifest, tmp_path / "home")
        fetch.assert_not_called()
        cli.assert_not_called()
        assert "unresolved cleanup" in capsys.readouterr().err


def test_disabled_plugin_missing_cli_reports_unresolved(tmp_path, monkeypatch, capsys):
    parse = _profile_with_cached_plugin(tmp_path, monkeypatch, {
        "name": "cached-market", "plugins": [{"name": "milknado"}]
    })
    monkeypatch.delenv("MILKNADO_ENABLED", raising=False)
    with patch("subprocess.run", side_effect=FileNotFoundError()):
        CopilotRenderer().render(parse(), tmp_path / "home")
    assert "unresolved cleanup" in capsys.readouterr().err


def test_enabled_cached_plugin_still_installs(tmp_path, monkeypatch):
    parse = _profile_with_cached_plugin(tmp_path, monkeypatch, {
        "name": "cached-market",
        "plugins": [{"name": "milknado", "source": "./plugins/milknado"}],
    })
    monkeypatch.setenv("MILKNADO_ENABLED", "true")
    cache_root = tmp_path / ".cache" / "ap" / "plugins" / "milknado"
    with patch("agent_profile.ingest._resolve_git_plugin", return_value=cache_root) as fetch, patch(
        "subprocess.run", return_value=MagicMock(returncode=0, stdout="", stderr="")
    ) as cli:
        manifest = parse()
        assert manifest.retired_copilot_plugins == []
        CopilotRenderer().render(manifest, tmp_path / "home")
    fetch.assert_called_once()
    assert _argv_calls(cli) == [
        ["copilot", "plugin", "marketplace", "add", str(cache_root)],
        ["copilot", "plugin", "install", "milknado@cached-market"],
    ]


def test_disabled_local_marketplace_retires_exact_id(tmp_path, monkeypatch):
    parse = _profile_with_cached_plugin(tmp_path, monkeypatch, {
        "name": "local-market", "plugins": [{"name": "milknado"}]
    }, local=True)
    monkeypatch.delenv("MILKNADO_ENABLED", raising=False)
    with patch("agent_profile.ingest._resolve_git_plugin") as fetch, patch(
        "subprocess.run", return_value=MagicMock(returncode=0, stdout="", stderr="")
    ) as cli:
        CopilotRenderer().render(parse(), tmp_path / "home")
    fetch.assert_not_called()
    assert _argv_calls(cli) == [
        ["copilot", "plugin", "uninstall", "milknado@local-market"]
    ]


def test_disabled_plugin_uninstall_failure_reports_unresolved(tmp_path, monkeypatch, capsys):
    parse = _profile_with_cached_plugin(tmp_path, monkeypatch, {
        "name": "cached-market", "plugins": [{"name": "milknado"}]
    })
    monkeypatch.delenv("MILKNADO_ENABLED", raising=False)
    with patch("subprocess.run", return_value=MagicMock(returncode=1, stderr="busy", stdout="")):
        CopilotRenderer().render(parse(), tmp_path / "home")
    assert "unresolved cleanup for milknado@cached-market" in capsys.readouterr().err
