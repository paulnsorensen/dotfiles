"""Shared pytest fixtures + a stub renderer for steel-thread tests.

The five production harness renderers are owned by sibling curds, so the
steel threads drive the CLI through a minimal in-test stub renderer
(:class:`StubRenderer`). The stub exercises the exact orchestration the
golden-from-bash threads care about — shared cross-harness writes
(``.claude/agents/<n>.md`` via the shared writer, so ref-counting is
real), per-harness whole-file artefacts, and a merged-file ``clean`` —
without pulling in a production renderer module.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile import shared
from agent_profile.parse import Manifest
from agent_profile.renderers.base import mcps_for
from agent_profile.cli import ALL_HARNESSES

GOLDEN = Path(__file__).parent / "fixtures" / "golden"


@pytest.fixture
def golden():
    """Load a golden fixture. ``golden("strings/errors.json")`` parses
    JSON; any other extension returns raw text."""

    def _load(rel: str) -> object:
        path = GOLDEN / rel
        text = path.read_text()
        if path.suffix == ".json":
            return json.loads(text)
        return text

    return _load


@pytest.fixture
def env(monkeypatch, tmp_path):
    """Sandbox the discovery env: a fresh profile root via
    AP_EXTRA_SEARCH_PATHS, an empty DOTFILES_DIR, and a scratch target.
    Returns a small namespace with ``profiles`` and ``target`` paths."""
    profiles = tmp_path / "profiles"
    target = tmp_path / "target"
    profiles.mkdir()
    target.mkdir()
    monkeypatch.setenv("AP_EXTRA_SEARCH_PATHS", str(profiles))
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path / "empty-dots"))
    monkeypatch.chdir(target)

    class _Env:
        pass

    e = _Env()
    e.profiles = profiles
    e.target = target
    e.tmp = tmp_path
    return e


def write_profile(root: Path, name: str, yaml_text: str, files: dict | None = None):
    """Materialize a profile dir under ``root``."""
    d = root / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "profile.yaml").write_text(yaml_text)
    for rel, content in (files or {}).items():
        p = d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    return d


class StubRenderer:
    """A minimal renderer covering one cross-harness shared agent write and
    one per-harness whole-file artefact, plus a merged-file clean.

    - Each agent with a body writes the shared ``.claude/agents/<n>.md``
      (so two profiles sharing a name exercise ref-counting), and a
      per-harness marker ``.<name>/agents/<agent>.md``.
    - MCPs scoped to this harness are merged into a per-target
      ``<name>.json`` merged file; ``clean`` surgically removes them.
    """

    def __init__(self, name: str):
        self.name = name

    def _merged_path(self, target: Path) -> Path:
        return Path(str(target).rstrip("/")) / f"{self.name}.json"

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        out: list[str] = []
        base = Path(str(target).rstrip("/"))
        for agent in manifest.agents:
            body_rel = agent.get("body_path") or ""
            body = Path(agent["_source_dir"]) / body_rel
            if body_rel and body.is_file():
                shared.write_shared_claude_agent(
                    target, agent["name"], body, {"name": agent["name"]}, out
                )
                marker_rel = f".{self.name}/agents/{agent['name']}.md"
                marker = base / marker_rel
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.write_text(body.read_text())
                shared.track_file(out, marker_rel)

        mine = mcps_for(manifest, self.name, tuple(ALL_HARNESSES))
        if mine:
            path = self._merged_path(target)
            data = json.loads(path.read_text()) if path.is_file() else {}
            servers = data.setdefault("mcpServers", {})
            for mcp in mine:
                servers[mcp["name"]] = {"command": mcp["command"]}
            path.write_text(json.dumps(data, indent=2) + "\n")
        return out

    def clean(self, manifest: Manifest, target: Path) -> None:
        path = self._merged_path(target)
        if not path.is_file():
            return
        names = {
            m["name"]
            for m in mcps_for(
                manifest, self.name, tuple(ALL_HARNESSES)
            )
        }
        data = json.loads(path.read_text())
        servers = data.get("mcpServers", {})
        for n in names:
            servers.pop(n, None)
        if not servers:
            data.pop("mcpServers", None)
        if not data:
            path.unlink()
        else:
            path.write_text(json.dumps(data, indent=2) + "\n")


@pytest.fixture
def stub_renderers(monkeypatch):
    """Install StubRenderers for all harnesses into the CLI registry
    for the duration of the test."""
    from agent_profile import cli

    renderers = {h: StubRenderer(h) for h in cli.ALL_HARNESSES}
    saved = cli.RENDERERS
    cli.set_renderers(renderers)
    yield renderers
    cli.set_renderers(saved)
