// spawnSync wrappers. Arguments pass as an array; no shell is involved.
import { spawnSync } from 'node:child_process';

export function run(cmd, args = [], opts = {}) {
  const res = spawnSync(cmd, args, {
    cwd: opts.cwd,
    env: opts.env ?? process.env,
    input: opts.input,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  if (res.error) {
    return { status: 127, stdout: '', stderr: res.error.message };
  }
  return { status: res.status ?? 1, stdout: res.stdout ?? '', stderr: res.stderr ?? '' };
}

export function git(args, opts = {}) {
  return run('git', args, opts);
}

export function gh(args, opts = {}) {
  return run('gh', args, opts);
}
