// Shared input checks and the leased push used by restack and publish.
import { FxError, badInput } from './envelope.mjs';

const SHA_RE = /^[0-9a-f]{40}$/;

export function assertBranch(branch) {
  if (typeof branch !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(branch) || branch.includes('..')) {
    throw badInput(`invalid branch name: ${branch}`);
  }
  return branch;
}

export function assertSha(sha, label = 'sha') {
  if (typeof sha !== 'string' || !SHA_RE.test(sha)) {
    throw badInput(`${label} must be a full 40-hex SHA`);
  }
  return sha;
}

// expect: a full SHA, or 'none' when the remote branch must not exist.
// The lease pins the remote branch to expect; any other remote head refuses the push.
export function leasedPush(ctx, repo, { branch, sha, expect }) {
  const pinned = expect === 'none' ? '' : assertSha(expect, 'expect');
  const res = ctx.git(
    ['push', `--force-with-lease=refs/heads/${branch}:${pinned}`, 'origin', `${sha}:refs/heads/${branch}`],
    { cwd: repo, env: ctx.env },
  );
  if (res.status === 0) return;
  const stderr = res.stderr.trim();
  const code = /stale info|rejected|fetch first|non-fast-forward/i.test(stderr) ? 'lease-rejected' : 'push-failed';
  throw new FxError(code, `push of ${branch} failed: ${stderr}`, { branch, sha, expect, stderr });
}
