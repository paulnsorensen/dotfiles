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
- **codex** carries it in CLI ``-c`` overrides (no whole-file MCP flag exists).
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
  world + no-user-config + ephemeral, but *not* a ``--tools`` analog. The
  profile's ``tools`` / ``permissions_deny`` / ``enabled_plugins`` are
  ignored-with-warning. Tracked in a follow-up ticket.
- **codex ``/etc/codex/config.toml``** still loads under
  ``--ignore-user-config`` (it drops only the *user* layer). On a machine
  with a system config that can inject servers/approvals. Out of scope.
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
import sys
import tempfile
from pathlib import Path

from agent_profile.env import load_dotenv, resolve_env_value, resolve_item_env
from agent_profile.parse import Manifest
from agent_profile.renderers.base import mcp_server_entry
from agent_profile.renderers.opencode import (
    _OPENCODE_MCP_DEFAULT,
    _mcp_server_record,
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


# ─── codex (CLI -c overrides; no whole-file MCP flag) ────────────────


def _codex_toml_value(value: object) -> str:
    """Render a Python value as the RHS of a codex ``-c key=<value>`` override.

    Codex parses the value as TOML, falling back to the raw string literal
    when it doesn't parse (config_override.rs). A JSON-encoded string and a
    JSON-encoded list of strings are valid TOML scalars/arrays, so
    :func:`json.dumps` produces the correct ``"npx"`` / ``["-y","x"]`` forms
    in one call."""
    return json.dumps(value)


def _codex_mcp_overrides(manifest: Manifest) -> list[str]:
    """Lower the profile's MCPs to ``-c mcp_servers.<n>.*`` override flags.

    Codex has no ``--mcp-config <file>`` analog, so each server is injected
    key-by-key. Inline ``${VAR}`` env refs resolve from ``.env`` (D4), failing
    loud when unset — parity with the claude path. HTTP/SSE MCPs carry
    ``url``/``type`` instead of ``command``/``args``; stdio MCPs carry
    ``command`` and optional ``args``/``env``."""
    dotenv = _dotenv()
    flags: list[str] = []
    for raw in manifest.mcps:
        mcp = resolve_item_env(raw, dotenv)
        name = mcp["name"]
        prefix = f"mcp_servers.{name}"
        if mcp.get("url") or mcp.get("type") in ("http", "sse"):
            flags += ["-c", f"{prefix}.url={_codex_toml_value(mcp['url'])}"]
            flags += [
                "-c",
                f"{prefix}.type={_codex_toml_value(mcp.get('type') or 'http')}",
            ]
        else:
            flags += [
                "-c",
                f"{prefix}.command={_codex_toml_value(mcp['command'])}",
            ]
            if mcp.get("args") is not None:
                flags += [
                    "-c",
                    f"{prefix}.args={_codex_toml_value(mcp['args'])}",
                ]
        env = mcp.get("env")
        if isinstance(env, dict):
            for key, val in env.items():
                flags += [
                    "-c",
                    f"{prefix}.env.{key}={_codex_toml_value(str(val))}",
                ]
    return flags


def _codex_system_prompt(manifest: Manifest, profile_dir: Path) -> list[str]:
    """Inject the profile's system prompt as codex's ``instructions`` config.

    Codex's ``instructions`` key takes the system-instruction *content*
    string, not a file path (config_toml.rs). There is no documented
    ``instructions_file`` key, so the file is read and passed inline; codex's
    ``-c`` parser falls back to a raw string literal when the markdown body
    isn't valid TOML (config_override.rs), so arbitrary content round-trips."""
    if not manifest.system_prompt:
        return []
    sp = profile_dir / manifest.system_prompt
    if not sp.is_file():
        raise IsolationError(
            f"system_prompt file not found for profile '{manifest.name}': {sp}"
        )
    return ["-c", f"instructions={_codex_toml_value(sp.read_text())}"]


def _build_isolated_codex(
    manifest: Manifest,
    profile_dir: Path,
    scratch: Path | None = None,
) -> tuple[list[str], dict[str, str]]:
    """Assemble the codex closed-world ``-c`` overrides for an isolated profile.

    ``--ignore-user-config`` drops the user ``config.toml`` layer (the
    ``--setting-sources ""`` analog); ``--ephemeral`` skips session-rollout
    persistence; ``-c mcp_servers.<n>.*`` injects the profile's MCP world
    inline; ``-c instructions=<content>`` injects the system prompt.

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

    flags = ["--ignore-user-config", "--ephemeral"]
    flags += _codex_mcp_overrides(manifest)
    flags += _codex_system_prompt(manifest, profile_dir)
    return flags, dict(manifest.env)


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
        return []
    try:
        data = yaml.safe_load(registry.read_text()) or {}
    except yaml.YAMLError:
        return []
    mcps = data.get("mcps")
    if not isinstance(mcps, dict):
        return []
    names: list[str] = []
    for name, entry in mcps.items():
        item = entry if isinstance(entry, dict) else {}
        if includes_harness(item, "opencode", _OPENCODE_MCP_DEFAULT):
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
        block[mcp["name"]] = _mcp_server_record(mcp)
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
    The profile's ``env`` is injected alongside.

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

    env: dict[str, str] = {"OPENCODE_CONFIG_CONTENT": json.dumps(config)}
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
