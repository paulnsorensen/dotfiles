"""crush.py — render an agent profile into charmbracelet/crush's config (#223).

crush is the 6th harness and the simplest renderer: **MCP-only** and
**non-isolated**.

- **MCP-only.** The registry union's skills/hooks/agents/permissions surfaces
  do not map to crush — crush has no native skill/hook/subagent/permission
  config. This renderer touches only the ``mcp`` block of ``crush.json``.
- **Non-isolated.** crush exposes no config-suppression lever (``-c`` is
  ``--cwd``; ``CRUSH_GLOBAL_CONFIG`` relocates but does not suppress inherited
  layers), so an isolated launch fails loud — crush is deliberately absent from
  ``overlay._ISOLATION_BUILDERS``. Nothing here participates in isolation.

crush.json is a merged, user-editable file (XDG global ``~/.config/crush/``,
merged with project/workspace layers). Like opencode/cursor/copilot this
renderer reads the existing object, sets its own ``mcp`` entries, writes, and
returns ``[]`` (never tracked as a whole-file artefact — undone in :meth:`clean`).

Server shape (crush v0.76.0, https://charm.land/crush.json): top-level key is
``mcp`` (not ``mcpServers``); each server is
``{type: "stdio", command, args?, env?}`` with snake_case fields. All current
registry MCPs are stdio, so only the stdio shape is emitted.

Env expansion: crush expands env values via the ``$(echo $VAR)`` shell-eval
form (charmbracelet/crush README), NOT opencode's ``{env:VAR}``. :func:`_to_crush_env`
rewrites each ``${VAR}`` to ``$(echo $VAR)`` so the secret resolves at launch
and nothing is baked into ``crush.json``. (README-derived — confirmed against
the upstream docs; not yet exercised against a live ``crush`` launch on this
machine, where the binary is not installed.)

Substrate: stdlib :mod:`json` only (own your keys; ``pop`` for surgical removal).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from agent_profile.env import VAR_RE
from agent_profile.parse import Manifest
from agent_profile.renderers.base import mcps_for, read_json_object

# crush's MCP membership default. crush includes itself so an MCP that omits
# `harnesses` (the coding default-include set) flows into crush — parity with
# the other coding harnesses (D1: default-include).
_CRUSH_MCP_DEFAULT = ("claude", "codex", "opencode", "cursor", "crush")

_SCHEMA_STUB = {"$schema": "https://charm.land/crush.json"}


def _to_crush_env(value: str) -> str:
    """Rewrite every ``${VAR}`` in an env value to crush's ``$(echo $VAR)``
    shell-eval form.

    crush does NOT understand the ``${VAR}`` shell syntax the registry carries
    (nor opencode's ``{env:VAR}``); its documented expansion token is
    ``$(echo $VAR)``. Plain literals (no ``${}``) pass through unchanged; a bare
    ``$VAR`` or a malformed ``${}`` is left untouched (only the ``${IDENT}``
    form is rewritten, so non-secret literals are never corrupted)."""
    return VAR_RE.sub(lambda m: f"$(echo ${m.group(1)})", value)


def _mcp_server_record(mcp: dict[str, Any]) -> dict[str, Any]:
    """The crush mcp-server shape: ``{type: "stdio", command, args?, env?}``.

    ``args`` and ``env`` are included only when present. Env values carry the
    literal ``${VAR}`` from ingest; each is rewritten to crush's
    ``$(echo $VAR)`` placeholder so crush expands it at launch."""
    record: dict[str, Any] = {"type": "stdio", "command": mcp["command"]}
    if mcp.get("args") is not None:
        record["args"] = mcp["args"]
    if mcp.get("env") is not None:
        record["env"] = {
            k: _to_crush_env(str(v)) for k, v in mcp["env"].items()
        }
    return record


class CrushRenderer:
    """Renderer for the merged ``crush.json`` mcp surface (MCP-only).

    Implements the :class:`~agent_profile.renderers.base.Renderer` protocol.
    ``crush.json`` is a merged file: it is never returned from :meth:`render`
    (the install manifest must not track it) and is surgically un-merged in
    :meth:`clean`."""

    name = "crush"
    mcp_default = _CRUSH_MCP_DEFAULT

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        """Merge this profile's crush MCPs into ``<target>/crush.json``,
        bootstrapping the schema stub when the file is absent. Returns ``[]`` —
        the merged file is undone in :meth:`clean`, never tracked."""
        mcps = mcps_for(manifest, "crush", _CRUSH_MCP_DEFAULT)
        if not mcps:
            return []

        cfg = Path(str(target).rstrip("/")) / "crush.json"
        data: dict[str, Any] = (
            read_json_object(cfg, "crush.json")
            if cfg.is_file()
            else dict(_SCHEMA_STUB)
        )

        section = data.setdefault("mcp", {})
        for mcp in mcps:
            section[mcp["name"]] = _mcp_server_record(mcp)

        cfg.parent.mkdir(parents=True, exist_ok=True)
        cfg.write_text(json.dumps(data, indent=2) + "\n")
        return []

    def clean(self, manifest: Manifest, target: Path) -> None:
        """Surgically remove this profile's mcp entries from
        ``<target>/crush.json``, then prune the empty container.

        If the file reduces to ``{}`` or to ``{"$schema": ...}`` (the bootstrap
        stub), it is removed — the profile owned it (opencode's /age-fix
        parity)."""
        cfg = Path(str(target).rstrip("/")) / "crush.json"
        if not cfg.is_file():
            return

        data = read_json_object(cfg, "crush.json")
        ours = {m["name"] for m in mcps_for(manifest, "crush", _CRUSH_MCP_DEFAULT)}

        section = data.get("mcp")
        if isinstance(section, dict):
            for name in ours:
                section.pop(name, None)
            if not section:
                data.pop("mcp", None)

        if data == {} or list(data.keys()) == ["$schema"]:
            cfg.unlink()
            return

        cfg.write_text(json.dumps(data, indent=2) + "\n")

    def prune_mcps(self, manifest: Manifest, target: Path) -> None:
        """Evict dropped MCP servers from crush.json's ``mcp`` block (install
        reconcile). crush's clean is MCP-only, so this delegates to it;
        ``manifest`` holds only the dropped servers."""
        self.clean(manifest, target)
