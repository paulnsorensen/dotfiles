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
from agent_profile.permissions import (
    bash_argv,
    named_mcp_tools,
    parse_mcp_rule,
    whole_server_mcp_allows,
)
from agent_profile.renderers.base import (
    agents_for,
    body_abs,
    includes_harness,
    mcps_for,
    read_json_object,
    skills_for,
)
from agent_profile.shared import strip_frontmatter, track_file

# Copilot's MCP membership default in the bash select() is claude+codex
# (narrower than the common claude/codex/opencode triple).
_COPILOT_MCP_DEFAULT = ("claude", "codex")

# Hooks default to claude-only membership (bash ``.harnesses // ["claude"]``).
_COPILOT_HOOK_DEFAULT = ("claude",)

# Internal/non-frontmatter fields stripped before an agent's remaining keys
# become its ``.agent.md`` YAML frontmatter (bash ``del(...)``).
_AGENT_STRIP_KEYS = (
    "_source_dir",
    "body_path",
    "models",
    "fallback",
    "harnesses",
    "_from_native_plugin",
    "_from_codex_native_plugin",
)

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


def launch_flags(manifest: Manifest) -> list[str]:
    """Lower the canonical allow/deny lists to Copilot launch flags (lever 1).

    The Copilot CLI has no config-file surface for per-command rules, so the
    `copilot` launch wrapper injects these at invocation time. Mapping (from
    docs.github.com/.../about-copilot-cli):

      - ``Bash(<cmd>:*)`` allow -> ``--allow-tool=shell(<cmd>)``
      - ``Bash(<cmd>:*)`` deny  -> ``--deny-tool=shell(<cmd>)``
      - ``mcp__<s>__*``  allow  -> ``--allow-tool=<s>`` (whole server)
      - ``mcp__<s>__<t>`` allow -> ``--allow-tool=<s>(<t>)``
      - ``mcp__<s>__<t>`` deny  -> ``--deny-tool=<s>(<t>)``

    Non-Bash/non-MCP canonical entries (``Edit``/``Write``/``Read``/
    ``Grep``/``Glob``/``Skill``) have no Copilot shell/MCP surface and are
    skipped. Flags are emitted allow-first, then deny, each group sorted, so
    the wrapper output is deterministic and testable. ``<cmd>`` keeps its
    internal spaces (``shell(gh pr view)``) — Copilot matches first-level
    subcommands for git/gh."""
    settings = manifest.settings
    allow_flags = _flags_for(settings.get("permissions_allow") or [], "--allow-tool")
    deny_flags = _flags_for(settings.get("permissions_deny") or [], "--deny-tool")
    return allow_flags + deny_flags


def _flags_for(rules: list[str], option: str) -> list[str]:
    """Lower one canonical channel (allow or deny) to ``option`` flags,
    sorted for determinism. Skips entries with no Copilot surface."""
    out: list[str] = []
    for rule in sorted(rules):
        argv = bash_argv(rule)
        if argv is not None:
            out.append(f"{option}=shell({' '.join(argv)})")
            continue
        parsed = parse_mcp_rule(rule)
        if parsed is not None:
            server, tool = parsed
            spec = server if tool == "*" else f"{server}({tool})"
            out.append(f"{option}={spec}")
    return out


class CopilotRenderer:
    """Renderer for the Copilot CLI harness. See module docstring."""

    name = "copilot"
    mcp_default = _COPILOT_MCP_DEFAULT

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
        for agent in agents_for(manifest, "copilot"):
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
                parts.append(strip_frontmatter(body.read_text()))

            abs_path.write_text("".join(parts))
            track_file(out_files, rel)

    def _write_skills(
        self, manifest: Manifest, base: Path, out_files: list[str]
    ) -> None:
        for skill in skills_for(manifest, "copilot"):
            path = skill.get("path") or ""
            if not path:
                continue  # source: (gh-fetched) skill — handled by cmd_install
            name = skill["name"]
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

        # Lever 3: each server's `tools` array is derived from the canonical
        # allow list. `mcp__<server>__*` (or no canonical rule for the
        # server) -> ["*"] (all tools); named `mcp__<server>__<tool>` allows
        # -> the explicit tool list. A whole-server `mcp__<server>__*` wins
        # over named-tool entries for the same server (no restriction), so
        # check the whole-server set before the named-tool bucket.
        allow = manifest.settings.get("permissions_allow") or []
        named = named_mcp_tools(allow)
        whole = whole_server_mcp_allows(allow)
        for mcp in mcps:
            entry = {"command": mcp["command"], "args": mcp.get("args") or []}
            if mcp.get("env") is not None:
                entry["env"] = mcp["env"]
            tools = named.get(mcp["name"])
            if mcp["name"] in whole or not tools:
                entry["tools"] = ["*"]
            else:
                entry["tools"] = sorted(tools)
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

    def prune_mcps(self, manifest: Manifest, target: Path) -> None:
        """Evict dropped MCP servers from .copilot/mcp-config.json's
        ``mcpServers`` (install reconcile). Copilot's clean is MCP-only, so
        this delegates to it; ``manifest`` holds only the dropped servers."""
        self.clean(manifest, target)
