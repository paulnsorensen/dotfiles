# Code review cognitive load: evidence for decision cards

Published studies support grouping a diff into a few units. They do not prove impact ordering, an optimal card count, or that folded content hides no defects. Treat those three points as open questions, not decisions. Research ran on 2026-11-20. Tool patterns are in [[research/code-review-interfaces]].

## Why this page exists

The architecture review viewer shows a few decision cards and hides code behind a "show me" drill-down. The goal is less overload than reading code. This page lists the evidence on review load and marks its strength. See [[architecture/agents-dir]] (architecture review skill) and PR <https://github.com/paulnsorensen/dotfiles/pull/1615>.

## Evidence that supports the design

### Splitting a change into independent partitions

Barnett et al. (ICSE 2015, ClusterChanges) split a changeset into independent partitions. Most of 20 developers agreed the split was useful. Changes with six or more non-trivial partitions were 1.4% of reviews. The study has no defect outcome. Confidence: certain. Source: <https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/barnett2015hdh.pdf>

Implication: grouping into few units is supported. Most changes need only a few cards.

### Working memory and review order

Baum et al. (EMSE 2019, n=50) found that working memory capacity correlates with review effectiveness. A better change-part order was not statistically significant. Confidence: certain. Source: <https://sback.it/publications/emse2019a.pdf>

Implication: load matters. Ordering cards by impact is unproven.

### Change size

Google modern code review: the median change is 24 lines. About 90% of changes touch fewer than 10 files. Confidence: certain. Source: <https://dl.acm.org/doi/pdf/10.1145/3183519.3183525>

Implication: most reviews need few cards. Large diffs are the hard case for the viewer.

## Evidence with weaker confidence

- **Cisco and SmartBear case study:** review under 200-400 lines of code. Defect finding drops above that size. Author annotations help. The source is vendor-published and covers one team. Confidence: speculating. Source: <https://static0.smartbear.co/support/media/resources/cc/book/code-review-cisco-case-study.pdf>
- **LLM-assisted review field study:** developers value upfront AI summaries for large or unfamiliar PRs. They worry about trust and false positives. The study records perceptions only. Confidence: speculating. Source: <https://arxiv.org/html/2505.16339v1>
- **Fregnan et al. (ESEC/FSE 2022, n=106), verified 2026-11-21:** a defect in the last file had 64% lower odds of detection than in the first file. This is an odds ratio. It held for one of two seeded defect types (Corner Case), with no effect for Missing Break. The earlier wording "64% more likely" was wrong. Confidence: certain. Source: <https://eprints.gla.ac.uk/273443/3/273443.pdf>
- **Spadini et al. (ICSE 2019, n=93), verified 2026-11-21:** test-first review found the same share of production defects and more test defects. Most reviewers prefer to read production code first. Source: <https://sback.it/publications/icse2019a.pdf>
- **Interface-first review (2026-11-21):** Google ranks overall design first but also says to read every human-written line. No checked study shows defect location by public or private visibility. Full report: research/interface-first-code-review-load in the cheese corpus (~/.local/share/cheese/paulnsorensen-dotfiles/).
- **Spadini et al. (ICSE 2019):** test-first review may help. Only a search snippet was seen. Not verified.

## Open questions (not decisions)

1. **Impact ordering is unproven.** Baum found no significant order effect. The verified Fregnan result shows positional bias for one defect type. Then the first card gets more attention, and the order choice carries risk.
2. **No study gives an optimal card count.** A typical range is 2-5. Barnett suggests most changes have few partitions.
3. **No study measures defects missed behind folded content.** The "show me" fold is a design risk. A drill-down may not be opened.
4. **Test-first card order may help.** The evidence is a snippet only.
5. **AI summary trust.** Developers want summaries but distrust them. No checked tool shows per-claim provenance. The "watch out with its basis" field in a card addresses this gap, and no evidence tests it.

## How to use this page

- Cite grouping as supported. Cite the other four points as open.
- Quote the Fregnan figure as "64% lower odds when last", not as "64% more likely when first".
- Treat vendor-published numbers (Cisco/SmartBear, GitClear, NDepend, Greptile) as claims.

_Source: research brief for PR 1615, run 2026-11-20 · Updated: 2026-11-20 · Supersedes: none_
