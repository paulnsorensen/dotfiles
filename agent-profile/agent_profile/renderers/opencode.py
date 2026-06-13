"""opencode.py — render an agent profile into opencode's project layout.

Behavioral port of agent-profile/renderers/opencode.sh, scoped to the
``opencode.json`` merge + surgical clean (the mcp + permission surfaces).
This renderer also copies local ``path:`` skills into
``<target>/skills/<name>/`` (opencode's native skill directory) and writes
native subagent files at ``<target>/agents/<name>.md``. External
``source:`` skills are fetched by the CLI's ``cmd_install`` via ``npx`` and
land in the same ``skills/`` tree.

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
import shutil
from pathlib import Path
from typing import Any

from agent_profile.env import VAR_RE
from agent_profile.parse import Manifest
from agent_profile.renderers.base import body_abs, mcps_for, read_json_object
from agent_profile.shared import agent_is_read_only, strip_frontmatter, track_file

# opencode's MCP membership default (matches the bash select default).
_OPENCODE_MCP_DEFAULT = ("claude", "codex", "opencode")

_SCHEMA_STUB = {"$schema": "https://opencode.ai/config.json"}

# Claude `Bash(<cmd>:*)` prefix form -> opencode shell glob `<cmd> *`.
_BASH_PREFIX_RE = re.compile(r"^Bash\(([^:)]+):\*\)$")
# Generic `Tool(arg)` form.
_PAREN_RE = re.compile(r"^([A-Za-z]+)\((.*)\)$")

# Claude tool name -> opencode permission key.
_TOOL_KEY = {
    "Bash": "bash",
    "Read": "read",
    "Edit": "edit",
    "Write": "edit",
    "WebFetch": "webfetch",
    "WebSearch": "websearch",
    "Glob": "glob",
    "Grep": "grep",
    "Skill": "skill",
    "Agent": "task",
}

# opencode's pattern-map-capable tools. Every other key (webfetch, websearch,
# lsp, MCP tool keys) is shorthand-only: a string action, no {pattern: action}
# map. A ``None`` pattern from the classifier marks a shorthand key.
_MAP_TOOLS = frozenset(
    {"read", "edit", "glob", "grep", "bash", "task", "external_directory", "skill"}
)


def _translate_permission(p: str) -> tuple[str, str | None]:
    """Classify a Claude permission rule into an opencode ``(key, pattern)``.

    ``pattern is None`` means a shorthand-only key (rendered as
    ``permission.<key> = <action>``); a concrete pattern means a map-capable
    tool (rendered as ``permission.<key>[<pattern>] = <action>``).

    Best-effort, per the bash heritage: an unrecognized form lands under
    ``bash`` verbatim rather than being dropped."""
    m = _BASH_PREFIX_RE.match(p)
    if m:
        return ("bash", f"{m.group(1)} *")

    # MCP rule: mcp__server__tool / mcp__server__* / mcp__server.
    # opencode keys MCP tools as ``<server>_<tool>``; ``*`` or a missing tool
    # collapses to the whole-server ``<server>_*``. Split only on the ``mcp__``
    # prefix then the ``__`` separator so a hyphen/underscore in the server
    # name (e.g. code-review-graph) survives.
    if p.startswith("mcp__"):
        server, sep, tool = p[len("mcp__") :].partition("__")
        if not sep or tool in ("", "*"):
            return (f"{server}_*", None)
        return (f"{server}_{tool}", None)

    m = _PAREN_RE.match(p)
    if m:
        tool, arg = m.group(1), m.group(2)
        key = _TOOL_KEY.get(tool)
        if key in _MAP_TOOLS:
            return (key, arg)
        if key is not None:  # shorthand tool (webfetch/websearch)
            return (key, None)
        return ("bash", p)  # unknown Tool(arg) -> verbatim under bash

    # Bare token (no parens) -> bash literal (back-compat pass-through).
    return ("bash", p)


def _perms(manifest: Manifest, field: str) -> list[tuple[str, str | None]]:
    """Translate one permission channel (``permissions_allow`` /
    ``permissions_deny``) into opencode ``(key, pattern)`` pairs. Order
    follows the channel list (already sorted+deduped by the parser)."""
    return [_translate_permission(p) for p in manifest.settings.get(field, [])]


def _apply_perms(
    permission: dict[str, Any],
    perms: list[tuple[str, str | None]],
    action: str,
) -> None:
    """Write each ``(key, pattern)`` into the ``permission`` object with the
    given action. Shorthand keys (``pattern is None``) set a string; map keys
    append to the tool's ``{pattern: action}`` map. ``setdefault`` preserves
    user-set siblings; a user value that isn't a map under a map-tool key is
    left untouched."""
    for key, pattern in perms:
        if pattern is None:
            permission[key] = action
            continue
        bucket = permission.setdefault(key, {})
        if isinstance(bucket, dict):
            bucket[pattern] = action


def _to_opencode_env(value: str) -> str:
    """Rewrite every ``${VAR}`` in an env value to opencode's ``{env:VAR}``.

    opencode does NOT understand the ``${VAR}`` shell syntax the registry
    carries — it passes it through verbatim and breaks (MCP-secret-passthrough).
    Its runtime expansion token is ``{env:VAR}``. Plain literals (no ``${}``)
    pass through unchanged."""
    return VAR_RE.sub(lambda m: f"{{env:{m.group(1)}}}", value)


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
    mcp_default = _OPENCODE_MCP_DEFAULT

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        """Render opencode's native subagent files (``<target>/agents/``),
        copy local skills into ``<target>/skills/``, then merge this
        profile's opencode MCPs + translated permissions into
        ``<target>/opencode.json``, bootstrapping the schema stub when the
        file is absent. Returns the tracked paths; the merged
        ``opencode.json`` is never listed (it is undone in :meth:`clean`)."""
        written = self._render_agents(manifest, target)
        self._write_skills(manifest, target, written)

        mcps = mcps_for(manifest, "opencode", _OPENCODE_MCP_DEFAULT)
        allow = _perms(manifest, "permissions_allow")
        deny = _perms(manifest, "permissions_deny")

        # Bash early-returns when neither mcp/permission surface has anything
        # to add; agents and skills are written above regardless.
        if not mcps and not allow and not deny:
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

        if allow or deny:
            permission = data.setdefault("permission", {})
            # opencode is last-match-wins: emit allow entries before deny so
            # the more specific deny rule the user added wins within a tool map.
            _apply_perms(permission, allow, "allow")
            _apply_perms(permission, deny, "deny")

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

    def _write_skills(self, manifest: Manifest, target: Path, out: list[str]) -> None:
        """Copy local ``path:`` skills into opencode's native skill directory
        (``<target>/skills/<name>/``). External ``source:`` skills are handled
        by the CLI's ``_fetch_external_skills`` via ``npx skills add`` and are
        skipped here — they already land in the same ``skills/`` tree.

        opencode reads ``<config>/skills/<name>/SKILL.md`` natively, so local
        skills placed here are available as ``@skill`` invocations alongside
        the external ones fetched by the CLI. The cross-harness shared paths
        (``.agents/skills/``, ``.claude/skills/``) also serve opencode as
        fallback, but this copy puts them in opencode's own primary skill dir."""
        base = Path(str(target).rstrip("/"))
        for item in manifest.skills:
            path_rel = item.get("path") or ""
            if not path_rel:
                continue  # source: (gh-fetched) skill — handled by cmd_install
            name = item["name"]
            src = Path(item["_source_dir"]) / path_rel
            if not src.is_dir():
                continue  # same silent-skip as copilot renderer
            rel = f"skills/{name}"
            dst = base / rel
            if dst.exists():
                shutil.rmtree(dst)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src, dst)
            track_file(out, rel)

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
        ours_perms = _perms(manifest, "permissions_allow") + _perms(
            manifest, "permissions_deny"
        )

        mcp_section = data.get("mcp")
        if isinstance(mcp_section, dict):
            for name in ours_mcp:
                mcp_section.pop(name, None)
            if not mcp_section:
                data.pop("mcp", None)

        permission = data.get("permission")
        if isinstance(permission, dict):
            for key, pattern in ours_perms:
                if pattern is None:  # shorthand key (string action)
                    permission.pop(key, None)
                    continue
                bucket = permission.get(key)
                if isinstance(bucket, dict):
                    bucket.pop(pattern, None)
                    if not bucket:
                        permission.pop(key, None)
            if not permission:
                data.pop("permission", None)

        if data == {} or list(data.keys()) == ["$schema"]:
            cfg.unlink()
            return

        cfg.write_text(json.dumps(data, indent=2) + "\n")

    def prune_mcps(self, manifest: Manifest, target: Path) -> None:
        """Evict dropped MCP servers from opencode.json's ``mcp`` block
        (install reconcile). Delegates to :meth:`clean`: ``manifest`` holds
        only the dropped servers and no permission allow-list, so clean's
        permission pass is a no-op and only the dropped MCPs are removed."""
        self.clean(manifest, target)
