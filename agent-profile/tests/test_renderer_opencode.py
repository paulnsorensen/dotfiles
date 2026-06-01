"""test_renderer_opencode.py — opencode.json merge + surgical clean.

Ports the JSON-shape assertions from
tests/agent-profile-renderers-opencode.bats (the upstream bash suite) and
freezes the bash merge/clean output as golden fixtures under
fixtures/golden/opencode/.

The one intentional parity break: the bash ``opencode_clean`` removes the
bootstrapped ``opencode.json`` only when it reduces to exactly
``{"$schema": ...}``; when it reduces to a bare ``{}`` (no schema key) the
bash leaves an empty ``{}`` file behind. This was the /age finding. The
Python port removes the file in *both* cases, and
``test_clean_removes_bootstrapped_*`` proves it.
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_profile.parse import Manifest
from agent_profile.renderers.base import Renderer
from agent_profile.renderers.opencode import OpencodeRenderer

GOLDEN = Path(__file__).parent / "fixtures" / "golden" / "opencode"

SCHEMA = "https://opencode.ai/config.json"


def _manifest() -> Manifest:
    """A manifest whose opencode-scoped MCPs and permissions mirror the
    inputs used to freeze the golden fixtures (one opencode MCP, one
    claude-only MCP that must be skipped, a prefix-form Bash permission
    that translates, and two that do not)."""
    return Manifest(
        name="rust",
        mcps=[
            {
                "name": "serena",
                "command": "serena",
                "args": ["start-mcp-server"],
                "harnesses": ["claude", "codex", "opencode"],
            },
            {"name": "claude-only", "command": "co", "harnesses": ["claude"]},
        ],
        settings={
            "permissions_allow": [
                "Bash(cargo:*)",
                "Edit",
                "Bash(git push origin main)",
            ]
        },
    )


def _load_golden(name: str) -> dict:
    return json.loads((GOLDEN / name).read_text())


def test_implements_renderer_protocol():
    r = OpencodeRenderer()
    assert isinstance(r, Renderer)
    assert r.name == "opencode"


def test_merge_bootstrap_matches_golden(tmp_path: Path):
    """Fresh target: renderer bootstraps the schema stub then merges its
    mcp + permission entries. Byte-shape must match the frozen bash output."""
    OpencodeRenderer().render(_manifest(), tmp_path)
    got = json.loads((tmp_path / "opencode.json").read_text())
    assert got == _load_golden("merge_bootstrap.json")


def test_merge_preserves_user_entries_matches_golden(tmp_path: Path):
    """Pre-existing user opencode.json: ours merge in, user's stay."""
    (tmp_path / "opencode.json").write_text(
        json.dumps(
            {
                "$schema": SCHEMA,
                "model": "anthropic/claude-sonnet-4-5",
                "mcp": {
                    "user-mcp": {
                        "type": "local",
                        "enabled": True,
                        "command": ["my-tool"],
                    }
                },
                "permission": {"bash": {"npm *": "allow"}},
            }
        )
    )
    OpencodeRenderer().render(_manifest(), tmp_path)
    got = json.loads((tmp_path / "opencode.json").read_text())
    assert got == _load_golden("merge_into_user.json")
    # The claude-only MCP must never reach opencode.json.
    assert "claude-only" not in got["mcp"]


def test_permission_translation_prefix_form(tmp_path: Path):
    """``Bash(cargo:*)`` -> ``cargo *``; non-prefix forms pass through raw."""
    OpencodeRenderer().render(_manifest(), tmp_path)
    bash = json.loads((tmp_path / "opencode.json").read_text())["permission"][
        "bash"
    ]
    assert bash["cargo *"] == "allow"
    assert bash["Edit"] == "allow"
    assert bash["Bash(git push origin main)"] == "allow"
    assert "Bash(cargo:*)" not in bash


def test_render_does_not_track_merged_file(tmp_path: Path):
    """opencode.json is a merged file, never a whole-file artefact — it
    must not appear in the returned manifest paths (clean undoes it)."""
    written = OpencodeRenderer().render(_manifest(), tmp_path)
    assert "opencode.json" not in written


def test_no_mcps_no_perms_writes_nothing(tmp_path: Path):
    """Empty opencode scope: no file bootstrapped (bash early-returns)."""
    OpencodeRenderer().render(Manifest(name="empty"), tmp_path)
    assert not (tmp_path / "opencode.json").exists()


def test_clean_keeps_user_entries_matches_golden(tmp_path: Path):
    """Install over user content, then clean: only ours are removed."""
    (tmp_path / "opencode.json").write_text(
        json.dumps(
            {
                "$schema": SCHEMA,
                "model": "anthropic/claude-sonnet-4-5",
                "mcp": {
                    "user-mcp": {
                        "type": "local",
                        "enabled": True,
                        "command": ["my-tool"],
                    }
                },
                "permission": {"bash": {"npm *": "allow"}},
            }
        )
    )
    r = OpencodeRenderer()
    m = _manifest()
    r.render(m, tmp_path)
    r.clean(m, tmp_path)
    got = json.loads((tmp_path / "opencode.json").read_text())
    assert got == _load_golden("clean_keeps_user.json")
    assert "serena" not in got["mcp"]
    assert "user-mcp" in got["mcp"]
    assert "cargo *" not in got["permission"]["bash"]
    assert "npm *" in got["permission"]["bash"]


def test_mcp_env_maps_to_environment(tmp_path: Path):
    """An MCP carrying ``env`` renders an ``environment`` key on the server
    record (the bash ``+ {environment: .env}`` branch). Without this test
    the env-mapping branch in ``_mcp_server_record`` is unexercised."""
    m = Manifest(
        name="withenv",
        mcps=[
            {
                "name": "withenv",
                "command": "foo",
                "args": ["--x"],
                "env": {"KEY": "val"},
                "harnesses": ["opencode"],
            }
        ],
    )
    OpencodeRenderer().render(m, tmp_path)
    server = json.loads((tmp_path / "opencode.json").read_text())["mcp"][
        "withenv"
    ]
    assert server == {
        "type": "local",
        "enabled": True,
        "command": ["foo", "--x"],
        "environment": {"KEY": "val"},
    }


def test_mcp_env_rewrites_var_to_opencode_placeholder(tmp_path: Path):
    """Criterion 7: opencode does not understand ``${VAR}`` (it passes it
    through verbatim and breaks). Each ``${VAR}`` occurrence is rewritten to
    opencode's ``{env:VAR}`` syntax; a plain literal (e.g. SERENA_MUX_HARNESS,
    which is render-time, not a secret) passes through untouched. No resolved
    secret on disk — opencode expands ``{env:VAR}`` from its process env."""
    m = Manifest(
        name="withvar",
        mcps=[
            {
                "name": "withvar",
                "command": "foo",
                "env": {
                    "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}",
                    "SERENA_MUX_HARNESS": "opencode",
                },
                "harnesses": ["opencode"],
            }
        ],
    )
    OpencodeRenderer().render(m, tmp_path)
    raw = (tmp_path / "opencode.json").read_text()
    server = json.loads(raw)["mcp"]["withvar"]
    assert server["environment"] == {
        "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}",
        "SERENA_MUX_HARNESS": "opencode",
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
                "harnesses": ["opencode"],
            }
        ],
    )
    OpencodeRenderer().render(m, tmp_path)
    server = json.loads((tmp_path / "opencode.json").read_text())["mcp"]["embed"]
    assert server["environment"]["URL"] == "https://x/{env:TOKEN}/y"


def test_mcp_env_bare_dollar_and_multi_var_boundaries(tmp_path: Path):
    """Boundary: only the ``${IDENT}`` form is rewritten. A bare ``$VAR``
    (no braces), a literal ``$`` (e.g. a price), and a malformed ``${}`` must
    pass through UNTOUCHED — the rewrite must not broaden into shell-style
    expansion or it would corrupt non-secret literals. Multiple ``${VAR}``
    tokens in one value are each rewritten (``re.sub`` is global)."""
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
                "harnesses": ["opencode"],
            }
        ],
    )
    OpencodeRenderer().render(m, tmp_path)
    env = json.loads((tmp_path / "opencode.json").read_text())["mcp"]["bounds"][
        "environment"
    ]
    assert env["BARE"] == "$NOT_A_REF"
    assert env["PRICE"] == "costs $5.00 USD"
    assert env["MALFORMED"] == "${}"
    assert env["MULTI"] == "{env:A}-{env:B}"


def test_mcp_without_env_omits_environment(tmp_path: Path):
    """No ``env`` -> no ``environment`` key (the bash ``else {}`` branch)."""
    m = Manifest(
        name="noenv",
        mcps=[{"name": "noenv", "command": "foo", "harnesses": ["opencode"]}],
    )
    OpencodeRenderer().render(m, tmp_path)
    server = json.loads((tmp_path / "opencode.json").read_text())["mcp"][
        "noenv"
    ]
    assert "environment" not in server
    assert server["command"] == ["foo"]


def test_clean_missing_file_is_noop(tmp_path: Path):
    """Clean on a target with no opencode.json does nothing, no error."""
    OpencodeRenderer().clean(_manifest(), tmp_path)
    assert not (tmp_path / "opencode.json").exists()


def test_clean_is_idempotent_on_user_file(tmp_path: Path):
    """Cleaning twice leaves the user-owned file identical the second time
    (the surgical removal must not corrupt or re-trim user entries)."""
    (tmp_path / "opencode.json").write_text(
        json.dumps(
            {
                "$schema": SCHEMA,
                "mcp": {
                    "user-mcp": {
                        "type": "local",
                        "enabled": True,
                        "command": ["my-tool"],
                    }
                },
                "permission": {"bash": {"npm *": "allow"}},
            }
        )
    )
    r = OpencodeRenderer()
    m = _manifest()
    r.render(m, tmp_path)
    r.clean(m, tmp_path)
    once = (tmp_path / "opencode.json").read_text()
    r.clean(m, tmp_path)
    twice = (tmp_path / "opencode.json").read_text()
    assert once == twice
    assert json.loads(twice)["mcp"]["user-mcp"]["command"] == ["my-tool"]


def test_clean_removes_bootstrapped_schema_only(tmp_path: Path):
    """Round-trip on a fresh target: install bootstraps the schema stub,
    clean strips ours back down to ``{"$schema": ...}`` and removes the
    file (this case the bash also got right)."""
    r = OpencodeRenderer()
    m = _manifest()
    r.render(m, tmp_path)
    assert (tmp_path / "opencode.json").exists()
    r.clean(m, tmp_path)
    assert not (tmp_path / "opencode.json").exists()


def test_clean_removes_bootstrapped_empty_braces(tmp_path: Path):
    """THE /age FIX. A target whose opencode.json reduces to a bare ``{}``
    after surgical removal (no ``$schema`` key) must be removed. The bash
    port left an empty ``{}`` file here — this asserts the divergence."""
    (tmp_path / "opencode.json").write_text(
        json.dumps(
            {
                "mcp": {
                    "serena": {
                        "type": "local",
                        "enabled": True,
                        "command": ["serena", "start-mcp-server"],
                    }
                }
            }
        )
    )
    OpencodeRenderer().clean(_manifest(), tmp_path)
    assert not (tmp_path / "opencode.json").exists(), (
        "clean must remove a bootstrapped opencode.json that reduces to {} — "
        "the bash leaves an empty {} behind; the Python port must not"
    )


def test_corrupt_config_raises_clean_error(tmp_path: Path):
    """A hand-corrupted opencode.json surfaces MergedConfigError (caught by
    cli.main → clean stderr + exit 1) on both render and clean, not an
    uncaught JSONDecodeError traceback. Exercises the shared
    base.read_json_object guard used by all three merged-file renderers."""
    import pytest

    from agent_profile.renderers.base import MergedConfigError

    cfg = tmp_path / "opencode.json"
    cfg.write_text("{not valid json")
    with pytest.raises(MergedConfigError):
        OpencodeRenderer().render(_manifest(), tmp_path)
    with pytest.raises(MergedConfigError):
        OpencodeRenderer().clean(_manifest(), tmp_path)


def test_non_object_config_raises_clean_error(tmp_path: Path):
    """A JSON array (valid JSON, wrong shape) is also a clean MergedConfigError
    rather than an AttributeError when the renderer calls .setdefault/.get."""
    import pytest

    from agent_profile.renderers.base import MergedConfigError

    (tmp_path / "opencode.json").write_text("[1, 2, 3]")
    with pytest.raises(MergedConfigError):
        OpencodeRenderer().render(_manifest(), tmp_path)
