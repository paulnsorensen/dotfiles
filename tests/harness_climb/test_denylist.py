from __future__ import annotations

import json
import os
import tempfile
import unittest
import unittest.mock
from pathlib import Path

from .support import (
    HAVE_DUCKDB,
    RepoCase,
    call,
    hc_critic,
    hc_denylist,
    hc_policy,
    make_db,
)
from .test_critic import CriticCase

PROMPT = "please rotate the quarterly credentials for the acme billing cluster tonight"


def leaks(text: str, deny: dict) -> list[str]:
    return [v["category"] for v in hc_policy.check_leakage({"f": [(1, text)]}, deny)]


class ProjectNames(unittest.TestCase):
    def test_projectName_genericDirectoryWords_areNotDenied(self) -> None:
        projects = [f"/Users/p/{w}" for w in ("scripts", "tests", "hooks", "press")]
        projects += [f"/Users/p/{w}" for w in ("plate", "harness", "research", "wiki")]
        self.assertEqual(hc_policy.build_denylist([], projects)["project"], set())

    def test_projectName_ordinaryWordsContainingIt_areNotFlagged(self) -> None:
        deny = hc_policy.build_denylist([], ["/Users/p/plate", "/Users/p/press"])
        deny["project"] |= {"temp", "test", "press"}
        for text in ("template", "compress the notes", "run the tests"):
            self.assertEqual(leaks(text, deny), [], text)

    def test_projectName_substringOfALongerToken_isNotFlagged(self) -> None:
        deny = hc_policy.build_denylist([], ["/Users/p/zebra"])
        self.assertEqual(leaks("zebras and zebracorp", deny), [])

    def test_projectName_wholeTokenMatch_isFlagged(self) -> None:
        deny = hc_policy.build_denylist([], ["/Users/p/zebracorp"])
        self.assertEqual(leaks("see Zebracorp docs", deny), ["project"])

    def test_projectName_hyphenatedNameMatchesAsTokenRun(self) -> None:
        deny = hc_policy.build_denylist([], ["/Users/p/zebra-app"])
        self.assertEqual(leaks("~/Dev/zebra-app/src", deny), ["project"])

    def test_projectName_fourCharacterName_isNotDenied(self) -> None:
        deny = hc_policy.build_denylist([], ["/Users/p/acme"])
        self.assertEqual(deny["project"], set())


class SlashPrompts(unittest.TestCase):
    def test_slashPrompt_argumentsStillFeedNgrams(self) -> None:
        deny = hc_policy.build_denylist(["/review " + PROMPT], [])
        self.assertEqual(leaks(PROMPT, deny), ["prompt"])

    def test_slashPrompt_commandTokenIsNotPartOfNgrams(self) -> None:
        deny = hc_policy.build_denylist(["/review " + PROMPT], [])
        self.assertFalse(any(k.startswith("review") for k in deny["prompt"]))

    def test_slashPrompt_bareCommandAddsNothing(self) -> None:
        self.assertEqual(hc_policy.build_denylist(["/clear"], [])["prompt"], set())


class SelfEditScope(unittest.TestCase):
    def test_scope_harnessClimbAndSessionAnalytics_areSelfEdit(self) -> None:
        paths = [
            "skills/harness-climb/scripts/hc_policy.py",
            "skills/harness-climb/SKILL.md",
            "skills/session-analytics/scripts/ingest.py",
            "skills/Harness-Climb/SKILL.md",
        ]
        got = hc_policy.check_scope(paths, set())
        self.assertEqual([v["category"] for v in got], ["self-edit"] * len(paths))

    def test_scope_localSkill_staysOwned(self) -> None:
        self.assertEqual(hc_policy.check_scope(["skills/mine/SKILL.md"], {"mine"}), [])

    def test_scope_skillWithoutLocalDirAtBase_isVendored(self) -> None:
        got = hc_policy.check_scope(["skills/age/SKILL.md"], {"mine"})
        self.assertEqual([v["category"] for v in got], ["vendored"])

    def test_localSkillNames_readsLsTreeOutput(self) -> None:
        listing = "skills/mine\nskills/_shared\n"
        self.assertEqual(hc_policy.local_skill_names(listing), {"mine", "_shared"})


class AddedLines(unittest.TestCase):
    def test_parseAddedLines_formFeedInsideALine_doesNotSplitIt(self) -> None:
        diff = "+++ b/f\n@@ -0,0 +1,2 @@\n+one\x0ctwo\n+three\n"
        got = hc_policy.parse_added_lines(diff)
        self.assertEqual(got, {"f": [(1, "one\x0ctwo"), (2, "three")]})

    def test_parseAddedLines_unicodeLineSeparatorInsideALine_doesNotSplitIt(
        self,
    ) -> None:
        diff = "+++ b/f\n@@ -0,0 +1 @@\n+one two\n"
        self.assertEqual(hc_policy.parse_added_lines(diff), {"f": [(1, "one two")]})


class SelfEditCritic(CriticCase):
    def test_critic_selfEditProposal_isRejectedWithoutText(self) -> None:
        rc, out = self.propose({"skills/harness-climb/SKILL.md": "x\n"})
        self.assertEqual(rc, 1)
        self.assertIn("self-edit", self.categories(out))

    def test_critic_vendoredSkillAbsentFromRegistry_isRejected(self) -> None:
        rc, out = self.propose({"skills/age/SKILL.md": "x\n"})
        self.assertEqual(rc, 1)
        self.assertIn("vendored", self.categories(out))

    def test_critic_hookEdit_passesWithExecutableChangeWarning(self) -> None:
        rc, out = self.propose({"agents/hooks/guard.sh": "echo ok\n"})
        self.assertEqual((rc, out["status"]), (0, "pass"), out)
        self.assertEqual(len(out["warnings"]), 1)
        self.assertIn("executable change", out["warnings"][0])
        self.assertIn("agents/hooks/guard.sh", out["warnings"][0])
        saved = json.loads(
            (self.state / "t1" / "rounds" / "r1" / "critic.json").read_text()
        )
        self.assertEqual(saved["warnings"], out["warnings"])

    def test_critic_nonHookEdit_hasNoWarnings(self) -> None:
        rc, out = self.propose({"skills/mine/SKILL.md": "better\n"})
        self.assertEqual((rc, out["warnings"]), (0, []))


class PromptSources(unittest.TestCase):
    def test_textBlocks_collectsTextBlocksOnly(self) -> None:
        blocks = [
            {"type": "text", "text": "alpha"},
            {"type": "tool_result", "text": "skip"},
            {"type": "input_text", "text": "beta"},
        ]
        self.assertEqual(hc_denylist.text_blocks(blocks), ["alpha", "beta"])
        self.assertEqual(hc_denylist.text_blocks("plain"), ["plain"])
        self.assertEqual(hc_denylist.text_blocks(None), [])

    def rollout(self, root: Path, *entries: dict) -> None:
        day = root / "2026" / "01" / "01"
        day.mkdir(parents=True)
        (day / "rollout-a.jsonl").write_text(
            "\n".join(json.dumps(e) for e in entries) + "\nnot json\n"
        )

    def message(self, role: str, text: str, kind: str = "response_item") -> dict:
        return {
            "type": kind,
            "payload": {
                "type": "message",
                "role": role,
                "content": [{"type": "input_text", "text": text}],
            },
        }

    def test_codexPrompts_readsUserMessagesFromRollouts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.rollout(
                Path(tmp),
                self.message("user", PROMPT),
                self.message("assistant", "assistant words"),
                self.message("user", "<environment_context>x</environment_context>"),
                self.message("user", "# AGENTS.md instructions for /x"),
                self.message("user", "other", kind="event_msg"),
            )
            self.assertEqual(hc_denylist.codex_prompts(Path(tmp)), [PROMPT])

    def test_codexSessionsRoot_respectsCodexHome(self) -> None:
        with unittest.mock.patch.dict(os.environ, {"CODEX_HOME": "/tmp/chome"}):
            self.assertEqual(
                hc_denylist.codex_sessions_root(), Path("/tmp/chome/sessions")
            )

    def load(self, rows: list[dict], codex_home: Path):
        db = codex_home / "s.duckdb"
        if not db.exists():
            db.write_text("x")
        self.duck_sql: list[str] = getattr(self, "duck_sql", [])
        self.db = db

        def duck(_db, sql):
            self.duck_sql.append(sql)
            return rows if "raw_entries" in sql else [{"project": "/a/b/zebracorp"}]

        env = {"CODEX_HOME": str(codex_home), "XDG_CACHE_HOME": str(codex_home / "c")}
        with (
            unittest.mock.patch.object(hc_denylist, "resolve_db", return_value=db),
            unittest.mock.patch.object(hc_denylist, "duck", side_effect=duck),
            unittest.mock.patch.dict(os.environ, env),
        ):
            return hc_denylist.load_denylist(None, Path("/x/repo"))

    def test_loadDenylist_sameMtimes_reusesTheCachedDenylist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rows = [{"harness": "claude", "t": PROMPT}]
            first = self.load(rows, Path(tmp))
            calls = len(self.duck_sql)
            second = self.load([], Path(tmp))
            self.assertEqual(len(self.duck_sql), calls)
        self.assertEqual(second, first)
        self.assertEqual(leaks(PROMPT, second[0]), ["prompt"])

    def test_loadDenylist_changedDbMtime_rebuildsTheDenylist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.load([{"harness": "claude", "t": PROMPT}], Path(tmp))
            calls = len(self.duck_sql)
            os.utime(self.db, ns=(1, 1))
            deny, _notes = self.load([], Path(tmp))
            self.assertGreater(len(self.duck_sql), calls)
        self.assertEqual(leaks(PROMPT, deny), [])

    def test_loadDenylist_newRolloutInExistingDayDir_rebuildsTheDenylist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sessions = Path(tmp) / "sessions"
            self.rollout(sessions, self.message("user", "first prompt"))
            self.load([{"harness": "claude", "t": PROMPT}], Path(tmp))
            calls = len(self.duck_sql)
            fresh = sessions / "2026" / "01" / "01" / "rollout-b.jsonl"
            fresh.write_text(json.dumps(self.message("user", "fresh prompt")) + "\n")
            os.utime(fresh, ns=(2**62, 2**62))
            self.load([], Path(tmp))
            self.assertGreater(len(self.duck_sql), calls)

    def test_loadDenylist_arrayContentAndCodexRollouts_enterTheDenylist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.rollout(Path(tmp) / "sessions", self.message("user", PROMPT))
            text = "/go " + PROMPT.replace("acme", "bolt")
            rows = [{"harness": "claude", "t": text}]
            deny, notes = self.load(rows, Path(tmp))
        self.assertEqual(notes, [])
        self.assertEqual(leaks(PROMPT, deny), ["prompt"])
        self.assertEqual(leaks(PROMPT.replace("acme", "bolt"), deny), ["prompt"])
        self.assertEqual(leaks("zebracorp", deny), ["project"])

    def test_loadDenylist_harnessWithoutPrompts_isReportedPartial(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rows = [{"harness": "claude", "t": PROMPT}]
            _deny, notes = self.load(rows, Path(tmp))
        self.assertEqual(
            notes,
            [{"check": "leakage", "category": "denylist-partial", "harness": "codex"}],
        )

    def test_loadDenylist_explicitFile_returnsNoNotes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "deny.json"
            path.write_text(json.dumps({"prompts": [PROMPT]}))
            deny, notes = hc_denylist.load_denylist(str(path), Path("/x/repo"))
        self.assertEqual((leaks(PROMPT, deny), notes), (["prompt"], []))

    def test_rolloutPrompt_nonDictEntries_returnNone(self) -> None:
        for line in ("[1, 2]", "3", '"text"', "null"):
            self.assertIsNone(hc_denylist._rollout_prompt(line), line)

    def test_rolloutPrompt_arrayWithSkillBody_yieldsNoNgrams(self) -> None:
        body = "Base directory for this skill: /x/skill\n" + PROMPT
        entry = self.message("user", body)
        entry["payload"]["content"].append({"type": "text", "text": PROMPT})
        got = hc_denylist._rollout_prompt(json.dumps(entry))
        self.assertEqual(got, PROMPT)
        skill_only = self.message("user", body)
        self.assertIsNone(hc_denylist._rollout_prompt(json.dumps(skill_only)))


class InjectedText(unittest.TestCase):
    def test_promptBlocks_dropInjectedBlocksAndKeepUserText(self) -> None:
        blocks = [
            {"type": "text", "text": "Base directory for this skill: /x\n" + PROMPT},
            {"type": "text", "text": "<command-name>/go</command-name>"},
            {"type": "text", "text": "<system-reminder>" + PROMPT},
            {"type": "text", "text": "  " + PROMPT},
        ]
        got = hc_denylist.prompt_blocks(blocks)
        self.assertEqual(got, ["  " + PROMPT])
        deny = hc_policy.build_denylist(
            [t for b in blocks for t in hc_denylist.prompt_blocks([b])], []
        )
        self.assertEqual(leaks(PROMPT, deny), ["prompt"])

    def test_promptQuery_filtersInSqlAndReturnsOnlyText(self) -> None:
        sql = hc_denylist.prompt_query()
        self.assertIn("unnest", sql)
        self.assertIn("'input_text'", sql)
        for prefix in hc_denylist.INJECTED_PREFIXES:
            self.assertIn(f"'{prefix}'", sql)
        self.assertTrue(sql.startswith("SELECT harness, t FROM"))
        self.assertIn("harness = 'claude'", sql)

    @unittest.skipUnless(HAVE_DUCKDB, "duckdb not installed")
    def test_promptQuery_arrayRows_yieldUserTextOnly(self) -> None:
        user = json.dumps(
            {
                "content": [
                    {"type": "text", "text": "Base directory for this skill: /x"},
                    {"type": "text", "text": "<system-reminder>r"},
                    {"type": "tool_result", "content": "result words"},
                    {"type": "text", "text": PROMPT},
                ]
            }
        ).replace("'", "''")
        plain = json.dumps({"content": "/go " + PROMPT}).replace("'", "''")
        with tempfile.TemporaryDirectory() as tmp:
            db = make_db(
                Path(tmp) / "s.duckdb",
                "CREATE TABLE raw_entries(harness VARCHAR, type VARCHAR, message JSON)",
                f"INSERT INTO raw_entries VALUES ('claude','user','{user}'),"
                f"('codex','user','{plain}'),('claude','assistant','{user}')",
            )
            rows = hc_denylist.duck(db, hc_denylist.prompt_query())
        got = sorted((r["harness"], r["t"]) for r in rows)
        self.assertEqual(got, [("claude", PROMPT)])


class LeakageEdges(unittest.TestCase):
    PROMPT = (
        "please rotate the quarterly credentials for the acme billing cluster tonight"
    )

    def deny(self, **kw: list[str]) -> dict:
        return hc_policy.build_denylist(
            kw.get("prompts", []), kw.get("projects", []), kw.get("own", [])
        )

    def test_leakage_spanSplitAcrossTwoAddedLines_flagged(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        added = {
            "skills/m/SKILL.md": [
                (1, "rotate the quarterly credentials"),
                (2, "for the acme billing cluster"),
            ]
        }
        v = hc_policy.check_leakage(added, deny)
        self.assertEqual([x["category"] for x in v], ["prompt"])

    def test_leakage_spanSplitAcrossNonAdjacentHunks_isFalsePositive(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        added = {
            "f": [
                (3, "rotate the quarterly credentials"),
                (90, "for the acme billing cluster"),
            ]
        }
        self.assertEqual(hc_policy.check_leakage(added, deny), [])

    def test_leakage_caseAndPunctuationVariantsOfPrompt_flagged(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        text = "ROTATE, the Quarterly-Credentials; for the ACME billing (cluster)!"
        v = hc_policy.check_leakage({"f": [(1, text)]}, deny)
        self.assertTrue(v)

    def test_leakage_projectCaseVariant_flagged(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/ZebraCorp"])
        for text in ("ZEBRACORP", "zebracorp", "ZebraCorp"):
            v = hc_policy.check_leakage({"f": [(1, f"see {text} docs")]}, deny)
            self.assertEqual([x["category"] for x in v], ["project"], text)

    def test_leakage_repoPathCaseVariant_flagged(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/ZebraCorp"])
        v = hc_policy.check_leakage({"f": [(1, "cd /USERS/P/DEV/ZEBRACORP/src")]}, deny)
        self.assertIn("path", [x["category"] for x in v])

    def test_leakage_ownRepoNameIsNotADenylistTerm(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/dotfiles"], own=["dotfiles"])
        self.assertEqual(
            hc_policy.check_leakage({"f": [(1, "dotfiles repo")]}, deny), []
        )

    def test_leakage_shortProjectNameBelowMinimumIgnored(self) -> None:
        deny = self.deny(projects=["/a/b/abc"])
        self.assertEqual(deny["project"], set())

    def test_leakage_homeTildeFormOfRepoPath_flagged(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/zebra-app"])
        v = hc_policy.check_leakage({"f": [(1, "~/Dev/zebra-app/src")]}, deny)
        self.assertTrue(v)  # caught by the project basename

    def test_leakage_nonAsciiPromptSpan_flagged(self) -> None:
        prompt = "пожалуйста перезапусти боевой кластер клиента акме сегодня ночью пожалуйста"
        deny = self.deny(prompts=[prompt])
        v = hc_policy.check_leakage({"f": [(1, prompt)]}, deny)
        self.assertTrue(v, "a verbatim non-ASCII prompt must be flagged")

    def test_leakage_accentedWordsDoNotCreateFalseSpans(self) -> None:
        prompt = "café au lait for the quarterly acme billing cluster tonight please"
        deny = self.deny(prompts=[prompt])
        v = hc_policy.check_leakage(
            {"f": [(1, "café au lait for the quarterly acme billing cluster")]}, deny
        )
        self.assertTrue(v)

    def test_leakage_sevenWordSpanBelowNgramIsAllowed(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        v = hc_policy.check_leakage(
            {"f": [(1, "rotate the quarterly credentials for the acme")]}, deny
        )
        self.assertEqual(v, [])

    def test_leakage_emptyAndNoneInputs_noCrash(self) -> None:
        deny = self.deny(prompts=["", None], projects=["", None])  # type: ignore[list-item]
        self.assertEqual(hc_policy.check_leakage({"f": [(1, "")]}, deny), [])
        self.assertEqual(hc_policy.check_leakage({}, deny), [])

    def test_parseAddedLines_noNewlineMarkerAndBinaryDoNotCrash(self) -> None:
        diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1,2 @@\n+a\n+b\n\\ No newline at end of file\n"
        self.assertEqual(hc_policy.parse_added_lines(diff), {"x": [(1, "a"), (2, "b")]})

    def test_leakage_addedLineWhoseTextStartsWithPlusPlus_stillScanned(self) -> None:
        deny = hc_policy.build_denylist([LeakageEdges.PROMPT], [], [])
        diff = "--- a/x\n+++ b/x\n@@ -0,0 +1,1 @@\n+++ " + LeakageEdges.PROMPT + "\n"
        added = hc_policy.parse_added_lines(diff)
        self.assertTrue(hc_policy.check_leakage(added, deny))

    def test_parseAddedLines_addedLineStartingWithPlusPlusPlus_isKept(self) -> None:
        diff = "--- a/x\n+++ b/x\n@@ -0,0 +1,1 @@\n++++ secret text\n"
        self.assertEqual(
            hc_policy.parse_added_lines(diff), {"x": [(1, "+++ secret text")]}
        )


EASY_CHEESE_REGISTRY = """sources:
  paulnsorensen/easy-cheese:
    description: toolkit
"""


class CriticGit(RepoCase):
    PROMPT = (
        "please rotate the quarterly credentials for the acme billing cluster tonight"
    )

    def setUp(self) -> None:
        super().setUp()
        self.commit(
            {
                "AGENTS.md": "base\n",
                "skills/_registry.yaml": EASY_CHEESE_REGISTRY,
                "skills/mine/SKILL.md": "keep\n",
                "agents/instruction-budgets.toml": "version = 1\n",
            }
        )
        self.git("checkout", "-q", "-b", "harness-climb/t1/r1")
        env = unittest.mock.patch.dict(os.environ, {hc_critic.DENYLIST_ENV: "1"})
        env.start()
        self.addCleanup(env.stop)

    def critic(self, tags: dict, deny: dict | None = None, budget: str = "true"):
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
            "--tags",
            str(self.write_json("tags.json", tags)),
            "--denylist",
            str(self.write_json("deny.json", deny or {})),
            "--budget-cmd",
            budget,
        )

    def cats(self, out: dict) -> set[str]:
        return {v["category"] for v in out["violations"]}

    def test_critic_renameOfBudgetConfig_rejected(self) -> None:
        self.git("mv", "agents/instruction-budgets.toml", "skills/mine/budgets.toml")
        self.git("commit", "-q", "-m", "rename")
        rc, out = self.critic({"skills/mine/budgets.toml": "skill"})
        self.assertEqual(rc, 1)
        self.assertIn("budget-config", self.cats(out))

    def test_critic_renameIntoVendoredSkill_rejected(self) -> None:
        (self.repo / "skills" / "easy-cheese").mkdir()
        self.git("mv", "skills/mine/SKILL.md", "skills/easy-cheese/in.md")
        self.git("commit", "-q", "-m", "rename")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill", "skills/easy-cheese/in.md": "skill"}
        )
        self.assertEqual(rc, 1)
        self.assertIn("vendored", self.cats(out))

    def test_critic_tagOnDeletedFile_passes(self) -> None:
        self.git("rm", "-q", "skills/mine/SKILL.md")
        self.git("commit", "-q", "-m", "delete")
        rc, out = self.critic({"skills/mine/SKILL.md": "skill"})
        self.assertEqual((rc, out["status"]), (0, "pass"))

    def test_critic_deletedFileWithoutTag_tagMissing(self) -> None:
        self.git("rm", "-q", "skills/mine/SKILL.md")
        self.git("commit", "-q", "-m", "delete")
        _rc, out = self.critic({})
        self.assertIn("tag-missing", self.cats(out))

    def test_critic_rejectionOutputHoldsNoPromptText(self) -> None:
        self.commit({"skills/mine/SKILL.md": self.PROMPT + "\n"}, "leak")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, {"prompts": [self.PROMPT]}
        )
        self.assertEqual(rc, 1)
        self.assertIn("prompt", self.cats(out))
        blob = (
            json.dumps(out).lower()
            + (self.state / "t1/rounds/r1/critic.json").read_text().lower()
        )
        for word in ("rotate", "quarterly", "credentials", "acme", "billing"):
            self.assertNotIn(word, blob)

    def test_critic_projectLeakReasonHoldsNoProjectName(self) -> None:
        self.commit({"skills/mine/SKILL.md": "deploy to zebracorp\n"}, "leak")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, {"projects": ["/Users/p/Dev/zebracorp"]}
        )
        self.assertNotIn("zebracorp", json.dumps(out).lower())
        self.assertEqual(rc, 1)

    def test_critic_missingBudgetExecutable_doesNotPass(self) -> None:
        self.commit({"skills/mine/SKILL.md": "better\n"}, "edit")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, budget="/nonexistent/budget-cmd"
        )
        self.assertNotEqual(rc, 0)
        self.assertNotEqual(out.get("status"), "pass")

    def test_critic_symlinkInOwnedDirPointingAtRuntimeOutput_rejected(self) -> None:
        os.symlink(
            "/Users/someone/.claude/settings.json", self.repo / "skills/mine/link.md"
        )
        self.git("add", "skills/mine/link.md")
        self.git("commit", "-q", "-m", "symlink")
        rc, _out = self.critic({"skills/mine/link.md": "skill"})
        self.assertEqual(rc, 1, "a symlink to runtime output escapes the scope check")

    def test_critic_symlinkInOwnedDirPointingAtVendoredSkill_rejected(self) -> None:
        os.symlink("../easy-cheese", self.repo / "skills/mine/vend")
        self.git("add", "skills/mine/vend")
        self.git("commit", "-q", "-m", "symlink")
        rc, _out = self.critic({"skills/mine/vend": "skill"})
        self.assertEqual(
            rc, 1, "a symlink into a vendored skill escapes the scope check"
        )

    def test_critic_nonAsciiFilenameInOwnedSkill_passes(self) -> None:
        self.commit({"skills/mine/café.md": "ok\n"}, "unicode name")
        rc, out = self.critic({"skills/mine/café.md": "skill"})
        self.assertEqual((rc, out["status"]), (0, "pass"), out)

    def test_critic_filenameWithSpace_passes(self) -> None:
        self.commit({"skills/mine/a b.md": "ok\n"}, "space name")
        rc, out = self.critic({"skills/mine/a b.md": "skill"})
        self.assertEqual((rc, out["status"]), (0, "pass"), out)

    def test_critic_leakInFileWithSpaceInName_stillFlagged(self) -> None:
        self.commit({"skills/mine/a b.md": self.PROMPT + "\n"}, "leak")
        _rc, out = self.critic(
            {"skills/mine/a b.md": "skill"}, {"prompts": [self.PROMPT]}
        )
        self.assertIn("prompt", self.cats(out))

    def test_critic_leakPrefixedWithPlusPlus_stillRejected(self) -> None:
        self.commit({"skills/mine/SKILL.md": "++ " + self.PROMPT + "\n"}, "leak")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, {"prompts": [self.PROMPT]}
        )
        self.assertEqual(rc, 1)
        self.assertIn("prompt", self.cats(out))

    def test_critic_removedLeakingLineIsNotFlagged(self) -> None:
        deny = {"prompts": [LeakageEdges.PROMPT]}
        self.commit({"skills/mine/SKILL.md": LeakageEdges.PROMPT + "\n"}, "pre")
        self.git("checkout", "-q", "-B", "harness-climb/t1/r1")
        self.git("update-ref", "refs/heads/main", "HEAD")
        self.commit({"skills/mine/SKILL.md": "clean text now\n"}, "clean")
        rc, out = self.critic({"skills/mine/SKILL.md": "skill"}, deny)
        self.assertEqual((rc, out["status"]), (0, "pass"))


if __name__ == "__main__":
    unittest.main()
