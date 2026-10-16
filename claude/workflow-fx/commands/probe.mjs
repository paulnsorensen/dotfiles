// wfx probe [--repo <path>] --base <ref> --head <ref>... | --range <old>..<new>
// Conflict mode reports merge conflicts without touching the working tree.
// Range mode lists the paths changed between two refs.
import { resolve } from 'node:path';
import { FxError, badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { mergeTree, resolveCommit } from '../lib/merge.mjs';

function rangeMode(range, repo, ctx) {
  const m = /^(.+?)\.\.(.+)$/.exec(range);
  if (!m || m[2].startsWith('.')) throw badInput(`--range needs <old>..<new>, got: ${range}`);
  const [, oldRef, newRef] = m;
  const oldSha = resolveCommit(ctx, repo, oldRef);
  const newSha = resolveCommit(ctx, repo, newRef);
  const res = ctx.git(['diff', '--name-only', '-z', oldSha, newSha], { cwd: repo });
  if (res.status !== 0) throw new FxError('git-failed', `git diff failed: ${res.stderr.trim()}`);
  return { range, files: res.stdout.split('\0').filter(Boolean) };
}

function conflictMode(flags, repo, ctx) {
  if (!flags.base) throw badInput('probe needs --base <ref>');
  if (flags.head.length === 0) throw badInput('probe needs at least one --head <ref>');
  const base = { ref: flags.base, sha: resolveCommit(ctx, repo, flags.base) };
  const heads = flags.head.map((ref) => ({ ref, sha: resolveCommit(ctx, repo, ref) }));

  const conflicts = [];
  for (const head of heads) {
    const res = mergeTree(ctx, repo, base.sha, head.sha);
    if (!res.clean) conflicts.push({ a: base.ref, b: head.ref, files: res.files });
  }
  for (let i = 0; i < heads.length; i++) {
    for (let j = i + 1; j < heads.length; j++) {
      const res = mergeTree(ctx, repo, heads[i].sha, heads[j].sha);
      if (!res.clean) conflicts.push({ a: heads[i].ref, b: heads[j].ref, files: res.files });
    }
  }
  return { base, heads, conflicts };
}

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['repo', 'base', 'range'], repeat: ['head'] });
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  if (flags.range) {
    if (flags.base || flags.head.length > 0) throw badInput('--range excludes --base and --head');
    return { data: rangeMode(flags.range, repo, ctx) };
  }
  return { data: conflictMode(flags, repo, ctx) };
}
