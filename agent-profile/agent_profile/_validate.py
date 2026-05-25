"""_validate.py — shared validation primitives for profile parsing.

Houses :class:`ParseError` plus the name / relative-path validators used
by both :mod:`agent_profile.parse` (profile.yaml parsing) and
:mod:`agent_profile.discover` (profile lookup). Kept in a leaf module so
neither importer forms an import cycle: parse needs discover for include
resolution, and discover needs these validators — routing both through
this dependency-free leaf breaks the cycle.
"""

from __future__ import annotations

import re

_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class ParseError(Exception):
    """Raised on a malformed or unsafe profile.yaml. Carries the exact
    stderr line parse.sh would emit so callers can byte-match it."""


def _validate_name(what: str, value: str, where: str) -> None:
    """Reject names parse.sh's ``_ap_validate_name`` would reject.

    Empty values are tolerated (defaults fill in later); only non-empty
    values are checked.
    """
    if not value:
        return
    if not _NAME_RE.match(value):
        raise ParseError(
            f"ap_parse: invalid {what} '{value}' in {where} "
            "(must match [A-Za-z0-9._-]+)"
        )
    # The regex accepts bare '.' and '..' (non-empty allowed-char runs).
    # Both resolve to directory components at install time, so reject the
    # two literals explicitly.
    if value in (".", ".."):
        raise ParseError(
            f"ap_parse: invalid {what} '{value}' in {where} "
            "(must not be '.' or '..')"
        )


def _validate_relpath(what: str, value: str, where: str) -> None:
    """Reject paths parse.sh's ``_ap_validate_relpath`` would reject."""
    if not value:
        return
    if value.startswith("/"):
        raise ParseError(
            f"ap_parse: invalid {what} '{value}' in {where} "
            "(must be relative, not absolute)"
        )
    # parse.sh checks for '/../' in "/$value/" — a '..' path *component*,
    # not a '..' substring. 'foo..bar' must pass; 'a/../b' must fail.
    if ".." in f"/{value}/".split("/"):
        raise ParseError(
            f"ap_parse: invalid {what} '{value}' in {where} "
            "(must not contain '..' components)"
        )
