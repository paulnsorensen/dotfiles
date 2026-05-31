"""claude.py — render an agent profile as a Claude Code native plugin.

Behavioral port of ``agent-profile/renderers/claude.sh``. Implements the
:class:`~agent_profile.renderers.base.Renderer` protocol.

Layout (under ``target``)::

    .claude/plugins/local/<profile>/
      plugin.json                   curd-spec marker manifest at root
      .claude-plugin/plugin.json    manifest Claude actually loads
      agents/<name>.md              subagent files, plugin-scoped
      skills/<name>/                skill trees, copied from profile
      commands/<name>.md            slash commands
      hooks/<script>                hook scripts (wiring lives in plugin.json)
      .mcp.json                     mcpServers for harnesses ⊇ claude
      settings.json                 permissions.allow from manifest

Plus the cross-harness shared path::

    .claude/agents/<name>.md        also read by opencode + Cursor

``models.claude`` on an agent/command emits a ``model: <value>`` YAML
frontmatter line in the plugin-scoped file only; the shared
``.claude/agents/<n>.md`` stays neutral so opencode/Cursor read it cleanly.

JSON is emitted with stdlib :mod:`json` (``indent=2`` + trailing newline,
byte-identical to the bash ``jq`` output). No ``jq``/``yq``.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

from agent_profile import shared
from agent_profile.parse import Manifest
from agent_profile.renderers.base import (
    body_abs,
    copy_hook_shared_assets,
    hooks_for,
    mcp_server_entry,
    mcps_for,
    read_json_object,
)

# The bash .mcp.json select() defaults membership to all three of
# claude/codex/opencode; we keep claude's projection identical.
_MCP_DEFAULT = ("claude", "codex", "opencode")
# Hooks default to claude-only membership (matches the bash
# `(.harnesses // ["claude"])`).
_HOOK_DEFAULT = ("claude",)

# Events for which Claude writes a `matcher` field into the outer hook block
# (a tool-name regex). Mirrors `_hook_event_uses_matcher` for claude in
# agents/hooks/lib.sh — keep the two in sync. For any other event (e.g. a
# SessionStart entry carrying a codex-only source matcher) Claude ignores the
# matcher, so it is dropped on write rather than emitted as a dead field.
_CLAUDE_MATCHER_EVENTS = frozenset({"PreToolUse", "PostToolUse"})

# Name of the directory marketplace that backs the rendered plugin tree.
# Matches the hardcoded ``local`` path segment in ``plugin_dir`` below and
# the marketplace key profiles register (``global@local``). A Claude
# ``directory`` marketplace resolves plugins through a ``marketplace.json``
# whose ``name`` equals the registered key, so the three must agree.
_LOCAL_MARKETPLACE = "local"


def _dump_json(path: Path, data: object) -> None:
    """Write ``data`` as 2-space-indented JSON + trailing newline (the exact
    shape the bash ``jq`` emitted)."""
    path.write_text(json.dumps(data, indent=2) + "\n")


class ClaudeRenderer:
    """Renderer for the Claude Code native-plugin layout. See module docstring."""

    name = "claude"

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        out: list[str] = []
        base = Path(str(target).rstrip("/"))
        profile = manifest.name
        desc = manifest.description or ""
        plugin_dir = base / ".claude" / "plugins" / "local" / profile

        for sub in (".claude-plugin", "agents", "skills", "commands", "hooks"):
            (plugin_dir / sub).mkdir(parents=True, exist_ok=True)

        self._write_manifests(plugin_dir, base, profile, desc, out)
        self._write_agents(manifest, plugin_dir, base, target, out)
        self._write_skills(manifest, plugin_dir, base, out)
        self._write_commands(manifest, plugin_dir, base, out)
        self._write_hooks(manifest, plugin_dir, base, profile, out)
        self._write_mcp_json(manifest, plugin_dir, base, out)
        self._write_settings(manifest, plugin_dir, base, out)
        self._write_local_marketplace(manifest, base, profile, desc)
        self._merge_root_settings(manifest, base)

        # Track the plugin dir root so uninstall removes the whole tree
        # (including empty sub-dirs we mkdir'd above). Matches the bash
        # final `_claude_track "$target" "$plugin_dir"`.
        self._track(out, base, plugin_dir)
        return out

    def clean(self, manifest: Manifest, target: Path) -> None:
        """Surgically remove this profile's contributions to the live
        ``.claude/settings.json`` (``enabledPlugins`` + ``extraKnownMarketplaces``).

        The plugin tree itself is owned by the CLI's manifest sweep (each
        plugin gets its own dir; whole-file removal is sufficient). This
        method only touches the *shared* settings.json — the file holding
        user-owned config alongside profile-managed marketplace + plugin
        entries (mirroring how :class:`OpencodeRenderer.clean` un-merges
        ``opencode.json``)."""
        base = Path(str(target).rstrip("/"))
        if manifest.mcp_scope == "user":
            self._unregister_user_mcps(manifest)
        self._clean_local_marketplace(base, manifest.name)
        settings = base / ".claude" / "settings.json"
        if not settings.is_file():
            return

        data = read_json_object(settings, ".claude/settings.json")

        enabled = data.get("enabledPlugins")
        if isinstance(enabled, dict):
            for plugin_id in manifest.enabled_plugins:
                enabled.pop(plugin_id, None)
            if not enabled:
                data.pop("enabledPlugins", None)

        markets = data.get("extraKnownMarketplaces")
        if isinstance(markets, dict):
            for name in manifest.marketplaces:
                markets.pop(name, None)
            if not markets:
                data.pop("extraKnownMarketplaces", None)

        # Don't delete the file if other keys remain — they are user-owned.
        # Only if we reduced it to {} do we unlink, matching opencode's
        # "the profile owned it" rule.
        if data == {}:
            settings.unlink()
            return
        settings.write_text(json.dumps(data, indent=2) + "\n")

    # ─── helpers ─────────────────────────────────────────────────────

    @staticmethod
    def _track(out: list[str], base: Path, abs_path: Path) -> None:
        """Append ``abs_path`` relative to ``base`` to ``out``, deduping.
        Port of the bash ``_claude_track``."""
        rel = str(abs_path.relative_to(base))
        shared.track_file(out, rel)

    def _write_manifests(
        self,
        plugin_dir: Path,
        base: Path,
        profile: str,
        desc: str,
        out: list[str],
    ) -> None:
        manifest = {"name": profile, "version": "1.0.0", "description": desc}
        root_mf = plugin_dir / "plugin.json"
        loaded_mf = plugin_dir / ".claude-plugin" / "plugin.json"
        _dump_json(root_mf, manifest)
        _dump_json(loaded_mf, manifest)
        self._track(out, base, root_mf)
        self._track(out, base, loaded_mf)

    def _write_agents(
        self,
        manifest: Manifest,
        plugin_dir: Path,
        base: Path,
        target: Path,
        out: list[str],
    ) -> None:
        for item in manifest.agents:
            name = item["name"]
            body = body_abs(item)
            # Single Claude-complete frontmatter for both the plugin-scoped
            # file and the user-scoped shared file. The user-scoped file wins
            # (priority 4 > plugin priority 5), so it must carry the full
            # metadata — model/color/effort/skills — not a neutral subset.
            fm = shared.claude_agent_frontmatter(item)

            lines = ["---", *(f"{k}: {v}" for k, v in fm.items()), "---"]
            content = "\n".join(lines) + "\n\n"
            if body is not None:
                content += shared.strip_frontmatter(body.read_text())
            out_path = plugin_dir / "agents" / f"{name}.md"
            out_path.write_text(content)
            self._track(out, base, out_path)

            # Cross-harness shared write (Claude + Cursor) — same frontmatter.
            if body is not None:
                shared.write_shared_claude_agent(target, name, body, fm, out)

    def _write_skills(
        self,
        manifest: Manifest,
        plugin_dir: Path,
        base: Path,
        out: list[str],
    ) -> None:
        for item in manifest.skills:
            path = item.get("path") or ""
            if not path:
                continue  # source: (gh-fetched) skill — handled by cmd_install
            name = item["name"]
            src = Path(item["_source_dir"]) / path
            dst = plugin_dir / "skills" / name
            if src.is_dir():
                if dst.exists():
                    shutil.rmtree(dst)
                shutil.copytree(src, dst)
                self._track(out, base, dst)

    def _write_commands(
        self,
        manifest: Manifest,
        plugin_dir: Path,
        base: Path,
        out: list[str],
    ) -> None:
        for item in manifest.commands:
            name = item["name"]
            desc = item.get("description") or ""
            model = (item.get("models") or {}).get("claude") or ""
            body = body_abs(item)

            content = ""
            if desc or model:
                lines = ["---"]
                if desc:
                    lines.append(f"description: {desc}")
                if model:
                    lines.append(f"model: {model}")
                lines.append("---")
                content = "\n".join(lines) + "\n\n"
            if body is not None:
                content += body.read_text()
            out_path = plugin_dir / "commands" / f"{name}.md"
            out_path.write_text(content)
            self._track(out, base, out_path)

    def _write_hooks(
        self,
        manifest: Manifest,
        plugin_dir: Path,
        base: Path,
        profile: str,
        out: list[str],
    ) -> None:
        loaded_mf = plugin_dir / ".claude-plugin" / "plugin.json"
        root_mf = plugin_dir / "plugin.json"
        hook_entries: dict[str, list[dict]] = {}
        wrote_any = False

        for item in hooks_for(manifest, "claude", _HOOK_DEFAULT):
            event = item.get("event")
            matcher = item.get("matcher") or ""
            script = item.get("script") or ""
            command = item.get("command") or ""
            source_dir = item["_source_dir"]

            if script and command:
                raise ValueError(
                    f"claude_render: hook event '{event}' sets both 'script' "
                    f"and 'command' — they are mutually exclusive "
                    f"(profile {source_dir})"
                )
            if script:
                src = Path(source_dir) / script
                if not src.is_file():
                    raise FileNotFoundError(
                        f"claude_render: hook script not found: {src}"
                    )
                basename = Path(script).name
                dst = plugin_dir / "hooks" / basename
                shutil.copyfile(src, dst)
                dst.chmod(
                    dst.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
                )
                self._track(out, base, dst)
                # Deploy shared_assets alongside the script so the
                # self-locating SessionStart script resolves its lib/bank
                # under the plugin dir (HARNESS_ROOT = dirname(hooks/)).
                copy_hook_shared_assets(item, plugin_dir, base, out)
                cmd = "${CLAUDE_PLUGIN_ROOT}/hooks/" + basename
            elif command:
                # Literal command, used verbatim — no file deploy. For
                # external bridges (e.g. moshi-hook) that aren't deployed
                # scripts.
                cmd = command
            else:
                raise ValueError(
                    f"claude_render: hook event '{event}' has neither 'script' "
                    f"nor 'command' (profile {source_dir})"
                )

            inner = {"type": "command", "command": cmd}
            if item.get("timeout") is not None:
                inner["timeout"] = item["timeout"]
            if item.get("async") is not None:
                inner["async"] = item["async"]
            entry = (
                {"matcher": matcher, "hooks": [inner]}
                if matcher and event in _CLAUDE_MATCHER_EVENTS
                else {"hooks": [inner]}
            )
            hook_entries.setdefault(event, []).append(entry)
            wrote_any = True

        if not wrote_any:
            return

        # Merge hook entries into both manifests so the on-disk JSON Claude
        # reads (.claude-plugin/plugin.json) gets the wiring; the root marker
        # stays in sync. Bash sets `.hooks = $h` — the key lands last.
        for mf in (loaded_mf, root_mf):
            data = json.loads(mf.read_text())
            data["hooks"] = hook_entries
            _dump_json(mf, data)

    def _write_mcp_json(
        self,
        manifest: Manifest,
        plugin_dir: Path,
        base: Path,
        out: list[str],
    ) -> None:
        mine = mcps_for(manifest, "claude", _MCP_DEFAULT)
        if not mine:
            return
        if manifest.mcp_scope == "user":
            # User-scope install (the `global` profile): register each server
            # via `claude mcp add --scope user` so the tool names stay bare
            # (`mcp__<server>__*`) and land in ~/.claude.json. No plugin
            # .mcp.json is written, so its file is dropped from the install
            # manifest and swept on the next render.
            self._register_user_mcps(mine)
            return
        servers = {mcp["name"]: mcp_server_entry(mcp) for mcp in mine}
        out_path = plugin_dir / ".mcp.json"
        _dump_json(out_path, {"mcpServers": servers})
        self._track(out, base, out_path)

    @staticmethod
    def _claude_cli() -> str:
        """Resolve the ``claude`` CLI used for user-scope MCP registration.

        Fail loud when absent: a user-scope render targets the live
        ``~/.claude.json``, which only the CLI writes safely, so silently
        skipping would leave the MCPs unregistered."""
        cli = shutil.which("claude")
        if cli is None:
            raise FileNotFoundError(
                "claude_render: mcp_scope='user' needs the `claude` CLI on "
                "PATH to register MCP servers at user scope, but it was not "
                "found."
            )
        return cli

    def _register_user_mcps(self, mcps: list[dict]) -> None:
        """Register each MCP at user scope via the ``claude`` CLI.

        ``remove`` then ``add`` per server makes re-runs idempotent (``add``
        errors on a duplicate name). ``${VAR}`` refs in env values are passed
        through literally — the CLI stores them verbatim and Claude expands
        them at runtime, so secrets stay in ``.env`` and never land in
        ``~/.claude.json``."""
        cli = self._claude_cli()
        for mcp in mcps:
            name = mcp["name"]
            entry = mcp_server_entry(mcp)
            subprocess.run(
                [cli, "mcp", "remove", name, "--scope", "user"],
                capture_output=True,
                check=False,
            )
            cmd = [cli, "mcp", "add", name, "--scope", "user"]
            for key, val in (entry.get("env") or {}).items():
                cmd += ["-e", f"{key}={val}"]
            cmd += ["--", entry["command"], *entry.get("args", [])]
            subprocess.run(cmd, check=True)

    def _unregister_user_mcps(self, manifest: Manifest) -> None:
        """Remove this profile's user-scope MCP registrations (clean path)."""
        mine = mcps_for(manifest, "claude", _MCP_DEFAULT)
        if not mine:
            return
        cli = shutil.which("claude")
        if cli is None:
            return
        for mcp in mine:
            subprocess.run(
                [cli, "mcp", "remove", mcp["name"], "--scope", "user"],
                capture_output=True,
                check=False,
            )

    def _write_settings(
        self,
        manifest: Manifest,
        plugin_dir: Path,
        base: Path,
        out: list[str],
    ) -> None:
        allow = manifest.settings.get("permissions_allow") or []
        if not allow:
            return
        out_path = plugin_dir / "settings.json"
        _dump_json(out_path, {"permissions": {"allow": allow}})
        self._track(out, base, out_path)

    def _merge_root_settings(self, manifest: Manifest, base: Path) -> None:
        """Merge this profile's ``enabled_plugins`` and ``marketplaces`` into
        the live ``<base>/.claude/settings.json``, preserving siblings.

        Mirrors :meth:`OpencodeRenderer.render` for ``opencode.json``: read,
        own-our-keys, write. The file is shared (chezmoi-seeded user config
        + per-profile additions) so it is intentionally NOT tracked in the
        install manifest. :meth:`clean` un-merges by removing exactly the
        keys this method added.

        ``${VAR}`` / ``~`` in marketplace paths expand against the process
        env (``DOTFILES_DIR`` is the intended consumer) — same surface as
        ``cli._resolve_target``. The marketplace value is wrapped as a
        ``{"source": {"source": "directory", "path": <expanded>}}`` record;
        github-source marketplaces stay user-managed in the seed.

        No-op when the profile declares neither field. When the file does
        not exist, creates an empty ``{}`` seed first — operator running
        ``ap install global`` standalone (no chezmoi pass) gets a minimal
        file rather than a hard error; chezmoi's ``create_settings.json``
        won't overwrite it later (``create_`` semantics), so the operator
        is responsible for filling in the rest if they're skipping
        ``dots sync``."""
        if not manifest.enabled_plugins and not manifest.marketplaces:
            return

        settings = base / ".claude" / "settings.json"
        if settings.is_file():
            data = read_json_object(settings, ".claude/settings.json")
        else:
            settings.parent.mkdir(parents=True, exist_ok=True)
            data = {}

        if manifest.enabled_plugins:
            enabled = data.setdefault("enabledPlugins", {})
            for plugin_id, on in manifest.enabled_plugins.items():
                enabled[plugin_id] = bool(on)

        if manifest.marketplaces:
            markets = data.setdefault("extraKnownMarketplaces", {})
            for name, raw_path in manifest.marketplaces.items():
                expanded = os.path.expandvars(os.path.expanduser(str(raw_path)))
                markets[name] = {
                    "source": {"source": "directory", "path": expanded}
                }

        settings.write_text(json.dumps(data, indent=2) + "\n")

    def _write_local_marketplace(
        self, manifest: Manifest, base: Path, profile: str, desc: str
    ) -> None:
        """Ensure the directory-marketplace manifest at
        ``<base>/.claude/plugins/local/.claude-plugin/marketplace.json``
        lists this profile as a plugin.

        Without this manifest a Claude ``directory`` marketplace has no
        ``plugins[]`` to resolve, so an ``enabledPlugins`` entry like
        ``global@local`` is silently dropped and the plugin's bundled
        ``.mcp.json`` never loads. The manifest is shared across every
        profile rendered into the same local marketplace (like the live
        ``settings.json``), so the entry is upserted by name and siblings
        are preserved; :meth:`clean` removes exactly this profile's entry.

        A profile advertises itself here only when it enables itself in the
        local marketplace (``<profile>@local`` in ``enabled_plugins``) — a
        bare plugin render that no one enables stays out of the manifest.
        """
        if not manifest.enabled_plugins.get(f"{profile}@{_LOCAL_MARKETPLACE}"):
            return
        manifest_path = (
            base / ".claude" / "plugins" / "local" / ".claude-plugin"
            / "marketplace.json"
        )
        if manifest_path.is_file():
            data = read_json_object(manifest_path, "marketplace.json")
        else:
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            data = {}

        data["name"] = _LOCAL_MARKETPLACE
        # Claude's marketplace schema requires a non-empty `owner` object.
        data["owner"] = {"name": "agent-profile"}
        entry = {"name": profile, "source": f"./{profile}"}
        if desc:
            entry["description"] = desc
        siblings = [
            p
            for p in data.get("plugins", [])
            if isinstance(p, dict) and p.get("name") != profile
        ]
        data["plugins"] = siblings + [entry]
        _dump_json(manifest_path, data)

    def _clean_local_marketplace(self, base: Path, profile: str) -> None:
        """Remove ``profile``'s entry from the shared local marketplace
        manifest; delete the manifest when no plugins remain. Mirrors the
        ``settings.json`` un-merge in :meth:`clean`."""
        manifest_path = (
            base / ".claude" / "plugins" / "local" / ".claude-plugin"
            / "marketplace.json"
        )
        if not manifest_path.is_file():
            return
        data = read_json_object(manifest_path, "marketplace.json")
        remaining = [
            p
            for p in data.get("plugins", [])
            if isinstance(p, dict) and p.get("name") != profile
        ]
        if not remaining:
            manifest_path.unlink()
            return
        data["plugins"] = remaining
        _dump_json(manifest_path, data)
