"""discover.py — profile lookup across per-repo and global sources.

Behavioral port of agent-profile/lib/discover.sh.

Search order (first match wins):
  1. ``AP_EXTRA_SEARCH_PATHS`` (colon-separated, consulted first)
  2. ``$PWD/.agent-profiles/<name>/``       (per-repo, shadows global)
  3. ``$DOTFILES_DIR/profiles/<name>/``     (global library)

``DOTFILES_DIR`` defaults to ``$HOME/Dev/dotfiles`` to match the bash.
``find_profile_dir`` returns the canonicalized dir (``cd && pwd`` in the
bash resolves symlinks, e.g. /tmp -> /private/tmp on macOS) or ``None``.
"""

from __future__ import annotations

import os
from pathlib import Path

from agent_profile._validate import ParseError, _validate_name


def search_roots() -> list[Path]:
    """Resolved search roots in precedence order. Port of ``ap_search_roots``."""
    roots: list[Path] = []
    extra = os.environ.get("AP_EXTRA_SEARCH_PATHS", "")
    if extra:
        for r in extra.split(":"):
            if r:
                roots.append(Path(r))
    roots.append(Path.cwd() / ".agent-profiles")
    dotfiles = os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles")
    roots.append(Path(dotfiles) / "profiles")
    return roots


def find_profile_dir(name: str) -> Path | None:
    """Return the canonicalized profile dir for ``name``, or ``None``.

    Validates ``name`` (same rules as profile.yaml names) before joining
    it onto each root, so ``../escape`` and ``x/y`` are rejected loudly.
    Port of ``ap_find_profile_dir``.
    """
    if not name:
        raise ParseError("ap_find_profile_dir: empty name")
    _validate_name("profile name", name, "ap_find_profile_dir")

    for root in search_roots():
        candidate = root / name
        if candidate.is_dir() and (candidate / "profile.yaml").is_file():
            return candidate.resolve()
    return None


def list_profiles() -> list[tuple[str, Path]]:
    """Emit ``(name, source_root)`` for every discoverable profile.

    A per-repo profile shadows a global one with the same name; only the
    winning (first-seen) entry is emitted. Port of ``ap_list_profiles``.
    """
    out: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for root in search_roots():
        if not root.is_dir():
            continue
        for entry in sorted(root.iterdir()):
            if not entry.is_dir():
                continue
            if not (entry / "profile.yaml").is_file():
                continue
            name = entry.name
            if name in seen:
                continue
            seen.add(name)
            out.append((name, root))
    return out
