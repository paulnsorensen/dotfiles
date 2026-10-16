// wfx worktree add    --repo <path> --landing <id> --name <n> --ref <ref>
// wfx worktree remove --repo <path> --path <p>   (any worktree that git lists below the scratch root)
// wfx worktree list   --repo <path> [--landing <id>]
// Worktrees live under <main checkout>/.claude/worktrees, the scratch root that the workflow
// stale module (SCRATCH_PATH_SRC) accepts. SCRATCH_WORKTREE_RE allows one path segment under the root,
// so the directory name is <landing>@<name>. An '@' never occurs in an id, so the split is exact.
import { dirname, join, resolve } from 'node:path';
import { FxError, badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertId } from '../lib/ids.mjs';

function scratchRoot(ctx, repo) {
  const res = ctx.git(['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: repo });
  if (res.status !== 0) throw new FxError('not-a-repo', `not a git repository: ${repo}`, { stderr: res.stderr.trim() });
  return join(dirname(res.stdout.trim()), '.claude', 'worktrees');
}

function listUnder(ctx, repo, root) {
  const res = ctx.git(['worktree', 'list', '--porcelain'], { cwd: repo });
  const out = [];
  for (const block of res.stdout.split('\n\n')) {
    const lines = block.split('\n');
    const path = lines.find((l) => l.startsWith('worktree '))?.slice(9);
    if (!path || dirname(path) !== root) continue;
    const dir = path.slice(root.length + 1);
    const at = dir.indexOf('@');
    if (at === -1) continue;
    out.push({
      path,
      landing: dir.slice(0, at),
      name: dir.slice(at + 1),
      head: lines.find((l) => l.startsWith('HEAD '))?.slice(5) ?? '',
      branch: lines.find((l) => l.startsWith('branch '))?.slice(7) ?? null,
    });
  }
  return out;
}

// Every worktree that git lists below the scratch root, whatever its name.
// remove uses it, so it also cleans worktrees that the runtime made without a landing id.
function registeredUnder(ctx, repo, root) {
  const res = ctx.git(['worktree', 'list', '--porcelain'], { cwd: repo });
  return res.stdout
    .split('\n')
    .filter((l) => l.startsWith('worktree '))
    .map((l) => l.slice(9))
    .filter((p) => p.startsWith(`${root}/`));
}

export async function run(argv, ctx) {
  const sub = argv[0];
  const rest = argv.slice(1);
  if (sub === 'add') return add(rest, ctx);
  if (sub === 'remove') return remove(rest, ctx);
  if (sub === 'list') return list(rest, ctx);
  throw badInput('usage: wfx worktree add|remove|list');
}

function add(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['repo', 'landing', 'name', 'ref'] });
  for (const need of ['landing', 'name', 'ref']) {
    if (!flags[need]) throw badInput(`worktree add needs --${need}`);
  }
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  const landing = assertId(flags.landing, 'landing');
  const name = assertId(flags.name, 'name');
  const root = scratchRoot(ctx, repo);
  const path = join(root, `${landing}@${name}`);
  // A ref with a leading dash would parse as a git option. The rev-parse check also proves the ref names a commit.
  if (flags.ref.startsWith('-')) throw badInput(`invalid --ref: ${flags.ref}`);
  const found = ctx.git(['rev-parse', '--verify', '--quiet', '--end-of-options', `${flags.ref}^{commit}`], { cwd: repo });
  const sha = found.stdout.trim();
  if (found.status !== 0 || !sha) throw new FxError('worktree-failed', `cannot resolve ${flags.ref}`, { ref: flags.ref });
  const res = ctx.git(['worktree', 'add', '--detach', path, sha], { cwd: repo });
  if (res.status !== 0) throw new FxError('worktree-failed', res.stderr.trim(), { path });
  const head = ctx.git(['rev-parse', 'HEAD'], { cwd: path }).stdout.trim();
  return { data: { path, landing, name, head } };
}

function remove(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['repo', 'path'] });
  if (!flags.path) throw badInput('worktree remove needs --path');
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  const root = scratchRoot(ctx, repo);
  const path = resolve(ctx.cwd, flags.path);
  if (!registeredUnder(ctx, repo, root).includes(path)) {
    throw badInput(`not a registered worktree under ${root}: ${path}`);
  }
  const res = ctx.git(['worktree', 'remove', '--force', path], { cwd: repo });
  if (res.status !== 0) throw new FxError('worktree-failed', res.stderr.trim(), { path });
  return { data: { path, removed: true } };
}

function list(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['repo', 'landing'] });
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  if (flags.landing !== undefined) assertId(flags.landing, 'landing');
  const root = scratchRoot(ctx, repo);
  const worktrees = listUnder(ctx, repo, root).filter((w) => flags.landing === undefined || w.landing === flags.landing);
  return { data: { root, worktrees } };
}
