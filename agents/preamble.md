# Preamble — MCP tool routing

Owns the machine's code-intelligence routing: tilth is the workspace file-I/O and code-search layer; built-ins are last resort.

The `cheez-search` / `cheez-read` / `cheez-write` skills route through tilth — use them instead of host `Read` / `Edit` / `Write` / `Grep` whenever they're available.

**Codex:** don't use `exec_command`/shell for workspace file-I/O or code search — `cat`/`head`/`tail`/`sed -n` → `tilth_read`; `grep`/`rg`/`ls`/`find`/`fd` → `tilth_search`/`tilth_list`. Shell out only for tests, builds, and non-file-IO operations. (`exec_command` errored ~12% of file-IO calls; tilth 0%.)

## Ground in the repo wiki (hallouminate) first

If the hallouminate MCP is connected, **ground before you act and maintain before you stop** — the per-repo wiki holds the cross-session *why* (architecture rationale, gotchas, design decisions) that code and `git` can't tell you.

- **At session start / before non-trivial work** — especially anything touching architecture, config, or unfamiliar subsystems — query the wiki first: `ground` (semantic search) or `list_tree` / `read_markdown`. Run `list_corpora` if unsure which wiki applies. This is a read; it costs little and routinely saves a re-derivation. Skip only for trivial one-step edits or when no `repo:<name>:wiki` corpus exists.
- **Before each tool call, the self-check extends:** "Is the *why* behind this already written down?" If it's a design/rationale question, `ground` it before reading code blind.
- **At session end** — when the session established a non-obvious fact, decision, or gotcha a future agent would otherwise re-learn, write it back via `add_markdown` (one topic per file, capture the *why* not the *what*, link related pages). Don't duplicate what the code or `AGENTS.md` already states.

The wiki is the fast path to design rationale; `AGENTS.md` / `CLAUDE.md` is the command/structure reference. Use both.

## Workflow before editing code

1. **Scope it** — use `tilth_search` to find affected files and callers before touching multi-file changes.
2. **Read** — use `tilth_read` for a file or `tilth_search` / `tilth_grok` for a narrow symbol or call path.
3. **Edit** — use `tilth_write` tag-anchored operations; use its block operations for symbol-bounded edits.

**tilth verbs:** `tilth_read` (read), `tilth_list` (list dirs), `tilth_search` (symbol/content/callers), `tilth_write` (edit), `tilth_diff`, `tilth_grok`, `tilth_deps` — not `tilth_files`/`tilth_edit` (renamed; these do not exist).

## Routing self-check

Before each tool call, ask: "What's the smallest tilth operation that answers this?"

- File or symbol read, search, caller lookup, or edit → **tilth** (for "where is X" / "what calls Y": `tilth_search kind:"symbol"` or `kind:"callers"` — not `content`/`regex`)

If unsure, pick the smallest-scope tool that can answer the question. Don't rationalize built-ins with "the file is small" or "I already know the path" — those rationalizations have produced incorrect behavior before.

This rule is enforced by prose, not by the harness. The `tool-reroute` hook only rewrites clean-shape searches and falls through on any regex metacharacter, exotic flag, pipe, or chained command — in practice it catches under 8% of shell searches. Measured routing compliance is 63% for the explorer, 50% for the coder, and 17% for the reviewer, and the leak is read-side: built-in `Read` and shell `grep`/`cat`/`sed`, not `Edit`. Assume nothing will stop you; the self-check is the only gate.

## Phase-agent delegation (every skill, not just cheese-flow)

Four general phase-agents model the explore → research → review → code workflow. Delegate to them by default — under any easy-cheese skill (`/mold`, `/cook`, `/age`, `/cure`, …) **and** any user-installed skill or bare task. They run in isolated context windows and hand back a condensed digest, keeping file dumps and fetch bodies out of your window. Planning stays with you, the top-level orchestrator: you own the human approval loop and you are the only level that can fan these agents out (a level-1 subagent cannot spawn subagents).

| When the work is… | Delegate to | It returns |
|---|---|---|
| "where / how / what" about unfamiliar code — orientation, blast-radius, "find me X" | `explorer` (read-only) | cited findings digest |
| A question outside the codebase — library/API docs, current web facts, versions, comparisons | `researcher` (read-only on code; writes `.cheese/research/`) | cited claim table + slug path |
| Checking a diff/PR/branch/path before it lands | `reviewer` (read-only) | severity-grouped findings |
| Writing or changing code — spec, bug fix, applying review findings | `coder` (full write surface) | what changed + verification |

Default self-check before doing phase work inline: "Is this an explore / research / review / code task that a phase-agent should own?" If yes, delegate — don't burn your own context re-deriving what an isolated agent can hand back distilled. Skip delegation only for trivial one-step work where the dispatch overhead exceeds the task.

### Cross-phase handoff

Isolated phase-agents don't share context — each returns a condensed digest to you, and you thread that digest (or the artifact it points at) into the next phase's dispatch prompt. That is where context lives between phases: in the handoff, not in shared memory. Every phase-agent opens its digest with the same four-field block so you can machine-read where it landed:

```
status: ok | blocked: <one-line reason>
next: <recommended next phase> | done
artifact: <path to fuller output, if any>
<one-line orientation>
```

Default is the inline digest — `artifact:` is omitted when the digest is complete (explorer/reviewer outputs are designed small). When an agent's output is genuinely too large to inline, it writes a durable artifact (`.cheese/<phase>/<slug>.md`, or `.cheese/research/<slug>/` for the researcher) and returns the path as the lightweight reference, which you pass forward instead of re-pasting. `next:` is the agent's recommendation only — you own the routing decision and may override it. A `status: blocked: out of context` handback means the agent hit its context budget (130k tokens / 100 turns) mid-task — never resume the exhausted agent, including via SendMessage: a resumed transcript inherits the spent context and starts near-full. Dispatch a fresh one from the `artifact:` slug so it picks up where the last left off. When that `artifact:` path lives inside a disposable isolation worktree (`.claude/worktrees/agent-*`), copy it to a durable location (the main workspace's `.cheese/` or `.context/`) immediately on receiving the handback, before dispatching the successor — isolation worktrees are auto-cleaned when their tree looks unchanged, and gitignored/untracked artifacts don't count as changes.

### Coder fan-out

Default to one coder. Coding is a poor multi-agent fit — it needs shared context, burns far more tokens, and adds coordination overhead — so a coder fan-out only pays off for genuinely independent work. Dispatch multiple `coder` subagents only when the subtasks are file-disjoint and independent (no shared mutable state, no sequential dependency), the same disjointness test `/cheese-factory` applies to curds. Otherwise run a single coder: re-deriving shared context across split coders costs more than the parallelism saves.

**Dispatch sizing — split first, anchor second.** A coder's window is 130k tokens. Across 207 real dispatches, 37% ended `blocked: out of context`, and the failure rate tracks dispatch size almost linearly: 5.6% under 2.5k prompt chars, 18% at 2.5–4k, 56% at 4–6k, 67% above 6k. Anchors do not rescue an oversized dispatch — controlling for length, anchored and unanchored runs fail at the same rate. **Splitting is the lever; anchoring is a refinement.**

So: split outright when more than ~5 distinct edit sites are in scope, a target file over ~800 lines must be read whole, or a test-suite audit rides along with implementation. Split multi-finding packages so one dispatch carries only what it can complete. Treat your own prompt length as the tell — if you are past ~4k characters, you are probably bundling two dispatches, and pasting more source or more anchors will not fix that. Then pre-stage with an explorer and inline exact line anchors and seam signatures, which buys roughly a quarter off the coder's pre-write exploration (median 14 tool calls → 11) once the job already fits.

**What every coder dispatch must carry.** Six fields, in this order. The coder validates them on arrival and flags what's missing.

| field | states |
|---|---|
| **Task** | what must be true when done, one sentence |
| **Sites** | every file to touch, each with a line range or symbol name |
| **Done means** | the literal gate command *and* what green looks like — exit 0, a pass count, a `grep` that must return empty. "Run the gates" is not a success condition |
| **Scope fence** | what not to touch; whether to commit |
| **Locked decisions** | design calls already made and not the coder's to revisit — omit only when there genuinely are none |
| **Return format** | the handback shape, or "coder default" |

Measured coverage today: 95% name a gate command, 82% carry a scope fence, 64% carry line anchors, 54% state a return format, 34% a handoff schema, and only 7% state locked decisions. Locked decisions and a literal success string are the two cheapest fields to add and the two most often missing.

### Fresh-context taste-test (after `coder` returns)

The `coder` self-checks the taste-test lenses inline, but the writing context can't reliably see its own drift and a dispatched `coder` can't fan out (`disallowedTools: [Agent]`) to its own reviewer. So the **authoritative** taste-test is yours, run after the coder digest returns and before you accept the handoff.

**Cost gate.** Run it only when the coder's diff **touches more than one file OR adds public surface** (a new exported function, type, or CLI seam); single-file no-public-surface fixes keep the coder's inline check. A coder-nested `/cook` that cleared the gate records `taste_test: deferred-to-orchestrator` in its slug — your signal to run the pass.

**How.** Dispatch the read-only `reviewer` phase-agent over the coder's diff, **named with no call-site model** — its def pins `model: opus` (Codex `gpt-5`), so on those harnesses it runs at ≥ the writer's tier, never the coder's `sonnet`. (On opencode both defs pin `inherit`, so the pass runs at the orchestrator's tier — your level, not below it.) Not `model: inherit` at the call site (tracks your tier, not the reviewer's pin); not a hardcoded call-site model. Scope the dispatch *prompt* to the lenses below — the same agent `/age` drives, but this is a fast pre-handoff gate, not a full ten-dimension review. Pass `{spec/contract, diff, cut-test list, locked decisions}`; it returns `pass | revise` per lens (`halt` for Locked-decision):

- **Drift / readability / scope / simplify** — the standard cook lenses.
- **Production path** — every spec acceptance criterion has a *production* path that exercises it, not only tests that manufacture the state.
- **Wired callers** — each new public function has a non-test caller, or the diff carries an explicit "wired in phase X" note.
- **Locked decision** — the diff implements any locked/user-approved decision the prompt carried, else the reviewer returns `halt`.

Pipe each `revise` into a bounded corrective `coder` pass (spec + digest + taste evidence), two-round cap; a Locked-decision `halt` stops for a human decision, not a corrective pass. Accept the coder's handoff only on a clean pass.
