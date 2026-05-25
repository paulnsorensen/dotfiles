"""cli.py — CLI dispatch + subcommand bodies for the ``ap`` CLI.

Behavioral port of agent-profile/ap (dispatch + option parsing) and
agent-profile/lib/commands.sh (the cmd_* handlers). Stdout strings,
stderr error strings, and exit codes match the bash so the steel-thread
golden tests assert byte/string identity.

The five harness renderers are owned by sibling curds; this module
dispatches through a registry (:data:`RENDERERS`) keyed by harness name.
The registry is populated by the wiring phase (the ``renderers`` barrel).
:func:`set_renderers` lets tests inject stub renderers so the CLI's
orchestration — banners, manifest recording, orphan diff/clean,
ref-counted uninstall, merged_json cache — is exercised end-to-end
without the production renderers.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, NoReturn

import yaml

from agent_profile import discover, manifest as manifest_mod
from agent_profile.manifest import ManifestCorrupt
from agent_profile.parse import ParseError, parse_manifest
from agent_profile.renderers.base import Renderer

ALL_HARNESSES = ["claude", "codex", "opencode", "cursor", "copilot"]

# Harness-name -> Renderer. Populated by the wiring barrel; tests inject
# stubs via set_renderers(). Empty by default (seed phase ships no
# production renderers).
RENDERERS: dict[str, Renderer] = {}


def set_renderers(renderers: dict[str, Renderer]) -> None:
    """Replace the active renderer registry (used by wiring and tests)."""
    global RENDERERS
    RENDERERS = dict(renderers)


def _is_tty() -> bool:
    return sys.stdout.isatty()


class _Colors:
    """Color codes, blanked when stdout is not a TTY (matches the bash
    ``[[ -t 1 ]] || { GREEN=''; ... }`` guard)."""

    def __init__(self, enabled: bool) -> None:
        self.GREEN = "\033[0;32m" if enabled else ""
        self.BLUE = "\033[0;34m" if enabled else ""
        self.RED = "\033[0;31m" if enabled else ""
        self.CYAN = "\033[0;36m" if enabled else ""
        self.NC = "\033[0m" if enabled else ""


USAGE = """Usage: dots profile <command> [args]

Commands:
  list                          List available profiles
  describe <name>               Show resolved manifest for a profile
  path <name>                   Print profile source dir
  install <name> [opts]         Render profile into current dir
  uninstall <name> [opts]       Remove a previously-installed profile
  launch <harness> [name] [..]  Install + exec the named harness CLI
  help                          Show this message

Install/launch options:
  --harness <h>[,<h>...]        Limit to specific harnesses (default: all)
  --target <dir>                Render into <dir> instead of $PWD
  --profile-src <dir>           Extra search root for profile lookup

Uninstall accepts --target and --profile-src. --harness is honored but
limited: every cleaner still runs (shared/merged files like
opencode.json, .mcp.json carry profile-authored entries across the
harness boundary; a partial cleanup would leave dangling entries).

Examples:
  dots profile list
  dots profile install rust --harness claude
  dots profile launch claude rust -- --resume
  dots profile uninstall rust
"""


class CliError(Exception):
    """A handled CLI failure. ``message`` goes to stderr; exit code 1."""


def _describe_view(merged: dict[str, Any]) -> dict[str, Any]:
    """Project the resolved manifest to the ``describe`` view (port of the
    jq filter in cmd_describe)."""
    return {
        "name": merged.get("name"),
        "description": merged.get("description"),
        "mcps": [m["name"] for m in merged.get("mcps", [])],
        "agents": [a["name"] for a in merged.get("agents", [])],
        "skills": [s["name"] for s in merged.get("skills", [])],
        "commands": [c["name"] for c in merged.get("commands", [])],
        "hooks": [
            {
                "event": h.get("event"),
                "matcher": h.get("matcher"),
                "harnesses": h.get("harnesses") or ["claude"],
            }
            for h in merged.get("hooks", [])
        ],
        "permissions": merged.get("settings", {}).get("permissions_allow", []),
    }


# ─── subcommand handlers ─────────────────────────────────────────────


def cmd_list(colors: _Colors, out: Any) -> int:
    rows = discover.list_profiles()
    if not rows:
        pwd = Path.cwd()
        dotfiles = os.environ.get("DOTFILES_DIR") or str(
            Path.home() / "Dev/dotfiles"
        )
        print(
            f"(no profiles found in {pwd}/.agent-profiles or "
            f"{dotfiles}/profiles)",
            file=out,
        )
        return 0
    print(f"{colors.CYAN}Available profiles:{colors.NC}", file=out)
    for name, root in rows:
        desc = ""
        pyaml = root / name / "profile.yaml"
        if pyaml.is_file():
            data = yaml.safe_load(pyaml.read_text()) or {}
            desc = (data.get("description") if isinstance(data, dict) else "") or ""
        print(f"  {colors.GREEN}{name:<20}{colors.NC} {desc}", file=out)
        print(f"    {colors.BLUE}↳{colors.NC} {root / name}", file=out)
    return 0


def cmd_describe(name: str, colors: _Colors, out: Any) -> int:
    profile_dir = discover.find_profile_dir(name)
    if profile_dir is None:
        raise CliError(f"{colors.RED}ap: profile '{name}' not found{colors.NC}")
    merged = parse_manifest(profile_dir).to_dict()
    print(
        f"{colors.CYAN}Profile: {name}{colors.NC}  "
        f"{colors.BLUE}({profile_dir}){colors.NC}",
        file=out,
    )
    print(file=out)
    print(json.dumps(_describe_view(merged), indent=2), file=out)
    return 0


def cmd_path(name: str, colors: _Colors, out: Any) -> int:
    profile_dir = discover.find_profile_dir(name)
    if profile_dir is None:
        raise CliError(f"{colors.RED}ap: profile '{name}' not found{colors.NC}")
    print(profile_dir, file=out)
    return 0


def cmd_install(
    name: str,
    harnesses: list[str],
    target: Path,
    colors: _Colors,
    out: Any,
) -> int:
    if not name:
        raise CliError(
            f"{colors.RED}ap install: profile name required{colors.NC}"
        )
    profile_dir = discover.find_profile_dir(name)
    if profile_dir is None:
        raise CliError(f"{colors.RED}ap: profile '{name}' not found{colors.NC}")

    print(
        f"{colors.BLUE}→ Installing profile '{name}' "
        f"from {profile_dir}{colors.NC}",
        file=out,
    )
    print(f"  target:   {target}", file=out)
    print(f"  harness:  {' '.join(harnesses)}", file=out)

    manifest = parse_manifest(profile_dir)
    merged_dict = manifest.to_dict()

    manifest_mod.manifest_init(target)

    all_new_files: list[str] = []
    for h in harnesses:
        print(f"  {colors.CYAN}━━ {h} ━━{colors.NC}", file=out)
        renderer = RENDERERS.get(h)
        if renderer is None:
            raise CliError(
                f"{colors.RED}ap: no renderer registered for harness "
                f"'{h}'{colors.NC}"
            )
        written = renderer.render(manifest, target)
        all_new_files.extend(written)

    new_files = sorted(set(all_new_files))

    if len(harnesses) == len(ALL_HARNESSES):
        manifest_mod.diff_and_clean(target, name, new_files)
        _set_files(target, name, new_files)
    else:
        manifest_mod.diff_and_clean(target, name, new_files, harnesses)
        _union_files(target, name, new_files, harnesses)

    manifest_mod.record_merged_json(target, name, merged_dict)

    print(f"{colors.GREEN}✓ Installed{colors.NC}", file=out)
    return 0


def _set_files(target: Path, profile: str, new_files: list[str]) -> None:
    """Full-install: replace the profile's file list with ``new_files``."""
    path = manifest_mod.manifest_path(target)
    data = json.loads(path.read_text())
    entry = data.setdefault(profile, {})
    entry["files"] = new_files
    path.write_text(json.dumps(data, indent=2) + "\n")


def _union_files(
    target: Path, profile: str, new_files: list[str], harnesses: list[str]
) -> None:
    """Selective-install: union new files in, dropping only in-scope
    orphans (port of cmd_install's selective branch)."""
    path = manifest_mod.manifest_path(target)
    data = json.loads(path.read_text())
    entry = data.setdefault(profile, {})
    old = entry.get("files") or []
    entry["files"] = manifest_mod.select_files(old, new_files, harnesses)
    path.write_text(json.dumps(data, indent=2) + "\n")


def cmd_uninstall(
    name: str,
    target: Path,
    colors: _Colors,
    out: Any,
) -> int:
    if not name:
        raise CliError(
            f"{colors.RED}ap uninstall: profile name required{colors.NC}"
        )

    print(
        f"{colors.BLUE}→ Uninstalling profile '{name}' "
        f"from {target}{colors.NC}",
        file=out,
    )

    # Uninstall always runs every cleaner regardless of --harness so
    # shared/merged files stay consistent with the (globally-recorded)
    # manifest.
    merged = manifest_mod.merged_json(target, name)
    if merged is None:
        profile_dir = discover.find_profile_dir(name)
        if profile_dir is not None:
            merged = parse_manifest(profile_dir).to_dict()
        else:
            merged = {"name": name, "mcps": [], "settings": {}}

    from agent_profile.parse import Manifest

    merged_manifest = Manifest(
        name=merged.get("name", name),
        description=merged.get("description", ""),
        mcps=merged.get("mcps", []),
        agents=merged.get("agents", []),
        skills=merged.get("skills", []),
        commands=merged.get("commands", []),
        hooks=merged.get("hooks", []),
        settings=merged.get("settings", {}),
    )

    for h in ALL_HARNESSES:
        renderer = RENDERERS.get(h)
        if renderer is not None:
            renderer.clean(merged_manifest, target)

    base = Path(str(target).rstrip("/"))
    for f in manifest_mod.files(target, name):
        if not f:
            continue
        if manifest_mod.other_profiles_claim_file(target, name, f):
            print(
                f"  {colors.BLUE}↳{colors.NC} keeping {f} "
                "(claimed by another profile)",
                file=out,
            )
            continue
        abs_path = base / f
        if abs_path.exists() or abs_path.is_symlink():
            manifest_mod.remove_path(abs_path)

    manifest_mod.clear(target, name)
    print(f"{colors.GREEN}✓ Uninstalled{colors.NC}", file=out)
    return 0


def cmd_launch(
    remaining: list[str],
    target: Path,
    colors: _Colors,
    out: Any,
) -> NoReturn:
    harness = remaining[0] if remaining else ""
    if not harness:
        raise CliError(
            f"{colors.RED}ap launch: harness required "
            f"(claude|codex|opencode|cursor|copilot){colors.NC}"
        )
    if harness not in ALL_HARNESSES:
        raise CliError(
            f"{colors.RED}ap launch: unknown harness '{harness}'{colors.NC}"
        )
    name = remaining[1] if len(remaining) > 1 else ""
    passthrough = remaining[2:]

    if name:
        cmd_install(name, [harness], target, colors, out)

    print(
        f"{colors.BLUE}→ exec {harness} {' '.join(passthrough)}{colors.NC}",
        file=out,
    )
    os.execvp(harness, [harness, *passthrough])


# ─── option parsing + dispatch ───────────────────────────────────────


def _require_value(args: list[str], i: int, flag: str) -> str:
    """Return the token after a value-taking ``flag``, or raise ``CliError``
    when ``flag`` is the final argument. Prevents an ``IndexError`` +
    traceback when e.g. ``--harness`` is passed with no value."""
    if i + 1 >= len(args):
        raise CliError(f"ap: option '{flag}' requires a value")
    return args[i + 1]


def _parse_common_opts(args: list[str]) -> tuple[list[str], Path, list[str]]:
    """Split out --harness / --target / --profile-src; return
    (harnesses, target, remaining). Mirrors the bash parse_common_opts:
    --profile-src appends to AP_EXTRA_SEARCH_PATHS."""
    harnesses = list(ALL_HARNESSES)
    target = Path.cwd()
    remaining: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--harness":
            harnesses = _require_value(args, i, "--harness").split(",")
            i += 2
        elif a.startswith("--harness="):
            harnesses = a.split("=", 1)[1].split(",")
            i += 1
        elif a == "--target":
            target = Path(_require_value(args, i, "--target")).resolve()
            i += 2
        elif a.startswith("--target="):
            target = Path(a.split("=", 1)[1]).resolve()
            i += 1
        elif a == "--profile-src":
            _append_search_path(_require_value(args, i, "--profile-src"))
            i += 2
        elif a.startswith("--profile-src="):
            _append_search_path(a.split("=", 1)[1])
            i += 1
        elif a == "--":
            remaining.extend(args[i + 1 :])
            break
        else:
            remaining.append(a)
            i += 1
    return harnesses, target, remaining


def _append_search_path(path: str) -> None:
    existing = os.environ.get("AP_EXTRA_SEARCH_PATHS", "")
    os.environ["AP_EXTRA_SEARCH_PATHS"] = (
        f"{existing}:{path}" if existing else path
    )


def _validate_harnesses(harnesses: list[str], colors: _Colors) -> None:
    for h in harnesses:
        if h not in ALL_HARNESSES:
            raise CliError(
                f"{colors.RED}ap: unknown harness '{h}' "
                f"(valid: claude|codex|opencode|cursor|copilot){colors.NC}"
            )


def main(argv: list[str] | None = None) -> int:
    """Entry point. Returns the process exit code."""
    if argv is None:
        argv = sys.argv[1:]
    colors = _Colors(_is_tty())

    sub = argv[0] if argv else "help"
    rest = argv[1:]

    try:
        if sub in ("list", "ls"):
            return cmd_list(colors, sys.stdout)
        if sub in ("describe", "desc"):
            if not rest:
                raise CliError("profile name required")
            return cmd_describe(rest[0], colors, sys.stdout)
        if sub == "path":
            if not rest:
                raise CliError("profile name required")
            return cmd_path(rest[0], colors, sys.stdout)
        if sub == "install":
            harnesses, target, remaining = _parse_common_opts(rest)
            _validate_harnesses(harnesses, colors)
            name = remaining[0] if remaining else ""
            return cmd_install(name, harnesses, target, colors, sys.stdout)
        if sub in ("uninstall", "rm"):
            harnesses, target, remaining = _parse_common_opts(rest)
            _validate_harnesses(harnesses, colors)
            name = remaining[0] if remaining else ""
            return cmd_uninstall(name, target, colors, sys.stdout)
        if sub == "launch":
            _harnesses, target, remaining = _parse_common_opts(rest)
            cmd_launch(remaining, target, colors, sys.stdout)
        if sub in ("help", "-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        print(
            f"{colors.RED}ap: unknown subcommand '{sub}'{colors.NC}",
            file=sys.stderr,
        )
        sys.stderr.write(USAGE)
        return 1
    except (CliError, ParseError, ManifestCorrupt) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
