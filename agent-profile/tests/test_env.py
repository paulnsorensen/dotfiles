"""test_env.py — render-time ${VAR} resolution from .env (spec D4).

Env refs in MCP/skill/hook items resolve at render time from a .env-style
mapping; unset references fail loud unless the item is `optional`, in which
case the item is dropped non-fatally. Mirrors the bash mcp_load_dotenv +
mcp_build_env_flags / _mcp_first_unset_env_var semantics.
"""

from __future__ import annotations

import pytest

from agent_profile.env import (
    EnvResolutionError,
    first_unset_var,
    load_dotenv,
    resolve_env_value,
    resolve_item_env,
)


# ─── load_dotenv ──────────────────────────────────────────────────────


def test_load_dotenv_parses_key_values(tmp_path):
    f = tmp_path / ".env"
    f.write_text("TAVILY_API_KEY=abc123\nTODOIST_API_KEY=xyz\n")
    assert load_dotenv(f) == {"TAVILY_API_KEY": "abc123", "TODOIST_API_KEY": "xyz"}


def test_load_dotenv_strips_export_and_quotes(tmp_path):
    f = tmp_path / ".env"
    f.write_text('export FOO="bar"\nBAZ=\'qux\'\n')
    out = load_dotenv(f)
    assert out["FOO"] == "bar"
    assert out["BAZ"] == "qux"


def test_load_dotenv_skips_comments_and_blanks(tmp_path):
    f = tmp_path / ".env"
    f.write_text("# a comment\n\nKEY=val\n  # indented comment\n")
    assert load_dotenv(f) == {"KEY": "val"}


def test_load_dotenv_rejects_illegal_identifiers(tmp_path):
    f = tmp_path / ".env"
    f.write_text("1BAD=x\nGOOD=y\nbad-key=z\n")
    out = load_dotenv(f)
    assert out == {"GOOD": "y"}


def test_load_dotenv_missing_file_returns_empty(tmp_path):
    assert load_dotenv(tmp_path / "nope.env") == {}


def test_load_dotenv_value_with_equals_sign(tmp_path):
    # A value containing '=' (e.g. base64 padding) keeps everything after
    # the first '='.
    f = tmp_path / ".env"
    f.write_text("TOKEN=a=b=c\n")
    assert load_dotenv(f) == {"TOKEN": "a=b=c"}


def test_load_dotenv_duplicate_key_last_wins(tmp_path):
    # Two assignments to the same key: the later line wins (dict insertion
    # overwrite), matching shell `export` re-assignment.
    f = tmp_path / ".env"
    f.write_text("K=first\nK=second\n")
    assert load_dotenv(f) == {"K": "second"}


def test_load_dotenv_empty_value(tmp_path):
    # `KEY=` is a legal assignment to the empty string, not a skipped line.
    f = tmp_path / ".env"
    f.write_text("EMPTY=\nFILLED=x\n")
    out = load_dotenv(f)
    assert out["EMPTY"] == ""
    assert out["FILLED"] == "x"


def test_load_dotenv_hash_inside_value_is_kept(tmp_path):
    # Only whole-line comments are dropped (key starts with '#'). A '#' after
    # the '=' is part of the value — the loader does not strip trailing
    # comments (parity with mcp_load_dotenv, which keeps everything after '=').
    f = tmp_path / ".env"
    f.write_text("URL=https://x/y#frag\n")
    assert load_dotenv(f) == {"URL": "https://x/y#frag"}


def test_load_dotenv_unmatched_quote_not_stripped(tmp_path):
    # Quote stripping only fires on a matched leading+trailing pair; a value
    # with a lone quote keeps it (the matched-pair guard, not blind strip).
    f = tmp_path / ".env"
    f.write_text('K="abc\n')
    assert load_dotenv(f) == {"K": '"abc'}


# ─── resolve_env_value ────────────────────────────────────────────────


def test_resolve_env_value_substitutes(tmp_path):
    assert resolve_env_value("${FOO}", {"FOO": "bar"}) == "bar"


def test_resolve_env_value_embedded(tmp_path):
    assert resolve_env_value("pre-${FOO}-post", {"FOO": "X"}) == "pre-X-post"


def test_resolve_env_value_no_ref_passthrough():
    assert resolve_env_value("plain", {}) == "plain"


def test_resolve_env_value_unset_raises():
    with pytest.raises(EnvResolutionError) as exc:
        resolve_env_value("${MISSING}", {})
    assert "MISSING" in str(exc.value)


def test_resolve_env_value_multiple_refs_first_unset_named():
    with pytest.raises(EnvResolutionError) as exc:
        resolve_env_value("${SET}-${ALSO_MISSING}", {"SET": "ok"})
    assert "ALSO_MISSING" in str(exc.value)


# ─── first_unset_var ──────────────────────────────────────────────────


def test_first_unset_var_finds_missing():
    item = {"env": {"K": "${MISSING}"}}
    assert first_unset_var(item, {}) == "MISSING"


def test_first_unset_var_none_when_all_set():
    item = {"env": {"K": "${SET}"}}
    assert first_unset_var(item, {"SET": "v"}) is None


def test_first_unset_var_none_when_no_env():
    assert first_unset_var({"command": "x"}, {}) is None


def test_first_unset_var_reports_first_in_insertion_order():
    # The docstring promises insertion order across env entries, left-to-right
    # within a value. With two unset vars across two keys, the FIRST key's var
    # is reported — locks the "first" contract that drives the optional skip.
    item = {"env": {"A": "${MISS_A}", "B": "${MISS_B}"}}
    assert first_unset_var(item, {}) == "MISS_A"


def test_first_unset_var_skips_set_then_reports_unset():
    # A resolvable first entry does not short-circuit; the scan continues to
    # the first genuinely-unset reference.
    item = {"env": {"A": "${SET}", "B": "${MISS}"}}
    assert first_unset_var(item, {"SET": "v"}) == "MISS"


def test_first_unset_var_detects_embedded_ref():
    # An embedded (non-anchored) ${VAR} is still detected — finditer, not a
    # whole-value anchor. (Superset of the bash anchored match.)
    item = {"env": {"K": "prefix-${MISS}-suffix"}}
    assert first_unset_var(item, {}) == "MISS"


# ─── resolve_item_env ─────────────────────────────────────────────────


def test_resolve_item_env_returns_resolved_copy():
    item = {"name": "todoist", "env": {"TODOIST_API_KEY": "${KEY}"}}
    out = resolve_item_env(item, {"KEY": "secret"})
    assert out["env"]["TODOIST_API_KEY"] == "secret"
    # Original untouched (immutable pattern).
    assert item["env"]["TODOIST_API_KEY"] == "${KEY}"


def test_resolve_item_env_no_env_passthrough():
    item = {"name": "x", "command": "y"}
    assert resolve_item_env(item, {}) == item


def test_resolve_item_env_unset_raises_with_item_name():
    item = {"name": "todoist", "env": {"K": "${MISSING}"}}
    with pytest.raises(EnvResolutionError) as exc:
        resolve_item_env(item, {})
    assert "MISSING" in str(exc.value)
    assert "todoist" in str(exc.value)
