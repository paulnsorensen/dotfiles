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
from dataclasses import replace
from pathlib import Path
from typing import Any, NoReturn

import yaml

from agent_profile import discover, manifest as manifest_mod
from agent_profile.manifest import ManifestCorrupt
from agent_profile.parse import ParseError, parse_manifest
from agent_profile.renderers.base import (
    MergedConfigError,
    Renderer,
    includes_harness,
)

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
    jq filter in cmd_describe). Isolated profiles additionally surface the
    launch-overlay fields so the closed world is inspectable."""
    view: dict[str, Any] = {
        "name": merged.get("name"),
        "description": merged.get("description"),
        "mcps": [m["name"] for m in merged.get("mcps", [])],
        "agents": [a["name"] for a in merged.get("agents", [])],
        # A repo-level external skill (auto-discovery — no explicit name)
        # carries only `source`; fall back to it so describe never KeyErrors.
        "skills": [
            s.get("name") or s.get("source") for s in merged.get("skills", [])
        ],
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
    if merged.get("isolated"):
        view["isolated"] = True
        view["system_prompt"] = merged.get("system_prompt")
        view["tools"] = merged.get("tools", [])
        view["permissions"] = {
            "allow": merged.get("permissions_allow", []),
            "deny": merged.get("permissions_deny", []),
        }
        view["enabled_plugins"] = merged.get("enabled_plugins", {})
        view["env"] = merged.get("env", {})
        view["extra_args"] = merged.get("extra_args", [])
    return view


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
    m = parse_manifest(profile_dir)
    merged = m.to_dict()
    if m.isolated:
        merged.update(
            isolated=True,
            system_prompt=m.system_prompt,
            tools=list(m.tools),
            permissions_allow=list(m.permissions_allow),
            permissions_deny=list(m.permissions_deny),
            enabled_plugins=dict(m.enabled_plugins),
            env=dict(m.env),
            extra_args=list(m.extra_args),
        )
    print(
        f"{colors.CYAN}Profile: {name}{colors.NC}  "
        f"{colors.BLUE}({profile_dir}){colors.NC}",
        file=out,
    )
    print(file=out)
    print(json.dumps(_describe_view(merged), indent=2), file=out)
    return 0


def cmd_copilot_flags(name: str, out: Any) -> int:
    """Print the Copilot launch flags (``--allow-tool``/``--deny-tool``) the
    profile's canonical permission lists lower to (lever 1).

    The Copilot CLI has no config-file surface for per-command rules, so the
    `copilot` launch wrapper calls this to inject the flags at invocation.
    One flag per line (the wrapper splits on newline into its argv array, so
    flags whose value contains spaces — ``shell(gh pr view)`` — survive as a
    single token). No output when the profile declares no canonical rules."""
    profile_dir = discover.find_profile_dir(name)
    if profile_dir is None:
        raise CliError(f"ap: profile '{name}' not found")
    from agent_profile.renderers.copilot import launch_flags

    manifest = parse_manifest(profile_dir)
    for flag in launch_flags(manifest):
        print(flag, file=out)
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
    target_opt: Path | None,
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

    manifest = parse_manifest(profile_dir)

    if (
        target_opt is None
        and not manifest.target_default
        and _within_git_repo(Path.cwd())
    ):
        raise CliError(
            f"{colors.RED}ap install: refusing to install profile '{name}' "
            f"into a git working tree (cwd: {Path.cwd()}).{colors.NC}\n"
            f"  Without --target and with no target_default, the rendered "
            f"runtime (.codex/, .cursor/, manifest.json, …) would be dumped "
            f"into the repo.\n"
            f"  Pass --target <dir> to stage the render, or install an "
            f"install-overlay profile like 'global' (it targets $HOME)."
        )

    target = _resolve_target(target_opt, manifest.target_default)

    print(
        f"{colors.BLUE}→ Installing profile '{name}' "
        f"from {profile_dir}{colors.NC}",
        file=out,
    )
    print(f"  target:   {target}", file=out)
    print(f"  harness:  {' '.join(harnesses)}", file=out)

    merged_dict = manifest.to_dict()

    manifest_mod.manifest_init(target)
    # Snapshot the prior resolved manifest BEFORE the render loop overwrites
    # it (record_merged_json runs at the end) so the reconcile can diff which
    # MCPs dropped out of the registry since the last install.
    prior_merged = manifest_mod.merged_json(target, name)

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

    _fetch_external_skills(manifest, harnesses, colors, out)

    new_files = sorted(set(all_new_files))

    if len(harnesses) == len(ALL_HARNESSES):
        manifest_mod.diff_and_clean(target, name, new_files)
        _set_files(target, name, new_files)
    else:
        manifest_mod.diff_and_clean(target, name, new_files, harnesses)
        _union_files(target, name, new_files, harnesses)

    _reconcile_dropped_mcps(prior_merged, manifest, harnesses, target, out, colors)

    manifest_mod.record_merged_json(target, name, merged_dict)

    print(f"{colors.GREEN}✓ Installed{colors.NC}", file=out)
    return 0


def _reconcile_dropped_mcps(
    prior_merged: dict[str, Any] | None,
    manifest: Any,
    harnesses: list[str],
    target: Path,
    out: Any,
    colors: Any,
) -> None:
    """Evict MCP servers that fell out of a harness since the last install.

    Renderers MERGE MCPs into persistent/user-owned files (codex config.toml,
    opencode/cursor/copilot JSON, claude user-scope ~/.claude.json), so a
    server that stops rendering into a harness lingers — render only writes
    the current set. A server is "dropped" from a harness either by leaving
    the registry entirely OR by losing that harness from its membership (e.g.
    ``harnesses: []`` scopes it out of every harness while it stays in the
    manifest). Both must be reconciled, so the diff is computed per-harness
    using the same membership projection render uses (:func:`includes_harness`
    with each renderer's MCP default) rather than against the global manifest —
    otherwise a server still present in ``manifest.mcps`` but scoped out of a
    harness would never be pruned from it. No prior install, or nothing dropped
    → no-op (keeps fresh renders byte-identical)."""
    if not prior_merged:
        return
    prior_mcps = prior_merged.get("mcps") or []
    if not prior_mcps:
        return

    current_by_name = {m.get("name"): m for m in manifest.mcps}
    pruned: set[str] = set()
    for h in harnesses:
        renderer = RENDERERS.get(h)
        if renderer is None:
            continue
        default = renderer.mcp_default
        current_for_h = {
            name
            for name, m in current_by_name.items()
            if includes_harness(m, h, default)
        }
        dropped_h = [
            m
            for m in prior_mcps
            if includes_harness(m, h, default)
            and m.get("name") not in current_for_h
        ]
        if not dropped_h:
            continue
        renderer.prune_mcps(replace(manifest, mcps=dropped_h), target)
        pruned.update(str(m.get("name", "?")) for m in dropped_h)

    if not pruned:
        return

    names = ", ".join(sorted(pruned))
    print(f"  {colors.BLUE}↺ pruned dropped MCP(s): {names}{colors.NC}", file=out)


def _skill_fetch_runner(argv: list[str]) -> int:
    """Default ``npx skills add`` runner. Indirected through a module-level
    name so tests can monkeypatch it without spawning ``npx``."""
    from agent_profile.fetch import _default_runner

    return _default_runner(argv)


def _fetch_external_skills(
    manifest: Any,
    harnesses: list[str],
    colors: _Colors,
    out: Any,
) -> None:
    """Fetch every ``source:`` skill into the in-scope harnesses via
    ``npx skills add`` (spec curd 4) — one shallow clone per source repo,
    installed to all harnesses at once. ``path:`` skills are copied by the
    renderers, so they are excluded here."""
    from agent_profile.fetch import (
        SkillFetchError,
        external_skills,
        fetch_external_source,
    )

    ext = external_skills(manifest.skills)
    if not ext:
        return

    # Group items by source repo. A bare `source:` (no name) means "all skills"
    # for that repo (--skill '*') and wins over any explicit names from sibling
    # items. `pin` is a per-source property. Insertion order is preserved so
    # output (and test assertions) stay deterministic.
    order: list[str] = []
    groups: dict[str, dict[str, Any]] = {}
    for skill in ext:
        source = skill["source"]
        if source not in groups:
            groups[source] = {"names": set(), "all": False, "pin": None}
            order.append(source)
        g = groups[source]
        name = skill.get("name")
        if name:
            g["names"].add(name)
        else:
            g["all"] = True
        if skill.get("pin"):
            g["pin"] = skill["pin"]

    try:
        for source in order:
            g = groups[source]
            names = None if g["all"] else sorted(g["names"])
            label = "*" if names is None else ", ".join(names)
            print(
                f"  {colors.BLUE}↳{colors.NC} fetching skills "
                f"{source} ({label}) -> {', '.join(harnesses)}",
                file=out,
            )
            fetch_external_source(
                source, names, g["pin"], harnesses, _skill_fetch_runner
            )
    except SkillFetchError as exc:
        raise CliError(f"{colors.RED}{exc}{colors.NC}") from exc
    except OSError as exc:
        raise CliError(
            f"{colors.RED}ap: cannot run npx "
            f"({exc}); is Node/npx installed?{colors.NC}"
        ) from exc


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
    target_opt: Path | None,
    colors: _Colors,
    out: Any,
) -> int:
    if not name:
        raise CliError(
            f"{colors.RED}ap uninstall: profile name required{colors.NC}"
        )

    # Mirror install's target resolution so `ap uninstall global` (without
    # --target) honors the profile's declared default. When the profile dir
    # is gone, falls through to Path.cwd(); the operator can still pass
    # --target explicitly to point at the right install root.
    target_default: str | None = None
    profile_dir = discover.find_profile_dir(name)
    if profile_dir is not None:
        try:
            target_default = parse_manifest(profile_dir).target_default
        except ParseError:
            target_default = None
    target = _resolve_target(target_opt, target_default)

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
        mcp_scope=merged.get("mcp_scope", "plugin"),
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
    passthrough: list[str],
    target_opt: Path | None,
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
    # Positionals after the name (when no `--` separator was used) are also
    # exec passthrough, matching the bash `launch <harness> [name] [args..]`.
    exec_args = remaining[2:] + passthrough

    if name:
        profile_dir = discover.find_profile_dir(name)
        if profile_dir is None:
            raise CliError(
                f"{colors.RED}ap: profile '{name}' not found{colors.NC}"
            )
        manifest = parse_manifest(profile_dir)
        if manifest.isolated:
            _launch_isolated(
                manifest, profile_dir, harness, exec_args, colors, out
            )  # NoReturn
        # Pass the unresolved target_opt down to cmd_install; it will apply
        # the same explicit > profile.target_default > PWD precedence we use
        # for standalone install. Launching the global profile thus targets
        # $HOME without forcing the operator to pass --target.
        install_rc = cmd_install(name, [harness], target_opt, colors, out)
        if install_rc != 0:
            raise CliError(
                f"{colors.RED}ap launch: install of '{name}' failed "
                f"(exit {install_rc}); not exec'ing {harness}{colors.NC}"
            )

    print(
        f"{colors.BLUE}→ exec {harness} {' '.join(exec_args)}{colors.NC}",
        file=out,
    )
    _exec(harness, exec_args, colors)


def _launch_isolated(
    manifest: Any,
    profile_dir: Path,
    harness: str,
    exec_args: list[str],
    colors: _Colors,
    out: Any,
) -> NoReturn:
    """Closed-world launch (spec curd 6 / D6): build the ccp-parity flags,
    inject the profile env, exec the harness. Isolated profiles are
    claude-only (the flags are claude's); any other harness fails loud."""
    from agent_profile.env import EnvResolutionError
    from agent_profile.overlay import IsolationError, build_isolated_flags

    if harness != "claude":
        raise CliError(
            f"{colors.RED}ap launch: profile '{manifest.name}' is isolated; "
            f"isolation is claude-only (got '{harness}'){colors.NC}"
        )
    try:
        flags, env = build_isolated_flags(manifest, profile_dir)
    except (IsolationError, EnvResolutionError) as exc:
        raise CliError(f"{colors.RED}{exc}{colors.NC}")

    for key, value in env.items():
        os.environ[key] = value

    full_args = flags + exec_args
    print(
        f"{colors.BLUE}→ exec {harness} (isolated profile "
        f"'{manifest.name}'){colors.NC}",
        file=out,
    )
    _exec(harness, full_args, colors)


def _exec(harness: str, exec_args: list[str], colors: _Colors) -> NoReturn:
    """execvp the harness, converting an OSError into a clean CliError."""
    try:
        os.execvp(harness, [harness, *exec_args])
    except OSError as exc:
        raise CliError(
            f"{colors.RED}ap launch: cannot exec '{harness}': {exc}{colors.NC}"
        )


# ─── option parsing + dispatch ───────────────────────────────────────


def _require_value(args: list[str], i: int, flag: str) -> str:
    """Return the token after a value-taking ``flag``, or raise ``CliError``
    when ``flag`` is the final argument. Prevents an ``IndexError`` +
    traceback when e.g. ``--harness`` is passed with no value."""
    if i + 1 >= len(args):
        raise CliError(f"ap: option '{flag}' requires a value")
    return args[i + 1]


def _parse_common_opts(
    args: list[str],
) -> tuple[list[str], Path | None, list[str], list[str]]:
    """Split out --harness / --target / --profile-src; return
    (harnesses, target_opt, remaining, passthrough). Mirrors the bash
    parse_common_opts: --profile-src appends to AP_EXTRA_SEARCH_PATHS.

    ``target_opt`` is ``None`` when ``--target`` was not passed, letting the
    cmd_* handlers fall through to ``profile.target_default`` (if declared)
    and then to ``Path.cwd()``. Resolving the precedence here would require
    reading the manifest before option parsing, so the fallback is deferred.

    ``remaining`` holds the positionals *before* a ``--`` separator;
    ``passthrough`` holds everything after it. Keeping the boundary lets
    ``launch`` tell "no profile name, just exec args" (``launch claude --
    --resume``) from "profile name is the first positional" — folding both
    into one list mis-read the first passthrough token as a profile name."""
    harnesses = list(ALL_HARNESSES)
    target: Path | None = None
    remaining: list[str] = []
    passthrough: list[str] = []
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
            passthrough = args[i + 1 :]
            break
        else:
            remaining.append(a)
            i += 1
    return harnesses, target, remaining, passthrough


def _resolve_target(target_opt: Path | None, target_default: str | None) -> Path:
    """Resolve target precedence: explicit ``--target`` > profile
    ``target_default`` (env-expanded) > ``Path.cwd()``.

    ``${VAR}`` and ``$VAR`` refs in ``target_default`` expand against the
    process env (``$HOME`` and ``$DOTFILES_DIR`` are the intended consumers).
    ``~`` is also expanded. An unset ``${VAR}`` is left as a literal so the
    surface failure mode is the resulting path not existing — easier to
    debug than a generic KeyError."""
    if target_opt is not None:
        return target_opt
    if target_default:
        expanded = os.path.expandvars(os.path.expanduser(target_default))
        return Path(expanded).resolve()
    return Path.cwd()


def _within_git_repo(start: Path) -> bool:
    """True if ``start`` or any ancestor contains a ``.git`` (dir or file —
    worktrees use a ``.git`` file). Walks the filesystem rather than shelling
    out to ``git``, mirroring how this module avoids subprocess."""
    for d in (start, *start.parents):
        if (d / ".git").exists():
            return True
    return False

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
        if sub == "copilot-flags":
            if not rest:
                raise CliError("profile name required")
            return cmd_copilot_flags(rest[0], sys.stdout)
        if sub == "install":
            harnesses, target, remaining, _passthrough = _parse_common_opts(rest)
            _validate_harnesses(harnesses, colors)
            name = remaining[0] if remaining else ""
            return cmd_install(name, harnesses, target, colors, sys.stdout)
        if sub in ("uninstall", "rm"):
            harnesses, target, remaining, _passthrough = _parse_common_opts(rest)
            _validate_harnesses(harnesses, colors)
            name = remaining[0] if remaining else ""
            return cmd_uninstall(name, target, colors, sys.stdout)
        if sub == "launch":
            _harnesses, target, remaining, passthrough = _parse_common_opts(rest)
            cmd_launch(remaining, passthrough, target, colors, sys.stdout)
        if sub in ("help", "-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        print(
            f"{colors.RED}ap: unknown subcommand '{sub}'{colors.NC}",
            file=sys.stderr,
        )
        sys.stderr.write(USAGE)
        return 1
    except (CliError, ParseError, ManifestCorrupt, MergedConfigError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
