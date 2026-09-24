# Agent Instructions for the bash-shortening skill

This document is for LLMs and agents adding rules to or maintaining
`scripts/bash-shorten.py`.

## Default to ast-grep, not Python regex

ast-grep (via tree-sitter-bash) sees bash structurally — `comment`,
`heredoc_body`, `command_substitution`, `test_command` (`[ ]`),
`conditional_expression` (`[[ ]]`), and so on are distinct AST node
kinds. Python regex sees a flat byte stream and will happily match
inside comments, heredocs, or the wrong bracket form.

**When you add a new rule, write it as an ast-grep rule first** —
land it in `scripts/sg-rules/<id>.yml` and register the Python rule
id in `SG_HANDLED_IDS` (in `scripts/rules.py`). Only fall back to
Python regex when ast-grep genuinely can't express the pattern, and
say so out loud in the rule's docstring with the specific blocker.

The Python regex layer is for rules that need:

- **Cross-metavariable equality** — same name on both sides of a
  rewrite (`mkdir-guard`, `empty-default`, `expr-increment`). YAML
  ast-grep rules can't express `$X == $X`; regex backreferences can.
- **Runtime arithmetic** — checking that captured tokens form a
  consecutive integer sequence (`for-range-expansion`). YAML rules
  can't compute "are these N integers in step-1 order?"
- **Character-class restrictions** in the matcher itself
  (`sed-replace-*` literal-pattern guard).
- **Cross-line spans** that ast-grep's pattern syntax doesn't
  cleanly capture (`empty-default`, `mkdir-guard`).

Anything that's structurally recognizable in tree-sitter — node kind,
parent context, sibling shape — should be ast-grep. Two past regex bugs
are the cautionary tale: `backticks` rewrote markdown spans inside `#`
comments, and `test-numeric` bled into `[[ ]]`. The regex layer produced
broken bash because it could not see context the grammar already encodes.
Both rules now live in `scripts/sg-rules/`.

Tests: the in-process fixtures run with `--self-test`; the CLI suite is
`tests/bash-shortening.bats` at the dotfiles repo root.

## Engine dispatch

The CLI requires `sg` on PATH (verified via `sg --version`'s output to
distinguish ast-grep from util-linux's `sg`). At dispatch time:

1. `_apply_sg(text, enabled)` filters sg rules to those whose Python
   id is in `enabled & SG_HANDLED_IDS`, runs `sg scan --filter` with
   that regex, returns the rewritten text + per-rule counts.
2. The Python regex loop runs over `RULES`, **skipping any rule whose
   id is in `SG_HANDLED_IDS`** so Python doesn't double-fire on sg's
   output.

A Python rule entry in `RULES` for an sg-handled id is still useful
for `--explain`, `--list`, and the in-process `--self-test`
fixtures — but the regex itself never runs at default invocation.

## Rule-name conventions

- One YAML file per ast-grep rule under `scripts/sg-rules/`.
- ast-grep rule id: `bash-shorten-<py-id>` for 1:1 ports
  (`bash-shorten-backticks`).
- For Python rules that fan out into multiple sg rules
  (e.g. one Python `test-numeric` → six ast-grep rules per operator),
  use suffixes: `bash-shorten-test-numeric-eq`, `-ne`, etc. The filter
  regex in `_apply_sg` is `^bash-shorten-(<id>)(-|$)` so suffixed forms
  match the parent Python id automatically.
- Python rule's `examples` tuple drives `--self-test`. After porting
  to sg, those fixtures must still produce the expected output through
  the dispatch (sg pass + remaining regex). If they don't, the bug is
  either in the sg rule, the count-back, or the dispatch ordering.

## When to add a new sg rule

- The rewrite is structural (same shape, no arithmetic, no cross-meta).
- The bug class would be context-blindness (matching inside comments,
  heredocs, the wrong bracket form). If the regex would need
  lookbehind/lookahead to be correct, ast-grep almost certainly does
  it natively.
- The fix string in YAML produces deterministic, valid bash.

## When NOT to add a new sg rule

- The rule needs to compute something (arithmetic on captures, length
  checks, sequence detection). Use Python regex with `apply_fn`.
- The pattern is multi-line with conditional bodies that don't have a
  clean tree-sitter parent. Use Python regex with `re.MULTILINE`.
- The same metavariable must appear in two positions (cross-meta
  equality). Use Python regex with `\1` backreferences.

If you're not sure whether ast-grep can express it, write a quick
probe with `sg --pattern '...' --lang bash <fixture>` before reaching
for regex.

## Counting rewrites for sg-handled rules

`_apply_sg` counts per-rule, not via a shared loop. Each sg-handled
rule gets its own branch picking whichever signal is unambiguous against
untouched code:

- `backticks` counts removed backtick pairs in the byte-level delta —
  every `` `cmd` `` → `$(cmd)` removes exactly two backticks, and the
  `$(...)` after-form is too generic to count directly (it matches
  pre-existing command substitutions in untouched code).
- `test-numeric` re-applies the *before* regex `[ $V -OP N ]` against
  `text` and `new_text` and reports the delta. The `[[ ]]` form lives
  under a different tree-sitter node so the sg rule never touches it
  and the count stays precise.

When adding a new sg-handled rule, append a matching branch to
`_apply_sg` after the existing two. Prefer counting drops in the
*before* pattern unless the rewrite removes a uniquely-identifiable
character (like backticks).
