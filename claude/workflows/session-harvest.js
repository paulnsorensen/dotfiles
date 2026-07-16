export const meta = {
  name: 'session-harvest',
  description:
    'Farm recent sessions and worktrees for salvageable work: unpromoted workflow scripts, unmerged worktree/branch content, and abandoned handoff notes/specs.',
  whenToUse:
    'Periodic sweep to find work that happened but never got promoted, merged, or followed up on. Requires args.sinceIso (the cutoff timestamp) — workflow scripts cannot call Date.now() or new Date(), so the caller must pass the cutoff explicitly. Report-only: never commits, promotes, or deletes anything.',
  phases: [
    { title: 'Sweep', detail: 'three parallel finders — unpromoted workflow scripts, worktree/branch salvage, abandoned handoffs' },
    { title: 'Verify', detail: 'one agent per candidate confirming it is still relevant, with evidence' },
    { title: 'Report', detail: 'barrier synthesis into a ranked salvage table' },
  ],
}

// Tracked source: claude/workflows/session-harvest.js in the dotfiles repo.
// Deployed to ~/.claude/workflows/ as a symlink by claude/.sync (the `configs`
// array). Invoked as `/session-harvest <args>`; `args` is {sinceIso, devRoot?}.
//
// Date.now() / new Date() are unavailable inside workflow scripts (harness
// runs them in a restricted scope) — sinceIso is a REQUIRED caller-supplied
// cutoff, never derived here.

const WORKFLOW_SCRIPT_SCHEMA = {
  type: 'object',
  required: ['candidates'],
  properties: {
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        required: ['name', 'path', 'occurrences', 'already_saved'],
        properties: {
          name: { type: 'string' },
          path: { type: 'string' },
          occurrences: { type: 'integer' },
          already_saved: { type: 'boolean' },
          why: { type: 'string' },
        },
      },
    },
    scanned_count: { type: 'integer' },
  },
}

const WORKTREE_SCHEMA = {
  type: 'object',
  required: ['candidates'],
  properties: {
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        required: ['repo', 'path', 'branch', 'unique_commits', 'dirty_files', 'untracked_worth_keeping'],
        properties: {
          repo: { type: 'string' },
          path: { type: 'string' },
          branch: { type: 'string' },
          unique_commits: { type: 'integer' },
          dirty_files: { type: 'integer' },
          untracked_worth_keeping: { type: 'boolean' },
          why: { type: 'string' },
        },
      },
    },
    scanned_count: { type: 'integer' },
  },
}

const HANDOFF_SCHEMA = {
  type: 'object',
  required: ['candidates'],
  properties: {
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        required: ['slug', 'path', 'kind', 'status', 'next'],
        properties: {
          slug: { type: 'string' },
          path: { type: 'string' },
          kind: { type: 'string', enum: ['notes', 'specs'] },
          status: { type: 'string' },
          next: { type: 'string' },
          why: { type: 'string' },
        },
      },
    },
    scanned_count: { type: 'integer' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['still_relevant', 'evidence'],
  properties: {
    still_relevant: { type: 'boolean' },
    evidence: { type: 'string' },
    reason: { type: 'string' },
  },
}

const REPORT_SCHEMA = {
  type: 'object',
  required: ['rows'],
  properties: {
    rows: {
      type: 'array',
      items: {
        type: 'object',
        required: ['candidate', 'kind', 'where', 'why_it_matters', 'suggested_action'],
        properties: {
          candidate: { type: 'string' },
          kind: { type: 'string', enum: ['workflow', 'branch', 'handoff'] },
          where: { type: 'string' },
          why_it_matters: { type: 'string' },
          suggested_action: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
  },
}

function scriptsPrompt(sinceIso) {
  return [
    'Find unpromoted workflow scripts written in recent Claude Code sessions.',
    '',
    `Cutoff: only consider files with mtime newer than ${sinceIso}.`,
    '',
    'Method:',
    '1. Find files matching ~/.claude/projects/*/*/workflows/scripts/*.js newer than the cutoff (find -newermt works for a timestamp).',
    '2. For each match, read the file and extract its `meta.name` field (the exported meta object at the top, same shape as this file).',
    '3. Group matches by meta.name; count occurrences per name.',
    '4. List the saved workflow names already present under ~/.claude/workflows/ (basenames minus .js).',
    '5. Flag a name as a candidate when it occurs 2 or more times across sessions AND is NOT already in ~/.claude/workflows/ — that repetition signals real, reusable demand that never got promoted.',
    '',
    'Return candidates: [{name, path (one representative script path), occurrences, already_saved, why}]. already_saved is true only if a matching ~/.claude/workflows/<name>.js already exists (never a candidate in that case — you may still list it with why explaining it is already saved, but still set already_saved=true so it gets filtered downstream). Also return scanned_count = total scripts examined.',
  ].join('\n')
}

function worktreePrompt(sinceIso, devRoot) {
  return [
    'Find git worktrees and recent branches with salvageable, unmerged content.',
    '',
    `Cutoff: prioritize worktrees/branches with activity (last commit or mtime) newer than ${sinceIso}.`,
    `Dev root: ${devRoot}`,
    '',
    'Method:',
    `1. For each git repo under ${devRoot}, list its worktrees (git worktree list) and recent branches (git for-each-ref --sort=-committerdate refs/heads/ with a cutoff around the given date).`,
    '2. For each worktree/branch, digest its content the way worktree-content-digest does: unique commits vs the repo default branch (git log <default>..<branch> --oneline), dirty/uncommitted files (git status --porcelain), and untracked files that look worth keeping vs throwaway (build artifacts, node_modules, .venv, caches, logs are throwaway; source, config, docs are not).',
    '3. Only report a candidate when it has at least one unique commit, dirty tracked change, or non-throwaway untracked file — a clean worktree already merged into default has nothing to salvage.',
    '',
    'Return candidates: [{repo, path, branch, unique_commits, dirty_files, untracked_worth_keeping, why}]. Also return scanned_count = total worktrees/branches examined.',
  ].join('\n')
}

function handoffPrompt(sinceIso) {
  return [
    'Find abandoned handoff notes and specs — work that was written down but never picked back up.',
    '',
    `Cutoff: only consider files newer than ${sinceIso}.`,
    '',
    'Method:',
    '1. Find .cheese/notes/*.md and .cheese/specs/*.md files (across repos reachable from the current session, or the current repo if that is all that is in scope) newer than the cutoff.',
    '2. For each, read the top handoff slug block (status/next/artifact fields, same shape /wheypoint and /cook write).',
    '3. Search for later-modified files (any repo file, especially other .cheese/ slugs) that reference the slug by name or path — a reference means it WAS consumed.',
    '4. Flag a candidate only when no later reference was found — the handoff was written and never followed up on.',
    '',
    'Return candidates: [{slug, path, kind (notes|specs), status, next, why}]. Also return scanned_count = total slugs examined.',
  ].join('\n')
}

function verifyPrompt(candidate) {
  return [
    'Confirm whether this salvage candidate is STILL relevant right now — not already merged, superseded, or promoted since it was found.',
    '',
    `Candidate (JSON): ${JSON.stringify(candidate)}`,
    '',
    'Checks by kind:',
    '- workflow: re-check ~/.claude/workflows/ for a file with this name — if it now exists, still_relevant=false (already promoted).',
    '- branch: re-check whether the branch is now merged into its default branch, or the worktree/branch no longer exists — if so, still_relevant=false.',
    '- handoff: re-check for any file (in this repo or others in scope) that references this slug more recently than the handoff itself, or that shows the described `next` step already happened — if so, still_relevant=false.',
    '',
    'Return still_relevant (boolean), evidence (what you checked and found, with a file path or command output), and reason (one sentence).',
  ].join('\n')
}

function reportPrompt(question, verified) {
  return [
    'Synthesize a ranked salvage report from the verified candidates below. Report only — do not commit, promote, or delete anything; this report just tells the user what to look at.',
    '',
    `Scope: ${question}`,
    '',
    'Verified candidates (JSON):',
    JSON.stringify(verified, null, 2),
    '',
    'Rules:',
    '- One row per candidate: candidate (short name/slug), kind (workflow|branch|handoff), where (path), why_it_matters (one sentence — what would be lost if ignored), suggested_action (one concrete next step, e.g. "cp to ~/.claude/workflows/", "cherry-pick commit X", "resume via /cheese --continue <slug>"). Handoff candidates carry a subtype (notes|specs) — mention it in why_it_matters or suggested_action so the note-vs-spec distinction survives into the report.',
    '- Rank rows by how much would be lost if the candidate is never revisited — most valuable first.',
    '- summary: 2-3 sentences on the overall sweep — how many candidates found, how many verified, any pattern worth naming.',
  ].join('\n')
}

// ── run ───────────────────────────────────────────────────────────────────

const rawArgs = args && typeof args === 'object' ? args : {}
const sinceIso = typeof rawArgs.sinceIso === 'string' ? rawArgs.sinceIso.trim() : ''
const devRoot = typeof rawArgs.devRoot === 'string' && rawArgs.devRoot.trim() ? rawArgs.devRoot.trim() : '~/Dev'

if (!sinceIso) {
  log('No sinceIso provided. Usage: /session-harvest {"sinceIso": "<ISO timestamp>", "devRoot": "~/Dev"} — the cutoff must be supplied by the caller.')
  return { error: 'sinceIso is required — workflow scripts cannot compute the current time themselves.' }
}

phase('Sweep')
log(`Sweeping for salvage since ${sinceIso} under ${devRoot}.`)

const [scriptsResult, worktreeResult, handoffResult] = await parallel([
  () => agent(scriptsPrompt(sinceIso), { schema: WORKFLOW_SCRIPT_SCHEMA, phase: 'Sweep', label: 'scripts', agentType: 'explorer' }),
  () => agent(worktreePrompt(sinceIso, devRoot), { schema: WORKTREE_SCHEMA, phase: 'Sweep', label: 'worktrees', agentType: 'explorer' }),
  () => agent(handoffPrompt(sinceIso), { schema: HANDOFF_SCHEMA, phase: 'Sweep', label: 'handoffs', agentType: 'explorer' }),
])

const merged = []
for (const c of (scriptsResult && scriptsResult.candidates) || []) {
  if (c.already_saved) continue
  merged.push({ kind: 'workflow', name: c.name, where: c.path, occurrences: c.occurrences, why: c.why || '' })
}
for (const c of (worktreeResult && worktreeResult.candidates) || []) {
  merged.push({ kind: 'branch', name: `${c.repo}:${c.branch}`, where: c.path, unique_commits: c.unique_commits, dirty_files: c.dirty_files, why: c.why || '' })
}
for (const c of (handoffResult && handoffResult.candidates) || []) {
  merged.push({ kind: 'handoff', subtype: c.kind, name: c.slug, where: c.path, status: c.status, next: c.next, why: c.why || '' })
}

const scannedScripts = (scriptsResult && scriptsResult.scanned_count) || 0
const scannedWorktrees = (worktreeResult && worktreeResult.scanned_count) || 0
const scannedHandoffs = (handoffResult && handoffResult.scanned_count) || 0
log(`Sweep found ${merged.length} candidate(s) (workflows: ${(scriptsResult && scriptsResult.candidates || []).length}, branches: ${(worktreeResult && worktreeResult.candidates || []).length}, handoffs: ${(handoffResult && handoffResult.candidates || []).length}) across ${scannedScripts + scannedWorktrees + scannedHandoffs} scanned item(s).`)

if (!merged.length) {
  log('Nothing to verify — no salvage candidates found in this sweep.')
  return { since: sinceIso, devRoot, candidates_found: 0, verified_relevant: 0, rows: [], summary: 'No salvage candidates found.' }
}

phase('Verify')
const verdicts = await pipeline(
  merged,
  (candidate) => agent(verifyPrompt(candidate), { schema: VERIFY_SCHEMA, phase: 'Verify', label: `verify:${candidate.kind}:${candidate.name}` }),
)

const verified = merged
  .map((candidate, i) => ({ candidate, verdict: verdicts[i] }))
  .filter(({ verdict }) => verdict && verdict.still_relevant)
  .map(({ candidate, verdict }) => ({ ...candidate, evidence: verdict.evidence, reason: verdict.reason || '' }))

log(`Verified ${verified.length}/${merged.length} candidate(s) as still relevant.`)

if (!verified.length) {
  return { since: sinceIso, devRoot, candidates_found: merged.length, verified_relevant: 0, rows: [], summary: 'All candidates were already promoted, merged, or consumed since the sweep found them.' }
}

phase('Report')
const question = `salvage sweep since ${sinceIso} under ${devRoot}`
const report = await agent(reportPrompt(question, verified), { schema: REPORT_SCHEMA, phase: 'Report', label: 'report' })

return {
  since: sinceIso,
  devRoot,
  candidates_found: merged.length,
  verified_relevant: verified.length,
  rows: (report && report.rows) || [],
  summary: (report && report.summary) || '',
}
