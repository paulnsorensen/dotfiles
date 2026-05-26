"""overlay.py — launch-time isolation overlay (spec curd 6, decision D6).

The retired ``ccp`` zsh function launched ``claude`` as a closed world:
strict MCP scoping (``--strict-mcp-config --mcp-config <generated>``),
inherited settings stripped (``--setting-sources ""``), a tool whitelist
(``--tools``), a profile system-prompt append, a generated settings file
carrying ``permissions.deny``, per-profile env, and verbatim extra args.

This module rebuilds that overlay from an ``isolated: true`` profile so the
behaviour lives inside ``ap`` instead of zsh. :func:`build_isolated_flags`
materializes the two ephemeral files (``.mcp.json`` + ``settings.json``)
into a tmp dir and returns the assembled ``claude`` flag list plus the env
mapping to inject; ``cli.cmd_launch`` execvp's with them.

Only ``claude`` supports these flags; an isolated profile launched against
another harness fails loud (parity with ``ccp`` being claude-only).
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from agent_profile.env import load_dotenv, resolve_env_value, resolve_item_env
from agent_profile.parse import Manifest
from agent_profile.renderers.base import mcp_server_entry


class IsolationError(Exception):
    """Raised when an isolated profile is launched against a non-claude
    harness (only claude supports the ccp-parity flags)."""


def _dotenv() -> dict[str, str]:
    """Load ``$DOTFILES_DIR/.env`` for render-time ``${VAR}`` resolution
    (spec D4), mirroring :func:`agent_profile.parse._repo_root`."""
    repo_root = Path(
        os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles")
    )
    return load_dotenv(repo_root / ".env")


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


def build_isolated_flags(
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
