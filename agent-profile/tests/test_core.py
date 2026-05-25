"""test_core.py — parse / discover / manifest behavioral parity.

Ported from tests/agent-profile-core.bats. Strong assertions on exact
values, not just presence.
"""

from __future__ import annotations

import json

import pytest

from agent_profile import discover, manifest as m, parse
from agent_profile.manifest import ManifestCorrupt
from agent_profile.parse import ParseError, parse_manifest, parse_one
from tests.conftest import write_profile

# ─── parse_one ───────────────────────────────────────────────────────


def test_parse_one_defaults_empty_sections(env):
    write_profile(env.profiles, "minimal", "name: minimal\ndescription: tiny\n")
    out = parse_one(env.profiles / "minimal")
    assert out["name"] == "minimal"
    for section in ("mcps", "agents", "skills", "commands", "hooks"):
        assert out[section] == []


def test_parse_one_injects_source_dir(env):
    write_profile(
        env.profiles,
        "srctest",
        "name: srctest\n"
        "agents:\n  - name: foo\n    body_path: agents/foo.md\n"
        "hooks:\n  - event: PreToolUse\n    script: hooks/x.sh\n",
    )
    out = parse_one(env.profiles / "srctest")
    assert out["agents"][0]["_source_dir"] == str(env.profiles / "srctest")
    assert out["hooks"][0]["_source_dir"] == str(env.profiles / "srctest")


def test_parse_one_missing_name_fails(env):
    write_profile(env.profiles, "nameless", "description: noname\n")
    with pytest.raises(ParseError, match="missing required field 'name'"):
        parse_one(env.profiles / "nameless")


def test_parse_one_strips_fallback(env):
    write_profile(
        env.profiles,
        "fb",
        "name: fb\n"
        "agents:\n  - name: a\n    body_path: agents/a.md\n    fallback: legacy\n",
    )
    out = parse_one(env.profiles / "fb")
    assert "fallback" not in out["agents"][0]


# ─── input validation ────────────────────────────────────────────────


def test_parse_one_profile_name_shellmeta_fails(env):
    write_profile(env.profiles, "bad", "name: bad$name\n")
    with pytest.raises(ParseError, match="invalid profile name"):
        parse_one(env.profiles / "bad")


def test_parse_one_item_name_shellmeta_fails(env):
    write_profile(
        env.profiles,
        "shellmeta",
        "name: shellmeta\nagents:\n  - name: 'a;b'\n    body_path: agents/a.md\n",
    )
    with pytest.raises(ParseError, match="invalid item name"):
        parse_one(env.profiles / "shellmeta")


def test_parse_one_body_path_traversal_fails(env):
    write_profile(
        env.profiles,
        "traverse",
        "name: traverse\nagents:\n  - name: a\n    body_path: ../../etc/passwd\n",
    )
    with pytest.raises(ParseError) as exc:
        parse_one(env.profiles / "traverse")
    assert "invalid body_path" in str(exc.value)
    assert "must not contain '..'" in str(exc.value)


def test_parse_one_absolute_body_path_fails(env):
    write_profile(
        env.profiles,
        "absolute",
        "name: absolute\nagents:\n  - name: a\n    body_path: /etc/passwd\n",
    )
    with pytest.raises(ParseError) as exc:
        parse_one(env.profiles / "absolute")
    assert "invalid body_path" in str(exc.value)
    assert "must be relative" in str(exc.value)


def test_parse_one_hook_script_traversal_fails(env):
    write_profile(
        env.profiles,
        "hooktraverse",
        "name: hooktraverse\nhooks:\n  - event: SessionStart\n    script: ../outside.sh\n",
    )
    with pytest.raises(ParseError) as exc:
        parse_one(env.profiles / "hooktraverse")
    assert "invalid script" in str(exc.value)
    assert "must not contain '..'" in str(exc.value)


def test_parse_one_skill_path_traversal_fails(env):
    write_profile(
        env.profiles,
        "skilltraverse",
        "name: skilltraverse\nskills:\n  - name: s\n    path: skills/../../escape\n",
    )
    with pytest.raises(ParseError, match="invalid path"):
        parse_one(env.profiles / "skilltraverse")


def test_parse_one_dots_substring_name_passes(env):
    # 'a..b' has a '..' substring but no '..' path *component* — must pass.
    write_profile(
        env.profiles,
        "dots",
        "name: dots\nagents:\n  - name: a..b\n    body_path: agents/a..b.md\n",
    )
    out = parse_one(env.profiles / "dots")
    assert out["agents"][0]["name"] == "a..b"


def test_parse_one_bare_dotdot_name_rejected(env):
    write_profile(env.profiles, "dotdot", "name: '..'\n")
    with pytest.raises(ParseError, match="must not be '.' or '..'"):
        parse_one(env.profiles / "dotdot")


def test_parse_one_bare_dot_item_name_rejected(env):
    write_profile(
        env.profiles,
        "dot",
        "name: dot\nagents:\n  - name: '.'\n    body_path: agents/x.md\n",
    )
    with pytest.raises(ParseError, match="must not be '.' or '..'"):
        parse_one(env.profiles / "dot")


# ─── parse_manifest (includes) ───────────────────────────────────────


def test_parse_manifest_include_concatenates_includes_first(env):
    write_profile(
        env.profiles,
        "base",
        "name: base\nagents:\n  - name: a\n"
        "settings:\n  permissions_allow: [base-perm]\n",
    )
    write_profile(
        env.profiles,
        "leaf",
        "name: leaf\ninclude: [base]\nagents:\n  - name: b\n"
        "settings:\n  permissions_allow: [leaf-perm]\n",
    )
    out = parse_manifest(env.profiles / "leaf")
    assert out.name == "leaf"
    assert out.agents[0]["name"] == "a"
    assert out.agents[1]["name"] == "b"
    assert out.settings["permissions_allow"] == ["base-perm", "leaf-perm"]


def test_parse_manifest_permissions_dedup_sorted(env):
    write_profile(env.profiles, "base", "name: base\nsettings:\n  permissions_allow: [a, b]\n")
    write_profile(
        env.profiles,
        "leaf",
        "name: leaf\ninclude: [base]\nsettings:\n  permissions_allow: [b, c]\n",
    )
    out = parse_manifest(env.profiles / "leaf")
    # jq unique sorts; union is {a,b,c}.
    assert out.settings["permissions_allow"] == ["a", "b", "c"]


def test_parse_manifest_cycle_errors(env):
    write_profile(env.profiles, "a", "name: a\ninclude: [b]\n")
    write_profile(env.profiles, "b", "name: b\ninclude: [a]\n")
    with pytest.raises(ParseError, match="cycle detected"):
        parse_manifest(env.profiles / "a")


def test_parse_manifest_diamond_dag_allowed(env):
    write_profile(env.profiles, "dag_a", "name: dag_a\ninclude: [dag_b, dag_c]\n")
    write_profile(env.profiles, "dag_b", "name: dag_b\ninclude: [dag_d]\n")
    write_profile(env.profiles, "dag_c", "name: dag_c\ninclude: [dag_d]\n")
    write_profile(env.profiles, "dag_d", "name: dag_d\ndescription: shared base\n")
    out = parse_manifest(env.profiles / "dag_a")
    assert out.name == "dag_a"


def test_parse_manifest_missing_include_errors_with_name(env):
    write_profile(env.profiles, "orphan", "name: orphan\ninclude: [nonexistent]\n")
    with pytest.raises(ParseError, match="include 'nonexistent' not found"):
        parse_manifest(env.profiles / "orphan")


# ─── discover ─────────────────────────────────────────────────────────


def test_find_profile_dir_returns_match(env):
    write_profile(env.profiles, "foo", "name: foo\n")
    assert discover.find_profile_dir("foo") == (env.profiles / "foo").resolve()


def test_find_profile_dir_missing_returns_none(env):
    assert discover.find_profile_dir("notthere") is None


def test_find_profile_dir_per_repo_wins(env, monkeypatch):
    # Per-repo .agent-profiles (PWD) shadows global profiles.
    monkeypatch.delenv("AP_EXTRA_SEARCH_PATHS", raising=False)
    global_root = env.tmp / "global-root"
    monkeypatch.setenv("DOTFILES_DIR", str(global_root))
    (global_root / "profiles" / "dup").mkdir(parents=True)
    (global_root / "profiles" / "dup" / "profile.yaml").write_text(
        "name: dup\ndescription: global\n"
    )
    local = env.target / ".agent-profiles" / "dup"
    local.mkdir(parents=True)
    (local / "profile.yaml").write_text("name: dup\ndescription: local\n")
    assert discover.find_profile_dir("dup") == local.resolve()


def test_find_profile_dir_invalid_name_rejected(env):
    with pytest.raises(ParseError, match="invalid profile name"):
        discover.find_profile_dir("../escape")


def test_list_profiles_one_row_per_profile(env):
    write_profile(env.profiles, "a", "name: a\n")
    write_profile(env.profiles, "b", "name: b\n")
    rows = dict(discover.list_profiles())
    assert set(rows) == {"a", "b"}
    assert rows["a"] == env.profiles


# ─── manifest ──────────────────────────────────────────────────────────


def test_manifest_record_list_clear_roundtrip(env):
    t = env.tmp / "tgt"
    t.mkdir()
    m.record_file(t, "rust", ".claude/foo.md")
    m.record_file(t, "rust", ".claude/bar.md")
    files = m.files(t, "rust")
    assert files == sorted([".claude/bar.md", ".claude/foo.md"])
    m.clear(t, "rust")
    assert m.files(t, "rust") == []


def test_manifest_merged_json_roundtrip(env):
    t = env.tmp / "tgt"
    t.mkdir()
    m.record_merged_json(t, "rust", {"name": "rust", "mcps": []})
    assert m.merged_json(t, "rust")["name"] == "rust"


def test_other_profiles_claim_file_true_when_shared(env):
    t = env.tmp / "tgt"
    t.mkdir()
    m.record_file(t, "alpha", ".mcp.json")
    m.record_file(t, "beta", ".mcp.json")
    assert m.other_profiles_claim_file(t, "alpha", ".mcp.json") is True


def test_other_profiles_claim_file_false_when_sole(env):
    t = env.tmp / "tgt"
    t.mkdir()
    m.record_file(t, "alpha", ".mcp.json")
    assert m.other_profiles_claim_file(t, "alpha", ".mcp.json") is False


def test_other_profiles_claim_file_false_when_other_owns_different(env):
    t = env.tmp / "tgt"
    t.mkdir()
    m.record_file(t, "alpha", ".claude/agents/shared.md")
    m.record_file(t, "beta", ".something-else.md")
    assert m.other_profiles_claim_file(t, "alpha", ".claude/agents/shared.md") is False


def test_diff_and_clean_removes_dropped(env):
    t = env.tmp / "tgt"
    (t / ".claude").mkdir(parents=True)
    (t / ".claude/foo.md").touch()
    (t / ".claude/bar.md").touch()
    m.record_file(t, "rust", ".claude/foo.md")
    m.record_file(t, "rust", ".claude/bar.md")
    m.diff_and_clean(t, "rust", [".claude/foo.md"])
    assert (t / ".claude/foo.md").is_file()
    assert not (t / ".claude/bar.md").exists()


def test_diff_and_clean_keeps_claimed_by_other(env):
    t = env.tmp / "tgt"
    t.mkdir()
    (t / "shared.json").touch()
    m.record_file(t, "alpha", "shared.json")
    m.record_file(t, "beta", "shared.json")
    m.diff_and_clean(t, "alpha", [])
    assert (t / "shared.json").is_file()


def test_diff_and_clean_noop_when_nothing_dropped(env):
    t = env.tmp / "tgt"
    (t / ".claude").mkdir(parents=True)
    (t / ".claude/foo.md").touch()
    m.record_file(t, "rust", ".claude/foo.md")
    m.diff_and_clean(t, "rust", [".claude/foo.md"])
    assert (t / ".claude/foo.md").is_file()


def test_diff_and_clean_selective_preserves_other_harness(env):
    # A --harness claude re-install must not touch .codex/ entries.
    t = env.tmp / "tgt"
    (t / ".claude/agents").mkdir(parents=True)
    (t / ".codex/agents").mkdir(parents=True)
    (t / ".claude/agents/keep.md").touch()
    (t / ".codex/agents/keep.toml").touch()
    m.record_file(t, "rust", ".claude/agents/keep.md")
    m.record_file(t, "rust", ".codex/agents/keep.toml")
    # New claude files only; selective to claude. .codex stays.
    m.diff_and_clean(t, "rust", [], ["claude"])
    assert not (t / ".claude/agents/keep.md").exists()
    assert (t / ".codex/agents/keep.toml").is_file()


# ─── manifest corruption ─────────────────────────────────────────────


def _write_manifest(t, content):
    (t / ".agent-profile").mkdir(parents=True)
    (t / ".agent-profile/manifest.json").write_text(content)


def test_corrupt_json_fails_on_read(env):
    t = env.tmp / "tgt"
    t.mkdir()
    _write_manifest(t, "not-valid-json{")
    with pytest.raises(ManifestCorrupt) as exc:
        m.files(t, "rust")
    assert "corrupt" in str(exc.value)


def test_corrupt_non_object_top_level_fails(env):
    t = env.tmp / "tgt"
    t.mkdir()
    _write_manifest(t, '["not-an-object"]')
    with pytest.raises(ManifestCorrupt) as exc:
        m.files(t, "rust")
    assert "corrupt" in str(exc.value)
    assert "got array" in str(exc.value)


def test_corrupt_non_object_entry_fails(env):
    t = env.tmp / "tgt"
    t.mkdir()
    _write_manifest(t, '{"rust":"oops"}')
    with pytest.raises(ManifestCorrupt) as exc:
        m.files(t, "rust")
    assert "non-object entries for profile(s): rust" in str(exc.value)


def test_corrupt_fails_on_merged_json_read(env):
    t = env.tmp / "tgt"
    t.mkdir()
    _write_manifest(t, "garbage")
    with pytest.raises(ManifestCorrupt, match="corrupt"):
        m.merged_json(t, "rust")


def test_corrupt_fails_on_profiles_listing(env):
    t = env.tmp / "tgt"
    t.mkdir()
    _write_manifest(t, "][")
    with pytest.raises(ManifestCorrupt, match="corrupt"):
        m.profiles(t)
