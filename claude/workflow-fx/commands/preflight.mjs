// wfx preflight [--python <path>] [--worktree <path>]... [--need <csv>]
// Checks that the tools and paths a workflow needs are ready.
import { accessSync, constants, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { delimiter, join, resolve } from 'node:path';
import { FxError, badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';

const KNOWN = ['git', 'node', 'wfx', 'gh', 'pytest'];

function findOnPath(name, env) {
  for (const dir of (env.PATH ?? '').split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, name);
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // not here; try the next directory
    }
  }
  return null;
}

function versionCheck(name, ctx) {
  const res = ctx.run(name, ['--version'], { cwd: ctx.cwd, env: ctx.env });
  const line = res.stdout.split('\n')[0].trim();
  return res.status === 0
    ? { name, ok: true, detail: line }
    : { name, ok: false, detail: res.stderr.trim() || `${name} not runnable` };
}

function worktreeCheck(path, ctx) {
  const name = `worktree:${path}`;
  const abs = resolve(ctx.cwd, path);
  let dir;
  try {
    if (!statSync(abs).isDirectory()) return { name, ok: false, detail: 'not a directory' };
    dir = mkdtempSync(join(abs, '.wfx-preflight-'));
    writeFileSync(join(dir, 'probe'), 'ok');
    return { name, ok: true, detail: 'writable' };
  } catch (err) {
    return { name, ok: false, detail: err.code === 'ENOENT' ? 'does not exist' : `not writable: ${err.code ?? err.message}` };
  } finally {
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
}

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['python', 'need'], repeat: ['worktree'] });
  const python = flags.python ?? 'python3';
  const need = (flags.need ?? KNOWN.join(',')).split(',').map((s) => s.trim()).filter(Boolean);
  for (const n of need) {
    if (!KNOWN.includes(n)) throw badInput(`unknown --need entry: ${n}`, { known: KNOWN });
  }

  const checks = [];
  for (const n of need) {
    if (n === 'git' || n === 'node') {
      checks.push(versionCheck(n, ctx));
    } else if (n === 'wfx') {
      const found = findOnPath('wfx', ctx.env);
      checks.push({ name: 'wfx', ok: found !== null, detail: found ?? 'wfx not found on PATH' });
    } else if (n === 'gh') {
      const res = ctx.gh(['auth', 'status'], { cwd: ctx.cwd, env: ctx.env });
      checks.push({ name: 'gh', ok: res.status === 0, detail: res.status === 0 ? 'authenticated' : (res.stderr.trim() || 'gh auth status failed') });
    } else if (n === 'pytest') {
      const res = ctx.run(python, ['-c', 'import pytest'], { cwd: ctx.cwd, env: ctx.env });
      checks.push({ name: 'pytest', ok: res.status === 0, detail: res.status === 0 ? `${python} imports pytest` : (res.stderr.trim() || `${python} cannot import pytest`) });
    }
  }
  for (const path of flags.worktree) checks.push(worktreeCheck(path, ctx));

  const failed = checks.filter((c) => !c.ok);
  if (failed.length > 0) {
    throw new FxError('preflight-failed', `preflight failed: ${failed.map((c) => c.name).join(', ')}`, { checks });
  }
  return { data: { checks } };
}
