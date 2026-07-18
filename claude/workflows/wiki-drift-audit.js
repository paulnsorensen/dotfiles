export const meta = {
  name: 'wiki-drift-audit',
  description: 'Sweep a hallouminate-wiki\'d repo for stale documentation: extract checkable claims from every wiki page, try to refute each against live code, and report a ranked drift table with suggested rewrites. Report only — this workflow NEVER writes to the wiki; folding a confirmed rewrite back in is the `hallouminate:wiki-ingest` skill\'s job.',
  whenToUse: 'A repo with a .hallouminate/wiki/ you want audited for drift — pages that assert something about the code (a file path, a command name, an architecture claim, "X does Y") that is no longer true.',
  phases: [
    { title: 'Map', detail: 'one cheap agent lists wiki pages under .hallouminate/wiki/' },
    { title: 'Falsify', detail: 'pipeline over pages — one agent per page extracts claims and tries to refute each against live code' },
    { title: 'Verify', detail: 'adversarial second opinion, scoped to pages with any stale/contradicted claim' },
    { title: 'Report', detail: 'barrier synthesis — ranked drift table + suggested-rewrite one-liner per confirmed-stale page' },
  ],
}

// Tracked source: claude/workflows/wiki-drift-audit.js in the dotfiles repo.
// Deployed to ~/.claude/workflows/ as a symlink by claude/.sync (the `configs`
// array). Invoked as `/wiki-drift-audit`; `args` is {repoRoot?, maxPages?}.
//
// This workflow is REPORT ONLY. It never calls hallouminate add_markdown /
// delete_markdown or otherwise edits .hallouminate/wiki/ — folding a
// confirmed-stale page's rewrite back into the wiki is the
// `hallouminate:wiki-ingest` skill's job, driven by a human (or a separate
// invocation) reading this report.

const DEFAULT_MAX_PAGES = 40
const MAX_PAGES = 200
const UNSAFE_REPO_ROOT_CHARS = /[;&|`$(){}<>'"\\]/

const VERDICT_ENUM = ['current', 'stale', 'contradicted']

const MAP_SCHEMA = {
  type: 'object',
  required: ['pages'],
  properties: {
    pages: {
      type: 'array',
      items: {
        type: 'object',
        required: ['path', 'title'],
        properties: {
          path: { type: 'string' },
          title: { type: 'string' },
        },
      },
    },
  },
}

const CLAIM_ITEM_SCHEMA = {
  type: 'object',
  required: ['claim', 'verdict'],
  properties: {
    claim: { type: 'string' },
    verdict: { type: 'string', enum: VERDICT_ENUM },
    evidence: { type: 'string' },
  },
}

const PAGE_CLAIMS_SCHEMA = {
  type: 'object',
  required: ['page', 'claims'],
  properties: {
    page: { type: 'string' },
    claims: { type: 'array', items: CLAIM_ITEM_SCHEMA },
  },
}

const REPORT_SCHEMA = {
  type: 'object',
  required: ['drift_table'],
  properties: {
    drift_table: {
      type: 'array',
      items: {
        type: 'object',
        required: ['page', 'claim', 'verdict', 'evidence'],
        properties: {
          page: { type: 'string' },
          claim: { type: 'string' },
          verdict: { type: 'string', enum: VERDICT_ENUM },
          evidence: { type: 'string' },
          unverified: { type: 'boolean', description: 'true when the Verify pass could not re-check this claim and the first-pass verdict is unconfirmed' },
        },
      },
    },
    rewrites: {
      type: 'array',
      items: {
        type: 'object',
        required: ['page', 'suggestion'],
        properties: {
          page: { type: 'string' },
          suggestion: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
    report_path: { type: 'string' },
  },
}

function mapPrompt(repoRoot, maxPages) {
  return [
    'List every wiki page under the hallouminate wiki tree for this repo. Do NOT read page content yet — just enumerate.',
    '',
    `Repo root: ${repoRoot}`,
    `Wiki tree: ${repoRoot}/.hallouminate/wiki/`,
    '',
    'Method (either works — pick whichever is available):',
    `1. Read the directory tree at ${repoRoot}/.hallouminate/wiki/ directly (recursive listing of *.md files), deriving each title from its first markdown heading or, failing that, the filename.`,
    `2. Or, if the hallouminate MCP is connected (load it via ToolSearch if its tools are deferred), call list_tree against the repo:<name>:wiki corpus for this repo and use its path/title pairs. Every path list_tree returns is corpus-relative and MUST be normalized to the repo-relative filesystem form before you return it: \`${repoRoot}/.hallouminate/wiki/<corpus-relative-path>.md\`. Invariant: every returned path MUST be readable relative to the repo root — this is what the Falsify and Report phases assume.`,
    '',
    `Skip index.md files that are pure navigation (no checkable claims) unless they are the only page. Cap at ${maxPages} pages — if there are more, include the ${maxPages} most substantive ones (largest / most specific) and note the omission in your reasoning, but still just return the array.`,
    '',
    'Return pages: [{path, title}] — path relative to repo root, title short and human-readable.',
  ].join('\n')
}

function falsifyPrompt(page, repoRoot) {
  return [
    'Audit ONE hallouminate wiki page for drift against the live codebase. You are trying to REFUTE the page, not confirm it.',
    `Repo root: ${repoRoot}`,
    `Page: ${page.path} ("${page.title}")`,
    '',
    'Method:',
    '1. Read the page in full.',
    '2. Extract its checkable claims — architecture assertions ("X talks to Y via Z"), file/directory paths, command names, config keys, and "X does Y" behavioural statements. Skip opinions, rationale-only prose, and claims with no way to check them against code.',
    '3. For each claim, independently check it against the CURRENT codebase — read the referenced file/symbol, run the referenced command\'s --help or search for it, confirm the path exists. Cite a file:line (or "path not found" / "command not found") as evidence.',
    '4. Verdict per claim: "current" (still true, evidence confirms it), "stale" (was true, code has since diverged — cite what changed), "contradicted" (the claim and the code disagree outright, or the referenced path/symbol/command does not exist).',
    '',
    'Do not guess — if you cannot find evidence either way, default to "current" (a false "stale" is worse than a miss; the Verify phase will double-check flagged claims, not clean ones).',
    '',
    `Return page="${page.path}" and claims: [{claim, verdict, evidence}] — one entry per checkable claim found.`,
  ].join('\n')
}

function verifyPrompt(pageResult, repoRoot) {
  const flagged = (pageResult.claims || []).filter((c) => c.verdict === 'stale' || c.verdict === 'contradicted')
  return [
    'You are an adversarial second opinion on a wiki-drift finding. A first pass flagged the claims below as stale or contradicted — your job is to re-check them independently, not rubber-stamp the flag.',
    `Repo root: ${repoRoot}`,
    `Page: ${pageResult.page}`,
    '',
    'Flagged claims (JSON):',
    JSON.stringify(flagged, null, 2),
    '',
    'For each claim, re-read the page and independently re-check the cited code location (or find a better one). A false "stale"/"contradicted" verdict is worse than missing a real one — default to "current" when the evidence is ambiguous, thin, or you cannot independently confirm the drift yourself.',
    'Only keep "stale" or "contradicted" when you can personally cite the file:line (or absence) that disagrees with the claim.',
    '',
    `Return page="${pageResult.page}" and claims: [{claim, verdict, evidence}] covering exactly the flagged claims above (echo claim text verbatim), with your own independently re-checked verdict and evidence.`,
  ].join('\n')
}

function reportPrompt(results, truncated, totalPagesFound, maxPages) {
  return [
    'Synthesize a wiki-drift audit report from the per-page claim checks below (Verify-phase re-checks have already been folded in for previously-flagged claims).',
    '',
    `Pages audited: ${results.length}${truncated ? ` (truncated from ${totalPagesFound} found, maxPages=${maxPages})` : ''}`,
    '',
    'Per-page claims (JSON):',
    JSON.stringify(results, null, 2),
    '',
    'Rules:',
    '- drift_table: one row per claim that is NOT verdict="current" — {page, claim, verdict, evidence}. Carry the claim\'s `unverified: true` flag through into the row when the input data has it, so the report can show which verdicts the Verify pass could not re-check. Rank stale/contradicted pages by how many flagged claims they carry, most first. Omit current claims from the table entirely (this is a drift report, not a coverage report).',
    '- rewrites: for every page with at least one confirmed stale or contradicted claim, one suggestion — a single sentence describing what the page should say instead, grounded in the evidence already collected. Do NOT write full replacement prose, just the one-liner.',
    '- summary: 2-3 sentences — how many pages audited, how many clean, how many with drift, and the single most consequential finding if any.',
    '- This is a REPORT. Do not propose editing the wiki directly here — that is a separate, human-triggered step (the `hallouminate:wiki-ingest` skill). If a durable artifact path is available for this report (e.g. ./.cheese/research/wiki-drift-audit/<repo>.md), write it and return report_path; otherwise return "".',
  ].join('\n')
}

// ── run ───────────────────────────────────────────────────────────────────

const opts = args && typeof args === 'object' ? args : {}
const rawRepoRoot = (typeof opts.repoRoot === 'string' && opts.repoRoot.trim()) || '.'
const repoRootUnsafe = UNSAFE_REPO_ROOT_CHARS.test(rawRepoRoot)
if (repoRootUnsafe) {
  log(`wiki-drift-audit: repoRoot "${rawRepoRoot}" contains unsafe characters — falling back to ".".`)
}
const repoRoot = repoRootUnsafe ? '.' : rawRepoRoot
const rawMaxPages = Number(opts.maxPages)
if (opts.maxPages !== undefined && !(Number.isFinite(rawMaxPages) && rawMaxPages > 0)) {
  log(`wiki-drift-audit: maxPages "${opts.maxPages}" is not a usable positive number — falling back to ${DEFAULT_MAX_PAGES}.`)
}
let maxPages = Number.isFinite(rawMaxPages) && rawMaxPages > 0 ? Math.floor(rawMaxPages) : DEFAULT_MAX_PAGES
if (maxPages > MAX_PAGES) {
  log(`wiki-drift-audit: maxPages ${maxPages} exceeds max ${MAX_PAGES} — clamping to ${MAX_PAGES}.`)
  maxPages = MAX_PAGES
}

phase('Map')
log(`Listing wiki pages under ${repoRoot}/.hallouminate/wiki/ (maxPages=${maxPages}).`)
const mapResult = await agent(mapPrompt(repoRoot, maxPages), { schema: MAP_SCHEMA, label: 'map' })
if (!mapResult || !Array.isArray(mapResult.pages) || !mapResult.pages.length) {
  log('No wiki pages found — nothing to audit.')
  return { error: 'No wiki pages found under .hallouminate/wiki/.', pages_found: 0 }
}

const totalPagesFound = mapResult.pages.length
log(`Found ${totalPagesFound} wiki page(s).`)
let pages = mapResult.pages
let truncated = false
if (pages.length > maxPages) {
  pages = pages.slice(0, maxPages)
  truncated = true
  log(`Truncated to maxPages=${maxPages} (${totalPagesFound - maxPages} page(s) dropped).`)
}

phase('Falsify')
const falsified = await pipeline(pages, (p) => agent(falsifyPrompt(p, repoRoot), { schema: PAGE_CLAIMS_SCHEMA, phase: 'Falsify', label: `falsify:${p.path}` }))
const falsifyResults = falsified.filter(Boolean)
log(`Extracted and checked claims for ${falsifyResults.length}/${pages.length} page(s).`)

phase('Verify')
const flaggedPages = falsifyResults.filter((r) => Array.isArray(r.claims) && r.claims.some((c) => c.verdict === 'stale' || c.verdict === 'contradicted'))
if (flaggedPages.length) {
  log(`${flaggedPages.length}/${falsifyResults.length} page(s) carry a stale/contradicted claim — running adversarial second opinion.`)
  const reverified = await pipeline(flaggedPages, (r) => agent(verifyPrompt(r, repoRoot), { schema: PAGE_CLAIMS_SCHEMA, phase: 'Verify', label: `verify:${r.page}` }))
  const reverifiedByPage = new Map(reverified.filter(Boolean).map((v) => [v.page, v]))
  for (let i = 0; i < falsifyResults.length; i++) {
    const r = falsifyResults[i]
    const rv = reverifiedByPage.get(r.page)
    const flaggedPositions = r.claims
      .map((c, idx) => ((c.verdict === 'stale' || c.verdict === 'contradicted') ? idx : -1))
      .filter((idx) => idx >= 0)
    if (!rv || !Array.isArray(rv.claims)) {
      log(`Verify pass returned nothing for page ${r.page} — keeping the first-pass verdict(s), marked unverified.`)
      flaggedPositions.forEach((pos) => { r.claims[pos] = { ...r.claims[pos], unverified: true } })
      continue
    }
    // Prefer verbatim claim-text association: when every flagged claim's text
    // is unique and present in the reverified result, match by text so a
    // paraphrase can't silently retain the first pass's stale/contradicted
    // verdict. Fall back to positional alignment (or a partial text match)
    // only when text association can't uniquely resolve every flagged claim.
    const flaggedTexts = flaggedPositions.map((pos) => r.claims[pos].claim)
    const uniqueFlaggedTexts = new Set(flaggedTexts).size === flaggedTexts.length
    const rvByClaim = new Map(rv.claims.map((c) => [c.claim, c]))
    const textMatchCoversAll = uniqueFlaggedTexts && flaggedTexts.every((t) => rvByClaim.has(t))
    if (textMatchCoversAll) {
      flaggedPositions.forEach((pos) => { r.claims[pos] = rvByClaim.get(r.claims[pos].claim) })
    } else if (rv.claims.length === flaggedPositions.length) {
      flaggedPositions.forEach((pos, k) => { r.claims[pos] = rv.claims[k] })
    } else {
      flaggedPositions.forEach((pos) => {
        const matched = rvByClaim.get(r.claims[pos].claim)
        r.claims[pos] = matched || { ...r.claims[pos], unverified: true }
      })
    }
  }
} else {
  log('No flagged claims — skipping the adversarial re-check.')
}

phase('Report')
const report = await agent(reportPrompt(falsifyResults, truncated, totalPagesFound, maxPages), { schema: REPORT_SCHEMA, label: 'report' })
if (!report) return { error: 'Report synthesis failed.', pages_audited: falsifyResults.length }

return {
  repo_root: repoRoot,
  pages_found: totalPagesFound,
  pages_audited: falsifyResults.length,
  truncated,
  drift_table: report.drift_table || [],
  rewrites: report.rewrites || [],
  summary: report.summary || '',
  report_path: report.report_path || '',
}
