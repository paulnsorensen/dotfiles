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
import os
import shutil
import stat
import sys
from pathlib import Path

import tomlkit

from agent_profile import shared
from agent_profile.env import load_dotenv
from agent_profile.parse import Manifest
from agent_profile.renderers import base

# Codex's MCP membership default matches the bash select() fallback
# `(.harnesses // ["claude","codex"])`.
_CODEX_MCP_DEFAULT = ("claude", "codex")


def _inherited_env_keys() -> frozenset[str]:
    """Keys present in $DOTFILES_DIR/.env (resolved via the same fallback
    as :func:`overlay._dotenv`). The codex renderer treats any env var
    listed here as already-exported by the user's shell (zsh/core.zsh
    sources .env on startup) and omits it from rendered MCP env blocks
    so credentials aren't duplicated as plaintext in ~/.codex/config.toml.

    Set ``AP_CODEX_INHERIT_ENV=0`` to disable the scrub (forces every
    env entry to be baked, matching the pre-scrub behaviour).
    """
    if os.environ.get("AP_CODEX_INHERIT_ENV", "1") == "0":
        return frozenset()
    repo_root = Path(
        os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles")
    )
    return frozenset(load_dotenv(repo_root / ".env").keys())


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
            body = shared.strip_frontmatter(body)

            doc = tomlkit.document()
            doc["name"] = name
            doc["description"] = desc
            if model:
                doc["model"] = model
            if shared.agent_is_read_only(item):
                doc["sandbox_mode"] = "read-only"
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
            rel_path = item.get("path") or ""
            if not rel_path:
                continue  # source: (gh-fetched) skill — handled by cmd_install
            name = item["name"]
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

        # Strip legacy [[hooks.<event>]] blocks from .codex/config.toml that
        # the retired agents/hooks/sync.sh wrote, before we land hooks.json.
        # Codex merges hooks.json and config.toml hooks at load time
        # (developers.openai.com/codex/hooks: "Codex loads all matching
        # hooks"), so leaving orphan legacy blocks fires every managed hook
        # twice per session — once from each source.
        self._clean_legacy_config_toml_hooks(codex_hooks, target)

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

            # Deploy shared_assets under .codex/ so the self-locating
            # SessionStart script resolves its lib/bank (HARNESS_ROOT =
            # dirname(.codex/hooks/) = .codex/).
            base.copy_hook_shared_assets(
                item, base_dir / ".codex", base_dir, out_files
            )

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
    #
    # Env-block scrubbing: keys present in $DOTFILES_DIR/.env are dropped
    # from the rendered [mcp_servers.*.env] table. Reason: zsh/core.zsh
    # exports every key=value from .env into the interactive shell, so
    # codex (a terminal-launched CLI) and its MCP server children already
    # inherit those values at runtime. Re-baking them as plaintext in
    # ~/.codex/config.toml just duplicates the credential on disk for no
    # behavioural gain. Non-.env env entries (e.g. SERENA_MUX_HARNESS,
    # which is render-time per-harness, not a credential) stay baked.
    def _write_mcps(self, manifest: Manifest, target: Path) -> None:
        mcps = base.mcps_for(manifest, "codex", _CODEX_MCP_DEFAULT)
        if not mcps:
            return

        inherited = _inherited_env_keys()
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
            env = {
                k: v
                for k, v in (mcp.get("env") or {}).items()
                if k not in inherited
            }
            if env:
                env_tbl = tomlkit.table()
                for k, v in env.items():
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

    # ─── legacy config.toml hook cleanup ───────────────────────────────
    # The retired agents/hooks/sync.sh wrote [[hooks.<event>]] blocks into
    # ~/.codex/config.toml. The ap codex renderer writes ~/.codex/hooks.json
    # instead, but Codex CLI loads both file formats and merges them — see
    # developers.openai.com/codex/hooks. So machines that ran the legacy
    # sync end up firing every managed hook from both sources. This is a
    # one-time migration sweep: for each hook we're about to write to
    # hooks.json, drop any config.toml block whose command points at
    # .codex/hooks/<our basename>. User-authored entries (any other path
    # or basename) are preserved.
    def _clean_legacy_config_toml_hooks(
        self, codex_hooks: list[dict], target: Path
    ) -> None:
        cfg = Path(str(target).rstrip("/")) / ".codex" / "config.toml"
        if not cfg.is_file():
            return
        managed_per_event = _managed_basenames_per_event(codex_hooks)
        if not managed_per_event:
            return

        doc = base.load_toml(cfg)
        hooks_table = doc.get("hooks")
        if hooks_table is None:
            return

        changed = False
        for event_key in list(hooks_table.keys()):
            event_managed = managed_per_event.get(event_key)
            if not event_managed:
                continue  # not an event we manage — leave user entries alone
            event_array = hooks_table.get(event_key)
            if not _is_array_of_tables(event_array):
                continue
            rebuilt = _prune_event_blocks(event_array, event_managed)
            if rebuilt is None:
                continue  # nothing stripped for this event
            changed = True
            if len(rebuilt) == 0:
                del hooks_table[event_key]
            else:
                hooks_table[event_key] = rebuilt

        if len(hooks_table) == 0:
            del doc["hooks"]
            changed = True

        if changed:
            base.dump_toml(cfg, doc)

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


def _managed_basenames_per_event(
    codex_hooks: list[dict],
) -> dict[str, set[str]]:
    """Map each codex event the registry manages to the set of script
    basenames it owns under that event. Keying per-event is the migration
    invariant: a user could legally route the same script basename through
    a different event (e.g. PreToolUse) than the one the registry manages
    (SessionStart), and that cross-event entry must survive the cleanup."""
    out: dict[str, set[str]] = {}
    for item in codex_hooks:
        event = item.get("event")
        script = item.get("script")
        if event and script:
            out.setdefault(event, set()).add(Path(script).name)
    return out


def _prune_event_blocks(
    event_array: object, event_managed: set[str]
) -> "tomlkit.items.AoT | None":
    """Return a rebuilt AoT containing only the blocks the caller should
    keep, or ``None`` when no block matched ``event_managed`` (the
    caller short-circuits in that case to avoid a no-op rewrite).

    Extracted from ``_clean_legacy_config_toml_hooks`` so the cleanup
    stays under the 40-line function budget — the loop is one of two
    natural seams (the other is managed-set building, lifted into the
    caller above)."""
    kept = [
        block
        for block in event_array
        if not _is_managed_legacy_block(block, event_managed)
    ]
    if len(kept) == len(event_array):
        return None
    # tomlkit AoT has no in-place item delete that survives the
    # round-trip cleanly; rebuild the array from the kept blocks.
    rebuilt = tomlkit.aot()
    for block in kept:
        rebuilt.append(block)
    return rebuilt


def _is_array_of_tables(value: object) -> bool:
    """tomlkit exposes [[hooks.SessionStart]] as an Array-of-Tables. Other
    `hooks.<key>` values (a scalar typo, a sub-table for some future
    feature) are not arrays and must not be walked."""
    return isinstance(value, list) or isinstance(value, tomlkit.items.AoT)


def _is_managed_legacy_block(
    block: object, managed_basenames: set[str]
) -> bool:
    """A [[hooks.<event>]] block was written by the retired
    agents/hooks/sync.sh iff its first inner hook command points at
    .codex/hooks/<basename> for one of the basenames currently in the
    registry. Tolerates quoted vs unquoted `$HOME` (sync.sh wrote both
    forms across its history) by stripping outer quotes from the script
    token before path-matching."""
    inner = block.get("hooks") if hasattr(block, "get") else None
    if not isinstance(inner, (list, tomlkit.items.AoT)) or len(inner) == 0:
        return False
    first = inner[0]
    cmd = first.get("command", "") if hasattr(first, "get") else ""
    if not isinstance(cmd, str):
        return False
    tokens = cmd.strip().split()
    if not tokens:
        return False
    script_token = tokens[-1].strip("'").strip('"')
    if "/.codex/hooks/" not in script_token:
        return False
    return Path(script_token).name in managed_basenames
