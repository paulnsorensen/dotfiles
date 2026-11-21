# review-leverage: human review aimed by deterministic rules

`skills/review-leverage/` ranks the areas of an agent PR, walks the human through them one at a time, and keeps an outcome ledger. Code sets every tier and rank. A model summary is an aid, never a gate. Confidence in the method is `speculating`: no study measures it on agent code.

## Decisions (2026-11-15)

- **Policy home (R3).** Builtin rules live in `scripts/review_leverage.py`. A repo adds rules only through `.review-leverage.toml`, which the script reads from `origin/<default>` and never from the reviewed head. A PR that edits the policy file is a `gate-mute` must area. Why: stamphog and policy-bot use the same shape; any gate config inside the PR can redefine success.
- **Floor categories.** Repo policy is append-only. It cannot skip `gate-mute` (gate config or suppression comments) or `test-oracle` (removed or rewritten assertion, skip marker, removed test case). Why: agents edit visible tests to pass (cheez-wiki `engineering/independent-oracles-for-agent-code.md`, ImpossibleBench).
- **Outcome record (R5).** The ledger is `~/.local/share/review-leverage/ledger.jsonl`, outside every repo. Each line binds area, tier, decision, and head SHA. `close` writes one `skipped` line with a reason for each area outside the walk. `outcomes` matches later revert or fix commits on the default branch by subject keyword and file overlap. Why: git notes break on squash merge, and PR comments add noise and need network.
- **Tier comes from category, not size.** Size and `git-file-risk` only add to the score that orders areas inside a tier.

## Gotchas

- `dots sync` runs the main checkout's `.sync`, so it deploys `~/Dev/dotfiles`, not the worktree under review. An agent branch of dotfiles can change the deployed ranker. The builtin policy marks `**/review-leverage/**` as `gate-mute`.
- Shell functions count as interface only in sourced libraries (`lib/`, `lib*.sh`, `.bash`). A local helper in a plain script is not API.
- The tool cannot tell an agent commit from a human commit. It assumes the PR author wrote both code and tests.
- `outcomes` is a weak label (SZZ-style links reach F1 near 0.5). Read each match before counting it.

## Acceptance evidence

- PR #1568 (`bbe51ee6bd00`): 10 areas, walk 3 (test-added, api-change, agent-config), 7 skipped with reasons, 10 ledger lines.
- Seeded branch that rewrote a bats assertion and disabled a markdownlint rule: both ranked `must`; `close` exited 3 until decided.
- Two seeded mutants (empty floor, policy read from HEAD) each fail one unit test.
