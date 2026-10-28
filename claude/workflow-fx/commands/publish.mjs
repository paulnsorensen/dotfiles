// wfx publish --repo <path> --branch <b> --sha <sha> --expect <sha|none>
// Pushes sha to origin refs/heads/<b> with a lease pinned to expect.
import { resolve } from 'node:path';
import { badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertBranch, assertSha, leasedPush } from '../lib/push.mjs';

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['repo', 'branch', 'sha', 'expect'] });
  for (const need of ['branch', 'sha', 'expect']) {
    if (!flags[need]) throw badInput(`publish needs --${need}`);
  }
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  const branch = assertBranch(flags.branch);
  const sha = assertSha(flags.sha);
  if (flags.expect !== 'none') assertSha(flags.expect, 'expect');
  leasedPush(ctx, repo, { branch, sha, expect: flags.expect });
  return { data: { branch, sha, expect: flags.expect, pushed: true } };
}
