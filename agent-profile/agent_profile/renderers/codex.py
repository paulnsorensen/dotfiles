"""codex.py — render an agent profile into Codex CLI's project layout.

Behavioral port of ``agent-profile/renderers/codex.sh``. Codex natively
reads:

  - ``.codex/agents/<n>.toml``       — subagents (TOML)
  - ``.agents/skills/<n>/SKILL.md``  — skills (cross-harness shared dir)
  - ``.codex/hooks.json``            — hooks (JSON object with a top-level
                                       ``hooks`` map, written only when
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
import subprocess
import sys
from pathlib import Path

import tomlkit

from agent_profile import shared
from agent_profile.env import load_dotenv
from agent_profile.parse import Manifest
from agent_profile.permissions import (
    bash_argv,
    named_mcp_tools,
    parse_mcp_rule,
    whole_server_mcp_allows,
)
from agent_profile.renderers import base

# Codex's MCP membership default matches the bash select() fallback
# `(.harnesses // ["claude","codex"])`.
_CODEX_MCP_DEFAULT = ("claude", "codex")

# ap owns this rules file under ~/.codex/rules/; the TUI-owned
# default.rules is never touched, so a clean uninstall = unlink this file.
_RULES_REL = ".codex/rules/ap-canonical.rules"

# Lever-1 Codex decision per canonical channel (most-restrictive-wins:
# forbidden > prompt > allow).
_ALLOW_DECISION = "allow"
_DENY_DECISION = "forbidden"


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
    mcp_default = _CODEX_MCP_DEFAULT

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        out_files: list[str] = []
        target = Path(target)
        self._write_agents(manifest, target, out_files)
        self._write_skills(manifest, target, out_files)
        self._write_hooks(manifest, target, out_files)
        self._write_mcps(manifest, target)
        self._render_native_plugins(manifest)
        self._write_rules(manifest, target, out_files)
        self._write_mcp_tool_scopes(manifest, target)
        self._warn_commands(manifest)
        return out_files

    def clean(self, manifest: Manifest, target: Path) -> None:
        self._clean_mcps(manifest, Path(target))
        self._clean_rules(Path(target))
        self._clean_mcp_tool_scopes(manifest, Path(target))
        self._clean_native_plugins(manifest)

    def prune_mcps(self, manifest: Manifest, target: Path) -> None:
        """Evict dropped MCP servers from config.toml's [mcp_servers]
        (install reconcile). Codex's clean is MCP-only, so this is the same
        operation; ``manifest`` holds only the dropped servers."""
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
        for item in base.agents_for(manifest, "codex"):
            if item.get("_from_codex_native_plugin"):
                continue  # native plugin delivers agents via codex plugin install
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
        for item in base.skills_for(manifest, "codex"):
            if item.get("_from_codex_native_plugin"):
                continue  # native plugin delivers skills via codex plugin install
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

    # ─── native plugins (codex_native marketplace install) ──────────────
    # Mirrors the claude renderer's native pass: a codex_native plugin is
    # installed via codex's own CLI (`codex plugin marketplace add <root>` +
    # `codex plugin add <name>@<marketplace>`) instead of being decomposed
    # into config.toml MCP + .agents/skills. Codex owns the install; ap only
    # drives the CLI. Idempotent on re-sync: re-runs use check=False and
    # tolerate "already added/installed".
    def _render_native_plugins(self, manifest: Manifest) -> None:
        for entry in manifest.native_plugins:
            if not entry.get("codex_native"):
                continue
            self._install_codex_native_plugin(entry)

    def _install_codex_native_plugin(self, entry: dict) -> None:
        name = entry["name"]
        marketplace_name = entry.get("marketplace_name", name)
        marketplace_root = entry["marketplace_root"]
        expanded = os.path.expandvars(os.path.expanduser(str(marketplace_root)))
        # marketplace add is fatal on failure: if it fails, the plugin gets
        # NEITHER the native install NOR the decomposed MCP (DEDUP already
        # stripped codex), so the plugin silently vanishes from codex. Raising
        # turns that silent strip into a loud render failure. Idempotency is
        # preserved by skipping the add when the marketplace is already
        # registered, so a re-sync never re-adds (and never sees the benign
        # "already exists" nonzero).
        if not self._marketplace_registered(marketplace_name):
            self._codex_cli_strict(
                ["codex", "plugin", "marketplace", "add", expanded],
                f"marketplace add {expanded}",
            )
        # plugin add stays tolerant: "already installed" on re-sync is benign.
        self._codex_cli(
            ["codex", "plugin", "add", f"{name}@{marketplace_name}"],
            f"plugin add {name}@{marketplace_name}",
        )

    def _clean_native_plugins(self, manifest: Manifest) -> None:
        for entry in manifest.native_plugins:
            if not entry.get("codex_native"):
                continue
            name = entry["name"]
            marketplace_name = entry.get("marketplace_name", name)
            self._codex_cli(
                ["codex", "plugin", "remove", f"{name}@{marketplace_name}"],
                f"plugin remove {name}@{marketplace_name}",
            )
            self._codex_cli(
                ["codex", "plugin", "marketplace", "remove", marketplace_name],
                f"marketplace remove {marketplace_name}",
            )

    @staticmethod
    def _marketplace_registered(marketplace_name: str) -> bool:
        """True if ``marketplace_name`` already appears in
        ``codex plugin marketplace list``. A missing codex binary or a failed
        list returns False (let the add attempt run and surface the real error).
        """
        try:
            result = subprocess.run(
                ["codex", "plugin", "marketplace", "list"],
                check=False,
                capture_output=True,
                text=True,
            )
        except FileNotFoundError:
            return False
        if result.returncode != 0:
            return False
        return any(
            line.split()[:1] == [marketplace_name]
            for line in result.stdout.splitlines()
        )

    @staticmethod
    def _codex_cli_strict(argv: list[str], label: str) -> None:
        """Run a codex plugin CLI command, failing loud on a nonzero exit.

        Used for the marketplace-add step, whose failure would otherwise strip
        the plugin from codex silently. A missing codex binary is still a no-op
        (nothing decomposed, nothing to leave inconsistent); a nonzero exit
        (e.g. an unparseable marketplace manifest) raises ``RuntimeError`` so
        the render fails instead of dropping the plugin.
        """
        try:
            result = subprocess.run(
                argv, check=False, capture_output=True, text=True
            )
        except FileNotFoundError:
            return  # codex CLI not present; nothing to install
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip()
            raise RuntimeError(
                f"'codex {label}' exited {result.returncode}. {detail}"
            )

    @staticmethod
    def _codex_cli(argv: list[str], label: str) -> None:
        """Run a codex plugin CLI command, tolerant of re-runs.

        check=False so a repeated add/remove (already present / already gone)
        does not hard-fail the render. A missing codex binary is a no-op:
        nothing decomposed into config for the plugin, so there is nothing to
        leave inconsistent."""
        try:
            result = subprocess.run(
                argv, check=False, capture_output=True, text=True
            )
        except FileNotFoundError:
            return  # codex CLI not present; nothing to install/clean
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip()
            print(
                f"    ap: 'codex {label}' exited {result.returncode}. {detail}",
                file=sys.stderr,
            )

    # ─── hooks ──────────────────────────────────────────────────────────
    # Codex reads .codex/hooks.json as a JSON object with a top-level
    # "hooks" map: event -> matcher groups -> command handlers. The file is
    # written only when at least one hook is codex-harnessed; the hook script
    # is copied to .codex/hooks/<basename>; user-level hooks.json stores the
    # absolute copied path because Codex runs hook commands from the session cwd,
    # not from ~/.codex.
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
        hook_groups: dict[str, list[dict]] = {}
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

            group = _codex_hook_group(
                command=f"bash {abs_script}", matcher=matcher, timeout=timeout
            )
            hook_groups.setdefault(str(event), []).append(group)

        rel = ".codex/hooks.json"
        abs_path = base_dir / rel
        abs_path.parent.mkdir(parents=True, exist_ok=True)
        abs_path.write_text(json.dumps({"hooks": hook_groups}, indent=2) + "\n")
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

    # ─── lever 1: canonical permission rules (Starlark) ─────────────────
    # Codex's execpolicy consumes prefix_rule() entries from .rules files it
    # scans under each config layer at startup (developers.openai.com/codex/
    # exec-policy). ap writes its OWN file (ap-canonical.rules), never the
    # TUI-owned default.rules, so a clean uninstall is a single unlink. Only
    # the Bash(...) subset of the canonical lists maps to execpolicy: a
    # Bash(<cmd>:*) allow becomes decision="allow", a deny becomes
    # decision="forbidden" (most-restrictive-wins). Non-Bash canonical
    # entries (Edit/Write/Read/Grep/Glob/Skill) are not shell commands —
    # Codex governs those via sandbox/posture — and mcp__* goes to lever 3.
    def _write_rules(
        self, manifest: Manifest, target: Path, out_files: list[str]
    ) -> None:
        rules = _collect_prefix_rules(manifest)
        if not rules:
            # SSOT: no Bash rule remains -> unlink any stale ap-canonical.rules
            # so a prior render's execpolicy floor is not stranded.
            self._clean_rules(target)
            return
        base_dir = Path(str(target).rstrip("/"))
        abs_path = base_dir / _RULES_REL
        abs_path.parent.mkdir(parents=True, exist_ok=True)
        abs_path.write_text(_render_rules_file(rules))
        shared.track_file(out_files, _RULES_REL)

    def _clean_rules(self, target: Path) -> None:
        """Unlink ap's canonical rules file (the TUI's default.rules is never
        touched, so nothing else under rules/ is ours to prune)."""
        abs_path = Path(str(target).rstrip("/")) / _RULES_REL
        if abs_path.is_file():
            abs_path.unlink()

    # ─── lever 3: MCP-tool scoping ──────────────────────────────────────
    # mcp__server__tool allow -> [mcp_servers.<server>] enabled_tools += tool
    # mcp__server__*    allow -> server stays enabled, no restriction
    # mcp__server__tool deny  -> disabled_tools += tool
    # Merge-preserve every user key/comment via the tomlkit round-trip (same
    # surface _write_mcps uses for [mcp_servers]).
    def _write_mcp_tool_scopes(self, manifest: Manifest, target: Path) -> None:
        managed = _managed_mcp_servers(manifest)
        if not managed:
            return
        scopes = _collect_mcp_tool_scopes(manifest)
        cfg = Path(str(target).rstrip("/")) / ".codex" / "config.toml"
        doc = base.load_toml(cfg)
        servers = doc.get("mcp_servers")

        # SSOT: for every server this pass manages, clear ANY prior
        # enabled/disabled key first, then re-add only the newly-computed
        # non-empty sets. A tool dropped from the canonical lists (or a
        # server downgraded to a whole-server allow) thus leaves no stale key.
        for server in managed:
            entry = servers.get(server) if servers is not None else None
            enabled, disabled = scopes.get(server, (set(), set()))
            if entry is not None:
                for key in ("enabled_tools", "disabled_tools"):
                    if key in entry:
                        del entry[key]
                if len(entry) == 0:
                    del servers[server]
                    entry = None
            if not enabled and not disabled:
                continue  # nothing to add for this server
            if servers is None:
                servers = tomlkit.table()
                doc["mcp_servers"] = servers
            if entry is None:
                entry = tomlkit.table()
                servers[server] = entry
            if enabled:
                entry["enabled_tools"] = sorted(enabled)
            if disabled:
                entry["disabled_tools"] = sorted(disabled)

        if servers is not None and len(servers) == 0:
            del doc["mcp_servers"]
        if len(doc) == 0:
            if cfg.is_file():
                cfg.unlink()
            return
        base.dump_toml(cfg, doc)

    def _clean_mcp_tool_scopes(self, manifest: Manifest, target: Path) -> None:
        """Remove the ap-written ``enabled_tools``/``disabled_tools`` keys
        from each scoped server, pruning a server table only if it now has no
        keys left (so a server still carrying its user ``command``/``args``
        survives)."""
        managed = _managed_mcp_servers(manifest)
        if not managed:
            return
        cfg = Path(str(target).rstrip("/")) / ".codex" / "config.toml"
        if not cfg.is_file():
            return
        doc = base.load_toml(cfg)
        servers = doc.get("mcp_servers")
        if servers is None:
            return
        for server in managed:
            entry = servers.get(server)
            if entry is None:
                continue
            for key in ("enabled_tools", "disabled_tools"):
                if key in entry:
                    del entry[key]
            if len(entry) == 0:
                del servers[server]
        if len(servers) == 0:
            del doc["mcp_servers"]
        if len(doc) == 0:
            cfg.unlink()
            return
        base.dump_toml(cfg, doc)

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

    def render_project_permissions(
        self, manifest: Manifest, target: Path, *, local: bool = False
    ) -> list[str]:
        """Write ONLY canonical perms into <target>/.codex/ (rules + config.toml tool scopes).

        Codex has no gitignored personal-settings analog: under ``local=True``
        this is a no-op (the CLI emits a one-line note at the call site)."""
        if local:
            return []
        out: list[str] = []
        self._write_rules(manifest, Path(target), out)
        self._write_mcp_tool_scopes(manifest, Path(target))
        return out


def _collect_prefix_rules(manifest: Manifest) -> list[tuple[list[str], str]]:
    """Lower the canonical Bash(...) subset to ``(pattern, decision)`` pairs.

    Allow entries -> ``"allow"``; deny entries -> ``"forbidden"``. Non-Bash
    canonical entries return ``None`` from :func:`bash_argv` and are dropped.
    Order: allow rules first (sorted), then deny rules (sorted) — Codex's
    most-restrictive-wins makes file order immaterial, but a stable order
    keeps the golden byte-identical."""
    settings = manifest.settings
    out: list[tuple[list[str], str]] = []
    for rule in sorted(settings.get("permissions_allow") or []):
        argv = bash_argv(rule)
        if argv:
            out.append((argv, _ALLOW_DECISION))
    for rule in sorted(settings.get("permissions_deny") or []):
        argv = bash_argv(rule)
        if argv:
            out.append((argv, _DENY_DECISION))
    return out


def _render_rules_file(rules: list[tuple[list[str], str]]) -> str:
    """Render the Starlark ``.rules`` file body. One ``prefix_rule()`` per
    canonical Bash rule; ``pattern`` is the argv prefix, ``decision`` the
    lowered action. A header marks the file as ap-managed."""
    lines = [
        (
            "# Managed by ap (agent-profile) — canonical cross-harness "
            "permission rules."
        ),
        (
            "# Do not edit; regenerated on every `dots sync`. The TUI-owned "
            "default.rules is untouched."
        ),
        "",
    ]
    for pattern, decision in rules:
        pattern_lit = ", ".join(json.dumps(tok) for tok in pattern)
        lines.append("prefix_rule(")
        lines.append(f"    pattern = [{pattern_lit}],")
        lines.append(f"    decision = {json.dumps(decision)},")
        lines.append(")")
    return "\n".join(lines) + "\n"


def _collect_mcp_tool_scopes(
    manifest: Manifest,
) -> dict[str, tuple[set[str], set[str]]]:
    """Lower the canonical ``mcp__*`` subset to per-server
    ``(enabled_tools, disabled_tools)`` sets.

    ``mcp__s__tool`` allow -> enabled_tools; ``mcp__s__tool`` deny ->
    disabled_tools. A ``mcp__s__*`` allow names no tool, so it adds no
    enabled entry (the server stays enabled with no restriction); a
    ``mcp__s__*`` deny is a whole-server disable, which Codex expresses by
    omitting the server, not by a tool list, so it too names no tool and is
    out of scope here.

    A whole-server ``mcp__s__*`` allow WINS over any named-tool allow for
    the same server: the server must stay unrestricted (no ``enabled_tools``
    key), so its named-allow tools are dropped here. The deny channel is
    independent — ``disabled_tools`` for that server survives. Only servers
    that gain at least one named tool (after the whole-server drop) reach the
    result."""
    settings = manifest.settings
    enabled = named_mcp_tools(settings.get("permissions_allow") or [])
    disabled = named_mcp_tools(settings.get("permissions_deny") or [])
    whole = whole_server_mcp_allows(settings.get("permissions_allow") or [])
    for server in whole:
        enabled.pop(server, None)
    servers = set(enabled) | set(disabled)
    return {
        s: (enabled.get(s, set()), disabled.get(s, set())) for s in servers
    }


def _managed_mcp_servers(manifest: Manifest) -> set[str]:
    """Every server this render pass manages — i.e. named by ANY ``mcp__*``
    canonical rule (named-tool OR whole-server ``mcp__<server>__*``), across
    both the allow and deny lists.

    ``_write_mcp_tool_scopes`` clears each managed server's prior
    enabled/disabled keys before re-adding the freshly-computed sets, so the
    managed set must include whole-server allows (whose set is empty): a
    server downgraded to a whole-server allow still needs its stale
    ``enabled_tools`` cleared (SSOT). Servers carrying NO ``mcp__*`` rule are
    not ours to touch and stay out of the set."""
    settings = manifest.settings
    out: set[str] = set()
    for channel in ("permissions_allow", "permissions_deny"):
        for rule in settings.get(channel) or []:
            parsed = parse_mcp_rule(rule)
            if parsed:
                out.add(parsed[0])
    return out



def _codex_hook_group(
    *, command: str, matcher: object, timeout: object
) -> dict[str, object]:
    handler: dict[str, object] = {"type": "command", "command": command}
    if timeout not in (None, ""):
        handler["timeout"] = int(timeout)

    group: dict[str, object] = {"hooks": [handler]}
    if matcher:
        group["matcher"] = str(matcher)
    return group

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
