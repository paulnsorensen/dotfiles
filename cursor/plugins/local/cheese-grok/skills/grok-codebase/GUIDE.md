# Grokking a codebase — Methodology guide

Long-form human-readable companion to `SKILL.md`. Read this once, then let
the skill drive on each new repo.

## 1. Why four pillars, and why this order?

The order — **Building Blocks → Entry Points → Infrastructure → Egress** — is
a synthesis of three established methodologies:

- **Spinellis, *Code Reading* (2003):** "Start with the system overview and
  architecture. Examine entry points and main control flow. Focus on data
  structures before algorithms." → Pillars 1 and 2.
- **Brown's C4 model:** Context → Container → Component → Code (zoom in from
  outside-in). Pillar 1 maps to Component, pillar 3 to Container, pillar 4
  partly to Context.
- **arc42 template:** §5 Building Block View, §6 Runtime View, §7 Deployment,
  §8 Crosscutting Concepts. The four pillars cover §5, §6 (via the request
  trace in Phase 5), §7, and a cross-cut of §8.

**Why Egress is its own pillar** (vs. folding it into Building Blocks): most
production incidents originate at egress — a third-party API rate-limit, a
DB write under load, a webhook that silently drops. Senior engineers onboard
by mapping the outbound surface first because that's the attack surface for
change. Treating egress as first-class forces the seam discovery that makes
the system testable later.

## 2. Pillar 1 — Building Blocks (deep dive)

A "building block" is anything reusable: a module, a class, a domain type, a
service. The question to answer is: **"If I had to explain this system on a
whiteboard in 5 minutes, which boxes would I draw?"**

For TS/JS:

- Start at `package.json` `workspaces` (monorepo roots).
- Then `exports` field (the official multi-entry standard) — this is the
  *intended* building block set. If `exports` is missing, fall back to
  `main` / `module` and the de facto top-level `index.ts`.
- `tsconfig.json` `paths` / `baseUrl` show alias-based module boundaries
  (e.g. `@/lib/*`).
- Run code-review-graph's `list_communities_tool` — the Leiden-clustered
  modules are the **de facto** building blocks (vs. the **intended** ones
  from `exports`). When they diverge, that's a smell.
- For each block: `get_symbols_overview` + `tilth_grok` on the 3 most
  central symbols.

For other stacks:

- **Python:** `pyproject.toml` `[project]` + `__init__.py` packages.
- **Go:** `go.mod` modules + `internal/`.
- **Rust:** `Cargo.toml` `[workspace]` + `lib.rs` `pub mod`.
- **Java:** `pom.xml` modules + package declarations.

The artifact: a table with columns
`Block | Path | Public API | Key types | God-nodes?`.

## 3. Pillar 2 — Entry Points (deep dive)

Every way control flow can begin. **If there's no entry point that leads to
a piece of code, that code is dead.** This is also Feathers's "change point"
if you're modifying behavior.

Categories to enumerate:

- **HTTP:** framework-specific. See `SKILL.md` Phase 2 for search patterns.
- **CLI:** `bin` in `package.json`; `process.argv` consumers.
- **Scheduled:** cron, BullMQ repeatable, Inngest scheduled functions.
- **Event-driven:** Lambda handlers, Cloudflare Workers, message-queue
  consumers, EventBridge rules, Kafka subscribers.
- **Real-time:** WebSocket handlers, tRPC subscriptions, gRPC streaming.
- **Library API** (if this is a library): every named export in the
  `exports` field.

For each entry, ask **"what's the SLA?"** and **"who calls this?"** (graph
dependents). If you can't answer the SLA, that's a documentation gap worth
flagging.

## 4. Pillar 3 — Infrastructure (deep dive)

Two questions: **"What does it take to run this locally?"** and **"What does
it take to ship a change to production?"** If you can answer both in <2
minutes after a grok, the grok was good.

The arc42 §7 Deployment view and §8 Crosscutting Concepts both live here.
Crosscutting specifically includes: logging, error handling, auth, i18n,
feature flags, observability. Scan for these patterns explicitly — they tend
to be implemented once and used everywhere, so missing them in the grok
means surprises later.

## 5. Pillar 4 — Egress (deep dive)

The Feathers lens applies: **every egress is a seam.** List them in a table:

| Egress | Caller | Mechanism (lib) | Seam (where to fake it) | Has characterization test? |
|---|---|---|---|---|

A codebase with many egresses and no seams is a refactoring liability —
flag it.

## 6. Stack-specific cheatsheets

### TypeScript / JavaScript (primary)

- **Manifests:** `package.json` (`main`, `module`, `exports`, `bin`,
  `scripts`, `workspaces`, `engines`, `type: "module"`).
- **TS config:** `tsconfig.json` `compilerOptions.paths`, `baseUrl`,
  `module`, `moduleResolution`, `target`, `lib`. `tsconfig.base.json` in
  monorepos.
- **Frameworks** (use Context7 for version-specific docs):
  - **Next.js:** `app/` (App Router) vs `pages/` (Pages Router);
    `middleware.ts`; `route.ts` and route handlers; `layout.tsx`;
    `loading.tsx`; `error.tsx`.
  - **Express / Fastify / Koa:** `app.use`, `app.METHOD`, middleware chains.
  - **NestJS:** `@Module`, `@Controller`, `@Injectable`, `@Get`/`@Post`;
    lifecycle hooks.
  - **Remix / React Router:** `loader`, `action`, `route` configs.
  - **tRPC:** `router`, `procedure`, `input`, `mutation`/`query`.
- **Build tools:** Vite, Webpack, Turbopack, esbuild, swc, tsc, Rollup,
  Parcel.
- **Test:** Vitest, Jest, Playwright, Cypress, Mocha, Tap.
- **Common egress libs:** `axios`, `node-fetch`, `got`, `ky`,
  `@prisma/client`, `drizzle-orm`, `bullmq`, `kafkajs`, `@aws-sdk/*`,
  `stripe`, `@sendgrid/mail`, `@sentry/*`, `@clerk/*`.

### Python

- **Manifests:** `pyproject.toml`, `setup.py`, `requirements*.txt`,
  `poetry.lock`, `uv.lock`.
- **Entry points:** `[project.scripts]`, `__main__.py`, FastAPI `@app.get`,
  Flask `@app.route`, Django `urls.py`, Celery tasks, Lambda `handler`.

### Go

- **Manifests:** `go.mod`, `go.sum`.
- **Entry points:** `main.go` per `cmd/<name>/`, `net/http` `Handler`, gin
  `r.GET`, echo `e.GET`, cobra commands.

### Rust

- **Manifests:** `Cargo.toml`, `Cargo.lock`.
- **Entry points:** `main.rs` per binary, `lib.rs` `pub fn`, axum
  `Router::route`, actix `web::resource`.

### Java / Kotlin

- **Manifests:** `pom.xml`, `build.gradle(.kts)`, `settings.gradle(.kts)`.
- **Entry points:** Spring `@RestController` / `@RequestMapping`, Spring
  Boot `@SpringBootApplication`, scheduled `@Scheduled`.

## 7. How to drive the skill

1. In Claude Code, open the repo root.
2. Say one of: "grok this codebase", "onboard me to this repo", "help me
   memorize this project", or use the slash form
   `/grok-codebase [optional focus area]`.
3. Confirm scope after Phase 0 reconnaissance.
4. Let the skill work through pillars 1–4, posting findings after each.
5. Confirm the Phase 5 trace target (which entry point to walk
   end-to-end).
6. Say "quiz me" to start Phase 6.
7. Re-run weekly on the same repo — the skill reads prior artifacts first
   and focuses on diffs via `detect_changes_tool` + `tilth_diff`.

## 8. When NOT to use this skill

- Single-file scripts or repos <500 LOC: just `Read` the files.
- Repos with no language-server support (exotic languages): the graph and
  Serena will be weak; lean harder on `tilth_read --section` and
  `tilth_list`.
- Generated code (e.g. an ORM client output dir): include it in the egress
  pillar by reference but don't grok internals.

## 9. Glossary

- **Seam:** a place where you can alter behavior without editing in that
  place (Feathers).
- **Blast radius:** the transitive set of callers / dependents / tests
  affected by a change.
- **God-node:** a function / module with disproportionately many inbound or
  outbound edges.
- **Characterization test:** a test that captures *current* behavior, used
  to refactor safely.
- **Bloom level:** Remember → Understand → Apply → Analyze → Evaluate →
  Create.
- **Community (graph):** a cluster of strongly-connected nodes detected by
  the Leiden algorithm. Often corresponds to a "real" module boundary.
