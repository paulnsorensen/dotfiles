"""opencode.py — render an agent profile into opencode's project layout.

Behavioral port of agent-profile/renderers/opencode.sh, scoped to the
``opencode.json`` merge + surgical clean (the mcp + permission surfaces).
The agent/skill/command writers route through the shared cross-harness
paths and are owned elsewhere; this renderer owns the merged
``opencode.json`` file.

Substrate: stdlib :mod:`json` only (own your keys; ``del``/``pop`` for
surgical removal). No ``jq``.

One intentional parity break from the bash (the /age finding): the bash
``opencode_clean`` removes the bootstrapped file only when it reduces to
exactly ``{"$schema": ...}`` and leaves a bare ``{}`` behind otherwise.
This port removes the file when it reduces to ``{}`` **or**
``{"$schema": ...}`` — see :func:`OpencodeRenderer.clean`.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from agent_profile.parse import Manifest
from agent_profile.renderers.base import mcps_for

# opencode's MCP membership default (matches the bash select default).
_OPENCODE_MCP_DEFAULT = ("claude", "codex", "opencode")

_SCHEMA_STUB = {"$schema": "https://opencode.ai/config.json"}

# Claude `Bash(<cmd>:*)` prefix form -> opencode shell glob `<cmd> *`.
# Anything else passes through verbatim (best-effort, per the bash).
_BASH_PREFIX_RE = re.compile(r"^Bash\(([^:)]+):\*\)$")


def _translate_permission(p: str) -> str:
    """Best-effort Claude-permission -> opencode shell-glob translation.

    ``Bash(cargo:*)`` -> ``cargo *``; every other form is returned as-is.
    Port of the bash ``capture("^Bash\\((?<cmd>[^:)]+):\\*\\)$")`` branch."""
    m = _BASH_PREFIX_RE.match(p)
    return f"{m.group(1)} *" if m else p


def _allow_keys(manifest: Manifest) -> list[str]:
    """The translated permission keys this profile contributes to
    ``permission.bash``. Order follows ``permissions_allow`` (already
    sorted+deduped by the parser)."""
    return [
        _translate_permission(p)
        for p in manifest.settings.get("permissions_allow", [])
    ]


def _mcp_server_record(mcp: dict[str, Any]) -> dict[str, Any]:
    """The opencode mcp-server shape:
    ``{type: "local", enabled: True, command: [cmd, *args], environment?}``.
    Port of the bash ``{type, enabled, command} + {environment}`` reduce."""
    record: dict[str, Any] = {
        "type": "local",
        "enabled": True,
        "command": [mcp["command"], *(mcp.get("args") or [])],
    }
    if mcp.get("env") is not None:
        record["environment"] = mcp["env"]
    return record


class OpencodeRenderer:
    """Renderer for the merged ``opencode.json`` mcp + permission surfaces.

    Implements the :class:`~agent_profile.renderers.base.Renderer`
    protocol. ``opencode.json`` is a merged file: it is never returned
    from :meth:`render` (the install manifest must not track it) and is
    surgically un-merged in :meth:`clean`."""

    name = "opencode"

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        """Merge this profile's opencode MCPs and translated permissions
        into ``<target>/opencode.json``, bootstrapping the schema stub
        when the file is absent. Returns ``[]`` — the merged file is not
        a tracked artefact."""
        mcps = mcps_for(manifest, "opencode", _OPENCODE_MCP_DEFAULT)
        allow = _allow_keys(manifest)

        # Bash early-returns when neither surface has anything to add.
        if not mcps and not allow:
            return []

        cfg = Path(str(target).rstrip("/")) / "opencode.json"
        data: dict[str, Any] = (
            json.loads(cfg.read_text())
            if cfg.is_file()
            else dict(_SCHEMA_STUB)
        )

        if mcps:
            mcp_section = data.setdefault("mcp", {})
            for mcp in mcps:
                mcp_section[mcp["name"]] = _mcp_server_record(mcp)

        if allow:
            permission = data.setdefault("permission", {})
            bash = permission.setdefault("bash", {})
            for key in allow:
                bash[key] = "allow"

        cfg.parent.mkdir(parents=True, exist_ok=True)
        cfg.write_text(json.dumps(data, indent=2) + "\n")
        return []

    def clean(self, manifest: Manifest, target: Path) -> None:
        """Surgically remove this profile's mcp + permission entries from
        ``<target>/opencode.json``, then prune empty containers.

        If the file reduces to ``{}`` (bootstrapped without a schema key)
        or to ``{"$schema": ...}`` (the bootstrap stub), it is removed —
        the profile owned it. This is the /age fix: the bash only handled
        the ``{"$schema": ...}`` case and left a bare ``{}`` behind."""
        cfg = Path(str(target).rstrip("/")) / "opencode.json"
        if not cfg.is_file():
            return

        data = json.loads(cfg.read_text())

        ours_mcp = {
            m["name"] for m in mcps_for(manifest, "opencode", _OPENCODE_MCP_DEFAULT)
        }
        ours_allow = set(_allow_keys(manifest))

        mcp_section = data.get("mcp")
        if isinstance(mcp_section, dict):
            for name in ours_mcp:
                mcp_section.pop(name, None)
            if not mcp_section:
                data.pop("mcp", None)

        permission = data.get("permission")
        if isinstance(permission, dict):
            bash = permission.get("bash")
            if isinstance(bash, dict):
                for key in ours_allow:
                    bash.pop(key, None)
                if not bash:
                    permission.pop("bash", None)
            if not permission:
                data.pop("permission", None)

        if data == {} or list(data.keys()) == ["$schema"]:
            cfg.unlink()
            return

        cfg.write_text(json.dumps(data, indent=2) + "\n")
