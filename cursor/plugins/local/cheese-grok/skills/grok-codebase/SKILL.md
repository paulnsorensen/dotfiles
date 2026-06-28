---
name: grok-codebase
description: Use when the user wants deep, multi-session internalization of an unfamiliar codebase — not just an orientation, but the goal of being able to explain it on a whiteboard and answer "what breaks if I change X" without re-checking. Triggers on "grok this repo", "onboard me", "memorize this project", "lock this codebase into memory", "quiz me on this repo", "help me understand this codebase deeply". Runs a four-pillar march (Building Blocks → Entry Points → Infrastructure → Egress) plus a trace-one-request exercise and an adaptive Socratic quiz; persists artifacts to .cheese/grok/<repo>/. Read-only stance — DO NOT propose edits unless explicitly asked. For a quick single-session orientation ("tour this repo", "trace how X works"), use `/tour` instead. Especially tuned for TS/JS monorepos and Next.js / Express / NestJS / Fastify apps; methodology is stack-agnostic. Do NOT use for single-file scripts, repos under 500 LOC, or editing tasks.
allowed-tools: read_file, codebase_search, find_symbol, mcp__serena__find_symbol, mcp__serena__find_referencing_symbols, mcp__serena__find_implementations, mcp__serena__find_declaration, mcp__serena__get_symbols_overview, mcp__serena__search_for_pattern, mcp__tilth__*, mcp__context7__*
metadata:
  version: 0.1.0
  author: paulnsorensen
  last-updated: 2026-05-22
---

# grok-codebase — Lock a repo into long-term understanding

You are about to help the user **grok** this codebase: not just read it, but
internalize it well enough to explain it on a whiteboard in five minutes and
answer "what breaks if I change X" without re-checking. You will work the
**four-pillar model** in order, persist artifacts under
`.cheese/grok/<repo>/`, and finish with an adaptive Socratic quiz.

## Hard rules (read first, no skipping)

1. **Structural tools before raw reads.** Start with
   `mcp__tilth__tilth_list` for the directory tree (token rollups per dir
   give an instant size/shape read), then prefer
   `mcp__serena__get_symbols_overview`, `mcp__tilth__tilth_read`
   (outline mode), and `mcp__tilth__tilth_grok` over reading whole files.
   Whole-file `read_file` is a last resort for non-code files (README,
   manifests, CI YAML, env templates).
2. **One pillar at a time.** Don't skip ahead. Complete pillar 1 before
   starting pillar 2 — out-of-order grokking produces shallow understanding
   that fails on the quiz.
3. **Persist findings to disk.** After each pillar write an artifact to
   `.cheese/grok/<repo-name>/<pillar-slug>.md`. Pillar slugs:
   `01-building-blocks`, `02-entry-points`, `03-infrastructure`,
   `04-egress`, `05-trace.md`, `summary.md`, `quiz-results.md`. The user can
   review artifacts later; re-runs read them first.
4. **Stack-agnostic, TS/JS-leaning examples.** Look up language-specific
   conventions in `GUIDE.md §6` when you hit a stack you don't recognize.
5. **Token budget.** Aim for ≤30k tokens of tool output across phases 0–5
   combined. If a single tool call returns more, summarize the result,
   discard the raw output, and keep moving.
6. **Reader-first stance.** Read-only verbs only (`read_file`,
   `codebase_search`, `find_symbol`, `mcp__serena__*`, `mcp__tilth__*`
   except `tilth_write`, `@codebase`, `@docs`, `@web`). Edits are forbidden
   until the user explicitly invites them.
7. **Adaptive quiz comes last.** Only start Phase 6 after all four pillars
   are mapped AND the user confirms "yes, quiz me" (or equivalent). Drive
   it from `QUIZ.md` — don't improvise the question selection.

## Phase 0 — Reconnaissance (≤5 tool calls, ≤2 minutes)

Goal: enough context to confirm scope with the user.

Run in parallel where possible:

1. `git log --oneline -10 && git status` — recent activity, branch state.
2. `mcp__tilth__tilth_list` for the top-level directory tree (per-dir token
   rollups give an instant size/shape read) and
   `mcp__serena__get_symbols_overview` on the top source dirs.
3. Read `README.md`, the primary manifest (`package.json` / `pyproject.toml` /
   `go.mod` / `Cargo.toml` / `pom.xml`), and any `AGENTS.md` / `CLAUDE.md` /
   `.cursor/rules/` at the repo root.
4. `tokei` for a rough LOC-per-language breakdown.

Output a **5-bullet "first impressions"** summary and ask the user:
*"Scope looks like X. Proceed with full four-pillar grok, or focus on
<area>?"* Wait for confirmation.

## Phase 1 — BUILDING BLOCKS

**Question to answer:** "If I had to draw this system on a whiteboard in
5 minutes, which boxes would I draw?"

Workflow:

1. `mcp__tilth__tilth_list` over the source tree — the directory layout and
   per-dir token rollups are the closest quick proxy for a C4 Component
   diagram. Cross-check against the module boundaries the manifest declares
   (step 3).
2. For each top-level source directory:
   `mcp__serena__get_symbols_overview(relative_path=<dir>)`.
3. **TS/JS specifically:** read `package.json` `workspaces`, `exports`, and
   `tsconfig.json` `paths`/`baseUrl`. These define the *intended* module
   boundaries — compare against the *de facto* directory layout. When
   they diverge, that's a smell worth surfacing.
4. Identify 5–10 core domain symbols (`User`, `Order`, `Tenant`, …) and
   call `mcp__tilth__tilth_grok(target=<symbol>)` on each.
5. Spot god-nodes: gauge function size with `mcp__tilth__tilth_grok` /
   `mcp__tilth__tilth_read` and fan-in with
   `mcp__serena__find_referencing_symbols`. Flag any function >150 LOC or any
   module with >25 inbound references.

Write `.cheese/grok/<repo>/01-building-blocks.md` with a table:
`Block | Path | Public API | Key types | God-nodes?`.

## Phase 2 — ENTRY POINTS

**Question to answer:** "Every way control flow can begin." If no entry
point leads to a piece of code, that code is dead.

Workflow (TS/JS-first; other stacks in `GUIDE.md §6`):

1. `package.json` → `main`, `module`, `bin`, `scripts.start`,
   `scripts.dev`. Each is an entry point.
2. HTTP routes — match the framework, then probe:
   - **Next.js:** `mcp__tilth__tilth_list(patterns=["**/app/**/route.ts", "**/app/**/page.tsx", "**/pages/api/**"])`.
   - **Express:** `mcp__tilth__tilth_search(query="app.get,app.post,router.get,router.post", kind="content")`.
   - **NestJS:** `mcp__tilth__tilth_search(query="@Controller,@Get,@Post,@Put,@Delete,@Patch", kind="content")`.
   - **Fastify:** `mcp__tilth__tilth_search(query="fastify.get,fastify.post,fastify.register", kind="content")`.
3. **CLI:** `process.argv` usages, `commander` / `yargs` / `oclif`
   registrations.
4. **Workers / cron:** `node-cron`, BullMQ `Worker`, AWS Lambda handlers
   (`exports.handler`), Inngest functions, Cloudflare Workers.
5. **Real-time:** `socket.io`, tRPC routers, gRPC services.
6. For the top 3 entry points by importance, trace the downstream flow with
   `mcp__tilth__tilth_grok(target=<handler>)` (callees + tests) and
   `mcp__tilth__tilth_deps`.

Write `.cheese/grok/<repo>/02-entry-points.md` with one line per entry
point: `<method> <path> → <handler file:line>`. For each, also note
**SLA?** and **who calls this?** — if either can't be answered, that's
a doc gap.

## Phase 3 — INFRASTRUCTURE

**Questions to answer:** "What does it take to run this locally?" and
"What does it take to ship a change to production?" If you can answer
both in <2 minutes after the grok, the grok was good.

Workflow:

1. **Runtime:** `engines.node`, `.nvmrc`, `Dockerfile` `FROM`.
2. **Build:** search for `tsc`, `swc`, `esbuild`, `vite`, `webpack`,
   `turbopack`, `rollup`, `nx`, `turbo`.
3. **Test:** `vitest.config.*`, `jest.config.*`, `playwright.config.*`,
   `.spec.ts` / `.test.ts` count.
4. **Lint / format:** `.eslintrc*`, `eslint.config.*`, `biome.json`,
   `.prettierrc*`.
5. **CI:** `.github/workflows/*.yml`, `.gitlab-ci.yml`,
   `.circleci/config.yml`.
6. **Deploy:** `Dockerfile`, `docker-compose.yml`, `k8s/`, `helm/`,
   `terraform/`, `vercel.json`, `netlify.toml`, `serverless.yml`,
   `sst.config.*`.
7. **Config & env:** `mcp__tilth__tilth_list(patterns=["**/.env*"])`
   and `mcp__tilth__tilth_search(query="process.env", kind="content")`.
   List every env var referenced.
8. **Dependency hygiene:** top 10 dependencies by inbound import count
   via `mcp__tilth__tilth_deps` (or `mcp__tilth__tilth_search` for import
   sites). For the top 3, use `mcp__context7__query-docs`.

Write `.cheese/grok/<repo>/03-infrastructure.md`. Also explicitly scan
for arc42 §8 crosscutting concerns: logging, error handling, auth,
i18n, feature flags, observability.

## Phase 4 — EGRESS

**Question to answer:** "Where does this system reach out or mutate the
world?" Egress is the Feathers seam surface — and most production
incidents originate here.

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
7. **For each egress, name the seam** (à la Feathers): "where could a
   test substitute a fake?" — usually the import statement or a DI
   registration.

Write `.cheese/grok/<repo>/04-egress.md` as a table:
`Egress | Caller | Mechanism (lib) | Seam (where to fake) | Has characterization test?`.

## Phase 5 — Trace one full request

Pick the entry point with the largest `get_affected_flows_tool` output
(or whatever the user's focus area points at). Walk it end-to-end:

**entry → middleware → handler → service → repository → DB → response**

Name every file:line. Use `mcp__tilth__tilth_grok` per hop. This single
exercise tests all four pillars at once and is the strongest grok
artifact.

Write `.cheese/grok/<repo>/05-trace.md` with the path and a one-line
gloss per hop. Then write `summary.md` containing:

1. One-paragraph elevator pitch of the codebase.
2. The four-pillar table.
3. The end-to-end trace.
4. Top 3 risks / god-nodes.
5. Suggested first PR for a new contributor.

## Phase 6 — Adaptive Socratic quiz

**Only start if the user confirms.** Ask: *"Pillars mapped. Want me to
quiz you to lock it in?"*

If yes, load `QUIZ.md` and follow its protocol. Maintain an internal
`confidence[pillar]` map and update it after every answer per the rules
in `QUIZ.md §Confidence rules`. Escalate Bloom level on strength,
descend on hedging or partial recall. Mark a pillar "locked" after
three consecutive strong answers. End when all four pillars are locked
OR the user says "stop" OR ~30 minutes have elapsed.

On end, write `.cheese/grok/<repo>/quiz-results.md` — strong areas,
weak areas, suggested next-session focus.

## Output format per pillar

After each pillar phase, post a Markdown section in chat with:

- 🔍 **What I found** — 3–7 bullets, named, file:line where possible.
- ⚠️ **Risks / unknowns** — anything that surprised you, anything missing.
- 📌 **Artifact written**: `.cheese/grok/<repo>/<file>.md`

For the quiz, post each question as a numbered prompt; on each answer,
post the detected confidence change and the next question — don't hide
the adaptive state from the user.

## Re-running on the same repo

The skill is designed to re-run weekly. On re-invocation:

1. Check for existing `.cheese/grok/<repo>/` artifacts; read them first.
2. Use `git diff` and `mcp__tilth__tilth_diff` to find what's changed since
   the last grok.
3. Focus the new run on diffs and partial-replay the quiz for any
   pillar that changed materially.

---

For methodology depth (why four pillars, why this order, stack-specific
cheatsheets, glossary), see `GUIDE.md`. For the question banks and
adaptive protocol, see `QUIZ.md`.
