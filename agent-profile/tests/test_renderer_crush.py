"""test_renderer_crush.py — crush.json merge + surgical clean (spec #223).

crush is the 6th harness: MCP-only (no skills/hooks/agents/permissions) and
non-isolated. The renderer mirrors :class:`OpencodeRenderer` minus those
surfaces — it merges the registry's coding MCPs into ``crush.json`` under the
top-level ``mcp`` key, with crush's own server shape
(``{type: "stdio", command, args?, env?}``) and crush's ``$(echo $VAR)``
env-expansion form.

The clean parity follows opencode's /age fix: a bootstrapped file that
reduces to ``{}`` OR ``{"$schema": ...}`` is removed; user keys survive a
render+clean round-trip.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile.parse import Manifest
from agent_profile.renderers.base import MergedConfigError, Renderer
from agent_profile.renderers.crush import CrushRenderer

SCHEMA = "https://charm.land/crush.json"


def _manifest() -> Manifest:
    """A manifest with one crush-scoped MCP (undeclared harnesses -> the
    default-include set, which contains crush) and one claude-only MCP that
    must be skipped."""
    return Manifest(
        name="rust",
        mcps=[
            {
                "name": "serena",
                "command": "serena",
                "args": ["start-mcp-server"],
                # No `harnesses` -> default-include flows to crush.
            },
            {"name": "claude-only", "command": "co", "harnesses": ["claude"]},
        ],
    )


def test_implements_renderer_protocol():
    r = CrushRenderer()
    assert isinstance(r, Renderer)
    assert r.name == "crush"


def test_mcp_default_includes_self_for_undeclared_flow():
    """D1: crush must be in its own ``mcp_default`` so an MCP that omits
    ``harnesses`` flows into crush (default-include parity with the other
    coding harnesses)."""
    assert "crush" in CrushRenderer().mcp_default


def test_merge_bootstrap_writes_schema_and_mcp_block(tmp_path: Path):
    """Fresh target: renderer bootstraps the crush schema stub then merges
    its server entry under the top-level ``mcp`` key."""
    CrushRenderer().render(_manifest(), tmp_path)
    got = json.loads((tmp_path / "crush.json").read_text())
    assert got["$schema"] == SCHEMA
    assert got["mcp"]["serena"] == {
        "type": "stdio",
        "command": "serena",
        "args": ["start-mcp-server"],
    }


def test_claude_only_mcp_never_reaches_crush(tmp_path: Path):
    """An MCP scoped to ``harnesses: [claude]`` must not render into crush."""
    CrushRenderer().render(_manifest(), tmp_path)
    got = json.loads((tmp_path / "crush.json").read_text())
    assert "claude-only" not in got["mcp"]


def test_empty_harnesses_mcp_excluded(tmp_path: Path):
    """An MCP with ``harnesses: []`` (e.g. todoist) is scoped out of every
    harness, crush included — the empty list never falls back to the
    default-include set."""
    m = Manifest(
        name="x",
        mcps=[{"name": "todoist", "command": "npx", "harnesses": []}],
    )
    CrushRenderer().render(m, tmp_path)
    assert not (tmp_path / "crush.json").exists()


def test_merge_preserves_user_entries(tmp_path: Path):
    """Pre-existing user crush.json: ours merge in, user's stay."""
    (tmp_path / "crush.json").write_text(
        json.dumps(
            {
                "$schema": SCHEMA,
                "options": {"context_paths": ["CRUSH.md"]},
                "mcp": {
                    "user-mcp": {"type": "stdio", "command": "my-tool"}
                },
            }
        )
    )
    CrushRenderer().render(_manifest(), tmp_path)
    got = json.loads((tmp_path / "crush.json").read_text())
    assert got["options"] == {"context_paths": ["CRUSH.md"]}
    assert got["mcp"]["user-mcp"] == {"type": "stdio", "command": "my-tool"}
    assert got["mcp"]["serena"]["command"] == "serena"


def test_render_does_not_track_merged_file(tmp_path: Path):
    """crush.json is a merged file, never a whole-file artefact — it must
    not appear in the returned manifest paths (clean undoes it)."""
    written = CrushRenderer().render(_manifest(), tmp_path)
    assert written == []


def test_no_mcps_writes_nothing(tmp_path: Path):
    """Empty crush scope: no file bootstrapped (parity with opencode's
    early-return)."""
    CrushRenderer().render(Manifest(name="empty"), tmp_path)
    assert not (tmp_path / "crush.json").exists()


def test_mcp_without_env_omits_env_key(tmp_path: Path):
    """No ``env`` -> no ``env`` key on the server record."""
    m = Manifest(
        name="noenv",
        mcps=[{"name": "noenv", "command": "foo"}],
    )
    CrushRenderer().render(m, tmp_path)
    server = json.loads((tmp_path / "crush.json").read_text())["mcp"]["noenv"]
    assert "env" not in server
    assert server == {"type": "stdio", "command": "foo"}


def test_mcp_without_args_omits_args_key(tmp_path: Path):
    """No ``args`` -> no ``args`` key (crush defaults it; we omit when absent)."""
    m = Manifest(
        name="noargs",
        mcps=[{"name": "noargs", "command": "foo"}],
    )
    CrushRenderer().render(m, tmp_path)
    server = json.loads((tmp_path / "crush.json").read_text())["mcp"]["noargs"]
    assert "args" not in server


def test_mcp_env_rewrites_var_to_crush_shell_eval(tmp_path: Path):
    """crush expands env via ``$(echo $VAR)`` shell-eval (charmbracelet/crush
    README), NOT opencode's ``{env:VAR}``. Each ``${VAR}`` is rewritten to
    ``$(echo $VAR)``; a plain literal passes through untouched, and no
    resolved secret lands on disk."""
    m = Manifest(
        name="withvar",
        mcps=[
            {
                "name": "withvar",
                "command": "npx",
                "env": {
                    "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}",
                    "CRG_TOOLS": "build,review",
                },
            }
        ],
    )
    CrushRenderer().render(m, tmp_path)
    raw = (tmp_path / "crush.json").read_text()
    server = json.loads(raw)["mcp"]["withvar"]
    assert server["env"] == {
        "CONTEXT7_API_KEY": "$(echo $CONTEXT7_API_KEY)",
        "CRG_TOOLS": "build,review",
    }
    assert "${CONTEXT7_API_KEY}" not in raw


def test_mcp_env_rewrites_embedded_var(tmp_path: Path):
    """A ``${VAR}`` embedded in a larger value is rewritten in place; only the
    ``${VAR}`` token is touched, surrounding text is preserved."""
    m = Manifest(
        name="embed",
        mcps=[
            {
                "name": "embed",
                "command": "foo",
                "env": {"URL": "https://x/${TOKEN}/y"},
            }
        ],
    )
    CrushRenderer().render(m, tmp_path)
    server = json.loads((tmp_path / "crush.json").read_text())["mcp"]["embed"]
    assert server["env"]["URL"] == "https://x/$(echo $TOKEN)/y"


def test_mcp_env_bare_dollar_and_boundaries_untouched(tmp_path: Path):
    """Only the ``${IDENT}`` form is rewritten. A bare ``$VAR`` (no braces), a
    literal ``$`` (a price), and a malformed ``${}`` pass through untouched —
    the rewrite must not broaden into shell expansion or it corrupts
    non-secret literals. Multiple tokens in one value are each rewritten."""
    m = Manifest(
        name="bounds",
        mcps=[
            {
                "name": "bounds",
                "command": "foo",
                "env": {
                    "BARE": "$NOT_A_REF",
                    "PRICE": "costs $5.00 USD",
                    "MALFORMED": "${}",
                    "MULTI": "${A}-${B}",
                },
            }
        ],
    )
    CrushRenderer().render(m, tmp_path)
    env = json.loads((tmp_path / "crush.json").read_text())["mcp"]["bounds"]["env"]
    assert env["BARE"] == "$NOT_A_REF"
    assert env["PRICE"] == "costs $5.00 USD"
    assert env["MALFORMED"] == "${}"
    assert env["MULTI"] == "$(echo $A)-$(echo $B)"


def test_clean_keeps_user_entries(tmp_path: Path):
    """Install over user content, then clean: only ours are removed."""
    (tmp_path / "crush.json").write_text(
        json.dumps(
            {
                "$schema": SCHEMA,
                "options": {"context_paths": ["CRUSH.md"]},
                "mcp": {
                    "user-mcp": {"type": "stdio", "command": "my-tool"}
                },
            }
        )
    )
    r = CrushRenderer()
    m = _manifest()
    r.render(m, tmp_path)
    r.clean(m, tmp_path)
    got = json.loads((tmp_path / "crush.json").read_text())
    assert "serena" not in got["mcp"]
    assert got["mcp"]["user-mcp"]["command"] == "my-tool"
    assert got["options"] == {"context_paths": ["CRUSH.md"]}


def test_clean_missing_file_is_noop(tmp_path: Path):
    """Clean on a target with no crush.json does nothing, no error."""
    CrushRenderer().clean(_manifest(), tmp_path)
    assert not (tmp_path / "crush.json").exists()


def test_clean_is_idempotent_on_user_file(tmp_path: Path):
    """Cleaning twice leaves the user-owned file identical the second time."""
    (tmp_path / "crush.json").write_text(
        json.dumps(
            {
                "$schema": SCHEMA,
                "mcp": {"user-mcp": {"type": "stdio", "command": "my-tool"}},
            }
        )
    )
    r = CrushRenderer()
    m = _manifest()
    r.render(m, tmp_path)
    r.clean(m, tmp_path)
    once = (tmp_path / "crush.json").read_text()
    r.clean(m, tmp_path)
    twice = (tmp_path / "crush.json").read_text()
    assert once == twice
    assert json.loads(twice)["mcp"]["user-mcp"]["command"] == "my-tool"


def test_clean_removes_bootstrapped_schema_only(tmp_path: Path):
    """Round-trip on a fresh target: install bootstraps the schema stub,
    clean strips ours back to ``{"$schema": ...}`` and removes the file."""
    r = CrushRenderer()
    m = _manifest()
    r.render(m, tmp_path)
    assert (tmp_path / "crush.json").exists()
    r.clean(m, tmp_path)
    assert not (tmp_path / "crush.json").exists()


def test_clean_removes_bootstrapped_empty_braces(tmp_path: Path):
    """A target whose crush.json reduces to a bare ``{}`` after surgical
    removal (no ``$schema`` key) is removed (opencode's /age-fix parity)."""
    (tmp_path / "crush.json").write_text(
        json.dumps(
            {
                "mcp": {
                    "serena": {
                        "type": "stdio",
                        "command": "serena",
                        "args": ["start-mcp-server"],
                    }
                }
            }
        )
    )
    CrushRenderer().clean(_manifest(), tmp_path)
    assert not (tmp_path / "crush.json").exists()


def test_prune_mcps_delegates_to_clean(tmp_path: Path):
    """prune_mcps removes the dropped server's entry (D3: delegates to clean)."""
    (tmp_path / "crush.json").write_text(
        json.dumps(
            {
                "$schema": SCHEMA,
                "mcp": {
                    "serena": {"type": "stdio", "command": "serena"},
                    "user-mcp": {"type": "stdio", "command": "my-tool"},
                },
            }
        )
    )
    dropped = Manifest(
        name="rust",
        mcps=[{"name": "serena", "command": "serena"}],
    )
    CrushRenderer().prune_mcps(dropped, tmp_path)
    got = json.loads((tmp_path / "crush.json").read_text())
    assert "serena" not in got["mcp"]
    assert "user-mcp" in got["mcp"]


def test_corrupt_config_raises_clean_error(tmp_path: Path):
    """A hand-corrupted crush.json surfaces MergedConfigError on render and
    clean, not an uncaught JSONDecodeError traceback."""
    (tmp_path / "crush.json").write_text("{not valid json")
    with pytest.raises(MergedConfigError):
        CrushRenderer().render(_manifest(), tmp_path)
    with pytest.raises(MergedConfigError):
        CrushRenderer().clean(_manifest(), tmp_path)


# ─── real-registry contract (spec acceptance, #223 D1) ──────────────────
#
# The tests above drive a synthetic two-MCP manifest. The spec's central
# acceptance criterion is a property of the SHIPPED registry: rendering the
# real `base` profile (the union that reads agents/mcp/registry.yaml) into
# crush must yield EXACTLY the six coding MCPs and exclude todoist. Nothing
# above locks that — a registry edit that scoped a coding MCP away from the
# default-include set, or dropped `harnesses: []` from todoist, would leak
# past every synthetic test. This loads the real registry the same way
# test_overlay's `test_real_*_profile` tests do (DOTFILES_DIR -> repo root,
# parse the base profile). The renderer rewrites `${VAR}` -> `$(echo $VAR)`
# but does NOT resolve it, so no .env / credential stub is needed.

# Repo root: agent-profile/tests/test_renderer_crush.py -> ../../ is the clone.
REPO_ROOT = Path(__file__).resolve().parents[2]

# The exact MCP set crush must receive: every registry MCP that omits
# `harnesses` (default-include) flows to crush; todoist (`harnesses: []`) does
# not. Mirrors the spec acceptance bullet verbatim.
_CRUSH_REGISTRY_MCPS = {
    "tilth",
    "hallouminate",
    "context7",
    "tavily",
    "code-review-graph",
    "serena",
}


def _real_base_manifest(monkeypatch) -> Manifest:
    """Parse the shipped `base` profile against the real repo registry."""
    from agent_profile.discover import find_profile_dir
    from agent_profile.parse import parse_manifest

    monkeypatch.setenv("DOTFILES_DIR", str(REPO_ROOT))
    monkeypatch.delenv("AP_EXTRA_SEARCH_PATHS", raising=False)
    pdir = find_profile_dir("base")
    assert pdir is not None, "real profiles/base not found"
    return parse_manifest(pdir)


def test_real_registry_renders_exactly_the_coding_mcp_set(tmp_path, monkeypatch):
    """The shipped registry, rendered into crush, is EXACTLY the six coding
    MCPs — no more (a future MCP added without `harnesses` flows in and would
    trip this) and no fewer (a coding MCP scoped away would trip this)."""
    m = _real_base_manifest(monkeypatch)
    CrushRenderer().render(m, tmp_path)
    data = json.loads((tmp_path / "crush.json").read_text())
    assert set(data["mcp"]) == _CRUSH_REGISTRY_MCPS


def test_real_registry_excludes_todoist(tmp_path, monkeypatch):
    """todoist carries `harnesses: []` (scoped out of every harness); it must
    not reach crush. A regression that dropped the empty list would fall back
    to the default-include set and leak todoist's ~38k-token tool footprint
    into every crush session."""
    m = _real_base_manifest(monkeypatch)
    CrushRenderer().render(m, tmp_path)
    data = json.loads((tmp_path / "crush.json").read_text())
    assert "todoist" not in data["mcp"]


def test_real_registry_secrets_render_as_crush_shell_eval(tmp_path, monkeypatch):
    """The credentialed MCPs (context7, tavily) carry a `${VAR}` env ref in the
    real registry. Rendered into crush each must become `$(echo $VAR)` — the
    documented crush expansion form — and NO resolved secret value may land on
    disk. This is the env-rewrite contract exercised against the real registry
    values, not a synthetic `${CONTEXT7_API_KEY}` literal. (Live-launch
    resolution stays verify-in-deploy: the crush binary is not installed here.)"""
    m = _real_base_manifest(monkeypatch)
    CrushRenderer().render(m, tmp_path)
    raw = (tmp_path / "crush.json").read_text()
    data = json.loads(raw)
    assert data["mcp"]["context7"]["env"] == {
        "CONTEXT7_API_KEY": "$(echo $CONTEXT7_API_KEY)"
    }
    assert data["mcp"]["tavily"]["env"] == {
        "TAVILY_API_KEY": "$(echo $TAVILY_API_KEY)"
    }
    # No bare `${VAR}` and no resolved key survives into the rendered file.
    assert "${CONTEXT7_API_KEY}" not in raw
    assert "${TAVILY_API_KEY}" not in raw


def test_real_registry_serena_context_resolves_to_crush(tmp_path, monkeypatch):
    """serena's `--context={{ $h }}` template must resolve to `--context=crush`
    for this harness — proving crush flows through the per-harness templating
    pass with ZERO per-MCP registry edits (the D1 default-include claim). A
    regression that hardcoded a context, or failed to pass `crush` as `$h`,
    would surface here."""
    m = _real_base_manifest(monkeypatch)
    CrushRenderer().render(m, tmp_path)
    data = json.loads((tmp_path / "crush.json").read_text())
    assert "--context=crush" in data["mcp"]["serena"]["args"]


def test_real_registry_clean_round_trip_removes_bootstrapped_file(
    tmp_path, monkeypatch
):
    """Render the real coding set onto a fresh target, then clean: every one of
    ours is removed and the bootstrapped file (schema-stub only) is unlinked —
    the install/uninstall parity with opencode, exercised on the real set."""
    m = _real_base_manifest(monkeypatch)
    r = CrushRenderer()
    r.render(m, tmp_path)
    assert (tmp_path / "crush.json").exists()
    r.clean(m, tmp_path)
    assert not (tmp_path / "crush.json").exists()
