export const meta = {
  name: 'triage-sweep',
  description: 'Gather open GitHub issues/PRs, ground each one against live code, adversarially verify close-worthy verdicts, map the still-open items into domains with typed links, and route into a ranked table with a close plan',
  whenToUse: 'A backlog of open issues/PRs on a repo that needs an evidence-grounded triage pass — report only, never mutates GitHub.',
  phases: [
    { title: 'Gather', detail: 'list open issues/PRs via gh in one cheap agent' },
    { title: 'Ground', detail: 'one grounding agent per item verifies claims against live code, cites file:line' },
    { title: 'Verify', detail: 'adversarial re-check, only for items whose verdict would close them' },
    { title: 'Map', detail: 'lens agents (code, tests, docs, refs) find what each still-open item touches and type the links between items' },
    { title: 'Route', detail: 'barrier synthesis agent produces a ranked routing table, a close plan, and a domain map' },
  ],
}

// Canonicalizes a shape used ad-hoc across 7 prior one-off workflows
// (triage-open-bugs, triage-open-issues, brie-ground-open-issues,
// hallouminate-open-items-triage, ticket-validity-sweep,
// issue-triage-factory-routing, pr-issue-release-triage). Those all
// hardcoded a literal ITEMS/ISSUES/PRS array baked in at write time; this
// version replaces that with a live Gather phase so the same script runs
// against whatever is open right now. Divergence note: most prior instances
// ran Verify unconditionally on every item (or skipped it entirely); this
// canonical version follows the digest's tighter rule — Verify only fires
// for verdicts that would close an item (CLOSE_VERDICTS), since those are
// the claims with the highest cost if wrong.
//
// The Map phase comes from a 68-issue sweep where a count of explicit
// cross-references called 21 items "entangled". Lens agents over code,
// tests, docs, and the tracker found one hard coupling. Links therefore
// carry a type, and a mention alone is "narrative".
//
// Invoked as `/triage-sweep [args]`; args is {repo?, scope?, limit?, map?}
// or a bare "owner/name" string (repo shorthand). `map: false` skips the
// Map phase. Read-only — Gather/Ground/Verify/Map only inspect GitHub and
// local code; Route only synthesizes a report with a close plan; nothing in
// this file ever calls `gh issue close`, `gh pr close`, edits a label, or
// posts a comment.

const GATHER_SCHEMA = {
  type: 'object',
  required: ['items'],
  properties: {
    items: {
      type: 'array',
      items: {
        type: 'object',
        required: ['number', 'kind', 'title'],
        properties: {
          number: { type: 'integer' },
          kind: { type: 'string', enum: ['issue', 'pr'] },
          title: { type: 'string' },
          url: { type: 'string' },
        },
      },
    },
  },
}

const CLOSE_VERDICTS = ['stale', 'superseded', 'duplicate', 'misfiled']
const VERDICTS = ['valid', 'partial', 'needs-info', ...CLOSE_VERDICTS]
const GROUND_SCHEMA = {
  type: 'object',
  required: ['number', 'kind', 'title', 'verdict', 'evidence', 'summary', 'recommendation'],
  properties: {
    number: { type: 'integer' },
    kind: { type: 'string', enum: ['issue', 'pr'] },
    title: { type: 'string' },
    verdict: { type: 'string', enum: VERDICTS },
    duplicate_of: { type: 'integer', description: 'required when verdict is duplicate' },
    evidence: {
      type: 'array',
      items: {
        type: 'object',
        required: ['claim', 'citation'],
        properties: {
          claim: { type: 'string' },
          citation: { type: 'string', description: 'file:line, commit hash, or PR number proving the claim' },
        },
      },
    },
    summary: { type: 'string' },
    recommendation: { type: 'string', description: 'one-liner: fix now / close / needs human decision' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['number', 'refuted', 'final_verdict', 'note'],
  properties: {
    number: { type: 'integer' },
    refuted: { type: 'boolean' },
    final_verdict: { type: 'string', enum: VERDICTS },
    counter_evidence: {
      type: 'array',
      items: {
        type: 'object',
        required: ['claim', 'citation'],
        properties: { claim: { type: 'string' }, citation: { type: 'string' } },
      },
    },
    note: { type: 'string' },
  },
}

const LINK_SCHEMA = {
  type: 'object',
  required: ['from', 'to', 'type', 'evidence'],
  properties: {
    from: { type: 'integer' },
    to: { type: 'integer' },
    type: { type: 'string', enum: ['hard-coupling', 'ordering', 'shared-seam', 'alternative', 'umbrella', 'overlay', 'narrative'] },
    evidence: { type: 'string', description: 'file:line, test, or acceptance criterion proving the link type' },
  },
}

const MAP_SCHEMA = {
  type: 'object',
  required: ['touches', 'links'],
  properties: {
    touches: {
      type: 'array',
      items: {
        type: 'object',
        required: ['number', 'areas'],
        properties: {
          number: { type: 'integer' },
          areas: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    links: { type: 'array', items: LINK_SCHEMA },
  },
}

const MAP_LENSES = [
  { key: 'code', brief: 'production code paths. Open the modules each item would change and name them.' },
  { key: 'tests', brief: 'tests and harnesses. Find the test files and shared fixtures each item would add or change.' },
  { key: 'docs', brief: 'wiki, ADRs, and design docs. Find recorded decisions and public contracts each item would alter.' },
  { key: 'refs', brief: 'the tracker. Read item bodies, comments, and open PRs for cross-references, shared acceptance criteria, and blockers.' },
]
const ROUTE_SCHEMA = {
  type: 'object',
  required: ['routed', 'summary'],
  properties: {
    routed: {
      type: 'array',
      items: {
        type: 'object',
        required: ['number', 'kind', 'title', 'route', 'rank', 'why'],
        properties: {
          number: { type: 'integer' },
          kind: { type: 'string', enum: ['issue', 'pr'] },
          title: { type: 'string' },
          route: { type: 'string', enum: ['fix-now', 'needs-design', 'deferred', 'rescope', 'close', 'needs-human'] },
          rank: { type: 'integer', description: '1 = highest priority within its route bucket' },
          why: { type: 'string' },
          close_reason: { type: 'string', enum: ['completed', 'not planned', 'duplicate'] },
          duplicate_of: { type: 'integer' },
          confidence: { type: 'string', enum: ['certain', 'likely'] },
          comment: { type: 'string', description: 'evidence comment to post when closing' },
        },
      },
    },
    domains: {
      type: 'array',
      items: {
        type: 'object',
        required: ['name', 'contained', 'cross_cutting', 'overlays', 'revalidate'],
        properties: {
          name: { type: 'string' },
          contained: { type: 'array', items: { type: 'integer' } },
          cross_cutting: { type: 'array', items: { type: 'integer' } },
          overlays: { type: 'array', items: { type: 'integer' } },
          revalidate: { type: 'array', items: { type: 'integer' } },
          note: { type: 'string' },
        },
      },
    },
    links: { type: 'array', items: LINK_SCHEMA },
    summary: { type: 'string' },
  },
}

// ── args ─────────────────────────────────────────────────────────────────

const UNSAFE_REPO_CHARS = /[\s;&|`$(){}<>"'\\]/
const MAX_LIMIT = 200

function coerceArgs(a) {
  if (a == null) return {}
  if (typeof a === 'string') {
    const s = a.trim()
    return s.includes('/') && !UNSAFE_REPO_CHARS.test(s) ? { repo: s } : {}
  }
  if (typeof a === 'object') return a
  return {}
}

const opts = coerceArgs(args)
const repo = typeof opts.repo === 'string' && opts.repo.trim() && !UNSAFE_REPO_CHARS.test(opts.repo.trim())
  ? opts.repo.trim()
  : null
const scope = ['issues', 'prs', 'both'].includes(opts.scope) ? opts.scope : 'both'
const mapDomains = opts.map !== false
let limit = Number.isInteger(opts.limit) && opts.limit > 0 ? opts.limit : 30
if (limit > MAX_LIMIT) {
  log(`Requested limit ${limit} exceeds max ${MAX_LIMIT}; clamping to ${MAX_LIMIT}.`)
  limit = MAX_LIMIT
}

const repoFlag = repo ? ` --repo ${repo}` : ''
const repoCtx = repo ? `Repo: ${repo}.` : 'Repo: the current directory\'s repo (no --repo override).'

// ── prompts ──────────────────────────────────────────────────────────────

function gatherPrompt() {
  return [
    'List open GitHub issues and/or PRs for a repo. This is a CHEAP listing pass — no deep reading, no code grounding, just enumerate what is open.',
    '',
    repoCtx,
    `Scope: ${scope} (issues | prs | both). Limit: ${limit} per kind.`,
    '',
    'Steps:',
    scope !== 'prs' ? `- \`gh issue list${repoFlag} --state open --limit ${limit} --json number,title,url\`` : '',
    scope !== 'issues' ? `- \`gh pr list${repoFlag} --state open --limit ${limit} --json number,title,url\`` : '',
    '',
    'Return one entry per item: number, kind ("issue" or "pr"), title, url. Do not read issue bodies or diffs here — that belongs to the next phase.',
  ].filter(Boolean).join('\n')
}

function groundPrompt(item) {
  const source = item.kind === 'issue'
    ? `gh issue view ${item.number}${repoFlag} --comments`
    : `gh pr view ${item.number}${repoFlag} --json title,body,files,mergeStateStatus,reviewDecision; and gh pr diff ${item.number}${repoFlag} for the actual change`
  return [
    `You are grounding ${item.kind} #${item.number} against the LIVE code. This is a read-only verification pass — do not edit, comment, or close anything.`,
    '',
    repoCtx,
    `${item.kind === 'issue' ? 'Issue' : 'PR'} #${item.number} — ${item.title}`,
    '',
    'Steps:',
    `1. Read the source of truth: \`${source}\`.`,
    '2. For every concrete claim or file:line pointer it makes, open the CURRENT code (tilth) and confirm whether the claim still holds. Code moves — do not trust the item\'s own citations without re-checking them.',
    '3. Check recent history for work already addressing this (`git log --oneline -20`, merged PRs) — flag partially-done or already-fixed.',
    `4. For an automated failure report (CI, nightly, docs, evaluation), check the CURRENT runs of the same workflow (\`gh run list${repoFlag} --workflow <name> --limit 5\`). Passing current runs are the ruling-out citation.`,
    '5. Compare against the other open items for a duplicate. Check whether the defect belongs to a different repository.',
    '',
    'Decide a verdict:',
    '- valid = the problem/change is real and still needed/applicable at HEAD.',
    '- partial = part of it shipped, but some acceptance criteria remain unmet. List the remaining criteria in summary. The item stays open.',
    '- stale = describes something no longer true (env changed, code moved, historical failure that current runs no longer show).',
    '- superseded = already fixed/addressed by other merged work.',
    '- duplicate = another open item covers the same work. Set duplicate_of to that item number.',
    '- misfiled = not a defect of this repo; the remaining fix belongs elsewhere. Name where in summary.',
    '- needs-info = cannot determine from available evidence, or the evidence conflicts.',
    '',
    `Every claim in evidence[] MUST carry a citation: file:line, commit hash, PR number, or run URL. Rule 12: a close verdict (${CLOSE_VERDICTS.join(' / ')}) is an absence claim — you must cite what rules the original problem out, not just fail to find it. If you cannot cite a ruling-out, verdict is "valid", "partial", or "needs-info". A fixed symptom does not close an item whose requested test, diagnostic, or follow-up remains absent — that is "partial".`,
    '',
    `Set number=${item.number}, kind="${item.kind}", title to the item title. recommendation is one line: fix now / needs design / deferred / rescope / close / needs human decision.`,
  ].join('\n')
}

function verifyPrompt(item, ground) {
  return [
    `You are a SKEPTIC re-checking a triage verdict for ${item.kind} #${item.number} that would CLOSE it (verdict="${ground.verdict}"). Closing something wrongly is the expensive mistake here — default to disbelief.`,
    '',
    repoCtx,
    `Original verdict: ${ground.verdict}`,
    `Original summary: ${ground.summary}`,
    `Original evidence: ${JSON.stringify(ground.evidence)}`,
    '',
    'Independently re-read the cited code/commits/PRs yourself (tilth, git log, gh). Try to find the original problem STILL PRESENT — a missing fix, a claim that does not hold at the cited location, a stale citation.',
    'For a duplicate, read both items and confirm the surviving item covers every acceptance criterion of this one. For a misfiled item, confirm no defect remains in THIS repo.',
    'Set refuted=true only if you find concrete counter-evidence (with its own citation) that the close verdict is wrong. If refuted, final_verdict should be "valid", "partial", or "needs-info". If the close verdict holds up under your independent check, refuted=false and final_verdict repeats the original.',
    '',
    `Echo number=${item.number}.`,
  ].join('\n')
}

function mapPrompt(lens, survivors) {
  const list = survivors.map((g) => `- ${g.item.kind} #${g.item.number} — ${g.item.title} [${g.ground.verdict}]: ${g.ground.summary}`)
  return [
    `You are mapping which parts of the system each still-open item would affect, through ONE lens: ${lens.key}. This is a read-only pass — do not edit, comment, or close anything.`,
    '',
    repoCtx,
    `Lens: ${lens.brief}`,
    '',
    'ITEMS:',
    ...list,
    '',
    'Return touches[]: for each item this lens has evidence for, the concrete areas it would change (module, file, test harness, document, or contract).',
    'Return links[]: pairs of items that interact, each with a type and cited evidence:',
    '- hard-coupling = one item cannot ship correctly without the design of the other (shared schema, identity, or contract).',
    '- ordering = both ship alone, but one must land first.',
    '- shared-seam = both touch the same function or file, and each ships independently.',
    '- alternative = mutually exclusive options for one decision; the work is not cumulative.',
    '- umbrella = one item tracks the other as a part.',
    '- overlay = one item is verification or test infrastructure that spans the other.',
    '- narrative = one item mentions the other, and no implementation link exists.',
    '',
    'A cross-reference in an issue body is NOT coupling. Counting mentions overstates entanglement. Use "narrative" unless the cited code, test, or acceptance criterion proves a stronger type. Omit a link you cannot cite.',
  ].join('\n')
}

function domainInstructions(lenses) {
  if (!lenses.length) return ['No lens findings exist for this run. Return domains=[] and links=[].']
  return [
    'LENS FINDINGS (JSON) — what each still-open item would touch, and typed links between items:',
    JSON.stringify(lenses, null, 2),
    '',
    'Build domains[] from the lens findings. For each domain, sort its items into:',
    '- contained: the work stays inside this domain.',
    '- cross_cutting: the work crosses into another domain or a public contract.',
    '- overlays: verification or test infrastructure that spans domains and owns no product policy.',
    '- revalidate: partial or overlapping items to re-check before planning.',
    'Put a recommended order in the domain note when ordering links exist.',
    'Build links[] by merging lens links. Keep the strongest type that carries a citation; when lenses disagree, keep the weaker type and say so in evidence. Drop narrative links.',
    'State in summary how many hard couplings exist. Do not report mention counts as entanglement.',
  ]
}

function routePrompt(grounded, lenses) {
  return [
    'You are the triage lead. Below is the grounded (and, for close-worthy verdicts, adversarially verified) assessment for every open item swept this run.',
    '',
    'DATA (JSON):',
    JSON.stringify(grounded, null, 2),
    '',
    'Produce a ranked routing table. For each item, pick exactly one route:',
    '- fix-now: still valid with a clear fix, ready to route to a next skill (name it in why, e.g. /cook, /pasteurize).',
    '- needs-design: still valid, but the fix needs a design or product decision first (name /mold or the open decision in why).',
    '- deferred: still valid, but blocked on an upstream release, a later milestone, or another item (name the blocker in why).',
    '- rescope: verdict is partial — part of it shipped. State in why which acceptance criteria remain, so the item can be narrowed.',
    `- close: verdict is one of ${CLOSE_VERDICTS.join(' / ')}, verifyFailed is not true, and verification did not refute it.`,
    '- needs-human: needs-info, conflicting evidence, a verified verdict was refuted/uncertain, or verifyFailed=true (the adversarial re-check crashed — never close on an unverified close-worthy item).',
    '',
    'For every close route, also set:',
    '- close_reason: "completed" (superseded by merged work), "not planned" (stale or misfiled), or "duplicate".',
    '- duplicate_of: the surviving item number, for a duplicate.',
    '- confidence: "certain" when a merged PR, commit, or passing run proves it; "likely" when the fix exists but adoption or full coverage is debatable. Only "certain" items belong in a close batch.',
    '- comment: a short evidence comment a maintainer can post when closing. Cite the PR, commit, run, or file:line.',
    '',
    'Rank items within each route bucket by leverage/urgency (rank=1 highest). This is a REPORT ONLY — do not close, comment on, label, or edit any issue/PR; that is a follow-up action for a human or a later skill invocation.',
    '',
    ...domainInstructions(lenses),
    '',
    'summary: 3-5 sentences on the overall sweep — how many of each route, the certain close batch, and the single most important thing to act on next.',
  ].join('\n')
}

// ── run ──────────────────────────────────────────────────────────────────

phase('Gather')
log(`Gathering open ${scope} (limit ${limit} each)${repo ? ` for ${repo}` : ''}...`)
const gathered = await agent(gatherPrompt(), { schema: GATHER_SCHEMA, phase: 'Gather', label: 'gather', agentType: 'explorer' })
const items = (gathered && Array.isArray(gathered.items)) ? gathered.items : []

if (!items.length) {
  log('No open items found — nothing to triage.')
  return { items: [], grounded: [], routing: null }
}

if (budget.total != null && budget.remaining() <= 0) {
  log(`Budget exhausted (remaining ${budget.remaining()}) — skipping Ground/Verify/Route for ${items.length} gathered item(s).`)
  return { items, grounded: [], routing: null }
}

log(`Gathered ${items.length} item(s). Grounding each against live code...`)

phase('Ground')
const grounded = (await pipeline(
  items,
  (item) => agent(groundPrompt(item), { schema: GROUND_SCHEMA, phase: 'Ground', label: `ground:${item.kind}#${item.number}`, agentType: 'explorer' }),
  (ground, item) => {
    if (!ground) return null
    if (!CLOSE_VERDICTS.includes(ground.verdict)) return { item, ground, verify: null }
    return agent(verifyPrompt(item, ground), { schema: VERIFY_SCHEMA, phase: 'Verify', label: `verify:${item.kind}#${item.number}`, agentType: 'explorer' })
      .catch(() => null)
      .then((verify) => {
        const verifyFailed = verify == null
        if (verifyFailed) log(`Verify crashed for ${item.kind}#${item.number} (verdict=${ground.verdict}) — routing to needs-human.`)
        return { item, ground, verify, verifyFailed }
      })
  },
)).filter(Boolean)

const dispatchedVerify = grounded.filter((g) => Object.hasOwn(g, 'verifyFailed'))
const failedVerify = dispatchedVerify.filter((g) => g.verifyFailed)
log(`Grounded ${grounded.length}/${items.length} item(s); ${dispatchedVerify.length} sent through adversarial verify${failedVerify.length ? ` (${failedVerify.length} failed)` : ''}.`)

// An item leaves the map only when its close verdict survived verification.
const survivors = grounded.filter((g) => !CLOSE_VERDICTS.includes(g.ground.verdict) || g.verifyFailed || g.verify?.refuted)

let lenses = []
if (mapDomains && survivors.length >= 2) {
  phase('Map')
  log(`Mapping ${survivors.length} still-open item(s) across ${MAP_LENSES.length} lenses...`)
  const results = await parallel(MAP_LENSES.map((lens) => () =>
    agent(mapPrompt(lens, survivors), { schema: MAP_SCHEMA, phase: 'Map', label: `map:${lens.key}`, agentType: 'explorer', effort: 'high' })
      .then((result) => (result ? { lens: lens.key, ...result } : null))
      .catch(() => null)))
  lenses = results.filter(Boolean)
  if (lenses.length < MAP_LENSES.length) log(`${MAP_LENSES.length - lenses.length} map lens(es) failed — the domain map uses the ${lenses.length} that returned.`)
}

phase('Route')
const routing = await agent(routePrompt(grounded, lenses), { schema: ROUTE_SCHEMA, phase: 'Route', label: 'route', effort: 'high' })

return { items, grounded, lenses, routing }
