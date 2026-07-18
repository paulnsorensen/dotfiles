export const meta = {
  name: 'nih-scanner',
  description: 'Fan the nih-scanner sub-agent across a codebase, adversarially verify each Not-Invented-Here candidate, and emit a ranked build-vs-buy findings table',
  whenToUse: 'A codebase you suspect reinvents library functionality and you want an evidence-ranked build-vs-buy audit — report only, never mutates.',
  phases: [
    { title: 'Detect', detail: 'one cheap agent detects primary language(s), dependency manifests, and file count' },
    { title: 'Scan', detail: 'nih-scanner agents fan out over scope chunks; results are deduped and capped' },
    { title: 'Verify', detail: 'one skeptic agent per candidate, default-refute, names the replacement library' },
    { title: 'Rank', detail: 'barrier synthesis agent produces a ranked findings table' },
  ],
}

// Canonicalizes an evidence-grounded NIH ("not invented here") audit: fan the
// nih-scanner sub-agent (agents/agent_definitions/nih-scanner.md) across a
// codebase, adversarially verify every candidate before it counts as
// confirmed, and hand back a ranked report. Read-only — Detect/Scan/Verify
// only inspect code; Rank only synthesizes a report; nothing in this file
// ever writes a file, opens a PR, or calls `gh`.
//
// Invoked as `/nih-scanner [args]`; args is a bare scope-path string, or an
// object {scope?, languages?, minUsage?, maxCandidates?, workers?}.

const DETECT_SCHEMA = {
  type: 'object',
  required: ['languages', 'depManifest', 'fileCount', 'scope'],
  properties: {
    languages: { type: 'array', items: { type: 'string' } },
    depManifest: { type: 'array', items: { type: 'string' } },
    fileCount: { type: 'integer' },
    scope: { type: 'string' },
  },
}

const SCAN_SCHEMA = {
  type: 'object',
  required: ['scanMeta', 'candidates'],
  properties: {
    scanMeta: {
      type: 'object',
      required: ['languages', 'filesScanned', 'serenaAvailable', 'scope'],
      properties: {
        languages: { type: 'array', items: { type: 'string' } },
        filesScanned: { type: 'integer' },
        serenaAvailable: { type: 'boolean' },
        scope: { type: 'string' },
      },
    },
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        required: [
          'id', 'filePath', 'lineRange', 'category', 'pattern', 'snippet',
          'usageCount', 'functionName', 'linesOfCode',
        ],
        properties: {
          id: { type: 'integer' },
          filePath: { type: 'string' },
          lineRange: { type: 'array', items: { type: 'integer' } },
          category: { type: 'string' },
          pattern: { type: 'string' },
          snippet: { type: 'string' },
          usageCount: { type: 'integer' },
          functionName: { type: 'string' },
          linesOfCode: { type: 'integer' },
        },
      },
    },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reasoning'],
  properties: {
    refuted: { type: 'boolean' },
    library: { type: 'string', description: 'the specific replacement library, when not refuted' },
    effort: { type: 'string', enum: ['S', 'M', 'L'] },
    reasoning: { type: 'string' },
    citation: { type: 'string' },
  },
}

const REPORT_SCHEMA = {
  type: 'object',
  required: ['findings', 'summary'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: [
          'category', 'location', 'functionName', 'usageCount', 'library',
          'effort', 'confidence', 'recommendation',
        ],
        properties: {
          category: { type: 'string' },
          location: { type: 'string', description: 'file:line' },
          functionName: { type: 'string' },
          usageCount: { type: 'integer' },
          library: { type: 'string' },
          effort: { type: 'string', enum: ['S', 'M', 'L'] },
          confidence: { type: 'string' },
          recommendation: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
  },
}

// ── args ─────────────────────────────────────────────────────────────────

const UNSAFE_REPO_CHARS = /[\s;&|`$(){}<>"'\\]/
const MAX_CANDIDATES = 100
const MAX_WORKERS = 16

function coerceArgs(a) {
  if (a == null) return {}
  if (typeof a === 'string') return { scope: a }
  if (typeof a === 'object') return a
  return {}
}

function clampInt(value, min, max, fallback, name) {
  if (!Number.isInteger(value)) return fallback
  if (value < min) {
    log(`${name} ${value} below minimum ${min}; clamping to ${min}.`)
    return min
  }
  if (value > max) {
    log(`${name} ${value} exceeds maximum ${max}; clamping to ${max}.`)
    return max
  }
  return value
}

const opts = coerceArgs(args)

let scope = typeof opts.scope === 'string' && opts.scope.trim() ? opts.scope.trim() : '.'
if (UNSAFE_REPO_CHARS.test(scope)) {
  log(`scope "${scope}" contains unsafe characters; falling back to "."`)
  scope = '.'
}

const argLanguages = Array.isArray(opts.languages) ? opts.languages.filter((l) => typeof l === 'string') : []
const minUsage = clampInt(opts.minUsage, 0, Number.MAX_SAFE_INTEGER, 0, 'minUsage')
const maxCandidates = clampInt(opts.maxCandidates, 1, MAX_CANDIDATES, 25, 'maxCandidates')
const workers = clampInt(opts.workers, 1, MAX_WORKERS, 4, 'workers')

// ── helpers ──────────────────────────────────────────────────────────────

// The workflow sandbox has no filesystem access, so a real top-level
// directory listing is not available in plain code — chunking only has
// something to split when the caller already encodes multiple top-level
// paths as a comma-separated scope (e.g. "src/a,src/b,src/c"). Otherwise it
// falls back to a single chunk covering the whole scope, per spec.
function chunkScope(scopeValue, count) {
  const parts = scopeValue.split(',').map((p) => p.trim()).filter(Boolean)
  if (parts.length <= 1) return [scopeValue]
  const groups = Array.from({ length: Math.min(count, parts.length) }, () => [])
  parts.forEach((part, i) => groups[i % groups.length].push(part))
  return groups.map((g) => g.join(','))
}

function slugify(text) {
  return String(text).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'scope'
}

function candidateKey(c) {
  return `${c.filePath}:${c.lineRange ? c.lineRange[0] : ''}:${c.functionName || c.category}`
}

// ── prompts ──────────────────────────────────────────────────────────────

function detectPrompt() {
  return [
    `Detect the primary language(s), dependency manifest(s), and source file count under scope \`${scope}\`. This is a CHEAP detection pass — no deep code reading.`,
    '',
    'Steps:',
    '1. Identify the primary programming language(s) present under the scope.',
    '2. Locate and read dependency manifest(s) (package.json, Cargo.toml, pyproject.toml, go.mod) into a flat list of installed dependency names.',
    '3. Count the source files under scope (excluding tests, vendored deps, build output, .git/).',
    '',
    `Return languages (array), depManifest (array of dependency names), fileCount (integer), and scope="${scope}".`,
  ].join('\n')
}

function scanPrompt(chunk, detected) {
  const languages = argLanguages.length ? argLanguages : detected.languages
  return [
    'You are the NIH Scanner. Follow your protocol exactly: Serena first, ast-grep fallback, never Grep for pattern detection.',
    '',
    `Languages: ${JSON.stringify(languages)}`,
    `Scope: ${chunk}`,
    `depManifest: ${JSON.stringify(detected.depManifest)}`,
    `Slug: nih-scan-${slugify(chunk)}`,
  ].join('\n')
}

function verifyPrompt(candidate) {
  return [
    `You are a SKEPTIC verifying whether this candidate is a REAL reinvention of a well-supported library, or a false positive. Default to refuted=true — a confirmation is the expensive mistake here.`,
    '',
    `Category: ${candidate.category}`,
    `Location: ${candidate.filePath}:${candidate.lineRange ? candidate.lineRange.join('-') : '?'}`,
    `Function: ${candidate.functionName}`,
    `Pattern: ${candidate.pattern}`,
    `Usage count: ${candidate.usageCount}`,
    `Lines of code: ${candidate.linesOfCode}`,
    'Snippet:',
    candidate.snippet,
    '',
    'Known false positives to rule out: stdlib usage (structuredClone, crypto.randomUUID, Intl, http.Client, logging.basicConfig, timedelta), intentional/domain logic, code that already delegates to an installed dependency, or code too trivial to matter.',
    'Rule 12: an NIH confirmation is a positive claim that a specific library supplies this functionality — you must NAME the replacement library and explain why the local code duplicates it. If you cannot, set refuted=true.',
    'If not refuted, also return library (the specific replacement), effort (S = 1-3 callers, M = 4-9, L = 10+, based on the usage count above), and a citation backing your claim.',
  ].join('\n')
}

function reportPrompt(confirmed) {
  return [
    'You are producing the final ranked NIH (Not-Invented-Here) findings report. Below is every candidate confirmed by an independent skeptic verification pass.',
    '',
    'DATA (JSON):',
    JSON.stringify(confirmed, null, 2),
    '',
    'Produce a ranked findings table. For each finding include: category, location (file:line), functionName, usageCount, library, effort (S/M/L), confidence, and recommendation.',
    'Rank by leverage: highest usageCount and lowest effort first.',
    'summary: counts by category, and the single highest-leverage action to take next.',
    '',
    'REPORT ONLY: do not call gh, do not post anywhere, do not write files, do not mutate anything.',
  ].join('\n')
}

// ── run ──────────────────────────────────────────────────────────────────

phase('Detect')
log(`Detecting languages, dependency manifests, and file count in scope "${scope}"...`)
const detected = await agent(detectPrompt(), { agentType: 'explorer', schema: DETECT_SCHEMA, phase: 'Detect', label: 'detect' }).catch(() => null)

if (!detected || detected.fileCount === 0) {
  log(detected ? `No source files found in scope "${scope}" — nothing to scan.` : 'Detect agent returned no result — nothing to scan.')
  return { scanMeta: null, candidates: [], confirmed: [], report: null }
}

if (budget.total != null && budget.remaining() <= 0) {
  log(`Budget exhausted (remaining ${budget.remaining()}) — skipping Scan/Verify/Rank.`)
  return { scanMeta: detected, candidates: [], confirmed: [], report: null }
}

phase('Scan')
const chunks = chunkScope(scope, workers)
log(`Scanning ${chunks.length} chunk(s) of scope "${scope}" (up to ${workers} worker(s))...`)
const scanResults = await parallel(
  chunks.map((chunk) => () => agent(scanPrompt(chunk, detected), { agentType: 'nih-scanner', schema: SCAN_SCHEMA, phase: 'Scan', label: `scan:${chunk}` }))
)
const validScans = scanResults.filter(Boolean)
const rawCandidates = validScans.flatMap((r) => r.candidates || [])

// scanMeta is aggregated across every chunk (not just the last one) so a
// self-truncated fan-out (each nih-scanner agent has a bounded tool-call
// budget) is visible instead of silently reading as "clean". serenaAvailable
// is AND-reduced: the aggregate is only true when every chunk had it.
const scannedMetas = validScans.map((r) => r.scanMeta).filter(Boolean)
const filesScanned = scannedMetas.reduce((sum, m) => sum + (typeof m.filesScanned === 'number' ? m.filesScanned : 0), 0)
const serenaAvailable = scannedMetas.length > 0 && scannedMetas.every((m) => m.serenaAvailable === true)
const underScanned = filesScanned < detected.fileCount
if (underScanned) {
  log(`Under-scanned: scanned ${filesScanned} of ${detected.fileCount} detected file(s) — a scan agent may have self-truncated; results could be incomplete.`)
}
const scanMeta = {
  ...detected,
  filesScanned,
  serenaAvailable,
  underScanned,
  ...(underScanned ? { underScanNote: `Only ${filesScanned} of ${detected.fileCount} detected file(s) were scanned; findings may be incomplete.` } : {}),
}

const seen = new Set()
const deduped = []
for (const candidate of rawCandidates) {
  const key = candidateKey(candidate)
  if (seen.has(key)) continue
  seen.add(key)
  deduped.push(candidate)
}
if (rawCandidates.length !== deduped.length) {
  log(`Deduped ${rawCandidates.length - deduped.length} overlapping candidate(s).`)
}

const meetsUsage = deduped.filter((c) => (typeof c.usageCount === 'number' ? c.usageCount : 0) >= minUsage)
if (meetsUsage.length !== deduped.length) {
  log(`${deduped.length - meetsUsage.length} candidate(s) dropped below minUsage=${minUsage}.`)
}

const capped = meetsUsage.slice(0, maxCandidates)
if (meetsUsage.length > maxCandidates) {
  log(`${meetsUsage.length - maxCandidates} candidate(s) dropped by the maxCandidates cap (${maxCandidates}).`)
}
log(`Scan produced ${capped.length} candidate(s) to verify.`)

if (budget.total != null && budget.remaining() <= 0) {
  log(`Budget exhausted (remaining ${budget.remaining()}) — skipping Verify/Rank for ${capped.length} scanned candidate(s).`)
  return { scanMeta, candidates: capped, confirmed: [], report: null }
}

phase('Verify')
const verified = await pipeline(
  capped,
  (candidate) => agent(verifyPrompt(candidate), { agentType: 'explorer', schema: VERIFY_SCHEMA, phase: 'Verify', label: `verify:${candidate.functionName}` })
    .catch(() => null)
    .then((verify) => {
      const verifyFailed = verify == null
      if (verifyFailed) log(`Verify crashed for ${candidate.functionName} (${candidate.filePath}) — flagging low-confidence, needs-human.`)
      return { candidate, verify, verifyFailed }
    })
)

// candidates carries every verified survivor, flagged with its verify outcome
// (confirmed / refuted / crashed / unnamed-library). A crashed verify, and a
// non-refuted verify that names no replacement library (Rule 12 requires
// naming one to count as a confirmation), are both KEPT here flagged
// needs-human — never silently dropped or silently confirmed. confirmed
// narrows to the subset that survived adversarial verification.
const candidates = verified.filter(Boolean).map((v) => {
  if (v.verifyFailed) {
    return { ...v.candidate, confidence: 'low', verifyFailed: true, note: 'verify crashed — needs human review' }
  }
  if (v.verify && v.verify.refuted) {
    return { ...v.candidate, refuted: true }
  }
  if (!v.verify || typeof v.verify.library !== 'string' || !v.verify.library.trim()) {
    return { ...v.candidate, confidence: 'low', verifyFailed: true, note: 'verify confirmed without naming a replacement library — needs human review' }
  }
  return {
    ...v.candidate,
    confirmed: true,
    library: v.verify.library,
    effort: v.verify.effort,
    reasoning: v.verify.reasoning,
    citation: v.verify.citation,
  }
})
const confirmed = candidates.filter((c) => c.confirmed === true)
const refutedCount = candidates.filter((c) => c.refuted === true).length
const needsHumanCount = candidates.filter((c) => c.verifyFailed === true).length
log(`Verified ${capped.length} candidate(s): ${confirmed.length} confirmed, ${refutedCount} refuted, ${needsHumanCount} flagged needs-human.`)

if (budget.total != null && budget.remaining() <= 0) {
  log(`Budget exhausted (remaining ${budget.remaining()}) — skipping Rank for ${confirmed.length} confirmed candidate(s).`)
  return { scanMeta, candidates, confirmed, report: null }
}

phase('Rank')
const report = await agent(reportPrompt(confirmed), { schema: REPORT_SCHEMA, phase: 'Rank', label: 'rank', effort: 'high' }).catch(() => null)
if (!report) log('Rank agent crashed — returning candidates and confirmed findings without a synthesized report.')

return { scanMeta, candidates, confirmed, report }
