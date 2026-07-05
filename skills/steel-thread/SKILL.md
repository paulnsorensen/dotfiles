---
name: steel-thread
model: opus
effort: high
allowed-tools: Read, Bash(git log:*), Bash(git diff:*), Bash(git status:*), Bash(ls:*), Bash(rg:*), Agent, Skill, mcp__tilth__tilth_search, mcp__tilth__tilth_read, mcp__tilth__tilth_deps
description: >
  Map a concept end-to-end through a layered codebase — find the entry point,
  follow callers/callees layer by layer, and cross-check the impact radius.
  Use when the user says "trace this through", "map the X flow", "blast radius
  for Y", "what touches Z", "find the entry point for", "what's affected by
  this change", or invokes /steel-thread. Do NOT use for single-symbol lookups
  (Serena), filesystem search (/scout), or dead-code detection (/ghostbuster).
license: MIT
---

# /steel-thread

Trace a concept from its entry point through every layer of the architecture:
entry → workflow → domain → infrastructure. A **steel thread** is one
end-to-end execution flow. Find where the concept enters, follow the call chain
outward and inward, and cross-check what a change would ripple into.

**Target**: $ARGUMENTS — a concept ("ai extractors"), a model ("Invoice"), a
feature ("draft email preview"), a change ("the PR I just opened"), or a
question ("what's the blast radius if I change this function").

## Tools

Use whatever LSP- and MCP-backed code-intelligence tools your harness exposes,
picking the best available for each step — no specific tool is mandatory:

- **Symbol / reference lookup** — resolve names, find callers and callees,
  walk the call hierarchy. LSP call hierarchy where available; otherwise an
  AST-aware search (`tilth_search` with `kind="symbol"|"callers"`).
- **Semantic search** — reach a concept by meaning, not literal text. Use a
  semantic MCP search if one is present; otherwise `tilth_search(kind="any")`
  over the concept's vocabulary.
- **Impact / blast radius** — the dependency closure of a file or symbol.
  `tilth_deps`, an LSP reference set, or an impact-radius MCP query.
- **Reading** — pull files and slices with outlining via `tilth_read`.

If a precomputed flow/impact primitive is available (some code-graph MCPs
expose one), prefer it — it already assembles the entry→leaf chains this skill
reconstructs by hand.

## Hard rules

1. **Work from current code.** Code-intelligence results go stale the moment a
   file changes. If the user has uncommitted edits — often exactly what the
   question is about — resolve against the working tree, and re-resolve after
   any edit mid-session.
2. **Query along two axes** when searching by meaning. Results cluster by both
   behaviour and surface vocabulary. Run at least one query for each:
   - **Behaviour:** what the code *does* — domain verbs, model names, business
     concepts.
   - **Surface:** how the code is *reached* — routes, contracts, endpoints,
     adapters, handlers, repositories.
   Disjoint result sets reveal new layers, parallel rewrites, or contract
   surfaces the user just added.
3. **Confirm the entry point with a relationship query.** A semantic or
   name hit ranks by similarity, not by being the root of a call tree. Before
   calling something the entry point, verify with a callers/importers lookup
   that nothing above it calls in.
4. **Test names beat function names as anchors.** When triangulating, weight
   test-name hits — they describe the contract crisply.
5. **State coverage explicitly.** End every steel-thread map with a one-line
   caveat naming the queries you ran and what would not have been surfaced.

## Flow

### Phase 1 — Locate the concept

Find where the concept lives. Search by meaning along both axes (rule 2). For
a named symbol or model, resolve it directly. For "the PR I just opened" or
"what I just added", start from `git diff`/`git log` to bound the changed files,
then resolve the symbols in them.

### Phase 2 — Find the entry point

From the best-anchored hit, walk *up* the call chain (callers / importers)
until nothing internal calls in — that's the entry point (route handler, CLI
command, job, event consumer). Confirm with a relationship query (rule 3).
Weight test names as anchors (rule 4).

### Phase 3 — Follow the thread

From the entry point, follow callees *down* through each layer — workflow →
domain → infrastructure — naming the file:line and key symbol at each hop. Mark
legacy vs new surfaces explicitly when both exist. Note side threads
(validators, audit logs, feature flags, grounding checks) branching off the
main path.

### Phase 4 — Impact estimation (blast-radius mode)

When the user asks "what breaks if I change X", compute the dependency closure
of X's file/symbol (`tilth_deps` or an impact-radius query), then find which
threads pass through it. Keep the depth shallow first; widen only if the first
hop is thin. Cross-reference `git log` for *who* and *when* — code intelligence
is structural; git is authoritative for history.

### Phase 5 — Render the map

Output a top-down ASCII diagram from entry point → workflow → domain →
infrastructure. For each layer:

- Name the file(s) and the key symbol(s).
- Mark legacy vs new surfaces explicitly when both exist.
- Note any side threads (alternative paths, validators, grounding checks).
- Close with the coverage caveat: "Queries run: A, B, C. Threads not matching
  those vocabularies won't appear here."

## Anti-patterns

- **Trusting a semantic top-hit as the entry point.** Always confirm via a
  callers/importers query (rule 3).
- **Single-axis semantic query.** If every top hit lives in one directory, you
  over-fit the embedding cluster. Broaden vocabulary or switch axes.
- **Answering about stale code.** If the user said "I just added X" or "the PR
  I just opened" and you searched an index that predates the work, you will
  confidently miss it. Bound the changed set from `git diff` first.
- **Reporting completeness when only one axis was queried.** Be explicit about
  what your queries could not have surfaced.
- **Skipping the impact closure in blast-radius mode.** "What touches this" is
  a dependency question — follow the closure, don't eyeball the call site.

## See also

- `/xray` — interactive design verification via dependency-graph traversal. Its
  **Steel Threads** section runs this same trace inside an xray session, writing
  findings into the session graph. Use `/xray` for *did this implementation
  satisfy the spec*; `/steel-thread` for *where does this concept live and what
  touches it*.
- Serena MCP (`mcp__serena__find_symbol`, `find_referencing_symbols`) —
  single-symbol code intelligence. Faster for "what's the signature of Y" or
  "who calls Z" when you already have the exact symbol.
- `/ghostbuster` — dead code / stale spec detection. Disjoint concern.
- `/grok-codebase` — its Phase 5 traces one full request end-to-end as a
  standalone onboarding artifact.
