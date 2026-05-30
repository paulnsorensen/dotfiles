---
name: grok-codebase
description: >
  Build lasting understanding of an unfamiliar codebase via a four-pillar model
  (Building Blocks, Entry Points, Infrastructure, Egress) plus an adaptive
  Socratic quiz, orchestrating code-review-graph, Serena, tilth, and Context7.
  Use when the user says "help me understand this codebase", "grok this repo",
  "onboard me", "learn this project", "memorize this codebase", "study this
  code", "walk me through this code", or "quiz me on this repo". Do NOT use for
  single-file scripts, repos under 500 LOC, or editing tasks — understanding only.
argument-hint: <optional focus area, e.g. "auth flow" or "payments">
allowed-tools: Read, Write, TodoWrite, Skill, Bash(git:*), Bash(ls:*), Bash(cat:*), Bash(jq:*), Bash(yq:*), Bash(tokei:*), Bash(code-review-graph:*), mcp__serena__find_symbol, mcp__serena__find_referencing_symbols, mcp__serena__find_implementations, mcp__serena__find_declaration, mcp__serena__get_symbols_overview, mcp__serena__search_for_pattern, mcp__tilth__*, mcp__code-review-graph__*, mcp__context7__*
metadata:
  version: 1.0.0
  author: paulnsorensen
  last-updated: 2026-05-21
---

# /grok-codebase — Lock a repo into long-term understanding

You are about to help the user **grok** this codebase: not just read it, but
internalize it well enough to explain it on a whiteboard in five minutes and
answer "what breaks if I change X" without re-checking. You will work the
**four-pillar model** in order, persist artifacts under `.cheese/grok/<repo>/`,
and finish with an adaptive Socratic quiz.

**Focus area** (optional): $ARGUMENTS

## Hard rules (read first, no skipping)

1. **Structural tools before raw reads.** Call
   `mcp__code-review-graph__get_minimal_context_tool` FIRST on any new repo
   (~100 tokens). Then prefer `mcp__serena__get_symbols_overview`,
   `mcp__tilth__tilth_read` (outline mode), and `mcp__tilth__tilth_grok` over
   reading whole files. Whole-file `Read` is a last resort for non-code files
   (README, manifests, CI YAML, env templates) — the user's CLAUDE.md
   explicitly routes code search through tilth.
2. **One pillar at a time.** Don't skip ahead. Complete pillar 1 before
   starting pillar 2 — out-of-order grokking produces shallow understanding
   that fails on the quiz.
3. **Persist findings to disk, not memory.** This setup excludes serena's
   memory tools. Instead, after each pillar `Write` an artifact to
   `.cheese/grok/<repo-name>/<pillar-slug>.md`. Pillar slugs:
   `01-building-blocks`, `02-entry-points`, `03-infrastructure`, `04-egress`,
   `05-trace.md`, `summary.md`, `quiz-results.md`. The user can review
   artifacts later and re-runs read them first.
4. **Stack-agnostic, TS/JS-leaning examples.** Look up language-specific
   conventions in `GUIDE.md §6` (Stack-specific cheatsheets) when you hit a
   stack you don't recognize.
5. **Token budget.** Aim for ≤30k tokens of tool output across phases 0–5
   combined. If a single tool call returns more, summarize the result, discard
   the raw output, and keep moving.
6. **Adaptive quiz comes last.** Only start Phase 6 after all four pillars are
   mapped AND the user confirms "yes, quiz me" (or equivalent). Drive it from
   `QUIZ.md` — don't improvise the question selection.
7. **Track progress.** Use `TodoWrite` to maintain a checklist of the seven
   phases so the user can see where you are.

## Phase 0 — Reconnaissance (≤5 tool calls, ≤2 minutes)

Goal: enough context to confirm scope with the user.

Run in parallel where possible:

1. `git log --oneline -10 && git status` — recent activity, branch state.
2. `mcp__code-review-graph__get_minimal_context_tool(task="initial onboarding")`
   if the graph exists. If not, ask the user to run `code-review-graph build`
   then re-invoke. Don't proceed without the graph for repos >500 files —
   you'll burn tokens.
3. `Read` of `README.md`, the primary manifest (`package.json` /
   `pyproject.toml` / `go.mod` / `Cargo.toml` / `pom.xml`), and any
   `CLAUDE.md` / `AGENTS.md` at the repo root.
4. `tokei` for a rough LOC-per-language breakdown.

Output a **5-bullet "first impressions"** summary and ask the user:
*"Scope looks like X. Proceed with full four-pillar grok, or focus on
<area>?"* Wait for confirmation. If they already passed a focus area in
`$ARGUMENTS`, confirm that area covers it.

## Phase 1 — BUILDING BLOCKS

**Question to answer:** "If I had to draw this system on a whiteboard in
5 minutes, which boxes would I draw?"

Workflow:

1. `mcp__code-review-graph__get_architecture_overview_tool` and
   `mcp__code-review-graph__list_communities_tool` — Leiden-clustered modules
   are the closest thing to an automated C4 Component diagram.
2. For each top-level source directory:
   `mcp__serena__get_symbols_overview(relative_path=<dir>)`.
3. **TS/JS specifically:** read `package.json` `workspaces`, `exports`, and
   `tsconfig.json` `paths`/`baseUrl`. These define the *intended* module
   boundaries — compare them against the graph's *de facto* communities. When
   they diverge, that's a smell worth surfacing.
4. Identify 5–10 core domain symbols (`User`, `Order`, `Tenant`, …) and call
   `mcp__tilth__tilth_grok(target=<symbol>)` on each — that returns
   def + body + sig + callees + callers + siblings + tests in one shot.
5. Spot god-nodes: `mcp__code-review-graph__find_large_functions_tool` and
   `mcp__code-review-graph__get_hub_nodes_tool`. Flag any function >150 LOC
   or any module with >25 inbound edges.

`Write` `.cheese/grok/<repo>/01-building-blocks.md` with a table:
`Block | Path | Public API | Key types | God-nodes?`. See `GUIDE.md §2` for
the full pillar-1 checklist if you get stuck.

## Phase 2 — ENTRY POINTS

**Question to answer:** "Every way control flow can begin." If no entry point
leads to a piece of code, that code is dead.

Workflow (TS/JS-first; other stacks in `GUIDE.md §6`):

1. `package.json` → `main`, `module`, `bin`, `scripts.start`, `scripts.dev`.
   Each is an entry point.
2. HTTP routes — match the framework, then probe:
   - **Next.js:** `mcp__tilth__tilth_files(patterns=["**/app/**/route.ts", "**/app/**/page.tsx", "**/pages/api/**"])`.
   - **Express:** `mcp__tilth__tilth_search(query="app.get,app.post,router.get,router.post", kind="content")`.
   - **NestJS:** `mcp__tilth__tilth_search(query="@Controller,@Get,@Post,@Put,@Delete,@Patch", kind="content")`.
   - **Fastify:** `mcp__tilth__tilth_search(query="fastify.get,fastify.post,fastify.register", kind="content")`.
3. **CLI:** `process.argv` usages, `commander` / `yargs` / `oclif`
   registrations.
4. **Workers / cron:** `node-cron`, BullMQ `Worker`, AWS Lambda handlers
   (`exports.handler`), Inngest functions, Cloudflare Workers
   `addEventListener('fetch'`.
5. **Real-time:** `socket.io`, tRPC routers, gRPC services.
6. For the top 3 entry points by importance, call
   `mcp__code-review-graph__get_affected_flows_tool(target=<entry>)` to trace
   the downstream flow.

`Write` `.cheese/grok/<repo>/02-entry-points.md` with one line per entry
point: `<method> <path> → <handler file:line>`. For each, also note **SLA?**
and **who calls this?** — if either can't be answered, that's a doc gap.

## Phase 3 — INFRASTRUCTURE

**Questions to answer:** "What does it take to run this locally?" and "What
does it take to ship a change to production?" If you can answer both in
<2 minutes after the grok, the grok was good.

Workflow:

1. **Runtime:** `engines.node`, `.nvmrc`, `Dockerfile` `FROM`.
2. **Build:** search for `tsc`, `swc`, `esbuild`, `vite`, `webpack`,
   `turbopack`, `rollup`, `nx`, `turbo`. `package.json scripts.build` is the
   source of truth.
3. **Test:** `vitest.config.*`, `jest.config.*`, `playwright.config.*`,
   `.spec.ts` / `.test.ts` count.
4. **Lint / format:** `.eslintrc*`, `eslint.config.*`, `biome.json`,
   `.prettierrc*`.
5. **CI:** `Read` `.github/workflows/*.yml`, `.gitlab-ci.yml`,
   `.circleci/config.yml`.
6. **Deploy:** `Dockerfile`, `docker-compose.yml`, `k8s/`, `helm/`,
   `terraform/`, `vercel.json`, `netlify.toml`, `serverless.yml`,
   `sst.config.*`.
7. **Config & env:** `mcp__tilth__tilth_files(patterns=["**/.env*"])` and
   `mcp__tilth__tilth_search(query="process.env", kind="content")`. List
   every env var referenced — missing-on-boot validation is a common bug.
8. **Dependency hygiene:** top 10 dependencies by inbound import count via
   `mcp__code-review-graph__query_graph_tool(action="importers_of",
   target=<pkg>)`. For the top 3, use `mcp__context7__query-docs` for
   current docs (don't trust your training data for framework specifics).

`Write` `.cheese/grok/<repo>/03-infrastructure.md`. Also explicitly scan for
arc42 §8 crosscutting concerns: logging, error handling, auth, i18n, feature
flags, observability. Missing these in the grok = surprised later.

## Phase 4 — EGRESS

**Question to answer:** "Where does this system reach out or mutate the
world?" Egress is the Feathers seam surface — and most production incidents
originate here.

Workflow:

1. **Outbound HTTP:** `mcp__tilth__tilth_search(query="fetch,axios,got,ky,node-fetch", kind="content")`.
2. **DB writes:** Prisma `.create/.update/.delete/.upsert`, Drizzle
   `db.insert/update/delete`, TypeORM `repository.save/remove`, Knex
   `.insert/.update/.del`, raw `INSERT/UPDATE/DELETE`.
3. **Queues & pub/sub:** `bullmq`, `kafkajs`, `amqplib`,
   `@aws-sdk/client-sqs`, `nats`.
4. **File I/O:** `fs.writeFile`, `fs.appendFile`, `@aws-sdk/client-s3`
   `PutObject`, `@google-cloud/storage`.
5. **Third-party SDKs:** scan `package.json dependencies` for `stripe`,
   `@sendgrid/mail`, `resend`, `@sentry/*`, `posthog-js`, `mixpanel`,
   `twilio`, `auth0`, `@clerk/*`.
6. **Outbound webhooks:** search `webhook` / `signature` patterns.
7. **For each egress, name the seam** (à la Feathers): "where could a test
   substitute a fake?" — usually the import statement or a DI registration.

`Write` `.cheese/grok/<repo>/04-egress.md` as a table:
`Egress | Caller | Mechanism (lib) | Seam (where to fake) | Has characterization test?`.
Many egresses + no seams = refactoring liability; flag it.

## Phase 5 — Trace one full request

Pick the entry point with the largest `get_affected_flows_tool` output (or
whatever the user's focus area points at). Walk it end-to-end:

**entry → middleware → handler → service → repository → DB → response**

Name every file:line. Use `mcp__tilth__tilth_grok` per hop. This single
exercise tests all four pillars at once and is the strongest grok artifact.

`Write` `.cheese/grok/<repo>/05-trace.md` with the path and a one-line
gloss per hop.

Then `Write` `.cheese/grok/<repo>/summary.md` containing:

1. One-paragraph elevator pitch of the codebase.
2. The four-pillar table.
3. The end-to-end trace.
4. Top 3 risks / god-nodes.
5. Suggested first PR for a new contributor.

## Phase 6 — Adaptive Socratic quiz

**Only start if the user confirms.** Ask: *"Pillars mapped. Want me to quiz
you to lock it in?"*

If yes, load `QUIZ.md` and follow its protocol. Maintain an internal
`confidence[pillar]` map and update it after every answer per the rules in
`QUIZ.md §Confidence rules`. Escalate Bloom level on strength, descend on
hedging or partial recall. Mark a pillar "locked" after three consecutive
strong answers. End when all four pillars are locked OR the user says "stop"
OR ~30 minutes have elapsed (then suggest a break).

On end, `Write` `.cheese/grok/<repo>/quiz-results.md` — strong areas, weak
areas, suggested next-session focus.

## Output format per pillar

After each pillar phase, post a Markdown section in chat with:

- 🔍 **What I found** — 3–7 bullets, named, file:line where possible.
- ⚠️ **Risks / unknowns** — anything that surprised you, anything missing.
- 📌 **Artifact written**: `.cheese/grok/<repo>/<file>.md`

For the quiz, post each question as a numbered prompt; on each answer, post
the detected confidence change and the next question — don't hide the
adaptive state from the user.

## Re-running on the same repo

The skill is designed to re-run weekly. On re-invocation:

1. Check for existing `.cheese/grok/<repo>/` artifacts; read them first.
2. Use `mcp__code-review-graph__detect_changes_tool` and
   `mcp__tilth__tilth_diff` to find what's changed since the last grok.
3. Focus the new run on diffs and partial-replay the quiz for any pillar
   that changed materially.

If the user passed a focus area in `$ARGUMENTS` (e.g.
`/grok-codebase egress`), skip pillars 1–3, read their prior summaries, and
jump straight to that pillar + its quiz section.

---

For methodology depth (why four pillars, why this order, stack-specific
cheatsheets, glossary), see `GUIDE.md`. For the question banks and adaptive
protocol, see `QUIZ.md`.
