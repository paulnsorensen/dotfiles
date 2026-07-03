"""crush.py — render an agent profile into Crush's merged crush.json config.

Crush consumes a single JSON config file (`crush.json` / `.crush.json` / global
`~/.config/crush/crush.json`) rather than per-surface plugin trees. This
renderer owns the merged install target and surgically removes only the current
profile's MCP and hook entries on uninstall.

Writes/merges:
  - `crush.json` — `{mcp: {...}, hooks: {PreToolUse: [...]}}`

Only MCP and hook surfaces have a Crush equivalent today. Agents, skills,
commands, and permissions are intentionally ignored.

Hook constraints come from Crush itself:
  - only `PreToolUse` is supported
  - hooks are shell commands, not plugin manifests
  - project/global config dedupes by command, but this renderer preserves order

Registry compatibility:
  - hook registry entries use `script:` today, so Crush maps them to a deployed
    command path under `.config/crush/hooks/<basename>` relative to the chosen
    install target and copies the script there.
  - only hooks explicitly harnessed for `crush` are considered.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from agent_profile.parse import Manifest
from agent_profile.renderers.base import (
    copy_hook_shared_assets,
    hooks_for,
    mcps_for,
    read_json_object,
)
from agent_profile.shared import track_file

_CRUSH_MCP_DEFAULT = ("claude", "codex", "opencode", "cursor", "crush")
_CRUSH_HOOK_DEFAULT = ("claude",)
_CRUSH_CONFIG_REL = ".config/crush/crush.json"
_CRUSH_HOOKS_DIR_REL = ".config/crush/hooks"


class CrushRenderer:
    """Renderer for Crush's merged `crush.json` config."""

    name = "crush"
    mcp_default = _CRUSH_MCP_DEFAULT

    def render(self, manifest: Manifest, target: Path, logical_root: Path | None = None) -> list[str]:
        base = Path(str(target).rstrip("/"))
        config_path = base / _CRUSH_CONFIG_REL
        data = (
            read_json_object(config_path, _CRUSH_CONFIG_REL)
            if config_path.is_file()
            else {}
        )

        wrote: list[str] = []
        self._merge_mcps(manifest, data)
        self._merge_hooks(manifest, base, data, wrote)

        if data == {}:
            return wrote

        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(json.dumps(data, indent=2) + "\n")
        return wrote

    def clean(self, manifest: Manifest, target: Path) -> None:
        config_path = Path(str(target).rstrip("/")) / _CRUSH_CONFIG_REL
        if not config_path.is_file():
            return

        data = read_json_object(config_path, _CRUSH_CONFIG_REL)
        self._clean_mcps(manifest, data)
        self._clean_hooks(manifest, data)

        if data == {}:
            config_path.unlink()
            return
        config_path.write_text(json.dumps(data, indent=2) + "\n")

    def prune_mcps(self, manifest: Manifest, target: Path) -> None:
        """Evict dropped MCP servers from crush.json's ``mcp`` block (install
        reconcile). Delegates to :meth:`clean`: ``manifest`` carries only the
        dropped servers and no hooks, so clean's hook pass is a no-op and only
        the dropped MCPs are removed."""
        self.clean(manifest, target)

    def _merge_mcps(self, manifest: Manifest, data: dict[str, Any]) -> None:
        mine = mcps_for(manifest, "crush", _CRUSH_MCP_DEFAULT)
        if not mine:
            return

        mcp_section = data.get("mcp")
        if not isinstance(mcp_section, dict):
            mcp_section = {}
            data["mcp"] = mcp_section

        for mcp in mine:
            mcp_section[str(mcp["name"])] = _crush_mcp_entry(mcp)

    def _clean_mcps(self, manifest: Manifest, data: dict[str, Any]) -> None:
        names = {
            str(mcp["name"])
            for mcp in mcps_for(manifest, "crush", _CRUSH_MCP_DEFAULT)
        }
        if not names:
            return

        mcp_section = data.get("mcp")
        if not isinstance(mcp_section, dict):
            return

        for name in names:
            mcp_section.pop(name, None)
        if not mcp_section:
            data.pop("mcp", None)

    def _merge_hooks(
        self,
        manifest: Manifest,
        base: Path,
        data: dict[str, Any],
        wrote: list[str],
    ) -> None:
        crush_hooks = hooks_for(manifest, "crush", _CRUSH_HOOK_DEFAULT)
        if not crush_hooks:
            return

        existing_section = data.get("hooks")
        existing_section = (
            existing_section if isinstance(existing_section, dict) else {}
        )
        existing = existing_section.get("PreToolUse")
        entries: list[dict[str, Any]] = (
            [entry for entry in existing if isinstance(entry, dict)]
            if isinstance(existing, list)
            else []
        )

        hooks_dir = base / _CRUSH_HOOKS_DIR_REL

        for hook in crush_hooks:
            if hook.get("event") != "PreToolUse":
                continue

            script = hook.get("script") or ""
            source_dir = hook["_source_dir"]
            if not script:
                raise ValueError(
                    "crush_render: PreToolUse hook is missing 'script' "
                    f"(profile {source_dir})"
                )
            src = Path(source_dir) / script
            if not src.is_file():
                raise FileNotFoundError(
                    f"crush_render: hook script not found: {src}"
                )

            basename = Path(script).name
            dest = hooks_dir / basename
            hooks_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
            dest.chmod(0o755)
            track_file(wrote, f"{_CRUSH_HOOKS_DIR_REL}/{basename}")

            copy_hook_shared_assets(hook, base / ".config/crush", base, wrote)

            entry: dict[str, Any] = {"command": str(dest)}
            matcher = hook.get("matcher")
            if matcher not in (None, ""):
                entry["matcher"] = matcher
            timeout = hook.get("timeout")
            if timeout not in (None, ""):
                entry["timeout"] = int(timeout)

            entries = [
                existing_entry
                for existing_entry in entries
                if existing_entry.get("command") != entry["command"]
            ]
            entries.append(entry)

        if entries:
            existing_section["PreToolUse"] = entries
            data["hooks"] = existing_section

    def _clean_hooks(self, manifest: Manifest, data: dict[str, Any]) -> None:
        crush_hooks = hooks_for(manifest, "crush", _CRUSH_HOOK_DEFAULT)
        if not crush_hooks:
            return

        hooks_section = data.get("hooks")
        if not isinstance(hooks_section, dict):
            return

        existing = hooks_section.get("PreToolUse")
        if not isinstance(existing, list):
            return

        basenames = {
            Path(str(hook.get("script") or "")).name
            for hook in crush_hooks
            if hook.get("event") == "PreToolUse" and hook.get("script")
        }
        kept = [
            entry
            for entry in existing
            if not _is_crush_managed_hook_entry(entry, basenames)
        ]

        if kept:
            hooks_section["PreToolUse"] = kept
        else:
            hooks_section.pop("PreToolUse", None)
        if not hooks_section:
            data.pop("hooks", None)


def _crush_mcp_entry(mcp: dict[str, Any]) -> dict[str, Any]:
    if mcp.get("url") or mcp.get("type") in ("http", "sse"):
        entry: dict[str, Any] = {
            "type": str(mcp.get("type") or "http"),
            "url": str(mcp["url"]),
        }
        headers = mcp.get("headers")
        if isinstance(headers, dict) and headers:
            entry["headers"] = headers
    else:
        entry = {
            "type": str(mcp.get("type") or "stdio"),
            "command": str(mcp["command"]),
        }
        if mcp.get("args") is not None:
            entry["args"] = mcp["args"]
        if mcp.get("env") is not None:
            entry["env"] = mcp["env"]

    disabled_tools = mcp.get("disabled_tools")
    if isinstance(disabled_tools, list) and disabled_tools:
        entry["disabled_tools"] = disabled_tools
    timeout = mcp.get("timeout")
    if timeout not in (None, ""):
        entry["timeout"] = int(timeout)
    disabled = mcp.get("disabled")
    if isinstance(disabled, bool):
        entry["disabled"] = disabled
    return entry


def _is_crush_managed_hook_entry(entry: Any, basenames: set[str]) -> bool:
    if not isinstance(entry, dict):
        return False
    command = entry.get("command")
    if not isinstance(command, str):
        return False
    if "/.config/crush/hooks/" not in command:
        return False
    return Path(command).name in basenames
