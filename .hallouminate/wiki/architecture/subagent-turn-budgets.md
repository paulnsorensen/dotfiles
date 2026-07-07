# Sub-agent turn budgets: the data behind the `maxTurns` caps

Every rendered Claude sub-agent carries a `maxTurns` cap (shipped in PR #344) so a
runaway agent hands its partial digest back to the coordinator at the cap instead
of burning unbounded agentic turns — the motivation is API-credit cost, not
quality. The caps are harness-enforced (mechanical) rather than prompt-level "be
frugal" instructions, which drift. This page records the measured turn and
context distributions the caps were grounded in, so the values can be revisited
when legitimate work gets clipped rather than re-derived from scratch.

**Update (PRs #392/#401/#407):** `maxTurns` frontmatter turned out to be
unenforced upstream (claude-code#41143 — the hardcoded default always wins), so
enforcement moved to the `turn-budget-guard` hook. The data below still grounds
the budget values; the hook's non-obvious mechanics are at the bottom of this
page.

See [[agents-dir]] for the registry mechanics, [[agent-profile]] for the renderer
that emits the field, and [[agent-vs-skill-tiering]] for why each agent earns its
own context window in the first place.

## How the data was measured

Pulled via the `session-analytics` skill (DuckDB at
`~/.claude/analytics/sessions.duckdb`), claude harness, all projects. All figures
are aggregate counts and percentiles — no session IDs, project names, paths, or
content. Reproduce with the queries in that skill against `raw_entries`.

- **Sub-agent invocation** = one sidechain chain. `raw_entries.isSidechain=true`
  rows grouped into chains via `parentUuid`; every one of the 732 observed chains
  had a null-parent root, so chains are self-contained invocation units.
- **Turn** = one assistant inference (one `type='assistant'` message in the chain).
- **Agent type per chain** = ASOF-matched to the nearest preceding `agent_spawns`
  row in the same session (~67% matched; 241 chains were unmatched and skew
  lighter — treat per-type rows as the matched subset).
- **Context occupancy at a message** = `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens` from `message.usage`.
- **Dumb zone** = context ≥ 120K tokens.
- **Sample**: 732 sub-agent invocations across 158 sessions; the orchestrator
  contrast is 389 main (non-sidechain) sessions.

## Turns per invocation, by agent type

Well-sampled agents (n ≥ 6). `peak` columns are the per-chain peak context;
`crossed` is how many chains entered the 120K dumb zone.

| Agent | n | p50 | p90 | p95 | max | med peak | p95 peak | crossed 120K |
|---|---|---|---|---|---|---|---|---|
| coder | 74 | 55 | 157 | 183 | 244 | 100K | 177K | 20/74 |
| general-purpose | 165 | 26 | 101 | 123 | 339 | 74K | 146K | 20/164 |
| Explore (built-in) | 26 | 47 | 78 | 97 | 143 | 86K | 116K | 0 |
| reviewer | 84 | 27 | 48 | 54 | 81 | 80K | 129K | 8/85 |
| researcher | 50 | 27 | 41 | 46 | 81 | 64K | 92K | 0 |
| explorer | 57 | 16 | 36 | 51 | 65 | 55K | 99K | 0 |
| whey-drainer | 8 | 7 | 15 | 18 | 21 | 20K | 62K | 0 |
| duckdb-expert | 6 | 13 | 23 | 23 | 23 | 30K | 36K | 0 |

Scanners are too thin to percentile (n ≤ 3 each): `ghostbuster`, `ricotta-reducer`,
`fromage-age-arch`, `nih-scanner`, `fromage-secaudit`, `roquefort-wrecker` —
observed max turns 50–94.

Across all 732 invocations: mean 34 turns, p50 23, p95 108, p99 181, max 339.

## The dumb zone is an orchestrator problem, not a sub-agent one

- **Sub-agents rarely reach it.** Only 7% (51/731) ever cross 120K; when they do,
  the median crossing turn is 48 (mean 56). The median chain peaks at just 66K.
  Only `coder`, `general-purpose`, and `reviewer` produce any crossers.
- **Orchestrator sessions usually do.** 55% (214/389) cross 120K, median crossing
  turn 63, and the **median main session peaks at 125K** (p95 261K, max 436K),
  running a median of 83 turns.

The reframe that follows: a sub-agent `maxTurns` cap is a **credit-burn / runaway
backstop**, not a context-quality lever — 93% of sub-agents never approach the
dumb zone. Quality-at-large-context is the orchestrator's problem (taste-test gate
→ re-dispatch), not something a sub-agent turn cap fixes.

## Shipped caps (PR #344) and the gap to the data

`coder: 100`; all 14 other rendered agents: `50`. Emitted by
`claude_agent_frontmatter()` in `agent-profile/agent_profile/shared.py` (a
Claude-honored frontmatter field; Cursor reads the shared file and ignores it,
and codex/opencode/copilot build their own agent frontmatter, so the field is
Claude-only).

These are a deliberate **flat, conservative tightening**, not the raw p95s — for
several agents the cap sits *below* the measured p95 (e.g. `coder` p95 183 vs cap
100; `reviewer` p95 54 vs cap 50). The cap clips the runaway tail by design: a
capped agent returns its partial digest and the coordinator re-dispatches. If a
cap starts truncating legitimate work, this table is the evidence to raise it —
set the cap above the agent's real p95, below its runaway max.

## Built-in agents are out of reach

`general-purpose`, `Explore`, and `Plan` are Claude Code **built-ins**, not
rendered by `agents/registry.yaml`, so they cannot carry `maxTurns`. This matters
because they include the heaviest-tailed agents measured (`general-purpose` p95
123 / max 339; `Explore` max 143).

A same-name `~/.claude/agents/<name>.md` shadow is **not** a supported cap path:
the docs' file-scope precedence table (managed → CLI → project → user → plugin)
excludes built-ins, which are "always registered"; the `SubagentStart` matcher
treats built-in names and custom `name`-frontmatter as separate categories; and
for `general-purpose` (the default for untyped spawns) a shadow would replace
Claude's internal prompt fleet-wide. The only documented lever on a built-in is
`permissions.deny` (e.g. `Task(Explore)`, `Task(general-purpose)`) — which
*removes* it, not caps it — or `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS=1`
(headless/SDK only, removes all). Source: code.claude.com/docs/en/sub-agents
§Built-in subagents and §Choose the subagent scope.


## Enforcement layer: the turn-budget-guard hook (PRs #392, #401, #407)

`agents/hooks/turn-budget-guard.sh` → `agents/lib/turn-budget-guard.js` caps each
sub-agent on a dual ceiling — tool-call turns AND transcript bytes, whichever
trips first — via PreToolUse hard-deny, a one-time PostToolUse wrap-up nudge, and
SubagentStop cleanup. Keyed on `agent_id` (hook events inside a sub-agent carry
it; orchestrator calls don't, so the guard no-ops on them). Fail-open on every
error path — the guard caps runaways, it must never become a denial-of-service.

Non-obvious facts a future agent would re-derive (learned in PR #407):

- **Continued agents vs the byte wall.** SubagentStop wipes the turn counter but
  the transcript persists, so a SendMessage-continued agent already over the
  byte hard ceiling was denied on its *first* tool call with no handoff window
  (observed live in the decision log). Hence the 3-call grace window past the
  byte ceiling plus a hard nudge instructing the agent to persist a handoff and
  return `status: blocked: out of context` — the orchestrator's re-dispatch
  contract. The turn ceiling gets no grace: it ramps slowly and the soft nudge
  precedes it by design.
- **State is append-only on purpose.** Parallel tool calls in one batch fire
  concurrent PreToolUse hooks; the original state.json read-modify-write lost
  increments (duplicate turn counts observed live). Counters are the byte size
  of an append-only file (O_APPEND writes are atomic); nudge flags are `wx`
  marker files (EEXIST = already set, never re-emit).
- **The byte signal is a proxy, not a conversion.** Transcript JSONL size ≈
  context: the JSON envelope inflates bytes/token while the untranscripted
  system prompt deflates it. Thresholds are calibrated against live denies —
  don't treat the 4-bytes/token arithmetic as exact.
- **The decision log is debug-gated for the orchestrator.** Orchestrator
  no-agent-id records were 64% of `decisions.jsonl` volume on the hot path of
  every tool call; they only log under `CLAUDE_TURN_BUDGET_DEBUG`. The log
  rotates at 5MB (single `.1` generation) beside the SubagentStop sweep.
- **opencode tool hooks carry no identity.** `tool.execute.before/after` input
  is only `{tool, sessionID, callID}` — the adapter resolves
  `client.session.get()` and treats parentID-set AND agent-non-empty as
  sub-agent, with sessionID as the identity key and `session.idle`/`deleted` as
  the SubagentStop equivalent. Deny-by-throw is safe there: opencode v1.17.14
  triggers plugins inside the AI SDK tool `execute()`, and `ai@6.0.168`
  `execute-tool-call.ts` catches every execute throw into a model-visible
  `tool-error`, not a turn crash. The byte signal is inert on opencode (no
  transcript path) — turn-ceiling-only enforcement.
- **New heavy agent types must be added to `BUDGETS`.** Unknown types fall to
  `default` (40 soft / 50 hard turns). `general-purpose` — the ultracook /
  cheese-factory full-peer worker — sits at coder tier (75/100) for this reason;
  a new pipeline-scale agent type left off the table gets half a coder's budget.
