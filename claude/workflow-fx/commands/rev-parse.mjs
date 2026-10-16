// wfx rev-parse [--repo <path>] <sha-prefix>...
// Resolves each prefix to a full commit SHA.
import { resolve } from 'node:path';
import { FxError, badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';

export async function run(argv, ctx) {
  const { flags, positionals } = parseFlags(argv, { value: ['repo'] });
  if (positionals.length === 0) throw badInput('rev-parse needs at least one SHA prefix');
  const repo = resolve(ctx.cwd, flags.repo ?? '.');

  const resolved = {};
  const failures = {};
  for (const prefix of positionals) {
    if (!/^[0-9a-fA-F]{4,64}$/.test(prefix)) {
      failures[prefix] = { reason: 'unknown' };
      continue;
    }
    const res = ctx.git(['rev-parse', '--verify', '--quiet', '--end-of-options', `${prefix}^{commit}`], { cwd: repo });
    if (res.status === 0 && res.stdout.trim()) {
      resolved[prefix] = res.stdout.trim();
      continue;
    }
    const dis = ctx.git(['rev-parse', `--disambiguate=${prefix}`], { cwd: repo });
    const candidates = dis.status === 0 ? dis.stdout.split('\n').filter(Boolean) : [];
    const commits = candidates.filter(
      (sha) => ctx.git(['cat-file', '-t', sha], { cwd: repo }).stdout.trim() === 'commit',
    );
    failures[prefix] = { reason: commits.length > 1 ? 'ambiguous' : 'unknown' };
    if (commits.length > 1) failures[prefix].candidates = commits;
  }

  const bad = Object.keys(failures);
  if (bad.length > 0) {
    throw new FxError('unresolved', `unresolved prefixes: ${bad.join(', ')}`, { prefixes: failures });
  }
  return { data: { shas: resolved } };
}
