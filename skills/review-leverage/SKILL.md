---
name: review-leverage
model: sonnet
effort: medium
argument-hint: "[<pr number or URL> | <base>..<head>; blank = current branch vs default]"
description: >
  Aim human review at the highest-leverage areas of an agent-written diff,
  pull request, or branch. Walk the human through each area one at a time,
  record one decision per area against the head commit, and name every
  skipped area with its reason. Use when the user says "where should I look
  in this PR", "walk me through this agent PR", "triage my review",
  "which parts need my eyes", or invokes /review-leverage. Do NOT use for a
  full findings report (/age), history risk alone (/git-risk), or bot
  feedback and merge (/land).
---

# /review-leverage

Aim the human at the few areas where a decision pays most. Do not make the
human read every line.

Confidence: `speculating`. No study measures this method on agent code. The
outcome record exists to measure it later.

**Target**: $ARGUMENTS

## Rules

- The helper script sets every category, tier, rank, and skip. Do not change
  them by judgment.
- Model output is an aid, never a gate. Label each model summary
  `Aid (model, not a gate)`. A model reading never sets or changes a tier, a
  rank, or a decision.
- Only the human decides an area. Do not record a decision that the human did
  not give.
- Ask about one area at a time. Record the answer before you show the next
  area.
- Do not dump a long report. Show one screen per step.
- Never skip a `must` area. The human can answer `defer`; that is a recorded
  decision, not silence.
- State a material risk once. Then record the human's decision without more
  debate.
- Do not edit code, tests, or policy in this skill. Route fixes to `/cure` or
  to a coder.

## Policy source

The script merges two policy layers. The reviewed author cannot edit either
layer in the pull request.

1. Builtin rules in `scripts/review_leverage.py`, deployed from the dotfiles
   default branch by `dots sync`.
2. An optional `.review-leverage.toml`, read only from `origin/<default>`.
   The script never reads the copy in the reviewed head. A pull request that
   edits this file gets a `gate-mute` must area.

A repo policy can only add rules. It cannot remove builtin globs. It cannot
skip a `gate-mute` or `test-oracle` area. Format: `references/policy.md`.

## Flow

Run the helper from this skill's base directory:

```bash
RL="python3 <skill-dir>/scripts/review_leverage.py"
```

### 1. Rank

Run the command inside the repository checkout:

```bash
$RL rank --pr <number>            # pull request
$RL rank --base <ref> --head <ref> # branch or range
```

The script fetches `pull/<n>/head`, computes the diff against the merge
base, and writes a run file. Read the run file for area details.

Show the summary that `rank` prints: head SHA, policy source, tier counts,
and the walk list. Do not show reasons for skipped areas yet.

### 2. Walk

For each area id in `walk`, in order:

1. Show the id, category, tier, files, and the reasons from the run file.
2. Show at most 40 diff lines around the signal lines:
   `git diff <base_sha> <head_sha> -- <files>`.
3. Optionally add one line: `Aid (model, not a gate): <what changed>`.
4. Ask one question with the decision picker. Use these options:

   | Option | Meaning |
   | --- | --- |
   | `ok` | The human accepts the area at this head |
   | `fix` | The area needs a change before merge; ask for a one-line note |
   | `block` | Do not merge; ask for a one-line note |
   | `defer` | The human chooses not to decide now; the ledger keeps it |

   The human can ask for more diff through the free-text answer.
5. Record the answer:

   ```bash
   $RL record --run <run-file> --area <id> --decision <ok|fix|block|defer> --note "<text>"
   ```

When a `test-oracle` or `gate-mute` area gets `ok`, state the risk once.
Example: "This removes an assertion that the same author wrote."

### 3. Close

```bash
$RL close --run <run-file>
```

- Exit 0: the script writes one `skipped` ledger line with a reason for each
  area outside the walk. Show that list, one line per area.
- Exit 3: a walked area has no decision. Go back to it.
- Exit 4: the pull request head moved after the rank. Say so and offer a new
  rank. The old decisions stay bound to the old head.

### 4. Hand off

List each `fix` and `block` note. Suggest `/cure` for fixes. Do not apply
them here. This record is not a GitHub approval. GitHub does not let an
author approve their own pull request.

## Categories

| Category | Tier | Signal |
| --- | --- | --- |
| `gate-mute` | must | Edits gate config (workflows, lint, coverage, baselines, `slices.toml`, CODEOWNERS, this policy), or adds a suppression comment |
| `test-oracle` | must | Removes or rewrites an assertion, removes a test case, adds a skip marker, rewrites a snapshot, or deletes a test file |
| `auth-security` | must | Auth or secret path, or an added risky construct (`eval(`, `shell=True`, `pull_request_target`) |
| `schema-breaking` | must | Schema or migration change that removes lines or adds `DROP`, `RENAME`, or `ALTER COLUMN` |
| `api-breaking` | must | Removes or changes a public signature |
| `policy-must` | must | Repo policy `must_paths` |
| `test-added` | should | New tests only; the same author wrote code and oracle |
| `api-change` | should | Adds a public signature, or edits an entry point or manifest |
| `schema-additive` | should | Additive schema or migration change |
| `agent-config` | should | Agent instructions, skills, or MCP config |
| `hotspot` | should | `git-file-risk` band high with no other signal |
| `low-signal` | skip | Lockfiles, wiki, docs, `skip_paths`, or no signal |

The walk holds every `must` area and the top `should_budget` (default 3)
`should` areas by score. Score adds the category base, a `git-file-risk`
bonus, and a small size term. Size never changes a tier.

## Outcome record

The ledger is `~/.local/share/review-leverage/ledger.jsonl`. Each line holds
repo, PR, base SHA, head SHA, policy source, area, category, tier, files,
decision, note or skip reason, and time. The variable `REVIEW_LEVERAGE_HOME`
moves it.

Match later escapes against the ledger:

```bash
$RL outcomes [--days 90] [--json]
```

A match is a later commit on the default branch with a revert or fix subject
that touches a recorded file. The pull request's own squash commit does not
count. This label is weak. Read each match before you count it. With n clean
reviews, the 95% upper bound on the escape rate is near 3/n.

## Gotchas

- `dots sync` deploys this skill from the working checkout. An agent branch
  of dotfiles can change the deployed rules. The builtin policy marks
  `**/review-leverage/**` as `gate-mute`.
- A shallow clone breaks the merge base and `git-file-risk`. Fetch full
  history first.
- `git-file-risk` reads current history. For a merged PR, its counts include
  the PR itself.
- Regex rules miss signals in unusual layouts. Add globs to the repo policy
  on the default branch.
- The tool cannot tell an agent commit from a human commit. It assumes that
  the pull request author wrote both code and tests.

## What this skill never does

- Find bugs or rate code quality. That is `/age`.
- Approve, comment on, or label a pull request.
- Read policy from the reviewed head.
- Claim that the method lowers escaped defects.
