export const meta = {
  name: 'triage-sweep',
  description: 'Gather open GitHub issues/PRs, ground each one against live code, adversarially verify close-worthy verdicts, and route into a ranked fix-now / close / needs-human table',
  whenToUse: 'A backlog of open issues/PRs on a repo that needs an evidence-grounded triage pass — report only, never mutates GitHub.',
  phases: [
    { title: 'Gather', detail: 'list open issues/PRs via gh in one cheap agent' },
    { title: 'Ground', detail: 'one grounding agent per item verifies claims against live code, cites file:line' },
    { title: 'Verify', detail: 'adversarial re-check, only for items whose verdict would close them' },
    { title: 'Route', detail: 'barrier synthesis agent produces a ranked routing table' },
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
// for verdicts that would close an item (stale/superseded), since those are
// the claims with the highest cost if wrong.
//
// Invoked as `/triage-sweep [args]`; args is {repo?, scope?, limit?} or a
// bare "owner/name" string (repo shorthand). Read-only — Gather/Ground/
// Verify only inspect GitHub and local code; Route only synthesizes a
// report; nothing in this file ever calls `gh issue close`, `gh pr close`,
// or posts a comment.

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

const GROUND_SCHEMA = {
  type: 'object',
  required: ['number', 'kind', 'title', 'verdict', 'evidence', 'summary', 'recommendation'],
  properties: {
    number: { type: 'integer' },
    kind: { type: 'string', enum: ['issue', 'pr'] },
    title: { type: 'string' },
    verdict: { type: 'string', enum: ['valid', 'stale', 'superseded', 'needs-info'] },
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
    final_verdict: { type: 'string', enum: ['valid', 'stale', 'superseded', 'needs-info'] },
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
          route: { type: 'string', enum: ['fix-now', 'close', 'needs-human'] },
          rank: { type: 'integer', description: '1 = highest priority within its route bucket' },
          why: { type: 'string' },
        },
      },
    },
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
    '2. For every concrete claim or file:line pointer it makes, open the CURRENT code (tilth/serena) and confirm whether the claim still holds. Code moves — do not trust the item\'s own citations without re-checking them.',
    '3. Check recent history for work already addressing this (`git log --oneline -20`, merged PRs) — flag partially-done or already-fixed.',
    '',
    'Decide a verdict:',
    '- valid = the problem/change is real and still needed/applicable at HEAD.',
    '- stale = describes something no longer true (env changed, code moved) but not yet resolved as intended.',
    '- superseded = already fixed/addressed by other merged work.',
    '- needs-info = cannot determine from available evidence.',
    '',
    'Every claim in evidence[] MUST carry a citation: file:line, commit hash, or PR number. Rule 12: a "superseded" or "stale" verdict is an absence claim — you must cite what rules the original problem out, not just fail to find it. If you cannot cite a ruling-out, verdict is "valid" or "needs-info", not "superseded"/"stale".',
    '',
    `Set number=${item.number}, kind="${item.kind}", title to the item title. recommendation is one line: fix now / close / needs human decision.`,
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
    'Independently re-read the cited code/commits/PRs yourself (tilth/serena, git log, gh). Try to find the original problem STILL PRESENT — a missing fix, a claim that does not hold at the cited location, a stale citation.',
    'Set refuted=true only if you find concrete counter-evidence (with its own citation) that the item is NOT actually stale/superseded. If refuted, final_verdict should be "valid" or "needs-info". If the close verdict holds up under your independent check, refuted=false and final_verdict repeats the original.',
    '',
    `Echo number=${item.number}.`,
  ].join('\n')
}

function routePrompt(grounded) {
  return [
    'You are the triage lead. Below is the grounded (and, for close-worthy verdicts, adversarially verified) assessment for every open item swept this run.',
    '',
    'DATA (JSON):',
    JSON.stringify(grounded, null, 2),
    '',
    'Produce a ranked routing table. For each item, pick exactly one route:',
    '- fix-now: still valid, ready to route to a next skill (name it in why, e.g. /cook, /pasteurize, /mold).',
    '- close: verdict is stale or superseded, verifyFailed is not true, and (if verified) verification did not refute it.',
    '- needs-human: needs-info, a verified verdict was refuted/uncertain, verifyFailed=true (the adversarial re-check crashed — never close on an unverified close-worthy item), or the fix requires a design/product decision.',
    '',
    'Rank items within each route bucket by leverage/urgency (rank=1 highest). This is a REPORT ONLY — do not close, comment on, or edit any issue/PR; that is a follow-up action for a human or a later skill invocation.',
    '',
    'summary: 3-5 sentences on the overall sweep — how many of each route, and the single most important thing to act on next.',
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
    if (ground.verdict !== 'stale' && ground.verdict !== 'superseded') return { item, ground, verify: null }
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

phase('Route')
const routing = await agent(routePrompt(grounded), { schema: ROUTE_SCHEMA, phase: 'Route', label: 'route', effort: 'high' })

return { items, grounded, routing }
