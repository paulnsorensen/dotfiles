// module: stale; provides: SCRATCH_PATH_SRC, SCRATCH_WORKTREE_RE, FULL_SHA_RE, SHA_RE, SHORT_SHA_RE, DIGEST_RE, stampedBy, markersOf, shaErrors, staleVerdict; requires: call
// The runtime creates isolated worktrees under <main checkout>/.claude/worktrees/<id>. cheese-factory also builds SCRATCH_PREFIX_RE from this source.
const SCRATCH_PATH_SRC = String.raw`\/[A-Za-z0-9._/@+-]+\/\.claude\/worktrees\/[A-Za-z0-9._@+-]+`
// The anchored form of SCRATCH_PATH_SRC matches a whole path.
const SCRATCH_WORKTREE_RE = new RegExp(`^${SCRATCH_PATH_SRC}$`)
// A full commit SHA has 40 hex digits in either case.
const FULL_SHA_RE = /^[0-9a-f]{40}$/i
// A move-my-cheese SHA has 7 to 40 hex digits.
const SHA_RE = /^[0-9a-f]{7,40}$/i
// A writer may return a short SHA. A read-only call expands it.
const SHORT_SHA_RE = /^[0-9a-f]{7,16}$/i
// A landing digest has 16 lowercase hex digits.
const DIGEST_RE = /^[0-9a-f]{16}$/
// This approval recorded the PR's current head at the end of an earlier run.
const stampedBy = (p, d) => p.landing_digest === d && p.landing_head === p.head_sha
// Only well-formed markers count; anything else reads as no marker.
function markersOf(pr) {
  const aged = FULL_SHA_RE.test(pr.aged_sha.trim()) && FULL_SHA_RE.test(pr.aged_patch.trim())
  const landing = DIGEST_RE.test(pr.landing_digest.trim())
  return {
    aged_sha: aged ? pr.aged_sha.trim() : '', aged_patch: aged ? pr.aged_patch.trim() : '', aged_dirty: aged && pr.aged_dirty,
    landing_digest: landing ? pr.landing_digest.trim() : '',
    landing_head: landing && FULL_SHA_RE.test(pr.landing_head.trim()) ? pr.landing_head.trim() : '',
  }
}
// Code checks a SHA, not a schema pattern. A bad SHA is always substance: a formatter has no repo access and could only invent one.
// typed() trims the SHA fields in TRIM_FIELDS before a check runs, so a padded SHA in those fields never reaches this test.
const shaErrors = (path, value) =>
  (typeof value === 'string' && FULL_SHA_RE.test(value) ? [] : [substance(`${path} must be a 40-hex commit SHA`)])
// Compares a plan snapshot with the live repo. snapshot is { base, heads: { pr: sha }, files: [plan files] }.
// live is { base, heads }. changedFiles lists the files that changed between the two bases, or null when unknown.
// A moved head or a changed PR set needs a new plan. A moved base needs a new plan only when it touches a plan file.
function staleVerdict(snapshot, live, changedFiles) {
  const reasons = []
  const planned = Object.keys(snapshot.heads).sort()
  const current = Object.keys(live.heads).sort()
  if (planned.join(',') !== current.join(',')) reasons.push(`the PR set is now ${current.join(', ') || 'empty'}, not ${planned.join(', ') || 'empty'}`)
  for (const pr of planned) {
    if (Object.hasOwn(live.heads, pr) && live.heads[pr] !== snapshot.heads[pr]) reasons.push(`#${pr} head moved from ${snapshot.heads[pr]} to ${live.heads[pr]}`)
  }
  if (reasons.length) return { verdict: 'replan', reasons }
  if (snapshot.base === live.base) return { verdict: 'fresh', reasons: [] }
  const moved = `the base moved from ${snapshot.base} to ${live.base}`
  if (!Array.isArray(changedFiles)) return { verdict: 'replan', reasons: [`${moved}; the changed files are unknown`] }
  const hit = changedFiles.filter((f) => snapshot.files.includes(f)).sort()
  if (hit.length) return { verdict: 'replan', reasons: [`${moved}; it changed plan files: ${hit.join(', ')}`] }
  return { verdict: 'rebase', reasons: [`${moved}; it touched no plan file`] }
}
