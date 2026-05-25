"""copilot.py — render an agent profile into Copilot CLI's project layout.

Behavioral port of agent-profile/renderers/copilot.sh. Unlike
Codex/opencode/Cursor, Copilot reads from its own paths under ``.github/``
and ``.copilot/`` — it does not consume the shared ``.claude/agents/`` or
``.agents/skills/`` trees. So this renderer copies the skill tree directly
into ``.github/skills/<n>/`` and emits an ``.agent.md`` file under
``.github/agents/<n>.agent.md`` per subagent.

Writes:
  - ``.github/agents/<n>.agent.md`` — subagents (whole-file)
  - ``.github/skills/<n>/``         — skill trees (whole-tree)
  - ``.github/hooks/<n>.json``      — one JSON file per copilot hook (+ script copy)
  - ``.copilot/mcp-config.json``    — merged MCP entries (mandatory ``tools: ["*"]``)

Skips:
  - commands    — Copilot CLI has no slash-command surface; warns.
  - permissions — Copilot uses runtime ``--deny-tool`` flags, not config.
  - AGENTS.md   — never touched (chezmoi-managed globally).

Models: Copilot ignores the ``model`` field on agents. If a profile sets
``models.copilot``, it is stripped and a warning is emitted.

Substrate: stdlib :mod:`json` (own-your-keys; ``del``/``pop`` for surgical
removal). No ``jq``. The frontmatter, hook-JSON, and MCP-config shapes are
byte-compatible with the bash renderer's ``jq`` output (2-space indent,
trailing newline).
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from typing import Any

from agent_profile.parse import Manifest
from agent_profile.renderers.base import (
    body_abs,
    includes_harness,
    mcps_for,
    read_json_object,
)
from agent_profile.shared import track_file

# Copilot's MCP membership default in the bash select() is claude+codex
# (narrower than the common claude/codex/opencode triple).
_COPILOT_MCP_DEFAULT = ("claude", "codex")

# Hooks default to claude-only membership (bash ``.harnesses // ["claude"]``).
_COPILOT_HOOK_DEFAULT = ("claude",)

# Internal/non-frontmatter fields stripped before an agent's remaining keys
# become its ``.agent.md`` YAML frontmatter (bash ``del(...)``).
_AGENT_STRIP_KEYS = ("_source_dir", "body_path", "models", "fallback")

# Internal fields stripped before a hook item becomes its JSON payload.
_HOOK_STRIP_KEYS = ("_source_dir", "harnesses", "fallback")


def _warn(message: str) -> None:
    print(message, file=sys.stderr)


def _frontmatter_line(key: str, value: Any) -> str:
    """Render one frontmatter ``key: value`` line, matching the bash jq:

    - array  -> ``key: [a, b]`` (joined with ``", "``)
    - string -> ``key: value`` (raw)
    - else   -> ``key: <jq tostring>`` (lowercase bool, bare number)
    """
    if isinstance(value, list):
        return f"{key}: [{', '.join(str(v) for v in value)}]"
    if isinstance(value, str):
        return f"{key}: {value}"
    if isinstance(value, bool):
        return f"{key}: {'true' if value else 'false'}"
    return f"{key}: {value}"


def _dumps(data: Any) -> str:
    """Serialize JSON the way ``jq '.'`` does: 2-space indent, trailing
    newline, ``: `` / ``, `` separators."""
    return json.dumps(data, indent=2) + "\n"


class CopilotRenderer:
    """Renderer for the Copilot CLI harness. See module docstring."""

    name = "copilot"

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        out_files: list[str] = []
        base = Path(str(target).rstrip("/"))

        self._warn_unsupported(manifest)
        self._write_agents(manifest, base, out_files)
        self._write_skills(manifest, base, out_files)
        self._write_hooks(manifest, base, out_files)
        self._write_mcp(manifest, base)
        return out_files

    def _warn_unsupported(self, manifest: Manifest) -> None:
        for command in manifest.commands:
            name = command.get("name")
            if not name:
                continue
            _warn(f"copilot: skipping command '{name}' (no equivalent surface)")

    def _write_agents(
        self, manifest: Manifest, base: Path, out_files: list[str]
    ) -> None:
        for agent in manifest.agents:
            name = agent["name"]

            models = agent.get("models") or {}
            if models.get("copilot"):
                _warn(
                    f"copilot: model override on agent '{name}' ignored "
                    "(Copilot ignores model field)"
                )

            frontmatter = {
                k: v for k, v in agent.items() if k not in _AGENT_STRIP_KEYS
            }

            rel = f".github/agents/{name}.agent.md"
            abs_path = base / rel
            abs_path.parent.mkdir(parents=True, exist_ok=True)

            parts = ["---\n"]
            for key, value in frontmatter.items():
                parts.append(_frontmatter_line(key, value) + "\n")
            parts.append("---\n\n")

            body = body_abs(agent)
            if body is not None:
                parts.append(body.read_text())

            abs_path.write_text("".join(parts))
            track_file(out_files, rel)

    def _write_skills(
        self, manifest: Manifest, base: Path, out_files: list[str]
    ) -> None:
        for skill in manifest.skills:
            name = skill["name"]
            path = skill.get("path") or ""
            src = Path(skill["_source_dir"]) / path
            if not src.is_dir():
                _warn(f"copilot: skill '{name}' source dir not found: {src}")
                continue

            rel = f".github/skills/{name}"
            abs_path = base / rel
            if abs_path.exists():
                shutil.rmtree(abs_path)
            abs_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src, abs_path)
            track_file(out_files, rel)

    def _write_hooks(
        self, manifest: Manifest, base: Path, out_files: list[str]
    ) -> None:
        for hook in manifest.hooks:
            if not includes_harness(hook, "copilot", _COPILOT_HOOK_DEFAULT):
                continue

            event = hook.get("event")
            script = hook.get("script") or ""
            source_dir = hook["_source_dir"]

            if not script:
                raise ValueError(
                    f"copilot_render: hook event '{event}' is missing 'script' "
                    f"(profile {source_dir})"
                )
            script_src = Path(source_dir) / script
            if not script_src.is_file():
                raise FileNotFoundError(
                    f"copilot_render: hook script not found: {script_src}"
                )

            script_base = Path(script).name
            hook_name = script_base.rsplit(".", 1)[0] if "." in script_base else script_base

            script_rel = f".github/hooks/{script_base}"
            script_abs = base / script_rel
            script_abs.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(script_src, script_abs)
            script_abs.chmod(0o755)
            track_file(out_files, script_rel)

            payload = {k: v for k, v in hook.items() if k not in _HOOK_STRIP_KEYS}
            payload["script"] = script_rel

            rel = f".github/hooks/{hook_name}.json"
            (base / rel).write_text(_dumps(payload))
            track_file(out_files, rel)

    def _write_mcp(self, manifest: Manifest, base: Path) -> None:
        mcps = mcps_for(manifest, "copilot", _COPILOT_MCP_DEFAULT)
        if not mcps:
            return

        out = base / ".copilot" / "mcp-config.json"
        out.parent.mkdir(parents=True, exist_ok=True)

        data: dict[str, Any]
        if out.is_file():
            data = read_json_object(out, ".copilot/mcp-config.json")
        else:
            data = {"mcpServers": {}}
        servers = data.setdefault("mcpServers", {})

        for mcp in mcps:
            entry = {"command": mcp["command"], "args": mcp.get("args") or []}
            if mcp.get("env") is not None:
                entry["env"] = mcp["env"]
            entry["tools"] = ["*"]
            servers[mcp["name"]] = entry

        out.write_text(_dumps(data))

    def clean(self, manifest: Manifest, target: Path) -> None:
        base = Path(str(target).rstrip("/"))
        cfg = base / ".copilot" / "mcp-config.json"
        if not cfg.is_file():
            return

        names = {
            mcp["name"]
            for mcp in mcps_for(manifest, "copilot", _COPILOT_MCP_DEFAULT)
        }

        data = read_json_object(cfg, ".copilot/mcp-config.json")
        servers = data.get("mcpServers") or {}
        for name in names:
            servers.pop(name, None)
        if servers:
            data["mcpServers"] = servers
        else:
            data.pop("mcpServers", None)

        # Bootstrapped file with no remaining content: we were the only
        # writer, so remove it (matches the bash empty-`{}` cleanup).
        if data == {}:
            cfg.unlink()
        else:
            cfg.write_text(_dumps(data))
