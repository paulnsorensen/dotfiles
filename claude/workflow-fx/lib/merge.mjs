// Merge helpers that never touch the working tree or HEAD.
// They use `git merge-tree --write-tree`, which needs git >= 2.38.
import { FxError } from './envelope.mjs';

export function resolveCommit(ctx, repo, ref) {
  const res = ctx.git(['rev-parse', '--verify', '--quiet', '--end-of-options', `${ref}^{commit}`], { cwd: repo });
  const sha = res.stdout.trim();
  if (res.status !== 0 || !sha) {
    throw new FxError('unknown-ref', `unknown ref: ${ref}`, { ref });
  }
  return sha;
}

// Returns { clean: true, tree } or { clean: false, files }.
export function mergeTree(ctx, repo, a, b) {
  const res = ctx.git(['merge-tree', '--write-tree', '--name-only', '--no-messages', '-z', a, b], { cwd: repo });
  const parts = res.stdout.split('\0').filter(Boolean);
  if (res.status === 0) return { clean: true, tree: parts[0] };
  if (res.status === 1) return { clean: false, files: [...new Set(parts.slice(1))].sort() };
  throw new FxError('git-failed', `git merge-tree failed: ${res.stderr.trim() || `exit ${res.status}`}`);
}

// Supplies an identity only when the repo has none, so commit-tree always works.
export function identityEnv(ctx, repo) {
  const env = { ...ctx.env };
  const has = (key) => ctx.git(['config', key], { cwd: repo }).stdout.trim() !== '';
  if (!has('user.name')) {
    env.GIT_AUTHOR_NAME ??= 'wfx';
    env.GIT_COMMITTER_NAME ??= 'wfx';
  }
  if (!has('user.email')) {
    env.GIT_AUTHOR_EMAIL ??= 'wfx@localhost';
    env.GIT_COMMITTER_EMAIL ??= 'wfx@localhost';
  }
  return env;
}
