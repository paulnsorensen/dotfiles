# Sub-agent dispatch analytics

Evidence base for the `coder` dispatch contract in [[architecture/agents-dir]]
and the phase-agent delegation rules in `agents/preamble.md`. Numbers come from
`/session-analytics` (historically `~/.claude/analytics/sessions.duckdb`) over 578 sub-agent
runs reconstructed from sidechain transcripts.

## Method

Sidechain entries share a `sessionId` with their parent, so a run is recovered
by walking `parentUuid` from each `isSidechain AND parentUuid IS NULL` root. Each
root's first user message is the verbatim dispatch prompt, which joins back to
the `Agent` tool call to recover `subagent_type`. All 42,617 sidechain entries
resolved to one of 578 roots; 548 matched a recorded dispatch.

Reproduce with the queries in `references/subagent-runs.md`.

## Population

| agent | runs | avg prompt (chars) | median tools | median secs | tool err % |
|---|---|---|---|---|---|
| coder | 207 | 4639 | 34 | 303 | 3.8 |
| reviewer | 139 | 2552 | 12 | 196 | 4.1 |
| explorer | 87 | 2118 | 14 | 89 | 2.6 |
| researcher | 43 | 2470 | 16 | 153 | 2.4 |

`coder` is the dominant consumer — 57% of all sub-agent tool calls (7559 of
13,199) and by far the longest-running.

## Finding 1 — dispatch size, not dispatch detail, predicts coder failure

**77 of 207 coder runs (37%) ended `status: blocked: out of context`.** The
checkpoint discipline in `coder.md` fires as designed; the problem is that it
has to. Only 3 runs hit the hard harness ceiling
(`Sub-agent budget exceeded ... context 131028/130000 tokens`), so the coder is
self-checkpointing early and correctly — it is simply being handed jobs that do
not fit in one 130k window.

Failure rate scales almost purely with prompt length, which is a proxy for how
much scope was bundled:

| dispatch prompt size | runs | out-of-context |
|---|---|---|
| < 2.5k chars | 18 | **5.6%** |
| 2.5–4k chars | 89 | **18.0%** |
| 4–6k chars | 70 | **55.7%** |
| > 6k chars | 30 | **66.7%** |

A 12× swing. Prompt-length inflation is not verbosity: reading the five longest
prompts (26.8k, 26.7k, 26.2k, 21.5k, 14.4k chars) shows they carry the same
contract density per task as a 3k prompt and differ only by (a) task count —
one bundles 8 tasks across 7+ files — (b) verbatim pasted source, and (c)
re-stated resume state from a previous run that already blew its budget.

## Finding 2 — line anchors do not rescue an oversized dispatch

`agents/preamble.md` currently advises pre-staging with an explorer so the coder
arrives "pre-armed with anchors" and does "near-zero exploration". The data does
not support anchors as the lever.

| | runs | out-of-context |
|---|---|---|
| long prompt (≥4k), anchors | 60 | 61.7% |
| long prompt (≥4k), no anchors | 40 | 55.0% |
| short prompt (<4k), anchors | 41 | 19.5% |
| short prompt (<4k), no anchors | 66 | 13.6% |

Length dominates in both directions; anchors are neutral-to-slightly-negative
once length is controlled for (they correlate with bigger jobs, which is why the
uncontrolled figure looked bad: 44.6% vs 29.2%).

Anchors do buy a modest efficiency gain — median pre-write tool calls fall 14 → 11
and median wall-clock 341s → 291s — but they do not change whether the job fits.
**Splitting the dispatch is the lever; anchoring it is a refinement.**

## Finding 3 — coder burns ~40% of its budget before its first write

Median coder run makes **13 tool calls before its first write** — 39.7% of its
tool budget. 10 of 207 runs (4.8%) wrote nothing at all.

What those pre-write calls are (n=3017):

| tool | share |
|---|---|
| Bash | 60.1% |
| Read (built-in) | 16.7% |
| tilth_read | 11.6% |
| ToolSearch | 6.5% |
| tilth_search | 3.3% |

Top pre-write shell commands: `cd` 473, `grep` 411, `cat` 148, `git` 133,
`sed` 116, `wc` 51, `find` 39, `ls` 27. Roughly 770 of 1814 pre-write Bash calls
(42%) are file I/O that the routing preamble bans outright.

## Finding 4 — the routing preamble is prose-only, and prose loses

File-I/O routing compliance across whole runs:

| agent | tilth calls | built-in Read/Grep/Glob/Edit/Write | shell file I/O | tilth share |
|---|---|---|---|---|
| coder | 2199 | 722 | 1513 | **49.6%** |
| explorer | 630 | 147 | 228 | **62.7%** |
| reviewer | 152 | 448 | 322 | **16.5%** |

`coder.md` states "No host file tools … If tilth's edit tool is unavailable, stop
and report; do not fall back to `Edit`/`Write`/`sed`." The *write* half of that
rule holds — only 37 `Edit` calls, and two runs correctly returned
`status: blocked` when `tilth_write` was unloaded. The *read/search* half does
not: built-in `Read` (681 calls) outnumbers `tilth_read` (998) at a 0.68 ratio,
and shell search is used more than `tilth_search` by a factor of five.

The structural reason is that the prohibition is enforced by the tool grant only
where a tool could be removed. `Grep`, `Glob`, `Edit`, and `Write` are stripped
from the coder grant and are correspondingly near-zero. `Read` and `Bash` are
granted (Bash necessarily, for gates) and are the open doors.

## Finding 5 — the tool-reroute hook catches ~8% of what it targets

`agents/lib/tool-reroute/search.js` rewrites only "clean shape" searches. It
returns `null` (falls through to raw execution) for any of: a regex
metacharacter in the pattern (`[\\.^$*+?()[\]{}|]`), any long flag, any of
`-i -l -c -o -v -w -x -E -P -A -B -C -e -f -m`, more than two operands, or any
pipe / `&&` / redirect.

Applying those same predicates to real traffic:

| agent | shell `grep`/`rg`/`find` calls | would be rewritten |
|---|---|---|
| coder | 909 | **70 (7.7%)** |
| reviewer | 190 | 2 (1.1%) |
| explorer | 143 | 5 (3.5%) |

Every sampled coder `grep` fell through — typically because the pattern used
alternation (`^<<<<<<<\|^=======`) or the call was chained with `;`. The
conservatism is deliberate and correct in isolation (never silently change
search semantics), but the net effect is that the routing rule has no
enforcement at the point of use.

**The hooks are not too strict. They are too loose to bind.** Genuine
over-blocking is negligible: across all 578 runs the guards produced 11
write-redirect blocks for the reviewer, 8 for the coder, 2 sensitive-file
blocks, and 2 dirty-tree git blocks — all correct catches, none spurious.

## Finding 6 — the reviewer's read-only contract contradicts the pipeline

`reviewer.md` says "Never edit or write code … You have no Edit/Write tool", yet
reviewer runs made 16 `tilth_write` calls. Every one writes a handoff artifact
(`.cheese/ultracook/<slug>/curds/N/age.md`), which the `/cheese-factory` and
ultracook protocols require. The blanket prohibition is therefore false as
written, and the write-redirect guard blocks the shell path 11 times, forcing
the agent to discover the MCP path by trial.

The rule the reviewer actually needs is "never modify source; you may write your
own digest artifact under `.cheese/`".

## Finding 7 — dispatch prompts assume a contract they do not state

From reading 43 coder prompts and ~100 reviewer/explorer/researcher prompts in
full:

| field | coder | reviewer | explorer | researcher |
|---|---|---|---|---|
| names a gate/test command | 95% | — | — | — |
| "do NOT" scope fence | 82% | 78% | 66% | 72% |
| explicit output format | 54% | 56% | **90%** | 53% |
| line anchors | 64% | — | — | — |
| four-field handoff schema | 34% | — | 44% | — |
| explicit target (diff/commit/PR) | — | **98%** | ~90% | n/a |
| "locked decisions" block | 7% | — | — | — |
| "read first" pointer to resume doc | 7% | — | — | — |

`explorer` is the healthiest — 90% state an output contract, 92% demand
`file:line` citations, and its runs are the shortest and cleanest (median 89s,
2.6% error). `coder` is the weakest on output contract despite being the agent
whose handback the orchestrator must machine-read.

Two output dialects coexist in reviewer dispatches — the `/age`
`blocker|high|medium|low` findings block (34%) and the taste-test
`pass|revise|halt` per-lens block (48%) — with nothing in the prompt saying which
one applies.

## What changed as a result

- `agents/agent_definitions/coder.md` — added a "Dispatch contract" section the
  coder validates on arrival, and replaced the soft context guidance with the
  measured 130k budget and a refuse-or-flag rule for oversized dispatches.
- `agents/agent_definitions/reviewer.md` — narrowed "never write" to "never
  modify source", naming the sanctioned `.cheese/` artifact path, and pinned
  which output dialect applies.
- `agents/preamble.md` — replaced the anchor-centric sizing advice with the
  evidence-based split-first rule and the coder dispatch contract.

Open proposal, not yet implemented: widen `search.js` to *deny with guidance*
(rather than silently pass through) for exotic-shape searches that are plainly
code search, while continuing to allow pipes and redirects used for gate-output
parsing. This is the only change that would move Finding 4 materially, and it
carries a real risk of blocking legitimate shell work — it needs its own spec.

Related: [[architecture/agents-dir]], [[operations/dev-environment]]
