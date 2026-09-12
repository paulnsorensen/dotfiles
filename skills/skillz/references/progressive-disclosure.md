# Progressive-disclosure & size audit

Read when the **Information hierarchy** lens fires. Measures the body against
Anthropic's Level-2 budget and checks the reference tree for the failure modes
line-counting cannot see.

## Why tokens, not lines

Anthropic's agent-skills *overview* documents the progressive-disclosure budget
in **tokens**: Level 1 metadata ~100 tok (always loaded), Level 2 body **under
5k tokens** (loaded on trigger), Level 3+ resources none-until-accessed. The
500-line rule in *best-practices* is a backstop, not the budget — Anthropic's
own skills run a median of ~129 lines. Prose-dense skills (~95–112 bytes/line
here vs Anthropic's shorter lines) pass the line rule while blowing the token
budget: easy-cheese's `cook` is 330 lines but ~9,250 tokens. Audit the number
that governs context, not the one that reads clean.

## Measure (no tokenizer dependency)

Claude's tokenizer is not public; tiktoken is OpenAI's BPE and would
mis-estimate an already-soft round number — precision here is noise on noise.
Use bytes/4 on the **body only** (strip the frontmatter block):

    body=$(awk 'b{print} /^---$/{n++; b=(n>=2)}' SKILL.md)   # body after frontmatter
    printf '%s' "$body" | wc -c | awk '{print int($1/4)" ~tok"}'

Report `~N tok` against the 5k Level-2 budget as the **primary** size signal;
report lines as secondary context. Over 5k → **high**-severity
Information-hierarchy finding; approaching 5k → a heads-up.

## Structural checks (matter more than the raw number)

Run against the target's `references/` and repo-wide. Splitting into
`references/` saves tokens only when SKILL.md documents *when* to read each file
(SkillReducer F3) — these checks catch splits that saved nothing.

1. **Nested references (one-level-deep rule).** A reference that links to
   another reference violates *best-practices* ("keep references one level
   deep"; the stated failure is a partial `head -100` read missing the tail).
   Scan each reference for links whose target is itself a reference file:

       grep -nE '\]\([^)]*references/|\]\([^)]*\.md\)' references/*.md

2. **Orphaned references (repo-wide).** A reference linked from *no* SKILL.md
   anywhere carries no read-trigger and is dead weight. Cross-skill linking is
   legitimate, so scan every SKILL.md, not just the target's:

       for f in references/*.md; do
         grep -rqlF "$(basename "$f")" $(git ls-files '*SKILL.md') \
           || echo "orphan: $f"
       done

3. **Untriggered references (F3).** A reference linked *without* a stated
   "read this when X" is loaded-in-full-regardless — the split saved nothing.
   Each `## References` entry must name a read-trigger; flag bare links.

4. **No table of contents on a long reference.** A reference >100 lines with
   no TOC risks the same partial-read miss (*best-practices*). Flag it.

## Actionable-content ratio (de-slop signal)

SkillReducer (n=55,315 public skills) found only **38.5%** of body content is
actionable; >60% is non-actionable prose. Estimate the target's ratio
(imperative/checkable lines ÷ total body lines) and flag a low ratio as a
**Pruning** cross-finding. The descriptive baseline is solid; treat the causal
"compression improves quality" claim as weak (single self-benchmarked paper).

## Recommend splitting only with routing

Moving prose into `references/` without a documented "read when X" line does
not reduce loaded tokens (F3) — it just adds navigation. When recommending a
split, require the SKILL.md to gain a `## References` entry naming the
read-trigger; otherwise recommend **pruning** instead. Relocating content an
every-run path reads is never a fix.

Sources: Anthropic agent-skills *overview* + *best-practices* docs; SkillReducer
(arXiv 2603.29919). Full citation table in dotfiles issue #547.
