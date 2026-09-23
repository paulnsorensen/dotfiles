---
name: bash-shortening
description: >
  Rewrite verbose Bash into concise, idiomatic Bash without losing
  readability. Use when the user says "shorten this script", "make this
  more idiomatic", "clean up this bash", "this script is too long", "is
  there a shorter way to do this in bash", asks for a review of a Bash
  script, or when you write a new Bash `.sh`/`.bash` script or `bash` block.
  Covers parameter expansion, brace expansion, process substitution,
  arithmetic, functions, heredocs, associative arrays, parallel jobs, and
  IFS parsing, and refuses cryptic one-liners. Do NOT use for fish, zsh,
  or POSIX `/bin/sh` scripts, where bashisms break portability.
model: sonnet
effort: medium
license: MIT
---

# bash-shortening

Make Bash scripts shorter without making them harder to read.
The source is 51 techniques from Karandeep Singh's "Bash Code Shortening"
article, kept as a cheatsheet plus categorized references.

## Philosophy

Shortening expresses intent; it does not save keystrokes.
The win is fewer moving parts: subprocesses, temp files, and intermediate variables.
A cryptic `${1:-${X:-${Y/-,/ }}}` chain is worse than three clear lines.

Two questions decide every change:

1. Does the shorter form remove a class of bugs (a forgotten `rm`, a missed branch, a check-then-`mkdir` race)? If yes, shorten.
2. Does the shorter form hide intent from the next reader? If yes, keep it long.

When both fire, prefer clarity.

## Flow

Analyzers gather in parallel; the main thread is the only writer.
Parallel writes to one file race, and category rewrites overlap on the same lines.

1. **Identify the target.** Take file paths, a pasted snippet, or a `bash` block.
   Done when the shebang or context confirms Bash (see "When not to use").
2. **Run the analyzer sweep.** Dispatch one read-only analyzer per row of the category table, all in one batched call.
   Use any parallel primitive the host has: sub-agents, parallel tool calls, or `parallel`/`xargs -P`.
   With no parallel primitive, walk the table in one pass and tick off each row.
   Done when every category has a report, including empty ones.
3. **Merge.** Collect the `path:line — verbose → idiomatic` hits.
   Keep one entry per line and note every category that flagged it.
4. **Run the rewriter.** From the main thread, run `python3 scripts/bash-shorten.py --apply <file>` once per file.
   Paths under `scripts/` and `references/` are relative to this skill's directory.
   Never give `--apply` to an analyzer.
5. **Verify.** Run `bash -n <file>`, then `shellcheck <file>` when present, then read the diff.
   When a rule gives a surprising result, revert and narrow with `--rules` or `--skip`.
   Done when syntax and shellcheck pass and every hunk is expected.
6. **Show the punch list.** Present the analyzer hits the rewriter did not cover.
   Let the user pick categories, especially where anti-pattern hits conflict with shortening hits.
7. **Hand-edit.** Apply one technique per change, with its rationale visible.
   Use the before/after examples in the matching reference.
   Keep quoting, `set -euo pipefail`, and error handling.
   Stop before a rewrite needs a comment to explain *what* it does.

**Analyzer brief** (substitute `<category>` and `<target>`):

> Read `references/<category>.md` in the bash-shortening skill directory.
> Scan `<target>` for every pattern it covers.
> Return a markdown list: `path:line — verbose form → idiomatic form`.
> Do not rewrite or write any file, and do not run `scripts/bash-shorten.py`.
> Flag a hit that conflicts with the anti-patterns reference, but still include it.

## Categories

This table is the complete checklist.
A single reviewer tunnels on the first two or three categories; the sweep exists to prevent that.
The article numbers map to the example numbers inside each reference.

| Reference | Article | Patterns to find |
|---|---|---|
| `references/command-substitution.md` | 3-7 | temp files replaced by `$(cmd)` or pipelines, reused output, `xargs`, `find \| xargs` vs process substitution |
| `references/parameter-expansion.md` | 8-15 | `if [ -z "$X" ]` defaults, `cut -c`/`echo \| sed` substitutions, `${#S}`, `basename`/`dirname` |
| `references/functions.md` | 16-20 | repeated logging blocks, default params, echo-returns, named params |
| `references/brace-expansion.md` | 21-26 | sequential `mkdir`/`touch`, literal `for i in 1 2 3` ranges, zero-padded sequences |
| `references/process-substitution.md` | 27-31 | temp files feeding `diff` or loops, `echo x \| cmd` → `<<<` |
| `references/arithmetic.md` | 32-38 | `expr`, `$(…)+1` increments, `[ -gt ]` numeric tests, `[ A ] && [ B ]`, ternary gotcha |
| `references/real-world.md` | 39-45 | config parsing, log analysis, health checks, batch jobs, backups, API + `jq` |
| `references/advanced.md` | 48-51 | repeated `echo` → heredoc, 3+ branch `if` → `case` or assoc array, independent commands → `& wait`, `cut -d,` in loops → `IFS` |
| `references/anti-patterns.md` | 1-2, 46-47 | nested expansions, cryptic one-liners, places where shortening hurts; flag only, never auto-rewrite |

## Rewriter

`scripts/bash-shorten.py` applies the high-confidence rewrites.
It needs no third-party Python packages, but it requires [ast-grep](https://ast-grep.github.io/) (`sg`) on PATH.
It is a dry run by default: it prints a unified diff and per-rule counts.

```bash
python3 scripts/bash-shorten.py script.sh                         # preview
python3 scripts/bash-shorten.py --apply script.sh                 # atomic in-place write
python3 scripts/bash-shorten.py --rules backticks,test-numeric script.sh
python3 scripts/bash-shorten.py --skip find-exec-rm-delete script.sh
python3 scripts/bash-shorten.py --include modernize --apply script.sh
python3 scripts/bash-shorten.py --list                            # rules, groups, article refs
python3 scripts/bash-shorten.py --explain test-numeric
python3 scripts/bash-shorten.py --self-test
```

- **`core`** (default): idiomatic rewrites that keep the same tools.
- **`modernize`** (opt-in): rewrites to `sd`, `rg -F`, and `fd`.
  They need those binaries, and `find → fd` changes behavior because `fd` respects `.gitignore`.
- **Opt-out:** a `# bash-shorten: disable` … `# bash-shorten: enable` span, or `# bash-shorten: skip` for the next line, protects code from every rule.

The rewriter cannot do data-flow work: single-use variable inlining, temp-file → pipeline, function extraction, parallelization, or judging whether an `&& … ||` chain is safe.
Those are hand-edits from the references.

When `sg` is missing, the script exits with a diagnostic.
Install it (`brew install ast-grep` or `cargo install ast-grep --bin sg`), or skip the rewriter and run only the analyzer sweep.
To add or change a rule, read `AGENTS.md` first.

## Quick wins

| Verbose form | Idiomatic form | Reference (article #) |
|---|---|---|
| `if [ -z "$X" ]; then X=default; fi` | `X=${X:-default}` | parameter-expansion (8) |
| `$(echo "$S" \| cut -c1-5)` | `${S:0:5}` | parameter-expansion (10) |
| `$(basename "$P")` / `$(dirname "$P")` | `${P##*/}` / `${P%/*}` — hand-edit only: both break on a trailing `/`, and `dirname` returns `.` for a path with no `/` | parameter-expansion (11-12) |
| `$(echo "$S" \| sed 's/a/b/g')` | `${S//a/b}` | parameter-expansion (13-14) |
| `$(echo -n "$S" \| wc -c)` | `${#S}` | parameter-expansion (15) |
| `$(expr $A + $B)` / `C=$(expr $C + 1)` | `$((A + B))` / `((C+=1))` | arithmetic (32-34) |
| `[ $X -gt 100 ]` / `[ $A ] && [ $B ]` | `((X > 100))` / `[[ $A && $B ]]` | arithmetic (35, 37) |
| `mkdir a; mkdir b; mkdir c` | `mkdir -p {a,b,c}` | brace-expansion (21-22) |
| `for i in 1 2 3 4 5` | `for i in {1..5}` (or `{01..10}`, `{2..10..2}`) | brace-expansion (23-26) |
| `cmd > /tmp/x; cmd2 < /tmp/x; rm /tmp/x` | `cmd \| cmd2` or `cmd2 < <(cmd)` — differ from the temp-file form in concurrency, `SIGPIPE` handling, and `pipefail` exit status | command-substitution (5), process-substitution (29) |
| `sort a > /tmp/a; sort b > /tmp/b; diff …` | `diff <(sort a) <(sort b)` | process-substitution (27) |
| `if [ "$E" = dev ]; elif …` (3+ branches) | `case` or `${URLS[$E]:-default}` | functions, advanced (49) |
| Repeated `echo "[$(date)] [LEVEL] msg"` | a `log()` function with `${1^^}` | functions (16) |
| `find … > /tmp/x; while read …; done < /tmp/x` | `done < <(find …)` or `find … \| xargs cmd` | command-substitution (6), process-substitution (29) |
| Many `echo "..."` lines | `cat <<EOF … EOF` | advanced (48) |
| `cmd1; cmd2; cmd3` (independent) | `cmd1 & cmd2 & cmd3 & wait` | advanced (50) |
| `cut -d, -f1,2,3` inside a loop | `while IFS=, read -r a b c` | advanced (51) |

For a pattern not listed here, read the matching reference; each keeps the article's full before/after and gotchas.

## When not to use

- **Non-Bash shells.** `${var//x/y}`, `${var:o:l}`, `[[ ]]`, arrays, and process substitution are bashisms.
  For `#!/bin/sh`, dash, ash, or busybox, stay POSIX or refuse and explain; the anti-patterns reference has a portability checklist.
  fish and zsh have their own grammars.
- **Code golf.** When the user wants the shortest line, state the readability cost so the user owns the choice.
- **Critical infrastructure.** Boot, init, and pre-logging scripts gain from being boring; they run during 3 AM incidents.

## What this skill never does

- It never rewrites a whole file in one pass; each change is one technique with its rationale.
- It never adds a dependency (`yq`, `jq`, `parallel`) to enable a shortening without the user's agreement.
- It never strips comments or `set -euo pipefail`; both are load-bearing.
- It never claims a speedup without a `time` run; say "should be faster" instead.

## Review checklist

- **Unquoted `$var`** in a rewrite: word-splitting bugs are worse than verbosity.
- **Arithmetic ternary with strings:** `$((C > 10 ? "high" : "low"))` fails because Bash arithmetic is integer-only; use `[[ ]] && … || …` or `case`. Article example 36 has this bug.
- **`&& … ||` as if/else:** safe only when the first branch cannot fail; otherwise use `if`/`else`.
- **`mkdir` without `-p`:** the rewrite drops the existence check, so `-p` is what makes it safe.
- **`xargs` without `-r` or `-0`:** empty input or spaces in names break it; pair `-0` with `find -print0`.

## Source

<https://karandeepsingh.ca/posts/bash-code-shortening-techniques/> by Karandeep Singh (2023).
The references keep every numbered article example, and the numbering matches the original.
