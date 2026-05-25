"""codex.py — render an agent profile into Codex CLI's project layout.

Behavioral port of ``agent-profile/renderers/codex.sh``. Codex natively
reads:

  - ``.codex/agents/<n>.toml``       — subagents (TOML)
  - ``.agents/skills/<n>/SKILL.md``  — skills (cross-harness shared dir)
  - ``.codex/hooks.json``            — hooks (JSON array, written only when
                                       a hook is codex-harnessed)
  - ``.codex/config.toml``           — ``[mcp_servers]`` entries (merged
                                       into a user-authored file)

Slash commands are deprecated on Codex (use skills); we skip them with a
warning. ``AGENTS.md`` is owned globally by chezmoi and never touched.

Substrate (per spec): stdlib :mod:`json` for ``hooks.json``; ``tomlkit``
for *all* TOML. The bash hand-rolled two escaping helpers
(``_codex_toml_string`` / ``_codex_escape_toml_triple``) plus a
``yq``-driven ``config.toml`` merge that shredded user comments. tomlkit
replaces both: it writes correctly-escaped basic and multiline-basic
strings natively, and round-trip-parses ``config.toml`` so user keys,
comments and ordering survive the surgical ``[mcp_servers]`` merge/clean.
No ``jq``/``yq`` and no hand-rolled escaping remain.
"""

from __future__ import annotations

import json
import shutil
import stat
import sys
from pathlib import Path

import tomlkit

from agent_profile import shared
from agent_profile.parse import Manifest
from agent_profile.renderers import base

# Codex's MCP membership default matches the bash select() fallback
# `(.harnesses // ["claude","codex"])`.
_CODEX_MCP_DEFAULT = ("claude", "codex")


class CodexRenderer:
    """Renderer for the Codex CLI harness. Satisfies the
    :class:`~agent_profile.renderers.base.Renderer` protocol."""

    name = "codex"

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        out_files: list[str] = []
        target = Path(target)
        self._write_agents(manifest, target, out_files)
        self._write_skills(manifest, target, out_files)
        self._write_hooks(manifest, target, out_files)
        self._write_mcps(manifest, target)
        self._warn_commands(manifest)
        return out_files

    def clean(self, manifest: Manifest, target: Path) -> None:
        self._clean_mcps(manifest, Path(target))

    # ─── subagents ──────────────────────────────────────────────────────
    # Each agent lands at .codex/agents/<name>.toml with TOML fields:
    #   name, description, optional model, developer_instructions (multiline).
    # The body is inlined as a tomlkit multiline-basic string — tomlkit owns
    # the escaping that the bash did by hand.
    def _write_agents(
        self, manifest: Manifest, target: Path, out_files: list[str]
    ) -> None:
        base_dir = Path(str(target).rstrip("/"))
        for item in manifest.agents:
            name = item["name"]
            desc = item.get("description") or ""
            model = (item.get("models") or {}).get("codex") or ""

            body = ""
            body_path = base.body_abs(item)
            if body_path is not None:
                body = body_path.read_text()

            doc = tomlkit.document()
            doc["name"] = name
            doc["description"] = desc
            if model:
                doc["model"] = model
            doc["developer_instructions"] = tomlkit.string(body, multiline=True)

            rel = f".codex/agents/{name}.toml"
            abs_path = base_dir / rel
            abs_path.parent.mkdir(parents=True, exist_ok=True)
            abs_path.write_text(tomlkit.dumps(doc))
            shared.track_file(out_files, rel)

    # ─── skills ─────────────────────────────────────────────────────────
    # Copy the skill tree to the cross-harness shared .agents/skills/<n>/.
    def _write_skills(
        self, manifest: Manifest, target: Path, out_files: list[str]
    ) -> None:
        for item in manifest.skills:
            name = item["name"]
            rel_path = item.get("path") or ""
            src = Path(item["_source_dir"]) / rel_path
            if src.is_dir():
                shared.copy_shared_skill(target, name, src, out_files)
            else:
                print(
                    f"    codex: skill '{name}' source dir missing: {src}",
                    file=sys.stderr,
                )

    # ─── hooks ──────────────────────────────────────────────────────────
    # Codex reads .codex/hooks.json as a JSON array of hook records. The
    # file is written only when at least one hook is codex-harnessed; the
    # hook script is copied to .codex/hooks/<basename> so its command
    # ("bash .codex/hooks/<basename>") resolves relative to the target.
    def _write_hooks(
        self, manifest: Manifest, target: Path, out_files: list[str]
    ) -> None:
        codex_hooks = base.hooks_for(manifest, "codex")
        if not codex_hooks:
            return

        base_dir = Path(str(target).rstrip("/"))
        records: list[dict] = []
        for item in codex_hooks:
            event = item.get("event")
            matcher = item.get("matcher") or ""
            script = item.get("script") or ""
            source_dir = item["_source_dir"]
            timeout = item.get("timeout")

            if not script:
                raise ValueError(
                    f"codex_render: hook event '{event}' is missing 'script' "
                    f"(profile {source_dir})"
                )
            script_src = Path(source_dir) / script
            if not script_src.is_file():
                raise FileNotFoundError(
                    f"codex_render: hook script not found: {script_src}"
                )

            base_name = Path(script).name
            rel_script = f".codex/hooks/{base_name}"
            abs_script = base_dir / rel_script
            abs_script.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(script_src, abs_script)
            abs_script.chmod(abs_script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            shared.track_file(out_files, rel_script)

            record: dict = {"event": event, "command": f"bash {rel_script}"}
            if matcher:
                record["matcher"] = matcher
            if timeout not in (None, ""):
                record["timeout"] = int(timeout)
            records.append(record)

        rel = ".codex/hooks.json"
        abs_path = base_dir / rel
        abs_path.parent.mkdir(parents=True, exist_ok=True)
        abs_path.write_text(json.dumps(records, indent=2) + "\n")
        shared.track_file(out_files, rel)

    # ─── MCPs ───────────────────────────────────────────────────────────
    # Surgically merge codex-harnessed MCPs into .codex/config.toml under
    # [mcp_servers], preserving every user key, comment and ordering via a
    # tomlkit round-trip. config.toml is a merged file (never a whole-file
    # artefact); clean() removes our entries by name.
    def _write_mcps(self, manifest: Manifest, target: Path) -> None:
        mcps = base.mcps_for(manifest, "codex", _CODEX_MCP_DEFAULT)
        if not mcps:
            return

        cfg = Path(str(target).rstrip("/")) / ".codex" / "config.toml"
        doc = base.load_toml(cfg)

        servers = doc.get("mcp_servers")
        if servers is None:
            servers = tomlkit.table()
            doc["mcp_servers"] = servers

        for mcp in mcps:
            entry = tomlkit.table()
            entry["command"] = mcp["command"]
            if mcp.get("args") is not None:
                entry["args"] = mcp["args"]
            if mcp.get("env") is not None:
                env_tbl = tomlkit.table()
                for k, v in mcp["env"].items():
                    env_tbl[k] = v
                entry["env"] = env_tbl
            servers[mcp["name"]] = entry

        base.dump_toml(cfg, doc)

    # ─── commands (deprecated on Codex — skip with warning) ─────────────
    def _warn_commands(self, manifest: Manifest) -> None:
        for item in manifest.commands:
            print(
                f"    codex: skipping command '{item['name']}' "
                "(slash commands deprecated, use skills)",
                file=sys.stderr,
            )

    # ─── clean ──────────────────────────────────────────────────────────
    # Remove our [mcp_servers] entries by name. Drop the empty table, and
    # delete the file entirely when nothing else remains.
    def _clean_mcps(self, manifest: Manifest, target: Path) -> None:
        cfg = Path(str(target).rstrip("/")) / ".codex" / "config.toml"
        if not cfg.is_file():
            return

        names = [
            mcp["name"]
            for mcp in base.mcps_for(manifest, "codex", _CODEX_MCP_DEFAULT)
        ]
        if not names:
            return

        doc = base.load_toml(cfg)
        servers = doc.get("mcp_servers")
        if servers is not None:
            for name in names:
                if name in servers:
                    del servers[name]
            if len(servers) == 0:
                del doc["mcp_servers"]

        if len(doc) == 0:
            cfg.unlink()
            return
        base.dump_toml(cfg, doc)
