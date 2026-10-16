// wfx restack --repo <path> --branch <b> --onto <ref> [--from <old-base>] [--push] [--expect <sha>]
// wfx restack --stack [--repo <path>] [-- <gh stack rebase flags>]
// Rebases b onto a ref inside a temporary worktree. The caller's checkout stays untouched.
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FxError, badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertBranch, assertSha, leasedPush } from '../lib/push.mjs';

const STACK_REBASE = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'bin', 'gh-stack-rebase');

function revParse(ctx, repo, rev) {
  const res = ctx.git(['rev-parse', '--verify', '--quiet', '--end-of-options', `${rev}^{commit}`], { cwd: repo });
  if (res.status !== 0 || !res.stdout.trim()) throw new FxError('not-found', `cannot resolve ${rev}`, { rev });
  return res.stdout.trim();
}

function checkedOutBranches(ctx, repo) {
  const res = ctx.git(['worktree', 'list', '--porcelain'], { cwd: repo });
  return new Set(res.stdout.split('\n').filter((l) => l.startsWith('branch ')).map((l) => l.slice(7)));
}

function stackMode(argv, ctx) {
  const { flags, positionals } = parseFlags(argv, { value: ['repo'], bool: ['stack'] });
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  const res = ctx.run(STACK_REBASE, positionals, { cwd: repo, env: ctx.env });
  const out = { status: res.status, stdout: res.stdout, stderr: res.stderr };
  if (res.status !== 0) throw new FxError('stack-rebase-failed', `gh-stack-rebase exited ${res.status}`, out);
  return { data: out };
}

export async function run(argv, ctx) {
  if (argv.includes('--stack')) return stackMode(argv, ctx);
  const { flags } = parseFlags(argv, { value: ['repo', 'branch', 'onto', 'from', 'expect'], bool: ['push'] });
  if (!flags.branch) throw badInput('restack needs --branch');
  if (!flags.onto) throw badInput('restack needs --onto');
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  const branch = assertBranch(flags.branch);
  if (flags.expect) assertSha(flags.expect, 'expect');

  const old = revParse(ctx, repo, `refs/heads/${branch}`);
  const onto = revParse(ctx, repo, flags.onto);
  const from = flags.from
    ? revParse(ctx, repo, flags.from)
    : ctx.git(['merge-base', old, onto], { cwd: repo }).stdout.trim();
  if (!from) throw new FxError('no-merge-base', `no merge base for ${branch} and ${flags.onto}`);

  const scratch = mkdtempSync(join(tmpdir(), 'wfx-restack-'));
  const wt = join(scratch, 'wt');
  let next;
  try {
    const add = ctx.git(['worktree', 'add', '--detach', wt, old], { cwd: repo });
    if (add.status !== 0) throw new FxError('worktree-failed', add.stderr.trim());
    const env = { ...ctx.env, GIT_EDITOR: 'true' };
    const reb = ctx.git(['rebase', '--onto', onto, from], { cwd: wt, env });
    if (reb.status !== 0) {
      const files = ctx.git(['diff', '--name-only', '--diff-filter=U'], { cwd: wt }).stdout.split('\n').filter(Boolean);
      ctx.git(['rebase', '--abort'], { cwd: wt });
      throw new FxError('conflict', `rebase of ${branch} onto ${flags.onto} conflicts`, { files, stderr: reb.stderr.trim() });
    }
    next = ctx.git(['rev-parse', 'HEAD'], { cwd: wt }).stdout.trim();
  } finally {
    ctx.git(['worktree', 'remove', '--force', wt], { cwd: repo });
    ctx.git(['worktree', 'prune'], { cwd: repo });
    rmSync(scratch, { recursive: true, force: true });
  }

  // A branch that another checkout holds keeps its ref, so no checkout drifts from its HEAD.
  const held = checkedOutBranches(ctx, repo).has(`refs/heads/${branch}`);
  let localUpdated = false;
  if (!held && next !== old) {
    const upd = ctx.git(['update-ref', `refs/heads/${branch}`, next, old], { cwd: repo });
    if (upd.status !== 0) throw new FxError('ref-update-failed', upd.stderr.trim());
    localUpdated = true;
  }

  let pushed = false;
  if (flags.push) {
    leasedPush(ctx, repo, { branch, sha: next, expect: flags.expect ?? old });
    pushed = true;
  }
  return { data: { branch, old, new: next, pushed, localUpdated } };
}
