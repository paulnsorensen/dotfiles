"""opencode.py — render an agent profile into opencode's project layout.

Behavioral port of agent-profile/renderers/opencode.sh, scoped to the
``opencode.json`` merge + surgical clean (the mcp + permission surfaces).
The skill/command writers route through the shared cross-harness paths and
are owned elsewhere; this renderer owns the merged ``opencode.json`` file
plus opencode's native subagent files at ``<target>/agents/<name>.md``.

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

from agent_profile.env import _VAR_RE
from agent_profile.parse import Manifest
from agent_profile.renderers.base import body_abs, mcps_for, read_json_object
from agent_profile.shared import agent_is_read_only, strip_frontmatter, track_file

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


def _to_opencode_env(value: str) -> str:
    """Rewrite every ``${VAR}`` in an env value to opencode's ``{env:VAR}``.

    opencode does NOT understand the ``${VAR}`` shell syntax the registry
    carries — it passes it through verbatim and breaks (MCP-secret-passthrough).
    Its runtime expansion token is ``{env:VAR}``. Plain literals (no ``${}``)
    pass through unchanged."""
    return _VAR_RE.sub(lambda m: f"{{env:{m.group(1)}}}", value)


def _mcp_server_record(mcp: dict[str, Any]) -> dict[str, Any]:
    """The opencode mcp-server shape:
    ``{type: "local", enabled: True, command: [cmd, *args], environment?}``.
    Port of the bash ``{type, enabled, command} + {environment}`` reduce.

    Env values carry the literal ``${VAR}`` from ingest; each is rewritten to
    opencode's ``{env:VAR}`` placeholder so opencode expands it at launch and
    no secret is baked into ``opencode.json``."""
    record: dict[str, Any] = {
        "type": "local",
        "enabled": True,
        "command": [mcp["command"], *(mcp.get("args") or [])],
    }
    if mcp.get("env") is not None:
        record["environment"] = {
            k: _to_opencode_env(str(v)) for k, v in mcp["env"].items()
        }
    return record


class OpencodeRenderer:
    """Renderer for the merged ``opencode.json`` mcp + permission surfaces.

    Implements the :class:`~agent_profile.renderers.base.Renderer`
    protocol. ``opencode.json`` is a merged file: it is never returned
    from :meth:`render` (the install manifest must not track it) and is
    surgically un-merged in :meth:`clean`."""

    name = "opencode"

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        """Render opencode's native subagent files (``<target>/agents/``) and
        merge this profile's opencode MCPs + translated permissions into
        ``<target>/opencode.json``, bootstrapping the schema stub when the
        file is absent. Returns the tracked agent paths; the merged
        ``opencode.json`` is never listed (it is undone in :meth:`clean`)."""
        written = self._render_agents(manifest, target)

        mcps = mcps_for(manifest, "opencode", _OPENCODE_MCP_DEFAULT)
        allow = _allow_keys(manifest)

        # Bash early-returns when neither mcp/permission surface has anything
        # to add; agents are written above regardless.
        if not mcps and not allow:
            return written

        cfg = Path(str(target).rstrip("/")) / "opencode.json"
        data: dict[str, Any] = (
            read_json_object(cfg, "opencode.json")
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
        return written

    def _render_agents(self, manifest: Manifest, target: Path) -> list[str]:
        """Write each agent to ``<target>/agents/<name>.md`` — opencode's
        native subagent path (Markdown with ``mode: subagent`` frontmatter),
        not the shared ``.claude/agents/`` tree, which opencode does not read.

        The path is root-relative to ``target`` (the opencode config dir),
        mirroring how this renderer writes ``opencode.json`` at the target
        root. The installer points ``target`` at ``~/.config/opencode``, whose
        global agent dir is ``~/.config/opencode/agents/`` (plural, no extra
        ``.opencode/`` prefix — that prefix is the *project*-local convention,
        ``<project>/.opencode/agents/``, not the global config dir). Singular
        ``agent/`` only works via opencode's legacy backwards-compat alias.

        Read-only intent (see :func:`agent_is_read_only`) becomes a
        ``permission.edit: deny`` block. Returns the tracked rel paths."""
        base = Path(str(target).rstrip("/"))
        written: list[str] = []
        for item in manifest.agents:
            body_path = body_abs(item)
            if body_path is None:
                continue
            name = item["name"]
            fm = ["mode: subagent"]
            desc = item.get("description")
            if desc:
                # Omit an empty description, matching claude_agent_frontmatter
                # — avoids emitting a null-valued ``description:`` key.
                fm.insert(0, f"description: {desc}")
            model = (item.get("models") or {}).get("opencode") or ""
            if model and model != "inherit":
                fm.append(f"model: {model}")
            if agent_is_read_only(item):
                fm.append("permission:")
                fm.append("  edit: deny")
            body = strip_frontmatter(body_path.read_text())
            content = "---\n" + "\n".join(fm) + "\n---\n" + body
            rel = f"agents/{name}.md"
            abs_path = base / rel
            abs_path.parent.mkdir(parents=True, exist_ok=True)
            abs_path.write_text(content)
            track_file(written, rel)
        return written

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

        data = read_json_object(cfg, "opencode.json")

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
