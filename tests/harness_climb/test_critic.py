from __future__ import annotations

import json
import os
import unittest
from unittest import mock

from .support import RepoCase, call, hc_critic, hc_policy

REGISTRY = """sources:
  paulnsorensen/easy-cheese:
    description: toolkit
  paulnsorensen/routines:
    description: routines
    skills: [wiki-curator, routine-env]
"""


class CriticCase(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.commit(
            {
                "AGENTS.md": "base\n",
                "agents/preamble.md": "base\n",
                "skills/_registry.yaml": REGISTRY,
                "skills/mine/SKILL.md": "The zebracorp rollout kept the same ordinary text.\n",
                "agents/instruction-budgets.toml": "version = 1\n",
            }
        )
        self.git("checkout", "-q", "-b", "harness-climb/t1/r1")

    def propose(
        self,
        files: dict[str, str],
        tags: dict | None = None,
        deny: dict | None = None,
        budget: str = "true",
    ) -> tuple[int, dict]:
        self.commit(files, "propose")
        tags_file = self.write_json(
            "tags.json", {p: _tag(p) for p in files} if tags is None else tags
        )
        deny_file = self.write_json("deny.json", deny or {})
        return call(
            "critic",
            "--repo",
            str(self.repo),
            "--state-dir",
            str(self.state),
            "--thread",
            "t1",
            "--round",
            "1",
            "--base",
            "main",
            "--tags",
            str(tags_file),
            "--denylist",
            str(deny_file),
            "--budget-cmd",
            budget,
        )

    def categories(self, out: dict) -> set[str]:
        return {v["category"] for v in out["violations"]}

    # --- AC-4 tags ---

    def test_tag_good_proposal_passes(self) -> None:
        rc, out = self.propose(
            {"skills/mine/SKILL.md": "better\n", "AGENTS.md": "better\n"}
        )
        self.assertEqual((rc, out["status"]), (0, "pass"), out)

    def test_tag_wrong_branch_name_is_rejected(self) -> None:
        self.git("checkout", "-q", "-b", "feature/x")
        rc, out = self.propose({"AGENTS.md": "better\n"})
        self.assertEqual(rc, 1)
        self.assertIn("branch-name", self.categories(out))

    def test_tag_missing_is_rejected(self) -> None:
        _rc, out = self.propose({"AGENTS.md": "better\n"}, tags={})
        self.assertIn("tag-missing", self.categories(out))

    def test_tag_multiple_is_rejected(self) -> None:
        _rc, out = self.propose(
            {"AGENTS.md": "better\n"}, tags={"AGENTS.md": ["global-doc", "preamble"]}
        )
        self.assertIn("tag-multiple", self.categories(out))

    def test_tag_not_matching_the_path_class_is_rejected(self) -> None:
        _rc, out = self.propose({"AGENTS.md": "better\n"}, tags={"AGENTS.md": "hook"})
        self.assertIn("tag-mismatch", self.categories(out))

    def test_tag_unknown_name_is_rejected(self) -> None:
        _rc, out = self.propose({"AGENTS.md": "better\n"}, tags={"AGENTS.md": "prompt"})
        self.assertIn("tag-unknown", self.categories(out))

    def test_tag_path_classes_cover_the_five_components(self) -> None:
        cases = {
            "AGENTS.md": "global-doc",
            "profiles/fe/CLAUDE.md": "global-doc",
            "agents/preamble.md": "preamble",
            "agents/registry.yaml": "agent-def",
            "agents/agent_definitions/coder.md": "agent-def",
            "agents/hooks/registry.yaml": "hook",
            "claude/hooks/x.js": "hook",
            "skills/mine/SKILL.md": "skill",
            "skills/_registry.yaml": None,
            "bin/dots": None,
        }
        for path, tag in cases.items():
            self.assertEqual(hc_policy.classify(path), tag, path)

    # --- AC-5 scope ---

    def test_scope_vendored_runtime_and_unowned_paths_are_rejected(self) -> None:
        files = {
            "skills/easy-cheese/SKILL.md": "x",
            "skills/wiki-curator/SKILL.md": "x",
            ".claude/settings.json": "{}",
            "bin/dots": "x",
            "skills/_registry.yaml": REGISTRY + "# edit\n",
        }
        rc, out = self.propose(files, tags={p: "skill" for p in files}, budget="false")
        self.assertEqual(rc, 1)
        by_path = {
            v["path"]: v["category"] for v in out["violations"] if v["check"] == "scope"
        }
        self.assertEqual(by_path["skills/easy-cheese/SKILL.md"], "vendored")
        self.assertEqual(by_path["skills/wiki-curator/SKILL.md"], "vendored")
        self.assertEqual(by_path[".claude/settings.json"], "runtime-output")
        self.assertEqual(by_path["bin/dots"], "outside-allowlist")
        self.assertEqual(by_path["skills/_registry.yaml"], "outside-allowlist")
        self.assertNotIn(
            "budget-exit",
            self.categories(out),
            "budget check must not run after a scope failure",
        )

    def test_scope_rejects_absolute_home_and_parent_paths(self) -> None:
        got = hc_policy.check_scope(
            ["/etc/passwd", "~/.claude/x", "../x", "skills/mine/../../bin/dots"], set()
        )
        self.assertEqual(
            [v["category"] for v in got],
            ["runtime-output", "runtime-output", "runtime-output", "outside-allowlist"],
        )

    def test_scope_freeze_refuses_a_proposal_without_a_passing_critic_verdict(
        self,
    ) -> None:
        self.commit({"bin/dots": "x"}, "bad")
        rc, out = call(
            "freeze",
            "--repo",
            str(self.repo),
            "--state-dir",
            str(self.state),
            "--thread",
            "t1",
            "--round",
            "1",
            "--base",
            "main",
            "--component",
            "skill",
            "--targeted-query",
            "SELECT 1",
        )
        self.assertEqual(rc, 1)
        self.assertEqual(out["status"], "refused")
        self.assertFalse((self.repo / "harness-climb").exists())

    # --- AC-6 leakage ---

    def test_leakage_prompt_ngram_is_rejected_without_prompt_text(self) -> None:
        prompt = (
            "please refactor the secret billing pipeline for acme corporation right now"
        )
        text = "line one\nwe should refactor the secret billing pipeline for acme corporation soon\n"
        rc, out = self.propose({"AGENTS.md": text}, deny={"prompts": [prompt]})
        self.assertEqual(rc, 1)
        self.assertEqual(
            [(v["category"], v["file"], v["line"]) for v in out["violations"]],
            [("prompt", "AGENTS.md", 2)],
        )
        blob = json.dumps(out).lower()
        for word in ("billing", "acme", "refactor"):
            self.assertNotIn(word, blob)

    def test_leakage_project_name_and_repo_path_are_rejected(self) -> None:
        deny = {"projects": ["/Users/someone/work/zebracorp"]}
        _rc, out = self.propose(
            {"AGENTS.md": "see zebracorp\nopen /users/someone/work/zebracorp/src\n"},
            deny=deny,
        )
        got = sorted((v["category"], v["line"]) for v in out["violations"])
        self.assertEqual(got, [("path", 2), ("project", 1), ("project", 2)])

    def test_leakage_checks_added_lines_only(self) -> None:
        deny = {"projects": ["/Users/someone/work/zebracorp"]}
        rc, out = self.propose(
            {
                "skills/mine/SKILL.md": "The zebracorp rollout kept the same ordinary text.\nA new clean line.\n"
            },
            deny=deny,
        )
        self.assertEqual((rc, out["status"]), (0, "pass"), out)

    def test_leakage_ngram_needs_a_full_window_of_matching_words(self) -> None:
        prompt = (
            "please refactor the secret billing pipeline for acme corporation right now"
        )
        rc, out = self.propose(
            {"AGENTS.md": "refactor the secret billing pipeline\n"},
            deny={"prompts": [prompt]},
        )
        self.assertEqual(rc, 0, out)

    def test_leakage_missing_denylist_fails_closed(self) -> None:
        self.commit({"AGENTS.md": "better\n"}, "p")
        tags = self.write_json("tags.json", {"AGENTS.md": "global-doc"})
        env = {"SESSIONS_DB": str(self.dir / "absent.duckdb")}
        with mock.patch.dict(os.environ, env):
            rc, out = call(
                "critic",
                "--repo",
                str(self.repo),
                "--state-dir",
                str(self.state),
                "--thread",
                "t1",
                "--round",
                "1",
                "--base",
                "main",
                "--tags",
                str(tags),
                "--budget-cmd",
                "true",
            )
        self.assertEqual(rc, 1)
        self.assertIn("denylist-unavailable", self.categories(out))

    def critic_with_denylist(
        self, files: dict[str, str], deny: dict, notes: list[dict] | None = None
    ) -> tuple[int, dict]:
        """Run the critic with a database-style denylist: no --denylist file."""
        self.commit(files, "propose")
        tags = self.write_json("tags.json", {p: _tag(p) for p in files})
        loaded = ({"prompt": set(), "path": set(), **deny}, notes or [])
        with mock.patch("hc_critic.load_denylist", return_value=loaded):
            return call(
                "critic",
                "--repo",
                str(self.repo),
                "--state-dir",
                str(self.state),
                "--thread",
                "t1",
                "--round",
                "1",
                "--base",
                "main",
                "--tags",
                str(tags),
                "--budget-cmd",
                "true",
            )

    def test_leakage_partialDenylistNote_failsTheCritic(self) -> None:
        note = {"check": "leakage", "category": "denylist-partial", "harness": "codex"}
        rc, out = self.critic_with_denylist(
            {"AGENTS.md": "better\n"}, {"project": set()}, [note]
        )
        self.assertEqual(rc, 1)
        self.assertEqual(out["violations"], [note])

    def test_leakage_projectKeyThatBaseTreeHolds_isNotFlagged(self) -> None:
        text = "the rollout plan\nsee quokkaworks\n"
        rc, out = self.critic_with_denylist(
            {"AGENTS.md": text}, {"project": {"rollout", "quokkaworks"}}
        )
        self.assertEqual(rc, 1)
        self.assertEqual(
            [(v["category"], v["line"]) for v in out["violations"]], [("project", 2)]
        )
        self.assertNotIn("quokkaworks", json.dumps(out).lower())

    def test_leakage_repoVocabulary_failedGitKeepsEveryKey(self) -> None:
        self.assertEqual(
            hc_critic._repo_vocabulary(self.repo, "no-such-ref", {"rollout"}), set()
        )
        self.assertEqual(
            hc_critic._repo_vocabulary(self.repo, "main", {"rollout", "quokkaworks"}),
            {"rollout"},
        )

    # --- AC-7 budgets ---

    def test_budget_nonzero_exit_is_rejected(self) -> None:
        rc, out = self.propose({"AGENTS.md": "better\n"}, budget="false")
        self.assertEqual(rc, 1)
        self.assertEqual(self.categories(out), {"budget-exit"})

    def test_budget_config_edit_is_rejected(self) -> None:
        rc, out = self.propose(
            {"agents/instruction-budgets.toml": "version = 1\nmax = 9\n"},
            tags={"agents/instruction-budgets.toml": "global-doc"},
        )
        self.assertEqual(rc, 1)
        self.assertIn("budget-config", self.categories(out))

    # --- AC-8 repairs ---

    def test_repair_third_failing_attempt_is_rejected_and_ledgered(self) -> None:
        statuses = []
        for i in range(3):
            rc, out = self.propose({"AGENTS.md": f"try {i}\n"}, tags={})
            statuses.append((rc, out["status"], out["attempt"]))
        self.assertEqual(statuses, [(1, "fail", 1), (1, "fail", 2), (1, "rejected", 3)])
        ledger = (self.state / "t1" / "ledger.md").read_text().splitlines()
        self.assertEqual(len(ledger), 1)
        self.assertIn("candidate=rejected", ledger[0])
        self.assertIn("pr=none", ledger[0])
        rc, out = self.propose({"AGENTS.md": "fixed\n"})
        self.assertEqual(
            (rc, out["status"]), (1, "rejected"), "a rejected round stays rejected"
        )
        self.assertEqual(
            len((self.state / "t1" / "ledger.md").read_text().splitlines()), 1
        )

    def test_repair_second_attempt_can_pass(self) -> None:
        rc, out = self.propose({"AGENTS.md": "bad\n"}, tags={})
        self.assertEqual((rc, out["status"]), (1, "fail"))
        rc, out = self.propose({"AGENTS.md": "good\n"})
        self.assertEqual((rc, out["status"], out["attempt"]), (0, "pass", 2))
        self.assertFalse((self.state / "t1" / "ledger.md").exists())


def _tag(path: str) -> str:
    return hc_policy.classify(path) or "skill"


class DenylistCase(unittest.TestCase):
    def test_leakage_denylist_skips_the_repository_own_name_and_short_names(
        self,
    ) -> None:
        deny = hc_policy.build_denylist(
            [],
            ["/Users/a/Dev/dotfiles", "/Users/a/Dev/web", "/Users/a/Dev/zebracorp"],
            ["dotfiles"],
        )
        self.assertEqual(deny["project"], {"zebracorp"})

    def test_leakage_slash_command_token_is_stripped_but_arguments_are_denied(
        self,
    ) -> None:
        deny = hc_policy.build_denylist(
            ["/hill-climb run one iteration of the thread now please"], []
        )
        self.assertEqual(deny["prompt"], {"run one iteration of the thread now please"})


if __name__ == "__main__":
    unittest.main()
