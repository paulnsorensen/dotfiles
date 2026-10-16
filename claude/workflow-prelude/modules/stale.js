// module: stale; provides: SCRATCH_PATH_SRC, SCRATCH_WORKTREE_RE, FULL_SHA_RE; requires: none
// The runtime creates isolated worktrees under <main checkout>/.claude/worktrees/<id>. cheese-factory also builds SCRATCH_PREFIX_RE from this source.
const SCRATCH_PATH_SRC = String.raw`\/[A-Za-z0-9._/@+-]+\/\.claude\/worktrees\/[A-Za-z0-9._@+-]+`
// The anchored form of SCRATCH_PATH_SRC matches a whole path.
const SCRATCH_WORKTREE_RE = new RegExp(`^${SCRATCH_PATH_SRC}$`)
// A full commit SHA has 40 hex digits in either case.
const FULL_SHA_RE = /^[0-9a-f]{40}$/i
