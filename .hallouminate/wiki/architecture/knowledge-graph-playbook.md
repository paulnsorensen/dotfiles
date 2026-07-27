# Knowledge-graph engineering for multi-agent systems (playbook digest)

Digest of "Knowledge Graph Engineering for Multi-Agentic Systems: The
Anthropic Playbook" (independent synthesis of Anthropic's KG cookbook +
Building Effective AI Agents + Managed Agents, July 2026; ingested
2026-07-24). Kept here for the doctrine that transfers to this repo's
multi-agent stack: stage-tiered model selection, shared memory over
orchestrator bottlenecks, grounded evaluation, and production discipline for
unattended loops. Full text: `.context/attachments/fUOySu/` (gitignored).

## The pipeline and its model tiers

Four stages, each a structured-output prompt: extraction (typed entities +
subject–predicate–object triples per document) → resolution (cluster surface
forms into canonical nodes, descriptions as disambiguation context) → assembly
(MultiDiGraph + selective hub summarization) → querying (serialize a k-hop
subgraph, answer with edge-level citations).

| Stage | Model | Why |
|---|---|---|
| Extraction | Haiku | high volume, schema-constrained; speed and cost dominate |
| Resolution | Sonnet | weighing conflicting evidence; reasoning quality dominates |
| Summarization | Sonnet | synthesizing across documents; nuance matters |
| Querying | Sonnet | multi-hop reasoning over serialized triples |

The transferable rule: **schema-constrained volume work goes to the cheap
tier; judgment work goes to the reasoning tier.** And at scale, don't ask the
model to do what an index can: block candidates with cheap deterministic
signals (token index, embedding buckets — no model call), then spend LLM calls
only arbitrating within blocks of 50–100. Keep the model for judgment,
deterministic logic for everything else.

## Where a graph fits the agent patterns

- **Orchestrator–workers → shared memory.** Workers write findings into the
  store and read the slice they need; the orchestrator's window stays small
  instead of growing linearly with worker count. This is the blackboard
  architecture: a shared, provenance-carrying repository as collective memory.
  Anthropic's numbers frame why it matters: multi-agent systems outperform
  single agents by 90.2% on tasks needing multiple independent directions, but
  consume 10–15× the tokens and demand careful context management.
- **Evaluator–optimizer → grounding layer.** See below.
- **Loops → persistent world model.** The store survives context flushes;
  incremental updates (resolve new facts against the existing canonical set,
  never rebuild) keep cost proportional to the delta, not the corpus.
- **Routing → deterministic classifier input.** Entity type and degree route a
  query to the right specialist without an LLM call.

## When a graph earns its complexity

| Scenario | Right tool |
|---|---|
| Single-document QA | RAG or direct context |
| Multi-doc, single-hop | RAG with reranking |
| Multi-doc, multi-hop chaining | knowledge graph |
| Multi-agent shared state | knowledge graph |
| Evaluator needs ground truth | knowledge graph |
| Overnight loop, persistent memory | knowledge graph |
| Simple classification or routing | single agent |

Rule of thumb: the graph earns its complexity only when passing documents or
summaries through context windows either exceeds the window or loses the
connections.

## Grounded evaluation

An evaluator without ground truth judges "does this look right"; an evaluator
with a provenance-carrying store fact-checks: query the specific claim, cite
the specific evidence that supports or contradicts it. Feedback becomes
"triple (X, works_at, Y) does not exist; the store contains (X, left, Y) from
document Z" instead of "this seems off". A claim the store can neither confirm
nor refute is **escalated to a human**, never silently accepted or rejected.

## Facts entering a store: precision first

Favor precision over recall for anything written into a durable shared store:
a wrong fact spawns wrong downstream inferences that propagate through
multi-hop reasoning, while a missing fact leaves the store incomplete but
correct. Scope note: this governs *facts entering storage*. Review findings
are the opposite case — report everything and filter in a separate pass
([[operations/prompting-claude-opus-5]]) — because a review filter stage
exists downstream; a store write has no filter after it. Structured outputs
are the enabling contract either way: the interface between pipeline stages
must be schema-validated typed data, not parsed free-form text — interface
robustness is what separates processing ten documents from ten thousand.

## Production discipline for unattended loops

- **A loop's intelligence lives in its environmental feedback.** Change the
  prompt → rerun the scorer → watch the metric move. A pipeline without a
  scorer drifts blind. (The repo analogue: routing decisions.jsonl + the
  session-analytics query pack are the scorer for the routing overhaul.)
- **Per-run volume caps** bound the cost of ingestion errors (the repo
  analogue: wave batching and concurrency caps).
- **Version the schema alongside the artifact** so outputs from different
  prompt versions stay distinguishable.
- **Human-sample a random output regularly** — comprehension rot sets in the
  moment you cannot explain why an output is there.
- Production readiness is a checklist, not a feeling: gold set, alias/scorer
  coverage, schema version, volume cap, resolution fallback, provenance,
  incremental update, connectivity monitor, selective re-summarization, human
  sample. A missing item is a specific, nameable risk.

## Local implications (2026-07-24)

The hallouminate wiki + `.cheese/` artifacts already play the blackboard role
(durable, queryable, cited); a triple-style graph is the next rung only when
findings must be *chained* across workers, not just retrieved. The fan-in
payload contract ([[fanout-fanin-discipline]]) is this doctrine's
structured-output rule applied to worker handoffs. Reviewer/taste verdicts
should be grounded in provenance (diff hunks, spec lines, test output) with
unverifiable claims escalated, per [[subagent-routing-policy]].

*Source: "Knowledge Graph Engineering for Multi-Agentic Systems" (PDF ingest, hash 32c0769bb78d8fb7) · Updated: 2026-07-24*
