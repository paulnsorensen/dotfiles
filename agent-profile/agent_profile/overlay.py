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
- **opencode** carries it in launch env vars (``OPENCODE_CONFIG_CONTENT`` +
  ``OPENCODE_PERMISSION``), since opencode has no "ignore inherited config"
  flag — isolation is an inline highest-layer override.

:func:`build_isolated_launch` selects a per-harness builder from
:data:`_ISOLATION_BUILDERS` and returns ``(flags, env)``;
``cli._launch_isolated`` injects ``env`` into ``os.environ`` then execs
``harness + flags + exec_args`` identically for all three. cursor/copilot/
crush have no runtime-isolation levers, so an isolated launch against them
raises :class:`IsolationError` on the dispatch miss (fail loud).

Per-harness caveats (also in AGENTS.md § Profile System):

- **codex drops tool/permission restriction.** Codex has no per-launch
  built-in-tool whitelist; an isolated codex profile gets the closed MCP
  world + a redirected ``CODEX_HOME``, but *not* a ``--tools`` analog. The
  profile's ``tools`` / ``permissions_deny`` / ``enabled_plugins`` are
  ignored-with-warning. Tracked in a follow-up ticket.
- **codex auth.json symlink is File-mode only.** Login is preserved by
  symlinking ``<CODEX_HOME>/auth.json`` -> ``~/.codex/auth.json``, which
  works for ``File`` auth-storage mode. Keyring users must set
  ``CODEX_ACCESS_TOKEN`` instead — known limitation.
- **codex ``/etc/codex/config.toml``** (system config) still loads
  regardless of ``CODEX_HOME`` (it is a separate load path). On a machine
  with one it can inject servers/approvals. Out of scope. Project
  ``.codex/config.toml`` is loaded but inert (the fresh config trusts no
  projects).
- **opencode cannot suppress project ``AGENTS.md`` / ``CLAUDE.md``
  auto-load** — the profile's system prompt is *appended* via
  ``instructions``; an isolated opencode launch is not a fully-closed
  instruction world.
- **opencode MCP-tool deny keys** (``mcp__*`` as ``OPENCODE_PERMISSION``
  freeform keys) are syntactically accepted but enforcement is unconfirmed —
  best-effort.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

from agent_profile.env import load_dotenv, resolve_env_value, resolve_item_env
from agent_profile.parse import Manifest
from agent_profile.renderers.base import mcp_server_entry
from agent_profile.renderers.opencode import (
    OPENCODE_MCP_DEFAULT,
    mcp_server_record,
)


class IsolationError(Exception):
    """Raised when an isolated profile is launched against a harness with no
    runtime-isolation mechanism (cursor/copilot/crush) — there is no builder
    in :data:`_ISOLATION_BUILDERS` for it, so the closed world can't be built."""


def _dotenv() -> dict[str, str]:
    """Load ``$DOTFILES_DIR/.env`` for render-time ``${VAR}`` resolution
    (spec D4), mirroring :func:`agent_profile.parse._repo_root`."""
    repo_root = Path(
        os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles")
    )
    return load_dotenv(repo_root / ".env")


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
            headers = mcp.get("headers")
            if isinstance(headers, dict) and headers:
                lines.append(f"\n[mcp_servers.{name}.http_headers]")
                for key, val in headers.items():
                    lines.append(f"{_codex_toml_key(key)} = {_codex_toml_value(str(val))}")
        else:
            lines.append(f"command = {_codex_toml_value(mcp['command'])}")
            if mcp.get("args") is not None:
                lines.append(f"args = {_codex_toml_value(mcp['args'])}")
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

    Sets ``model_instructions_file`` to the profile's system-prompt file
    (an absolute path — codex's ``instructions`` key is reserved/noop, and
    ``model_instructions_file`` is the documented way to inject a custom
    system prompt; verified in the live ``~/.codex/config.toml``). Appends
    the profile's MCP world as ``[mcp_servers.<n>]`` tables. The fresh config
    trusts no projects, so any ``.codex/config.toml`` in the working tree is
    loaded but inert."""
    sections: list[str] = []
    if manifest.system_prompt:
        sp = profile_dir / manifest.system_prompt
        if not sp.is_file():
            raise IsolationError(
                f"system_prompt file not found for profile '{manifest.name}': {sp}"
            )
        sections.append(
            f"model_instructions_file = {_codex_toml_value(str(sp))}\n"
        )
    tables = _codex_mcp_tables(manifest)
    if tables:
        sections.append(tables)
    (codex_home / "config.toml").write_text("\n".join(sections))


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
    ``config.toml`` (the profile's MCP world + ``model_instructions_file``).
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

    Tool/permission restriction is dropped (codex has no per-launch built-in
    tool whitelist — see module docstring + follow-up ticket): ``tools``,
    ``permissions_deny`` and ``enabled_plugins`` are ignored-with-warning, as
    are the claude-only ``extra_args`` (D3)."""
    for name, present in (
        ("tools", bool(manifest.tools)),
        ("permissions_deny", bool(manifest.permissions_deny)),
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

    _write_codex_config(manifest, profile_dir, scratch)

    env = {"CODEX_HOME": str(scratch), **dict(manifest.env)}
    return [], env


# ─── opencode (launch env vars; inline highest-layer override) ───────

# Claude permission token -> opencode permission key. NotebookEdit has no
# opencode equivalent (dropped + logged). ``mcp__*`` deny entries pass
# through as freeform keys verbatim (best-effort; enforcement unconfirmed).
_CLAUDE_TO_OPENCODE_PERM = {
    "Edit": "edit",
    "Write": "edit",
    "Read": "read",
    "Grep": "grep",
    "Glob": "glob",
    "Bash": "bash",
}


def _inherited_opencode_mcps() -> list[str]:
    """The MCP server names opencode inherits from its global config —
    i.e. every registry server whose membership includes ``opencode``.

    An isolated opencode launch sets each of these ``enabled: false`` in
    ``OPENCODE_CONFIG_CONTENT.mcp`` so the global-config servers (layer 2,
    not suppressible) don't leak into the closed world. Read from the same
    ``agents/mcp/registry.yaml`` the renderers use, applying opencode's MCP
    membership default. A missing/unparseable registry yields an empty list
    (the profile's own servers still render — the closed world just doesn't
    explicitly disable inherited ones)."""
    import yaml

    from agent_profile.renderers.base import includes_harness

    repo_root = Path(
        os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles")
    )
    registry = repo_root / "agents" / "mcp" / "registry.yaml"
    if not registry.is_file():
        print(
            f"ap: could not read opencode registry {registry} (file not found);"
            " inherited global MCPs may not be sealed",
            file=sys.stderr,
        )
        return []
    try:
        data = yaml.safe_load(registry.read_text()) or {}
    except yaml.YAMLError as exc:
        print(
            f"ap: could not read opencode registry {registry} ({exc});"
            " inherited global MCPs may not be sealed",
            file=sys.stderr,
        )
        return []
    mcps = data.get("mcps")
    if not isinstance(mcps, dict):
        return []
    names: list[str] = []
    for name, entry in mcps.items():
        item = entry if isinstance(entry, dict) else {}
        if includes_harness(item, "opencode", OPENCODE_MCP_DEFAULT):
            names.append(name)
    return names


def _opencode_mcp_block(manifest: Manifest) -> dict:
    """Build ``OPENCODE_CONFIG_CONTENT.mcp``: the profile's own servers plus
    every inherited server pinned ``enabled: false``.

    The profile servers reuse the opencode renderer's record shape (``type:
    local`` + ``{env:VAR}`` placeholder rewrite). Inherited servers the
    profile also declares are NOT disabled — the profile's own (enabled)
    record wins, matching opencode's deep-merge override."""
    block: dict[str, dict] = {}
    own = {mcp["name"] for mcp in manifest.mcps}
    for name in _inherited_opencode_mcps():
        if name not in own:
            block[name] = {"enabled": False}
    for mcp in manifest.mcps:
        block[mcp["name"]] = mcp_server_record(mcp)
    return block


def _opencode_permission(manifest: Manifest) -> dict:
    """Translate the profile's ``permissions_deny`` to an ``OPENCODE_PERMISSION``
    block (spec D2 — keeps ``review`` genuinely read-only on opencode).

    ``Edit``/``Write`` -> ``edit: deny``; ``Read``/``Grep``/``Glob``/``Bash``
    -> their opencode key. ``NotebookEdit`` has no opencode equivalent
    (dropped + logged). ``mcp__*`` entries pass through verbatim as freeform
    permission keys (best-effort). Returns ``{}`` when nothing maps."""
    perm: dict[str, str] = {}
    for entry in manifest.permissions_deny:
        if entry.startswith("mcp__"):
            perm[entry] = "deny"
            continue
        mapped = _CLAUDE_TO_OPENCODE_PERM.get(entry)
        if mapped is None:
            _warn_ignored(f"permissions_deny[{entry}]", "opencode")
            continue
        perm[mapped] = "deny"
    return perm


def _build_isolated_opencode(
    manifest: Manifest,
    profile_dir: Path,
    scratch: Path | None = None,
) -> tuple[list[str], dict[str, str]]:
    """Assemble the opencode closed-world launch env for an isolated profile.

    opencode has no isolation CLI flag, so ``flags`` is empty and isolation
    rides in the env: ``OPENCODE_CONFIG_CONTENT`` (highest non-managed layer —
    suppresses the global-config seed write) carries the profile MCP world
    (own servers + inherited servers ``enabled: false``) and the system
    prompt as an additive ``instructions`` file path; ``OPENCODE_PERMISSION``
    carries the ``permissions_deny`` translation (omitted when nothing maps).
    ``OPENCODE_DISABLE_PROJECT_CONFIG`` keeps a project-level ``opencode.json``
    in the working tree from leaking its MCPs into the closed world (the
    inherited-disable list only covers the global registry). The profile's
    ``env`` is injected alongside.

    ``enabled_plugins`` (claude marketplace) and ``extra_args`` (raw claude
    flags) are claude-only — ignored-with-warning (D3)."""
    for name, present in (
        ("enabled_plugins", bool(manifest.enabled_plugins)),
        ("extra_args", bool(manifest.extra_args)),
    ):
        if present:
            _warn_ignored(name, "opencode")

    config: dict = {"mcp": _opencode_mcp_block(manifest)}
    if manifest.system_prompt:
        sp = profile_dir / manifest.system_prompt
        if not sp.is_file():
            raise IsolationError(
                f"system_prompt file not found for profile '{manifest.name}': {sp}"
            )
        config["instructions"] = [str(sp)]

    env: dict[str, str] = {
        "OPENCODE_CONFIG_CONTENT": json.dumps(config),
        "OPENCODE_DISABLE_PROJECT_CONFIG": "true",
    }
    permission = _opencode_permission(manifest)
    if permission:
        env["OPENCODE_PERMISSION"] = json.dumps(permission)
    env.update(manifest.env)
    return [], env


# ─── dispatch ────────────────────────────────────────────────────────

_ISOLATION_BUILDERS = {
    "claude": _build_isolated_claude,
    "codex": _build_isolated_codex,
    "opencode": _build_isolated_opencode,
}


def build_isolated_launch(
    manifest: Manifest,
    profile_dir: Path,
    harness: str,
    scratch: Path | None = None,
) -> tuple[list[str], dict[str, str]]:
    """Build an isolated profile's ``(flags, env)`` for ``harness``.

    Selects the per-harness builder from :data:`_ISOLATION_BUILDERS`. A
    harness with no builder (cursor/copilot/crush — no runtime-isolation
    lever) raises :class:`IsolationError`; the caller lowers it to a clean
    ``CliError``."""
    builder = _ISOLATION_BUILDERS.get(harness)
    if builder is None:
        raise IsolationError(
            f"isolated profile '{manifest.name}': isolation unsupported for "
            f"harness '{harness}'"
        )
    return builder(manifest, profile_dir, scratch)
