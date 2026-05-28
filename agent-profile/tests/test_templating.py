"""test_templating.py — Go-template render of MCP args/env per harness.

The retired ``agents/mcp/sync.sh`` ran the registry through
``chezmoi execute-template`` once per harness with HARNESS=<name>.
``ap`` is now the single deploy path, so the same render lives in
``agent_profile.templating`` and is called from the two MCP filter
functions (``mcps_for`` and cursor's ``_cursor_mcps``).

Tests assert the rendered output per harness, idempotence for values
without ``{{``, and the graceful fall-back when chezmoi is missing.
``chezmoi execute-template`` is run for real when the binary is on PATH;
otherwise the chezmoi-dependent tests are skipped (the fall-back test
still runs against the explicit absent-binary branch).
"""

from __future__ import annotations

import shutil
import subprocess
from unittest.mock import patch

import pytest

from agent_profile import templating

CHEZMOI = shutil.which("chezmoi")
needs_chezmoi = pytest.mark.skipif(
    CHEZMOI is None, reason="chezmoi binary not on PATH"
)


def _reset_module_cache() -> None:
    """Each test starts fresh: the templating module caches the chezmoi
    path lookup and a one-shot warning flag. Without a reset, swapping
    PATH mid-test would still hit the cached value."""
    templating._chezmoi_bin = None
    templating._chezmoi_warned.clear()


@pytest.fixture(autouse=True)
def _isolate_cache():
    _reset_module_cache()
    yield
    _reset_module_cache()


# ─── needs_render ──────────────────────────────────────────────────────


def test_needs_render_true_for_string_with_open_delim():
    assert templating.needs_render("{{ $h }}") is True
    assert templating.needs_render("plain {{ if eq $h \"x\" }}y{{ end }}") is True


def test_needs_render_false_for_string_without_open_delim():
    assert templating.needs_render("serena-mux") is False
    assert templating.needs_render("") is False


def test_needs_render_false_for_non_strings():
    assert templating.needs_render(None) is False
    assert templating.needs_render(42) is False
    assert templating.needs_render(["{{ $h }}"]) is False  # list, not string
    assert templating.needs_render({"k": "{{ $h }}"}) is False


# ─── render_value: real chezmoi ────────────────────────────────────────


@needs_chezmoi
def test_render_value_resolves_bare_harness_var():
    assert templating.render_value("{{ $h }}", "codex") == "codex"
    assert templating.render_value("{{ $h }}", "opencode") == "opencode"


@needs_chezmoi
def test_render_value_resolves_per_harness_branch():
    tmpl = '{{ if eq $h "claude" }}claude-code{{ else }}{{ $h }}{{ end }}'
    assert templating.render_value(tmpl, "claude") == "claude-code"
    assert templating.render_value(tmpl, "codex") == "codex"
    assert templating.render_value(tmpl, "cursor") == "cursor"
    assert templating.render_value(tmpl, "opencode") == "opencode"


@needs_chezmoi
def test_render_value_passes_through_plain_strings():
    # No template syntax => chezmoi prints it back verbatim.
    assert templating.render_value("serena-mux", "codex") == "serena-mux"


# ─── render_value: fall-backs ──────────────────────────────────────────


def test_render_value_returns_original_when_chezmoi_missing(capsys):
    with patch.object(templating.shutil, "which", return_value=None):
        out = templating.render_value("{{ $h }}", "codex")
    assert out == "{{ $h }}"
    err = capsys.readouterr().err
    assert "chezmoi not on PATH" in err
    assert "{{ $h }}" in err  # surfaces the first unrendered value


def test_render_value_warns_once_per_process(capsys):
    with patch.object(templating.shutil, "which", return_value=None):
        templating.render_value("{{ $h }}", "codex")
        templating.render_value("{{ $h }}", "cursor")
    err = capsys.readouterr().err
    # Exactly one warning line, no matter how many fall-backs.
    assert err.count("chezmoi not on PATH") == 1


def test_render_value_returns_original_when_chezmoi_errors(capsys):
    # Simulate a real chezmoi binary that fails on the template (e.g.
    # syntax error). The install must not abort the whole render.
    templating._chezmoi_bin = "/usr/bin/false"  # pre-seed cache
    err = subprocess.CalledProcessError(
        returncode=1, cmd=["chezmoi"], stderr="bad template"
    )
    with patch.object(templating.subprocess, "run", side_effect=err):
        out = templating.render_value("{{ borked }}", "codex")
    assert out == "{{ borked }}"
    captured = capsys.readouterr().err
    assert "chezmoi execute-template failed" in captured


# ─── render_mcp_for_harness ────────────────────────────────────────────


@needs_chezmoi
def test_render_mcp_resolves_env_per_harness():
    mcp = {
        "name": "serena",
        "command": "serena-mux",
        "env": {
            "SERENA_MUX_HARNESS": (
                '{{ if eq $h "claude" }}claude-code{{ else }}{{ $h }}{{ end }}'
            ),
            "OTHER_VAR": "static-value",
        },
    }
    out_claude = templating.render_mcp_for_harness(mcp, "claude")
    assert out_claude["env"]["SERENA_MUX_HARNESS"] == "claude-code"
    assert out_claude["env"]["OTHER_VAR"] == "static-value"

    out_codex = templating.render_mcp_for_harness(mcp, "codex")
    assert out_codex["env"]["SERENA_MUX_HARNESS"] == "codex"
    assert out_codex["env"]["OTHER_VAR"] == "static-value"


@needs_chezmoi
def test_render_mcp_resolves_args_per_harness():
    mcp = {
        "name": "serena",
        "command": "serena",
        "args": [
            "start-mcp-server",
            '--context={{ if eq $h "claude" }}claude-code{{ else }}{{ $h }}{{ end }}',
            "--project-from-cwd",
        ],
    }
    out = templating.render_mcp_for_harness(mcp, "codex")
    assert out["args"] == [
        "start-mcp-server",
        "--context=codex",
        "--project-from-cwd",
    ]


def test_render_mcp_returns_shallow_copy_does_not_mutate_input():
    # The same Manifest is projected across multiple harnesses in one
    # install; mutating the source would cross-contaminate later passes.
    mcp = {
        "name": "x",
        "command": "x",
        "args": ["a", "{{ $h }}"],
        "env": {"K": "{{ $h }}"},
    }
    original_args = mcp["args"]
    original_env = mcp["env"]
    with patch.object(templating, "render_value", return_value="RENDERED"):
        out = templating.render_mcp_for_harness(mcp, "codex")
    assert mcp["args"] is original_args  # not mutated
    assert mcp["env"] is original_env  # not mutated
    assert out["args"] is not original_args
    assert out["env"] is not original_env
    assert out["args"] == ["a", "RENDERED"]
    assert out["env"] == {"K": "RENDERED"}


def test_render_mcp_no_op_for_mcp_without_args_or_env():
    mcp = {"name": "x", "command": "x"}
    out = templating.render_mcp_for_harness(mcp, "codex")
    assert out == mcp
    assert out is not mcp  # still a shallow copy


def test_render_mcp_skips_render_for_static_values():
    # The render hot-path bails on values without `{{`; this guards
    # against the regression where every value would shell out to chezmoi.
    mcp = {"name": "x", "command": "x", "env": {"K": "plain"}}
    with patch.object(templating, "render_value") as fake_render:
        templating.render_mcp_for_harness(mcp, "codex")
    fake_render.assert_not_called()
