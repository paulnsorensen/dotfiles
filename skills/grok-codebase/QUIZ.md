# Adaptive Socratic quiz — protocol and question banks

Loaded by `SKILL.md` Phase 6. Contains the protocol, the confidence-update
rules, and the question banks per pillar × Bloom level.

## Protocol (read once at quiz start)

1. **State.** Maintain `confidence[pillar] ∈ {weak, mid, strong}` for each
   of the four pillars. Initialize all to `mid`. Also maintain
   `bloom[pillar] ∈ {remember, understand, apply, analyze, evaluate, create}`.
   Initialize all to `understand`.
2. **Turn loop.** Pick the pillar with the lowest confidence (ties broken
   by ordering 1→2→3→4). Pull one question from the bank for that pillar
   at the current `bloom` level. Ask it. Wait for the answer.
3. **Confidence update** (apply in order, take first match):
   - **Wrong / "I don't know"** → `confidence -= 2` (clamp to `weak`).
     Re-teach by calling the relevant code-intelligence MCP tool (typically
     `tilth_grok` or an available symbol/reference lookup), then ask a
     `remember`-level question next turn.
   - **Hedging language detected** (regex:
     `\b(I think|maybe|probably|kind of|sort of|I'm not sure|I guess|might be|possibly)\b`)
     → `confidence -= 1`.
   - **Partial recall** (concept right, specifics wrong / missing) → no
     change.
   - **Specific, file:line-grounded, named answer** → `confidence += 1` and
     `bloom += 1`.
   - **Three consecutive strong answers in a pillar** → mark pillar
     **locked**, skip it in future turns.
4. **Escalation ladder** (when an answer is weak or hedged, the next
   question for that pillar should go one rung deeper):
   1. **Clarify** — "When you said X, did you mean … or …?"
   2. **Why-exists** — "Why does <component> exist? What problem does it
      solve?"
   3. **What-breaks** — "If you delete <symbol>, what tests fail? What
      features break?"
   4. **Trace** — "Walk me from <entry-point> to <DB-write>, naming every
      file."
   5. **Counterfactual** — "How would this system look if <constraint> were
      different?"
5. **Ease-off ladder** (when answers are strong, skip ahead to
   Evaluate/Create):
   - **Evaluate** — "What's the riskiest single change you could make
     here?"
   - **Create** — "Where would you add a new <X> (payment provider /
     auth method / route)? What files would you touch?"
6. **End conditions:** all four pillars `locked`, OR user says
   "stop" / "enough" / "done", OR ~30 minutes elapsed (suggest a break).
   On end, `Write` `.cheese/grok/<repo>/quiz-results.md` — strong areas,
   weak areas, suggested next-session focus.

## Question banks

Each pillar has a bank of question stems organized by Bloom level. Substitute
`<placeholders>` with concrete findings from the grok artifacts (read
`.cheese/grok/<repo>/` first). Always prefer questions that reference
specific names / paths the user actually saw during the grok — generic
questions feel like a trivia quiz and don't lock the codebase in.

### Pillar 1 — Building Blocks

**Remember**

- Name the top-level packages / workspaces in this repo.
- What's the entry file for `<workspace-name>`?
- List three core domain types.

**Understand**

- In your own words, what does `<package-name>` do?
- Why is `<type>` defined as `<class | interface | type alias>` vs. the
  other options?
- What's the relationship between `<TypeA>` and `<TypeB>`?

**Apply**

- If you needed to add a new field to `<core-type>`, which files would you
  touch?
- Where would a new `<domain-concept>` live in this codebase?

**Analyze**

- Which module has the most inbound dependencies, and why? Is that
  healthy?
- The graph shows `<module-A>` and `<module-B>` in the same community —
  what's their shared concern?
- Identify a god-node. What's its blast radius?

**Evaluate**

- If you had to split this monorepo into two repos, where would you draw
  the line?
- Which abstraction here is over-engineered? Which is under-engineered?

**Create**

- Sketch a new module boundary that would reduce the blast radius of
  `<god-node>`.

### Pillar 2 — Entry Points

**Remember**

- How many HTTP routes does this app expose? Name three.
- What does `npm run dev` actually do?
- Is there a CLI binary? What does it do?

**Understand**

- Why are there separate `app/` and `pages/` directories? (Next.js) or
- What's the difference between a `@Controller` and a `@Service` here?
  (NestJS) or
- What does the `middleware.ts` at the root do, and when does it run?

**Apply**

- Add a new GET `/health` endpoint. Which file and which pattern do you
  copy?
- The user reports `/api/users` is slow. Where do you put your first
  `console.time`?

**Analyze**

- Trace one request from URL to response, naming every file:line.
- Which entry point has the largest downstream blast radius? What does
  that mean for risk?

**Evaluate**

- Are there entry points that look reachable but are actually dead (no
  callers, no docs, no tests)?
- Which entry point is missing input validation? How can you tell?

**Create**

- Design a new WebSocket endpoint for `<feature>`. What changes in
  routing, in services, in tests?

### Pillar 3 — Infrastructure

**Remember**

- Node version? Package manager? Build tool?
- Where are tests configured?
- What CI provider runs on push?

**Understand**

- Why does the build use `<tsc | swc | esbuild>`? What trade-off does
  that reflect?
- What does the Dockerfile's multi-stage build accomplish?

**Apply**

- Add a new env var `FEATURE_X_ENABLED`. Where do you declare it? Where
  do you read it? Where do you validate it?
- A new contributor can't run tests locally. What three things do you
  ask them to check?

**Analyze**

- Which dependency is the biggest risk if it had a critical CVE
  tomorrow, and why?
- The CI takes 12 minutes. Looking at the workflow, where's the
  bottleneck?

**Evaluate**

- Is the config validation strategy sound? (zod schema at boot?
  scattered `process.env.X`? what happens on missing vars?)
- Is there a circular dependency between build steps?

**Create**

- Add a `staging` deployment target. Which files change?

### Pillar 4 — Egress

**Remember**

- List every third-party SDK in `dependencies`.
- Which database client is used, and where is the connection string read
  from?
- Name three outbound HTTP calls.

**Understand**

- Why is `<egress-call>` retried with `<backoff-strategy>`? What failure
  mode is that defending against?
- The Stripe (or analogous) client is instantiated where? Singleton,
  per-request, or DI?

**Apply**

- Add a new outbound webhook to `<service>`. Where does it go? How do
  you sign it?
- The DB write in `<file>` needs to become idempotent. How do you change
  it?

**Analyze**

- For each egress, identify the seam: where would a test substitute a
  fake?
- Which egress is most likely to cause a production incident, and why?
- Are any egresses on the synchronous request path that should be on a
  queue?

**Evaluate**

- Audit: do all DB writes happen inside transactions? Where are the
  exceptions?
- Audit: which egress lacks a circuit breaker or timeout?

**Create**

- Replace `<provider-A>` with `<provider-B>` (e.g., Stripe → Adyen).
  List every file you'd touch and every seam you'd use.

## Sample turn (illustrative)

> **Claude:** Pillar 2 — Entry Points. (Bloom: understand.) **Q:** Why are
> there separate `app/` and `pages/` directories here?
>
> **User:** I think it's because they're migrating to the App Router but
> haven't moved everything yet. Maybe.
>
> **Claude:** Detected hedging ("I think", "maybe"). Confidence: `mid` →
> `weak` for Pillar 2. Re-teaching:
> [calls `mcp__tilth__tilth_grok(target="app/layout.tsx")` and
> `mcp__tilth__tilth_grok(target="pages/_app.tsx")`, shows excerpts].
> Now: **Q (clarify rung):** looking at `app/(marketing)/page.tsx` and
> `pages/checkout.tsx` — which features are still in `pages/`, and what's
> blocking their migration?

## Reset / partial-replay

If the user wants to re-quiz only on a weak pillar later, run the skill with
the focus flag (`/grok-codebase egress`) — the skill reads prior artifacts,
skips phases 1–3, and jumps straight to the quiz for that pillar.
