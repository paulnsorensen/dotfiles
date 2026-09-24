"""Rewrite engine for bash-shorten.

Internal split of bash-shorten.py — not a stable API. Holds the rewrite
dispatch (`apply_rules`), the ast-grep bridge (`_apply_sg`), and the I/O
helpers (`_diff`, `_atomic_write`) that the CLI module composes. Sole
consumer is the sibling `bash-shorten.py`; tests reach the engine through
the CLI.
"""

from __future__ import annotations

import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from rules import RULES, SG_HANDLED_IDS  # type: ignore[import-not-found]

# Path to the sgconfig.yml shipped alongside this script. Resolved once at
# import time so the dispatch is deterministic regardless of cwd.
_SG_CONFIG = Path(__file__).resolve().parent / "sgconfig.yml"

# Opt-out directive (issue #59), shellcheck-style. A comment line of the form
#   # bash-shorten: disable   — start a span copied through verbatim
#   # bash-shorten: enable    — end the span
#   # bash-shorten: skip      — no-op the single following line
# opts a region out of EVERY rule. Enforced in apply_rules (not per-rule) so it
# covers the sg pass and the regex pass uniformly. Leading indentation and the
# spacing around `#` / `:` are tolerated; the keyword must be the whole comment.
_DIRECTIVE = re.compile(
    r"[ \t]*#[ \t]*bash-shorten:[ \t]*(disable|enable|skip)[ \t]*\Z"
)


def _sg_available() -> bool:
    """True iff `sg` on PATH is the ast-grep binary AND sgconfig.yml exists.

    On Linux, `sg` is also util-linux's "execute command as a different group"
    — same binary name, totally different tool. We must not let that mask
    the missing-ast-grep case. `sg --version` on ast-grep prints
    "ast-grep <version>"; on util-linux it errors out. We probe that.
    """
    if shutil.which("sg") is None or not _SG_CONFIG.is_file():
        return False
    try:
        result = subprocess.run(
            ["sg", "--version"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return "ast-grep" in (result.stdout + result.stderr).lower()


def _apply_sg(text: str, enabled: set[str]) -> tuple[str, dict[str, int]]:
    """Run the ast-grep rule pack against `text`. Returns (new_text, counts).

    `enabled` is the set of Python rule ids the dispatch wants to apply.
    sg-handled rules outside that set are filtered out of the sg run via
    --filter so --rules / --skip work correctly across both engines.

    Counts are keyed by the Python rule id (backticks, test-numeric, …),
    read straight from each match's `ruleId` in a `--json` scan (sg rule
    ids are `bash-shorten-<python-id>` or `bash-shorten-<python-id>-<variant>`
    for suffixed forms like test-numeric-eq) so the upstream caller can
    present them uniformly without guessing from a before/after diff.

    On sg failure (parse error, rule error), emits a warning and returns
    the original text with empty counts. Non-sg-handled regex rules still
    run afterwards on the unmodified input.
    """
    if not _sg_available():
        return text, {}

    # Determine which sg-handled rules to actually run. Skip the sg pass
    # entirely when none are enabled — saves a subprocess and a tempfile.
    active_sg_ids = SG_HANDLED_IDS & enabled
    if not active_sg_ids:
        return text, {}
    # sg rule ids in sg-rules/*.yml are prefixed with "bash-shorten-" so
    # the filter is anchored to that namespace. The trailing (-|$) allows
    # suffixed forms (test-numeric-eq, test-numeric-ne, ...) to match the
    # parent Python rule id "test-numeric" without listing each variant.
    filter_regex = "^bash-shorten-(" + "|".join(sorted(active_sg_ids)) + ")(-|$)"

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".sh", delete=False
    ) as tmp:
        tmp.write(text)
        tmp_path = Path(tmp.name)

    base_cmd = ["sg", "scan", "--config", str(_SG_CONFIG), "--filter", filter_regex]
    try:
        try:
            # --json and --update-all conflict, so count matches with a
            # dry-run --json scan first, then apply with a second pass.
            json_result = subprocess.run(
                [*base_cmd, "--json=compact", str(tmp_path)],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                [*base_cmd, "--update-all", str(tmp_path)],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as e:
            stderr = (e.stderr or b"").decode(errors="replace").strip()
            print(
                f"# warning: sg scan failed ({stderr or 'no stderr'}); "
                "sg-handled rules will be skipped this run.",
                file=sys.stderr,
            )
            return text, {}
        new_text = tmp_path.read_text(encoding="utf-8")
    finally:
        tmp_path.unlink(missing_ok=True)

    matches = json.loads(json_result.stdout or b"[]")
    counts: dict[str, int] = {}
    for match in matches:
        parent = match.get("ruleId", "").removeprefix("bash-shorten-")
        for sg_id in active_sg_ids:
            if parent == sg_id or parent.startswith(f"{sg_id}-"):
                counts[sg_id] = counts.get(sg_id, 0) + 1
                break
    return new_text, counts


def _apply_pipeline(text: str, enabled: set[str]) -> tuple[str, dict[str, int]]:
    """Run sg-handled rules through ast-grep, then run remaining Python rules.

    sg is a hard requirement for this engine — the CLI verifies presence at
    startup. The dispatch here trusts that and skips rules whose ids are in
    SG_HANDLED_IDS so the Python regex doesn't double-fire on sg's output.
    """
    counts: dict[str, int] = {}

    sg_text, sg_counts = _apply_sg(text, enabled)
    text = sg_text
    counts.update(sg_counts)

    for rule in RULES:
        if rule.id not in enabled:
            continue
        if rule.id in SG_HANDLED_IDS:
            continue
        if rule.apply_fn is not None:
            new_text, n = rule.apply_fn(text)
        else:
            new_text, n = rule.pattern.subn(rule.replace, text)
        if n:
            counts[rule.id] = n
            text = new_text
    return text, counts


def _protected_mask(lines: list[str]) -> list[bool]:
    """Per-line flag: True where an opt-out directive (issue #59) is in effect.

    A directive comment line is itself protected (it is a comment, so no rule
    touches it anyway); `disable`/`enable` bracket a span and `skip` protects
    only the next line. Takes the `splitlines(keepends=True)` list and returns a
    mask of equal length.
    """
    mask: list[bool] = []
    disabled = False
    skip_next = False
    for line in lines:
        directive = _DIRECTIVE.match(line.rstrip("\r\n"))
        if directive:
            mask.append(True)
            kind = directive.group(1)
            if kind == "disable":
                disabled = True
            elif kind == "enable":
                disabled = False
            else:  # skip
                skip_next = True
            continue
        mask.append(disabled or skip_next)
        skip_next = False
    return mask


def apply_rules(text: str, enabled: set[str]) -> tuple[str, dict[str, int]]:
    """Rewrite `text`, honouring the `# bash-shorten:` opt-out directive (#59).

    Splits the input at directive boundaries and runs the rewrite pipeline only
    over unprotected runs, copying protected runs through verbatim. Enforcing
    the directive here — above both the sg and regex passes — is what makes it
    apply to every rule uniformly. With no directive present the input is passed
    straight through the pipeline, byte-for-byte identical to the un-split run.
    """
    if "bash-shorten:" not in text:
        return _apply_pipeline(text, enabled)

    lines = text.splitlines(keepends=True)
    mask = _protected_mask(lines)
    out: list[str] = []
    counts: dict[str, int] = {}
    i = 0
    while i < len(lines):
        j = i
        while j < len(lines) and mask[j] == mask[i]:
            j += 1
        chunk = "".join(lines[i:j])
        if mask[i]:
            out.append(chunk)
        else:
            new_chunk, chunk_counts = _apply_pipeline(chunk, enabled)
            out.append(new_chunk)
            for rid, n in chunk_counts.items():
                counts[rid] = counts.get(rid, 0) + n
        i = j
    return "".join(out), counts


def diff(before: str, after: str, label: str) -> str:
    if before == after:
        return ""
    diff_lines = difflib.unified_diff(
        before.splitlines(keepends=True),
        after.splitlines(keepends=True),
        fromfile=f"{label} (before)",
        tofile=f"{label} (after)",
        lineterm="",
    )
    return "".join(diff_lines)


def atomic_write(path: Path, content: str) -> None:
    # Resolve first so a symlinked target gets its real file replaced
    # in place, instead of os.replace() overwriting the symlink itself
    # with a regular file and severing the link.
    path = path.resolve()
    # Preserve the original file's permission and special bits (setuid,
    # setgid, sticky + ugo rwx — the full 0o7777 mask). NamedTemporaryFile
    # creates with 0600, and os.replace would otherwise silently strip the
    # +x bit from rewritten scripts.
    try:
        original_mode = path.stat().st_mode
    except FileNotFoundError:
        original_mode = None

    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        delete=False,
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
    ) as tmp:
        try:
            tmp.write(content)
            tmp.flush()
            os.fsync(tmp.fileno())
        except Exception:
            tmp.close()
            Path(tmp.name).unlink(missing_ok=True)
            raise
    try:
        if original_mode is not None:
            os.chmod(tmp.name, original_mode & 0o7777)
        os.replace(tmp.name, path)
    except Exception:
        Path(tmp.name).unlink(missing_ok=True)
        raise
