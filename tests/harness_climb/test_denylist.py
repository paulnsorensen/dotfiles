from __future__ import annotations

import argparse
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .support import hc_denylist, hc_policy
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

    def test_scope_otherSkills_stayOwned(self) -> None:
        self.assertEqual(hc_policy.check_scope(["skills/mine/SKILL.md"], set()), [])


class SelfEditCritic(CriticCase):
    def test_critic_selfEditProposal_isRejectedWithoutText(self) -> None:
        rc, out = self.propose({"skills/harness-climb/SKILL.md": "x\n"})
        self.assertEqual(rc, 1)
        self.assertIn("self-edit", self.categories(out))


class PromptSources(unittest.TestCase):
    def test_flattenContent_collectsTextBlocksOnly(self) -> None:
        blocks = [
            {"type": "text", "text": "alpha"},
            {"type": "tool_result", "text": "skip"},
            {"type": "input_text", "text": "beta"},
        ]
        self.assertEqual(hc_denylist.flatten_content(blocks), "alpha\nbeta")
        self.assertEqual(hc_denylist.flatten_content("plain"), "plain")
        self.assertEqual(hc_denylist.flatten_content(None), "")

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
        with mock.patch.dict(os.environ, {"CODEX_HOME": "/tmp/chome"}):
            self.assertEqual(
                hc_denylist.codex_sessions_root(), Path("/tmp/chome/sessions")
            )

    def load(self, rows: list[dict], codex_home: Path):
        args = argparse.Namespace(denylist=None)
        notes: list[dict] = []
        db = mock.Mock()
        db.is_file.return_value = True

        def duck(_db, sql):
            return rows if "raw_entries" in sql else [{"project": "/a/b/zebracorp"}]

        with (
            mock.patch.object(hc_denylist, "resolve_db", return_value=db),
            mock.patch.object(hc_denylist, "duck", side_effect=duck),
            mock.patch.dict(os.environ, {"CODEX_HOME": str(codex_home)}),
        ):
            deny = hc_denylist.load_denylist(args, Path("/x/repo"), notes)
        return deny, notes

    def test_loadDenylist_arrayContentAndCodexRollouts_enterTheDenylist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.rollout(Path(tmp) / "sessions", self.message("user", PROMPT))
            blocks = [{"type": "text", "text": "/go " + PROMPT.replace("acme", "bolt")}]
            rows = [{"harness": "claude", "c": json.dumps(blocks)}]
            deny, notes = self.load(rows, Path(tmp))
        self.assertEqual(notes, [])
        self.assertEqual(leaks(PROMPT, deny), ["prompt"])
        self.assertEqual(leaks(PROMPT.replace("acme", "bolt"), deny), ["prompt"])
        self.assertEqual(leaks("zebracorp", deny), ["project"])

    def test_loadDenylist_harnessWithoutPrompts_isReportedPartial(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rows = [{"harness": "claude", "c": json.dumps(PROMPT)}]
            _deny, notes = self.load(rows, Path(tmp))
        self.assertEqual(
            notes,
            [{"check": "leakage", "category": "denylist-partial", "harness": "codex"}],
        )


if __name__ == "__main__":
    unittest.main()
