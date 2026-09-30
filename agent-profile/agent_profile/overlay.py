"""overlay.py — launch-time isolation overlay, dispatched per harness.

The retired ``ccp`` zsh function launched ``claude`` as a closed world:
strict MCP scoping (``--strict-mcp-config --mcp-config <generated>``),
inherited settings stripped (``--setting-sources ""``), a tool whitelist
(``--tools``), a profile system-prompt append, a generated settings file
carrying ``permissions.deny``, per-profile env, and verbatim extra args.

This module rebuilds that closed world from an ``isolated: true`` profile so
the behaviour lives inside ``ap`` instead of zsh. The three isolating
harnesses reach the closed world by *different mechanisms* but fit one
``(flags, env)`` contract:

- **claude** carries isolation in CLI flags (the original ccp parity).
- **codex** carries it in a redirected ``CODEX_HOME`` (a fresh dir with a
  generated ``config.toml`` + an ``auth.json`` symlink), since codex 0.135.0
  has no top-level no-user-config flag.

:func:`build_isolated_launch` selects a per-harness builder from
:data:`_ISOLATION_BUILDERS` and returns ``(flags, env)``;
``cli._launch_isolated`` injects ``env`` into ``os.environ`` then execs
``harness + flags + exec_args`` identically for both. Cursor and Copilot
have no runtime-isolation levers, so an isolated launch against them raises
:class:`IsolationError` on the dispatch miss.

Per-harness caveats (also in AGENTS.md § Profile System):

- **codex drops built-in-tool restriction.** Codex has no per-launch
  built-in-tool whitelist, so an isolated codex profile gets a redirected
  ``CODEX_HOME`` with generated config, hooks, agents, rules, skills, and MCP
  tool scopes — but not a ``--tools`` analog. ``tools`` / ``enabled_plugins`` /
  ``extra_args`` are ignored-with-warning.
- **codex auth.json symlink is File-mode only.** Login is preserved by
  symlinking ``<CODEX_HOME>/auth.json`` -> ``~/.codex/auth.json``, which
  works for ``File`` auth-storage mode. Keyring users must set
  ``CODEX_ACCESS_TOKEN`` instead — known limitation.
- **codex ``/etc/codex/config.toml``** (system config) still loads
  regardless of ``CODEX_HOME`` (it is a separate load path). On a machine
  with one it can inject servers/approvals. Out of scope. Project
  ``.codex/config.toml`` is loaded but inert (the fresh config trusts no
  projects).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

from agent_profile.env import load_layered_env, resolve_env_value, resolve_item_env
from agent_profile.parse import Manifest
from agent_profile.renderers.base import mcp_server_entry
from agent_profile.renderers.codex import CodexRenderer, _collect_mcp_tool_scopes


class IsolationError(Exception):
    """Raised when an isolated profile targets a harness with no
    runtime-isolation mechanism."""


def _dotenv() -> dict[str, str]:
    """Load the repository's non-secret ``.env`` settings."""
    repo_root = Path(
        os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles")
    )
    return load_layered_env(repo_root)


def _warn_ignored(name: str, harness: str) -> None:
    """Print the ignore-with-warning line for a claude-only / codex-dropped
    profile field (spec D3). Never fails, never silently drops — the operator
    sees exactly which field had no effect on this harness."""
    print(f"    ap: field {name} ignored for harness {harness}", file=sys.stderr)


# ─── claude (original ccp parity) ────────────────────────────────────


def _server_record(mcp: dict) -> dict:
    """Project one profile MCP to a Claude ``mcpServers`` record.

    Supports the two shapes the ccp profiles used: a stdio MCP
    (``command``/``args``/``env`` — delegated to the shared
    :func:`mcp_server_entry`) and an HTTP MCP (``type: http`` + ``url``, e.g.
    notion), which carries ``type``/``url`` (and ``headers`` when present)
    instead of a command."""
    if mcp.get("url") or mcp.get("type") in ("http", "sse"):
        entry: dict = {"type": mcp.get("type") or "http", "url": mcp["url"]}
        if mcp.get("headers") is not None:
            entry["headers"] = mcp["headers"]
        return entry
    return mcp_server_entry(mcp)


def _write_mcp_config(manifest: Manifest, scratch: Path) -> Path:
    """Write the profile's MCPs to an ephemeral strict ``.mcp.json``.

    Includes every MCP the profile declares (membership defaulted to all
    harnesses); ``gate_unless`` is *not* applied — an isolated launch is a
    deliberate closed world, not the auto-render path. Inline ``${VAR}`` env
    refs resolve at render time from ``.env`` (D4), failing loud when unset —
    parity with the retired ``gen-profile-mcp.sh``."""
    dotenv = _dotenv()
    servers = {
        mcp["name"]: _server_record(resolve_item_env(mcp, dotenv))
        for mcp in manifest.mcps
    }
    path = scratch / "mcp.json"
    path.write_text(json.dumps({"mcpServers": servers}, indent=2) + "\n")
    return path


def _write_settings(manifest: Manifest, scratch: Path) -> Path | None:
    """Write an ephemeral ``settings.json`` carrying ``permissions.allow`` /
    ``permissions.deny`` and ``enabledPlugins``.

    Returns ``None`` when the profile declares none of them (no ``--settings``
    flag emitted in that case). ``permissions.allow`` restores the per-profile
    auto-approve entries the migrated ``settings-merge.json`` profiles carried;
    ``enabledPlugins`` restores their curated per-session plugin set (the old
    ccp passed both through ``--settings``). Without these the closed-world
    launch (``--setting-sources ""``) would prompt on every call and load no
    profile plugins."""
    if (
        not manifest.permissions_allow
        and not manifest.permissions_deny
        and not manifest.enabled_plugins
    ):
        return None
    settings: dict = {}
    permissions: dict[str, list[str]] = {}
    if manifest.permissions_allow:
        permissions["allow"] = list(manifest.permissions_allow)
    if manifest.permissions_deny:
        permissions["deny"] = list(manifest.permissions_deny)
    if permissions:
        settings["permissions"] = permissions
    if manifest.enabled_plugins:
        settings["enabledPlugins"] = dict(manifest.enabled_plugins)
    path = scratch / "settings.json"
    path.write_text(json.dumps(settings, indent=2) + "\n")
    return path


def _collect_plugin_skills(manifest: Manifest) -> list[tuple[str, Path]]:
    """Resolve ``(name, source_dir)`` for every skill that should ride into the
    closed world via the generated ``--plugin-dir``.

    Two origins, one destination:

    - **``path:`` skills** are copied from the profile's own tree
      (``<_source_dir>/<path>``) — always available, no network.
    - **``source:`` skills** were fetched to the global ``skills`` CLI store by
      the install half of ``ap launch``; their folders are resolved from the
      lockfile (:func:`fetch.source_skill_names`) and copied from
      ``~/.agents/skills/<name>``. Absent from the store (offline / staged
      install / lockfile drift) → silently skipped, so the launch degrades to
      the local skills rather than failing.

    Native-plugin skills are excluded (the plugin delivers them itself)."""
    from agent_profile.fetch import (
        group_external_sources,
        installed_skill_dir,
        source_skill_names,
    )

    out: list[tuple[str, Path]] = []
    for s in manifest.skills:
        if not isinstance(s, dict) or s.get("_from_native_plugin"):
            continue
        path = s.get("path")
        if path:
            out.append((s["name"], Path(s["_source_dir"]) / path))

    for source, names, _pin in group_external_sources(manifest.skills):
        for name in source_skill_names(source, names):
            out.append((name, installed_skill_dir(name)))

    return out


def _write_skills_plugin(manifest: Manifest, scratch: Path) -> Path | None:
    """Project the profile's skills into a scratch plugin tree so a closed-world
    claude launch can load them.

    ``--setting-sources ""`` strips the user/project setting sources, which is
    exactly where skills live (``~/.claude/skills/<name>`` for the renderer's
    ``path:`` copies and ``~/.agents/skills/<name>`` for the ``skills`` CLI's
    ``source:`` fetches). Without a delivery channel those skills are invisible
    to the isolated session — MCPs, the system prompt and permissions each have
    a closed-world channel, but skills did not. A ``--plugin-dir`` tree loads
    its skills regardless of setting sources (it is how the ``todo`` profile
    ships ``todoist-flow``), so every resolved skill is copied under
    ``<scratch>/skills-plugin/skills/<name>/`` and surfaced via ``--plugin-dir``.

    Returns the plugin dir, or ``None`` when no skill resolves to a real source
    directory (so no empty ``--plugin-dir`` is emitted)."""
    skills = [(name, src) for name, src in _collect_plugin_skills(manifest) if src.is_dir()]
    if not skills:
        return None

    plugin_dir = scratch / "skills-plugin"
    meta_dir = plugin_dir / ".claude-plugin"
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / "plugin.json").write_text(
        json.dumps(
            {
                "name": f"{manifest.name}-skills",
                "description": f"Closed-world skills for the '{manifest.name}' profile",
                "version": "0.0.0",
            },
            indent=2,
        )
        + "\n"
    )

    for name, src in skills:
        dest = plugin_dir / "skills" / name
        if dest.exists():
            continue  # first writer wins (path: before source:); no clobber
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dest)

    return plugin_dir


def _build_isolated_claude(
    manifest: Manifest,
    profile_dir: Path,
    scratch: Path | None = None,
) -> tuple[list[str], dict[str, str]]:
    """Assemble the ``ccp``-parity ``claude`` flags for an isolated profile.

    Returns ``(flags, env)`` where ``flags`` is the claude argument list
    (without the leading ``claude``) and ``env`` is the per-profile env to
    inject before exec. ``scratch`` defaults to a fresh tmp dir holding the
    generated ``.mcp.json`` / ``settings.json`` (they outlive this call so
    the exec'd claude can read them).

    Flag order matches the spec sketch::

        --strict-mcp-config --mcp-config <gen>
        --setting-sources ""
        --tools <csv>                          (when tools declared)
        --append-system-prompt-file <profile>/<system_prompt>  (when declared)
        --settings <gen>                       (when permissions/enabledPlugins set)
        --plugin-dir <gen>                     (when local path: skills declared)
        <extra_args...>
    """
    if scratch is None:
        scratch = Path(tempfile.mkdtemp(prefix=f"ap-{manifest.name}-"))

    flags: list[str] = []

    mcp_path = _write_mcp_config(manifest, scratch)
    flags += ["--strict-mcp-config", "--mcp-config", str(mcp_path)]

    # Closed settings world: no inherited user/project settings.
    flags += ["--setting-sources", ""]

    if manifest.tools:
        flags += ["--tools", ",".join(manifest.tools)]

    if manifest.system_prompt:
        sp = profile_dir / manifest.system_prompt
        if not sp.is_file():
            raise IsolationError(
                f"system_prompt file not found for profile '{manifest.name}': {sp}"
            )
        flags += ["--append-system-prompt-file", str(sp)]

    settings_path = _write_settings(manifest, scratch)
    if settings_path is not None:
        flags += ["--settings", str(settings_path)]

    # Closed-world skill delivery: --setting-sources "" hides the rendered
    # skill trees, so the profile's path: and source: skills ride in via a
    # generated --plugin-dir (which loads regardless of setting sources).
    skills_plugin = _write_skills_plugin(manifest, scratch)
    if skills_plugin is not None:
        flags += ["--plugin-dir", str(skills_plugin)]

    # extra_args expand ${VAR} from the process env (DOTFILES_DIR et al.)
    # then .env, matching the retired launch.zsh which used $DOTFILES_DIR
    # directly. Fail loud on an unset reference.
    proc_env = {**_dotenv(), **os.environ}
    flags += [resolve_env_value(a, proc_env) for a in manifest.extra_args]

    return flags, dict(manifest.env)


# ─── codex (CODEX_HOME redirect + generated config.toml) ────────


def _codex_toml_value(value: object) -> str:
    """Render a Python value as the RHS of a ``key = <value>`` line in the
    generated ``config.toml``.

    A JSON-encoded string and a JSON-encoded list of strings are valid TOML
    scalars/arrays, so :func:`json.dumps` produces the correct ``"npx"`` /
    ``["-y","x"]`` forms for an MCP ``command`` / ``args`` / ``env`` value in
    one call.

    ``ensure_ascii=False`` is required, not cosmetic: with the default,
    :func:`json.dumps` emits a non-BMP character (e.g. an emoji in an MCP
    arg or env value) as a UTF-16 surrogate-pair backslash-u escape, which
    TOML rejects -- a unicode escape must be a single Unicode scalar value,
    and a surrogate code point is not. Emitting the literal UTF-8 character
    keeps a TOML basic string parseable, so arbitrary content round-trips."""
    return json.dumps(value, ensure_ascii=False)


_BARE_TOML_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def _codex_toml_key(key: str) -> str:
    """Render a TOML key (MCP name, env/header key) safely.

    A TOML bare key allows only ``[A-Za-z0-9_-]``; an unquoted key with a space
    fails to parse and one with a dot silently nests into a sub-table. Bare-safe
    keys pass through verbatim; anything else is quoted via the same
    string-quoting path as values (``[mcp_servers."has space"]``,
    ``"my.dotted" = ...``)."""
    return key if _BARE_TOML_KEY.match(key) else _codex_toml_value(key)


def _codex_mcp_tables(manifest: Manifest) -> str:
    """Render the profile's MCPs as ``[mcp_servers.<n>]`` TOML tables.

    Codex loads MCP servers from ``$CODEX_HOME/config.toml`` (it has no
    ``--mcp-config <file>`` flag), so the closed MCP world is generated into
    the isolated home's config rather than passed as ``-c`` overrides. Inline
    ``${VAR}`` env refs resolve from ``.env`` (D4), failing loud when unset —
    parity with the claude path. stdio MCPs carry ``command`` + optional
    ``args``/``env`` (an ``[mcp_servers.<n>.env]`` sub-table); HTTP/SSE MCPs
    carry ``url``/``type`` + optional ``headers`` (an
    ``[mcp_servers.<n>.http_headers]`` sub-table — verified against codex
    0.135.0 ``codex mcp get``)."""
    dotenv = _dotenv()
    scopes = _collect_mcp_tool_scopes(manifest)
    lines: list[str] = []
    for raw in manifest.mcps:
        mcp = resolve_item_env(raw, dotenv)
        name = _codex_toml_key(mcp["name"])
        lines.append(f"[mcp_servers.{name}]")
        if mcp.get("url") or mcp.get("type") in ("http", "sse"):
            url = mcp.get("url")
            if not url:
                raise IsolationError(f"http MCP '{name}' missing url")
            lines.append(f"url = {_codex_toml_value(url)}")
            lines.append(
                f"type = {_codex_toml_value(mcp.get('type') or 'http')}"
            )
            enabled, disabled = scopes.get(mcp["name"], (set(), set()))
            if enabled:
                lines.append(f"enabled_tools = {_codex_toml_value(sorted(enabled))}")
            if disabled:
                lines.append(f"disabled_tools = {_codex_toml_value(sorted(disabled))}")
            headers = mcp.get("headers")
            if isinstance(headers, dict) and headers:
                lines.append(f"\n[mcp_servers.{name}.http_headers]")
                for key, val in headers.items():
                    lines.append(f"{_codex_toml_key(key)} = {_codex_toml_value(str(val))}")
        else:
            lines.append(f"command = {_codex_toml_value(mcp['command'])}")
            if mcp.get("args") is not None:
                lines.append(f"args = {_codex_toml_value(mcp['args'])}")
            enabled, disabled = scopes.get(mcp["name"], (set(), set()))
            if enabled:
                lines.append(f"enabled_tools = {_codex_toml_value(sorted(enabled))}")
            if disabled:
                lines.append(f"disabled_tools = {_codex_toml_value(sorted(disabled))}")
            env = mcp.get("env")
            if isinstance(env, dict) and env:
                lines.append(f"\n[mcp_servers.{name}.env]")
                for key, val in env.items():
                    lines.append(f"{_codex_toml_key(key)} = {_codex_toml_value(str(val))}")
        lines.append("")
    return "\n".join(lines)


def _write_codex_config(
    manifest: Manifest, profile_dir: Path, codex_home: Path
) -> None:
    """Generate ``<codex_home>/config.toml`` for the isolated launch.

    Pins Codex's Auto permissions defaults before adding the shared preamble
    or an explicit profile prompt and MCP world. A profile ``system_prompt``
    remains a deliberate replacement through ``model_instructions_file``.
    Profiles without one receive the shared preamble through additive
    ``developer_instructions``. The fresh config trusts no projects, so any
    ``.codex/config.toml`` in the working tree is loaded but inert."""
    sections: list[str] = [
        ('approval_policy = "on-request"\n'
        'approvals_reviewer = "auto_review"\n'
        'sandbox_mode = "workspace-write"\n')
    ]
    shared_preamble = Path(
        os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles")
    ) / "agents" / "preamble.md"
    if not manifest.system_prompt and shared_preamble.is_file():
        sections.append(
            f"developer_instructions = {_codex_toml_value(shared_preamble.read_text())}\n"
        )
    if manifest.system_prompt:
        sp = profile_dir / manifest.system_prompt
        if not sp.is_file():
            raise IsolationError(
                f"system_prompt file not found for profile '{manifest.name}': {sp}"
            )
        sections.append(
            f"model_instructions_file = {_codex_toml_value(str(sp))}\n"
        )
    sections.append('\n[tui]\ninput_mode = "vim"\n')
    tables = _codex_mcp_tables(manifest)
    if tables:
        sections.append(tables)
    (codex_home / "config.toml").write_text("\n".join(sections))


def _codex_with_isolated_settings(manifest: Manifest) -> Manifest:
    settings = dict(manifest.settings)
    if manifest.permissions_allow:
        settings["permissions_allow"] = sorted(
            set(settings.get("permissions_allow") or []) | set(manifest.permissions_allow)
        )
    if manifest.permissions_deny:
        settings["permissions_deny"] = sorted(
            set(settings.get("permissions_deny") or []) | set(manifest.permissions_deny)
        )
    return replace(manifest, settings=settings)


def _move_codex_dir_child(codex_home: Path, rel: str) -> None:
    src = codex_home / ".codex" / rel
    if not src.exists():
        return
    dst = codex_home / rel
    if dst.exists():
        if dst.is_dir():
            shutil.rmtree(dst)
        else:
            dst.unlink()
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))


def _rewrite_root_hook_commands(codex_home: Path) -> None:
    hooks_json = codex_home / "hooks.json"
    if not hooks_json.is_file():
        return
    old = str(codex_home / ".codex" / "hooks")
    new = str(codex_home / "hooks")
    hooks_json.write_text(hooks_json.read_text().replace(old, new))


def _write_isolated_codex_profile(manifest: Manifest, codex_home: Path) -> None:
    """Project Codex-native profile files into the redirected CODEX_HOME root."""
    renderer = CodexRenderer()
    out: list[str] = []
    renderer._write_agents(manifest, codex_home, out)
    renderer._write_skills(manifest, codex_home, out)
    renderer._write_hooks(manifest, codex_home, out)
    renderer._write_rules(manifest, codex_home, out)
    for rel in ("agents", "hooks", "hooks.json", "lib", "reference", "rules"):
        _move_codex_dir_child(codex_home, rel)
    _rewrite_root_hook_commands(codex_home)


def _codex_cache_base() -> Path:
    """Parent dir for the per-launch ``CODEX_HOME``, under the user cache (not
    ``/tmp``).

    codex 0.135.0 refuses to install its PATH-helper binaries when
    ``CODEX_HOME`` is under a temp dir, printing a "could not update PATH"
    warning every isolated launch (``tempfile.mkdtemp``'s ``/tmp`` default
    tripped this). Rooting under ``$XDG_CACHE_HOME`` / ``~/.cache`` clears the
    warning and restores the PATH-helper install while keeping per-launch
    ephemeral accumulation (``ap launch`` execs and can't clean up post-exec)."""
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "ap-codex"
    base.mkdir(parents=True, exist_ok=True)
    return base


def _build_isolated_codex(
    manifest: Manifest,
    profile_dir: Path,
    scratch: Path | None = None,
) -> tuple[list[str], dict[str, str]]:
    """Assemble the codex closed world via a redirected ``CODEX_HOME``.

    Codex 0.135.0 has no top-level ``--ignore-user-config`` / ``--ephemeral``
    (those are ``codex exec`` subcommand flags — rejected by the bare
    interactive ``codex`` the launcher execs). Isolation is instead achieved
    by pointing ``CODEX_HOME`` at a fresh per-launch dir holding a generated
    ``config.toml`` plus Codex-native projections for hooks, agents, rules, and
    shared skills.
    With ``CODEX_HOME`` redirected, the user's ``~/.codex/config.toml`` is not
    loaded; ``flags`` is therefore empty and codex launches interactive.

    Login is preserved by symlinking ``<home>/auth.json`` -> the real
    ``~/.codex/auth.json`` (``FileAuthStorage`` reads ``<CODEX_HOME>/auth.json``
    and follows symlinks). ``scratch`` (the isolated home) matches the claude
    path's ephemeral-dir convention: a fresh ``tempfile.mkdtemp`` per launch
    that outlives this call so the exec'd codex can read it — rooted under the
    user cache (:func:`_codex_cache_base`), not ``/tmp`` (codex refuses its
    PATH-helper install under a temp dir). ``ap launch`` execs and cannot clean
    up post-exec, so these accumulate exactly like the claude path's generated
    ``.mcp.json`` / ``settings.json`` dirs.

    Caveats (also in the module docstring):

    - The ``auth.json`` symlink only works for ``File`` auth-storage mode.
      Keyring users (``cli_auth_credentials_store_mode = keyring``) must set
      ``CODEX_ACCESS_TOKEN`` instead — known limitation.
    - ``/etc/codex/config.toml`` (system config) still loads regardless of
      ``CODEX_HOME``; on a machine with one it can inject servers/approvals.
    - Project ``.codex/config.toml`` is loaded but inert (the fresh config
      trusts no projects).

    Built-in tool restriction is dropped (codex has no per-launch built-in
    tool whitelist — see module docstring + follow-up ticket): ``tools`` and
    ``enabled_plugins`` are ignored-with-warning, as are the claude-only
    ``extra_args`` (D3). Codex-native hooks, agents, rules, skills, and MCP
    tool scopes are written into the redirected home."""
    for name, present in (
        ("tools", bool(manifest.tools)),
        ("enabled_plugins", bool(manifest.enabled_plugins)),
        ("extra_args", bool(manifest.extra_args)),
    ):
        if present:
            _warn_ignored(name, "codex")

    if scratch is None:
        scratch = Path(tempfile.mkdtemp(dir=_codex_cache_base(), prefix=f"ap-{manifest.name}-codex-"))

    auth = Path.home() / ".codex" / "auth.json"
    link = scratch / "auth.json"
    if auth.is_file() and not link.exists():
        link.symlink_to(auth)

    codex_manifest = _codex_with_isolated_settings(manifest)
    _write_codex_config(codex_manifest, profile_dir, scratch)
    _write_isolated_codex_profile(codex_manifest, scratch)

    env = {"CODEX_HOME": str(scratch), **dict(manifest.env)}
    return [], env



# ─── dispatch ────────────────────────────────────────────────────────

_ISOLATION_BUILDERS = {
    "claude": _build_isolated_claude,
    "codex": _build_isolated_codex,
}


def build_isolated_launch(
    manifest: Manifest,
    profile_dir: Path,
    harness: str,
    scratch: Path | None = None,
) -> tuple[list[str], dict[str, str]]:
    """Build an isolated profile's ``(flags, env)`` for ``harness``.

    Selects the per-harness builder from :data:`_ISOLATION_BUILDERS`. A
    harness with no builder (Cursor or Copilot) raises
    :class:`IsolationError`; the caller lowers it to a clean ``CliError``."""
    builder = _ISOLATION_BUILDERS.get(harness)
    if builder is None:
        raise IsolationError(
            f"isolated profile '{manifest.name}': isolation unsupported for "
            f"harness '{harness}'"
        )
    return builder(manifest, profile_dir, scratch)
