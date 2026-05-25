"""cursor.py — render an agent profile into Cursor's project layout.

Behavioral port of agent-profile/renderers/cursor.sh. Cursor reads two
cross-harness shared paths natively, delegated to the shared writers:

  - ``.claude/agents/<name>.md``     — subagent body (Cursor + Claude + opencode)
  - ``.agents/skills/<name>/SKILL.md`` — skill tree (Cursor + Codex + opencode)

Cursor-specific surfaces written here:

  - ``.cursor/commands/<name>.md`` — slash commands
  - ``.cursor/hooks.json``         — JSON array of ``{event, matcher, command}``
  - ``.cursor/mcp.json``           — ``{mcpServers: {...}}`` (merged with user file)
  - ``.cursor/agents/<name>.md``   — only when ``models.cursor`` is a real value
                                     (not ``inherit`` / absent), a per-harness
                                     model override

Permissions are UI-only on Cursor — skipped with a warning. ``AGENTS.md``
is owned globally by chezmoi — never touched here.

Substrate: stdlib :mod:`json` (own-your-keys, ``del``/``pop`` for surgical
removal). No ``jq``/``yq``.

The ``_source_dir`` fix
-----------------------
The bash ``_cursor_write_hooks`` projected each cursor hook to
``{event, matcher, command}`` (dropping ``_source_dir``), then re-derived
the source dir per index by *re-running* the same membership filter and
indexing positionally::

    source_dir=$(jq -r --argjson idx "$i" '
        [.hooks[] | select((.harnesses // ["claude"]) | index("cursor") != null)][$idx]._source_dir
    ' <<<"$merged_json")

That duplicated filter is fragile: the script→source mapping only holds
while the two filters stay byte-identical and stably ordered. This port
threads ``_source_dir`` *through* the projection (:func:`_cursor_hook_projection`),
so each hook entry carries the source dir that owns its script — no
positional re-query. In the multi-cursor-hook path every script maps to
the right source dir by construction.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from typing import Any

from agent_profile import shared
from agent_profile.parse import Manifest
from agent_profile.renderers.base import body_abs, includes_harness

# Cursor's MCP membership default — wider than the base claude/codex/opencode
# triple because Cursor opts itself into the shared default set.
_CURSOR_MCP_DEFAULT = ("claude", "codex", "opencode", "cursor")

# Hooks default to claude-only membership (bash: `.harnesses // ["claude"]`).
_CURSOR_HOOK_DEFAULT = ("claude",)


class CursorRenderer:
    """Render a resolved manifest into Cursor's ``.cursor/`` layout."""

    name = "cursor"

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        out: list[str] = []
        self._warn_unsupported(manifest)
        self._write_agents(manifest, target, out)
        self._write_skills(manifest, target, out)
        self._write_commands(manifest, target, out)
        self._write_hooks(manifest, target, out)
        self._write_mcp_json(manifest, target)
        return out

    def clean(self, manifest: Manifest, target: Path) -> None:
        """Surgically drop this profile's entries from the merged
        ``.cursor/mcp.json``, leaving user entries and unrelated top-level
        keys intact. Whole-file artefacts are swept by the CLI manifest."""
        cfg = Path(str(target).rstrip("/")) / ".cursor" / "mcp.json"
        if not cfg.is_file():
            return

        names = {mcp["name"] for mcp in _cursor_mcps(manifest)}
        data = json.loads(cfg.read_text())
        servers = data.get("mcpServers")
        if isinstance(servers, dict):
            for n in names:
                servers.pop(n, None)
            if not servers:
                data.pop("mcpServers", None)

        # Bootstrapped file we were the sole writer of collapses to `{}`;
        # remove it so uninstall on a fresh target leaves nothing behind.
        if data == {}:
            cfg.unlink()
        else:
            cfg.write_text(json.dumps(data, indent=2) + "\n")

    # ── unsupported surfaces ──────────────────────────────────────────

    def _warn_unsupported(self, manifest: Manifest) -> None:
        allow = manifest.settings.get("permissions_allow") or []
        if len(allow) > 0:
            print(
                "    cursor: permissions are UI-only, "
                "skipping permission entries",
                file=sys.stderr,
            )

    # ── subagents ─────────────────────────────────────────────────────

    def _write_agents(
        self, manifest: Manifest, target: Path, out: list[str]
    ) -> None:
        """Write the shared ``.claude/agents/<name>.md``; when
        ``models.cursor`` is a real override, also write the cursor-specific
        ``.cursor/agents/<name>.md`` so cursor sessions pick it up while
        other harnesses keep reading the shared file."""
        for item in manifest.agents:
            body = body_abs(item)
            if body is None:
                continue
            name = item["name"]
            frontmatter = _agent_frontmatter(item)
            shared.write_shared_claude_agent(
                target, name, body, frontmatter, out
            )
            model = _cursor_model(item)
            if model and model != "inherit":
                shared.render_model_override(
                    target, "cursor", "agent", name, body, model, out
                )

    # ── skills ────────────────────────────────────────────────────────

    def _write_skills(
        self, manifest: Manifest, target: Path, out: list[str]
    ) -> None:
        for item in manifest.skills:
            path_rel = item.get("path") or ""
            if not path_rel:
                continue
            src = Path(item["_source_dir"]) / path_rel
            if src.is_dir():
                shared.copy_shared_skill(target, item["name"], src, out)

    # ── commands ──────────────────────────────────────────────────────

    def _write_commands(
        self, manifest: Manifest, target: Path, out: list[str]
    ) -> None:
        if not manifest.commands:
            return
        commands_dir = Path(str(target).rstrip("/")) / ".cursor" / "commands"
        commands_dir.mkdir(parents=True, exist_ok=True)

        for item in manifest.commands:
            name = item["name"]
            desc = item.get("description") or ""
            model = _cursor_model(item)
            has_model = bool(model) and model != "inherit"

            parts: list[str] = []
            if desc or has_model:
                parts.append("---\n")
                if desc:
                    parts.append(f"description: {desc}\n")
                if has_model:
                    parts.append(f"model: {model}\n")
                parts.append("---\n\n")

            body = body_abs(item)
            if body is not None:
                parts.append(body.read_text())

            out_path = commands_dir / f"{name}.md"
            out_path.write_text("".join(parts))
            shared.track_file(out, f".cursor/commands/{name}.md")

    # ── hooks ─────────────────────────────────────────────────────────

    def _write_hooks(
        self, manifest: Manifest, target: Path, out: list[str]
    ) -> None:
        """Write ``.cursor/hooks.json`` (array of ``{event, matcher, command}``)
        and copy each cursor hook's script into ``.cursor/hooks/``.

        Each projected hook carries its own ``_source_dir`` (see
        :func:`_cursor_hook_projection`), so the script→source mapping is
        correct by construction — no positional re-query against a
        re-filtered list."""
        projected = _cursor_hook_projection(manifest)
        if not projected:
            return

        base = Path(str(target).rstrip("/"))
        (base / ".cursor").mkdir(parents=True, exist_ok=True)
        hooks_dir = base / ".cursor" / "hooks"
        hooks_dir.mkdir(parents=True, exist_ok=True)

        resolved: list[dict[str, Any]] = []
        for entry in projected:
            script_rel = entry["command"]
            src = Path(entry["_source_dir"]) / script_rel
            if not src.is_file():
                raise FileNotFoundError(
                    f"cursor_render: hook script not found: {src}"
                )
            script_name = Path(script_rel).name
            dest = hooks_dir / script_name
            shutil.copyfile(src, dest)
            dest.chmod(0o755)
            dest_rel = f".cursor/hooks/{script_name}"
            shared.track_file(out, dest_rel)
            resolved.append(
                {
                    "event": entry["event"],
                    "matcher": entry["matcher"],
                    "command": dest_rel,
                }
            )

        out_path = base / ".cursor" / "hooks.json"
        out_path.write_text(json.dumps(resolved, indent=2) + "\n")
        shared.track_file(out, ".cursor/hooks.json")

    # ── mcp.json ──────────────────────────────────────────────────────

    def _write_mcp_json(self, manifest: Manifest, target: Path) -> None:
        """Merge cursor MCPs into ``.cursor/mcp.json`` (``{mcpServers: {...}}``),
        preserving any pre-existing user entries and unknown top-level keys."""
        mcps = _cursor_mcps(manifest)
        if not mcps:
            return

        cursor_dir = Path(str(target).rstrip("/")) / ".cursor"
        cursor_dir.mkdir(parents=True, exist_ok=True)
        out_path = cursor_dir / "mcp.json"

        data = json.loads(out_path.read_text()) if out_path.is_file() else {}
        servers = data.get("mcpServers")
        if not isinstance(servers, dict):
            servers = {}
        data["mcpServers"] = servers

        for mcp in mcps:
            servers[mcp["name"]] = _cursor_mcp_entry(mcp)

        out_path.write_text(json.dumps(data, indent=2) + "\n")
        # Merged file — uninstall handled by clean().


def _cursor_model(item: dict[str, Any]) -> str:
    """Return ``models.cursor`` or empty string. Port of
    ``jq -r '.models.cursor // ""'``."""
    models = item.get("models") or {}
    value = models.get("cursor")
    return "" if value is None else str(value)


def _agent_frontmatter(item: dict[str, Any]) -> dict[str, Any]:
    """Build the shared-agent frontmatter dict, dropping empty/null values.

    Port of the bash jq object: ``{name, description, tools}`` where
    ``tools`` becomes a comma-joined string only when non-empty, and any
    empty/null entry is filtered out (``with_entries(select(...))``)."""
    fields: dict[str, Any] = {
        "name": item["name"],
        "description": item.get("description") or "",
    }
    tools = item.get("tools") or []
    if len(tools) > 0:
        fields["tools"] = ", ".join(tools)
    return {k: v for k, v in fields.items() if v != "" and v is not None}


def _cursor_mcp_entry(mcp: dict[str, Any]) -> dict[str, Any]:
    """Project one MCP to Cursor's server record.

    Unlike the base ``mcp_server_entry``, Cursor's bash always emits
    ``args`` (defaulting to ``[]``) and appends ``env`` only when present:
    ``{command, args: (.args // [])} + (if .env then {env:.env} else {} end)``.
    """
    entry: dict[str, Any] = {
        "command": mcp["command"],
        "args": mcp.get("args") if mcp.get("args") is not None else [],
    }
    if mcp.get("env") is not None:
        entry["env"] = mcp["env"]
    return entry


def _cursor_mcps(manifest: Manifest) -> list[dict[str, Any]]:
    """The MCPs whose membership includes ``cursor`` (default
    ``[claude, codex, opencode, cursor]``)."""
    return [
        mcp
        for mcp in manifest.mcps
        if includes_harness(mcp, "cursor", _CURSOR_MCP_DEFAULT)
    ]


def _cursor_hook_projection(manifest: Manifest) -> list[dict[str, Any]]:
    """Project the cursor hooks to ``{event, matcher, command, _source_dir}``.

    This is the fix for the bash positional re-query: ``_source_dir`` rides
    along inside each projected entry, so :meth:`CursorRenderer._write_hooks`
    resolves every script against the dir that owns it — independent of list
    ordering or filter duplication."""
    projected: list[dict[str, Any]] = []
    for hook in manifest.hooks:
        if not includes_harness(hook, "cursor", _CURSOR_HOOK_DEFAULT):
            continue
        projected.append(
            {
                "event": hook.get("event"),
                "matcher": hook.get("matcher") or "",
                "command": hook.get("script") or "",
                "_source_dir": hook["_source_dir"],
            }
        )
    return projected
