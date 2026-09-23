"""Rule definitions for bash-shorten.

Internal split of bash-shorten.py — not a stable API. The only consumer is
the sibling CLI module; tests reach the rules through the CLI. Imports here
are deliberately not advertised via `__all__` because that signals a public
surface this module does not provide.

Each rule is conservative — when in doubt, the pattern skips. The "core"
group is enabled by default. The "modernize" group is opt-in because it
rewrites to non-coreutils binaries (sd, rg, fd) the user may not have
installed.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable

# --- Building blocks -------------------------------------------------------

_VAR = r"[A-Za-z_][A-Za-z0-9_]*"  # bash identifier
# Safe literal characters for sed → bash parameter expansion conversion.
# Excludes `.` because sed treats it as "any char" while bash glob treats it
# literally — keeping it would silently change semantics on patterns like
# s/foo.bar/x/ (sed: matches fooXbar; bash ${V/foo.bar/x}: matches only the
# 7-char literal). All other listed chars are literal in both flavors.
_LITERAL = r"[A-Za-z0-9_/@:+-]"

_TEST_TO_ARITH = {
    "-eq": "==", "-ne": "!=",
    "-lt": "<",  "-le": "<=",
    "-gt": ">",  "-ge": ">=",
}


@dataclass(frozen=True)
class Rule:
    id: str
    description: str
    pattern: re.Pattern
    replace: Callable[[re.Match], str]
    source_example: str  # which article example this implements ("N/A" for bonus)
    shellcheck_id: str = ""
    notes: str = ""
    examples: tuple[tuple[str, str], ...] = field(default_factory=tuple)
    # "core" rules are enabled by default. "modernize" rules require an
    # explicit --include modernize because they assume binaries (sd, rg)
    # the user may not have installed.
    group: str = "core"
    # When set, the engine calls apply_fn(text) instead of pattern.subn —
    # used by rules whose rewrite is too context-sensitive for a single
    # regex (e.g. backticks must skip single-quoted regions).
    apply_fn: Callable[[str], tuple[str, int]] | None = None


# Rules that have an ast-grep equivalent in scripts/sg-rules/. When the
# sg engine handles these, the Python regex must NOT re-fire (it would
# either no-op or rewrite a partial match).
SG_HANDLED_IDS = frozenset({"backticks", "test-numeric"})


def _expr_op(escaped: str) -> str:
    """Strip leading backslash from `\\*` so it becomes `*` in arithmetic."""
    return escaped[1:] if escaped.startswith("\\") else escaped


# Detects the start of a quoted heredoc: <<'DELIM' or <<"DELIM" (optionally
# with the <<- form for tab-indented bodies). Bash treats the body of a
# quoted heredoc as literal text, so backticks inside must not be rewritten.
# Unquoted heredocs (<<DELIM) DO interpolate, so they're not skipped.
_QUOTED_HEREDOC = re.compile(
    r"<<-?(?P<q>['\"])(?P<delim>[A-Za-z_]\w*)(?P=q)"
)


def _apply_backticks(text: str) -> tuple[str, int]:
    """Replace `cmd` with $(cmd), skipping regions where backticks are literal text.

    Skipped regions:
    - Single-quoted strings — bash suppresses interpretation inside them.
    - Quoted-heredoc bodies (<<'EOF' or <<"EOF") — bash leaves them literal.

    Unquoted heredocs (<<EOF) DO interpolate backticks, so they are rewritten
    normally. Double-quoted strings interpolate both `...` and $(...), so
    they're equivalent targets — no double-quote tracking needed.
    """
    out: list[str] = []
    i, n, count = 0, len(text), 0
    in_squote = False
    heredoc_end: str | None = None  # delimiter line that closes the current quoted heredoc
    while i < n:
        if heredoc_end is not None:
            # Inside a quoted heredoc body — copy until the delimiter line.
            line_end = text.find("\n", i)
            if line_end == -1:
                out.append(text[i:])
                break
            line = text[i:line_end]
            out.append(text[i:line_end + 1])
            if line.strip() == heredoc_end:
                heredoc_end = None
            i = line_end + 1
            continue

        c = text[i]
        if c == "'":
            in_squote = not in_squote
            out.append(c)
            i += 1
            continue
        if not in_squote and c == "<" and i + 1 < n and text[i + 1] == "<":
            m = _QUOTED_HEREDOC.match(text, i)
            if m:
                # Emit the introducer + rest of the line, then enter heredoc body mode.
                out.append(m.group(0))
                heredoc_end = m.group("delim")
                i = m.end()
                line_end = text.find("\n", i)
                if line_end == -1:
                    out.append(text[i:])
                    break
                out.append(text[i:line_end + 1])
                i = line_end + 1
                continue
        if c == "`" and not in_squote:
            end = text.find("`", i + 1)
            if end == -1 or "\n" in text[i + 1:end]:
                out.append(c)
                i += 1
            else:
                out.append(f"$({text[i + 1:end]})")
                i = end + 1
                count += 1
        else:
            out.append(c)
            i += 1
    return "".join(out), count


_FOR_RANGE = re.compile(
    rf'\bfor\s+({_VAR})\s+in\s+(\d+(?:\s+\d+){{2,}})\s*;?\s*do\b'
)


def _apply_for_range(text: str) -> tuple[str, int]:
    """Collapse `for i in 1 2 3 4 5; do` to `for i in {1..5}; do` when the
    listed integers form a step-1 ascending sequence of >=3 elements.

    Conservative — does NOT handle:
    - non-step-1 sequences (1 3 5 → would be {1..5..2})
    - zero-padded literals (01 02 03 → would be {01..03}) — leading zeros
      get lost when parsed as int, so the rule skips
    - reverse sequences (5 4 3 2 1)
    """
    count = 0

    def repl(m: re.Match[str]) -> str:
        nonlocal count
        tokens = m.group(2).split()
        # Skip zero-padded literals — `int("01")` would lose the padding.
        if any(t != "0" and t.startswith("0") for t in tokens):
            return m.group(0)
        nums = [int(t) for t in tokens]
        if all(nums[i + 1] - nums[i] == 1 for i in range(len(nums) - 1)):
            count += 1
            return f"for {m.group(1)} in {{{nums[0]}..{nums[-1]}}}; do"
        return m.group(0)

    return _FOR_RANGE.sub(repl, text), count


_CAT_FILE_GREP = re.compile(
    r'\bcat\s+("(?:[^"\\]|\\.)*"|\'[^\']*\'|[\w./~$-]+)\s*\|\s*'
    r'grep\s+([^\n|]+?)(?=\s*$|\s*\||\s*;|\s*&&|\s*\|\|)',
    re.MULTILINE,
)


def _apply_cat_file_grep(text: str) -> tuple[str, int]:
    """Rewrite `cat FILE | grep PAT` to `grep PAT FILE` (drop the useless cat)."""
    def repl(m: re.Match) -> str:
        return f"grep {m.group(2).rstrip()} {m.group(1)}"
    new_text, count = _CAT_FILE_GREP.subn(repl, text)
    return new_text, count


# --- Rule definitions -----------------------------------------------------

RULES: list[Rule] = [
    # basename/dirname rewrites were removed: $(basename "$x") → ${x##*/}
    # silently corrupts to "" when $x carries a trailing slash (e.g. iterating
    # `for x in dir/*/`), and dirname's "." vs original-string divergence has
    # the same flavor of silent breakage. There is no clean general fix
    # without data-flow analysis of the variable's source. Keep using
    # basename/dirname when the path's shape is unknown.
    Rule(
        id="sed-replace-first",
        description='$(echo "$VAR" | sed \'s/PAT/REP/\') → ${VAR/PAT/REP}  (literal-only patterns)',
        pattern=re.compile(
            rf'\$\(\s*echo\s+"\$({_VAR})"\s*\|\s*'
            rf"sed\s+'s/({_LITERAL}+)/({_LITERAL}*)/'\s*\)"
        ),
        replace=lambda m: f"${{{m.group(1)}/{m.group(2)}/{m.group(3)}}}",
        source_example="13",
        notes="Skips when sed pattern contains regex metachars (bash glob ≠ sed regex).",
        examples=(
            ("X=$(echo \"$S\" | sed 's/foo/bar/')", "X=${S/foo/bar}"),
            ("X=$(echo \"$S\" | sed 's/.*/x/')", "X=$(echo \"$S\" | sed 's/.*/x/')"),  # unchanged: regex metachars
        ),
    ),
    Rule(
        id="sed-replace-all",
        description='$(echo "$VAR" | sed \'s/PAT/REP/g\') → ${VAR//PAT/REP}  (literal-only)',
        pattern=re.compile(
            rf'\$\(\s*echo\s+"\$({_VAR})"\s*\|\s*'
            rf"sed\s+'s/({_LITERAL}+)/({_LITERAL}*)/g'\s*\)"
        ),
        replace=lambda m: f"${{{m.group(1)}//{m.group(2)}/{m.group(3)}}}",
        source_example="14",
        examples=(
            ("X=$(echo \"$S\" | sed 's/old/new/g')", "X=${S//old/new}"),
        ),
    ),
    Rule(
        id="echo-wc-c",
        description='$(echo -n "$VAR" | wc -c) → ${#VAR}',
        pattern=re.compile(
            rf'\$\(\s*echo\s+-n\s+"\$({_VAR})"\s*\|\s*wc\s+-c\s*\)'
        ),
        replace=lambda m: f"${{#{m.group(1)}}}",
        source_example="15",
        notes="${#var} counts characters in your locale, not bytes. Use LANG=C wc -c for true byte count.",
        examples=(
            ('LEN=$(echo -n "$S" | wc -c)', 'LEN=${#S}'),
        ),
    ),
    Rule(
        id="cut-c-substring",
        description='$(echo "$VAR" | cut -c1-N) → ${VAR:0:N}  (leading-N substring)',
        pattern=re.compile(
            rf'\$\(\s*echo\s+"\$({_VAR})"\s*\|\s*cut\s+-c1-(\d+)\s*\)'
        ),
        replace=lambda m: f"${{{m.group(1)}:0:{m.group(2)}}}",
        source_example="10",
        notes="Only matches the cut -c1-N form (start at first char). Other ranges (-c2-7, -c3-) need offset/length math the rule deliberately avoids.",
        examples=(
            ('PRE=$(echo "$NAME" | cut -c1-5)', 'PRE=${NAME:0:5}'),
        ),
    ),
    Rule(
        id="expr-arith-vars",
        description='$(expr $A OP $B) → $((A OP B))  (numeric ops)',
        pattern=re.compile(
            rf'\$\(\s*expr\s+\$({_VAR})\s+(\\\*|[-+/%])\s+\$({_VAR})\s*\)'
        ),
        replace=lambda m: f"$(({m.group(1)} {_expr_op(m.group(2))} {m.group(3)}))",
        source_example="32",
        shellcheck_id="SC2003",
        examples=(
            ("R=$(expr $A + $B)", "R=$((A + B))"),
            ("R=$(expr $A \\* $B)", "R=$((A * B))"),
        ),
    ),
    # expr-increment must run BEFORE expr-arith-literal so the more specific
    # self-increment form claims `COUNT=$(expr $COUNT + 1)` first; otherwise
    # the literal rule would rewrite it to the more verbose `$((COUNT + 1))`.
    Rule(
        id="expr-increment",
        description='VAR=$(expr $VAR + 1) → ((VAR++))  (matched-name self-increment)',
        pattern=re.compile(
            rf'\b({_VAR})=\$\(\s*expr\s+\$\1\s+\+\s+1\s*\)'
        ),
        replace=lambda m: f"(({m.group(1)}++))",
        source_example="33",
        shellcheck_id="SC2003",
        notes="Cross-meta equality via backreference: only matches when the assigned name equals the operand name. ((var++)) drops the assignment-as-expression value (which the original expr form also lacked in practice).",
        examples=(
            ('COUNT=$(expr $COUNT + 1)', '((COUNT++))'),
        ),
    ),
    Rule(
        id="expr-arith-literal",
        description='$(expr $A OP N) → $((A OP N))',
        pattern=re.compile(
            rf'\$\(\s*expr\s+\$({_VAR})\s+(\\\*|[-+/%])\s+(\d+)\s*\)'
        ),
        replace=lambda m: f"$(({m.group(1)} {_expr_op(m.group(2))} {m.group(3)}))",
        source_example="32",
        shellcheck_id="SC2003",
        examples=(
            ("R=$(expr $A + 1)", "R=$((A + 1))"),
        ),
    ),
    # NOTE: when both sides are numeric tests (e.g. [ $A -ge 18 ] && [ $B -eq 1 ]),
    # the sg engine claims each side as test-numeric before this rule runs and
    # the result is `(( A >= 18 )) && (( B == 1 ))` — semantically equivalent,
    # just not fused. combined-tests still claims FILE/STRING test pairs.
    Rule(
        id="combined-tests",
        description='[ A ] && [ B ] → [[ A && B ]]  (file/string tests only; numeric pairs go through test-numeric per-side)',
        pattern=re.compile(
            r'\[\s+([^\[\]\n]+?)\s+\]\s*&&\s*\[\s+([^\[\]\n]+?)\s+\]'
        ),
        replace=lambda m: f"[[ {m.group(1)} && {m.group(2)} ]]",
        source_example="37",
        notes="Conservative — only matches when neither bracket contains nested brackets or newlines. For numeric tests with -eq/-ne/-lt/-le/-gt/-ge on both sides, the sg engine rewrites each side independently to (( )); the result is correct but unfused.",
        examples=(
            ('if [ -f "$F" ] && [ -r "$F" ]; then', 'if [[ -f "$F" && -r "$F" ]]; then'),
        ),
    ),
    Rule(
        id="test-numeric",
        description='[ $V -OP N ] → (( V OP N ))  (numeric comparison in if/while)',
        pattern=re.compile(
            rf'\[\s+\$({_VAR})\s+(-eq|-ne|-lt|-le|-gt|-ge)\s+(\d+)\s+\]'
        ),
        replace=lambda m: f"(( {m.group(1)} {_TEST_TO_ARITH[m.group(2)]} {m.group(3)} ))",
        source_example="35",
        examples=(
            ("if [ $X -gt 100 ]; then", "if (( X > 100 )); then"),
            ("while [ $i -lt 10 ]; do", "while (( i < 10 )); do"),
        ),
    ),
    Rule(
        id="empty-default",
        description='if [ -z "$V" ]; then V=DEFAULT; fi → V=${V:-DEFAULT}',
        pattern=re.compile(
            rf'if\s+\[\s+-z\s+"\$({_VAR})"\s+\]\s*;\s*then\s+'
            rf'\1=([^\n;]+?)\s*;?\s*fi',
            re.MULTILINE,
        ),
        replace=lambda m: f"{m.group(1)}=${{{m.group(1)}:-{m.group(2).strip()}}}",
        source_example="8",
        notes='Only matches single-line if/then/fi where the assigned variable matches the tested one. The RHS of the original assignment is preserved verbatim, so `ENV="dev"` rewrites to `ENV=${ENV:-"dev"}` (quotes inside the expansion). The more idiomatic `ENV="${ENV:-dev}"` would require parsing+reformatting the RHS, which the rule deliberately avoids.',
        examples=(
            (
                'if [ -z "$ENV" ]; then ENV="dev"; fi',
                'ENV=${ENV:-"dev"}',
            ),
        ),
    ),
    Rule(
        id="param-default",
        description='if [ -z "$N" ]; then VAR=DEFAULT; fi → VAR=${N:-DEFAULT}  (positional param)',
        pattern=re.compile(
            rf'if\s+\[\s+-z\s+"\$(\d+)"\s+\]\s*;\s*then\s+'
            rf'({_VAR})=([^\n;]+?)\s*;?\s*fi',
            re.MULTILINE,
        ),
        replace=lambda m: f"{m.group(2)}=${{{m.group(1)}:-{m.group(3).strip()}}}",
        source_example="17",
        notes='Like empty-default but for positional parameters ($1, $2, ...). Single-line if/then/fi only. The rewrite always assigns VAR; the original only assigned when $N was empty — equivalent IF VAR was unset before the if-block, which is the idiomatic "function-prologue default" usage this rule targets.',
        examples=(
            (
                'if [ -z "$1" ]; then NAME="anon"; fi',
                'NAME=${1:-"anon"}',
            ),
        ),
    ),
    Rule(
        id="mkdir-guard",
        description='if [ ! -d "$D" ]; then mkdir -p "$D"; fi → mkdir -p "$D"',
        pattern=re.compile(
            rf'if\s+\[\s+!\s+-d\s+"\$({_VAR})"\s+\]\s*;\s*then\s+'
            rf'mkdir\s+-p\s+"\$\1"\s*;?\s*fi',
            re.MULTILINE,
        ),
        replace=lambda m: f'mkdir -p "${{{m.group(1)}}}"',
        source_example="18",
        notes="mkdir -p is idempotent — the existence check is dead weight.",
        examples=(
            (
                'if [ ! -d "$DIR" ]; then mkdir -p "$DIR"; fi',
                'mkdir -p "${DIR}"',
            ),
        ),
    ),

    # --- Bonus patterns: not in the source article, but obvious wins ------

    Rule(
        id="backticks",
        description='`cmd` → $(cmd)  (POSIX-portable, nestable)',
        # apply_fn handles the rewrite; the regex is unused but kept
        # non-empty so --explain has something to show.
        pattern=re.compile(r"`([^`\n]+)`"),
        replace=lambda m: f"$({m.group(1)})",
        apply_fn=_apply_backticks,
        source_example="N/A",
        shellcheck_id="SC2006",
        notes="Skips backticks inside single-quoted strings and quoted-heredoc bodies (<<'EOF' / <<\"EOF\") — both are literal text in bash. Unquoted heredocs (<<EOF) interpolate, so backticks inside are rewritten as expected.",
        examples=(
            ("VER=`git rev-parse HEAD`", "VER=$(git rev-parse HEAD)"),
        ),
    ),
    Rule(
        id="for-range-expansion",
        description='for V in 1 2 3 4 5; do → for V in {1..5}; do  (step-1 ascending sequences only)',
        # apply_fn checks the captured token list for step-1 ordering and
        # rejects zero-padded literals; the regex captures the whole list
        # and the apply_fn does the arithmetic check.
        pattern=re.compile(r"(?!x)x"),
        replace=lambda m: m.group(0),
        apply_fn=_apply_for_range,
        source_example="23",
        notes='Skips non-consecutive (1 3 5), reverse (5 4 3), and zero-padded (01 02 03) sequences — those need different brace-expansion forms.',
        examples=(
            ('for i in 1 2 3 4 5; do echo $i; done', 'for i in {1..5}; do echo $i; done'),
            ('for i in 1 3 5; do echo $i; done', 'for i in 1 3 5; do echo $i; done'),  # unchanged
        ),
    ),
    Rule(
        id="legacy-null-check",
        description='[ "x$V" = "x" ] → [ -z "$V" ]  (and "x$V" != "x" → -n)',
        pattern=re.compile(
            rf'\[\s+"x\$({_VAR})"\s+(=|!=)\s+"x"\s+\]'
        ),
        # Mirrors the source's brace style — input had bare `$VAR`, output
        # keeps `$VAR` rather than introducing `${VAR}` for cosmetic stability.
        replace=lambda m: (
            f'[ -z "${m.group(1)}" ]' if m.group(2) == "="
            else f'[ -n "${m.group(1)}" ]'
        ),
        source_example="N/A",
        notes="Pre-POSIX null-check idiom from when older shells choked on bare empty comparisons. Modern bash does not need the x-prefix.",
        examples=(
            ('[ "x$VAR" = "x" ]', '[ -z "$VAR" ]'),
            ('[ "x$VAR" != "x" ]', '[ -n "$VAR" ]'),
        ),
    ),
    Rule(
        id="empty-string-eq",
        description='[ "$V" = "" ] → [ -z "$V" ]  (and "$V" != "" → -n)',
        pattern=re.compile(
            rf'\[\s+"\$({_VAR})"\s+(=|!=)\s+""\s+\]'
        ),
        replace=lambda m: (
            f'[ -z "${m.group(1)}" ]' if m.group(2) == "="
            else f'[ -n "${m.group(1)}" ]'
        ),
        source_example="N/A",
        examples=(
            ('[ "$X" = "" ]', '[ -z "$X" ]'),
            ('[ "$X" != "" ]', '[ -n "$X" ]'),
        ),
    ),
    Rule(
        id="find-exec-rm-delete",
        description='find ... -exec rm {} \\; → find ... -delete  (faster, no shell re-entry)',
        # Only -f is matched. -r/-R/-rf would change semantics: rm -r removes
        # non-empty dirs while find -delete refuses them without -depth.
        pattern=re.compile(
            r'(find\s+[^\n]*?)-exec\s+rm\s+(?:-f\s+)?\{\}\s+\\;'
        ),
        replace=lambda m: f"{m.group(1)}-delete",
        source_example="N/A",
        notes='Use only when find paths are files or empty dirs. find -delete refuses non-empty dirs without -depth, so the rule deliberately skips -r / -rf invocations.',
        examples=(
            (
                'find /tmp -name "*.bak" -exec rm {} \\;',
                'find /tmp -name "*.bak" -delete',
            ),
            (
                'find . -mtime +30 -exec rm -f {} \\;',
                'find . -mtime +30 -delete',
            ),
        ),
    ),
    Rule(
        id="cat-file-pipe-grep",
        description='cat FILE | grep PAT → grep PAT FILE  (drop the useless cat)',
        # apply_fn does the work — re-attaching the file as a trailing arg
        # of grep is awkward as a single re.sub. The regex is unused.
        pattern=re.compile(r"(?!x)x"),
        replace=lambda m: m.group(0),
        apply_fn=_apply_cat_file_grep,
        source_example="N/A",
        shellcheck_id="SC2002",
        notes="Triggers only when the cat target is a single quoted/bare path.",
        examples=(),  # see _CAT_GREP_CASES in bash-shorten.py
    ),

    # --- Modernize group: opt-in via --include modernize ------------------
    #
    # These rewrite to non-coreutils binaries (sd, rg, fd) the user may
    # not have installed. They are off by default and the rewriter never
    # checks whether the target binary is on PATH — that's the user's
    # responsibility when they opt in.

    Rule(
        id="sed-replace-to-sd",
        description="echo \"$V\" | sed 's/X/Y/g' → sd 'X' 'Y' <<< \"$V\"  (literal-only; needs `sd`)",
        # Literal patterns only — sd uses regex by default but our guard
        # restricts to alphanumeric + safe chars so the conservative
        # mapping holds. Mirrors sed-replace-all's safety stance.
        pattern=re.compile(
            rf'echo\s+"\$({_VAR})"\s*\|\s*'
            rf"sed\s+'s/({_LITERAL}+)/({_LITERAL}*)/g'"
        ),
        replace=lambda m: f"sd '{m.group(2)}' '{m.group(3)}' <<< \"${m.group(1)}\"",
        source_example="N/A",
        notes='Requires `sd` (https://github.com/chmln/sd). Skips when the sed pattern contains regex metachars to avoid sd-vs-sed semantic drift.',
        group="modernize",
        examples=(
            (
                'echo "$LINE" | sed \'s/foo/bar/g\'',
                'sd \'foo\' \'bar\' <<< "$LINE"',
            ),
        ),
    ),
    Rule(
        id="grep-fixed-to-rg",
        description="grep -F PAT FILE → rg -F PAT FILE  (literal-string grep; needs `rg`)",
        # Only -F (fixed-string) grep maps cleanly. Plain `grep PAT` uses
        # BRE which differs from rg's regex flavor enough to risk silent
        # behavior changes — skip those.
        pattern=re.compile(
            r'\bgrep\s+-F\s+([^\s|;&]+)\s+([^\s|;&]+)'
        ),
        replace=lambda m: f"rg -F {m.group(1)} {m.group(2)}",
        source_example="N/A",
        notes='Requires `rg` (https://github.com/BurntSushi/ripgrep). Only -F (fixed-string) grep maps cleanly because regex flavors differ.',
        group="modernize",
        examples=(
            ('grep -F localhost /etc/hosts', 'rg -F localhost /etc/hosts'),
        ),
    ),
    Rule(
        id="find-name-to-fd",
        description='find . -type f -name "GLOB" → fd -t f "GLOB"  (gitignore-aware; needs `fd`)',
        # WARNING in description: fd respects .gitignore by default and
        # find does not. The rewrite changes behavior in repos with
        # gitignored matches. Opt-in only.
        pattern=re.compile(
            r'\bfind\s+\.\s+-type\s+f\s+-name\s+"([^"]+)"(?!\s*-)'
        ),
        replace=lambda m: f'fd -t f "{m.group(1)}"',
        source_example="N/A",
        notes='Requires `fd` (https://github.com/sharkdp/fd). BEHAVIOR DIFFERENCE: fd respects .gitignore by default; find does not. Negative lookahead skips finds that have additional flags (-mtime, -exec, etc.).',
        group="modernize",
        examples=(
            ('find . -type f -name "*.py"', 'fd -t f "*.py"'),
        ),
    ),
]

RULES_BY_ID: dict[str, Rule] = {r.id: r for r in RULES}
KNOWN_GROUPS: frozenset[str] = frozenset({r.group for r in RULES})
