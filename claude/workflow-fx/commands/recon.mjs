// wfx recon --prs <n,n,...> [--repo-slug owner/name]
// Reads number, head, base, state, and mergeable state per PR, plus the base branch SHA.
// gh-pr-batch omits the head SHA, so recon calls `gh pr view` with headRefOid directly.
import { FxError, badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';

const FIELDS = 'number,state,mergeable,headRefName,headRefOid,baseRefName';

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['prs', 'repo-slug'] });
  if (!flags.prs) throw badInput('recon needs --prs');
  const slug = flags['repo-slug'];
  if (slug !== undefined && !/^[\w.-]+\/[\w.-]+$/.test(slug)) throw badInput('--repo-slug must be owner/name');
  const numbers = flags.prs.split(',').map((n) => assertPr(n.trim(), 'prs'));
  const repoArgs = slug ? ['--repo', slug] : [];

  const prs = numbers.map((n) => {
    const raw = ghOrThrow(ctx, ['pr', 'view', n, ...repoArgs, '--json', FIELDS]);
    const v = JSON.parse(raw);
    return {
      number: v.number,
      head: { ref: v.headRefName, sha: v.headRefOid },
      base: v.baseRefName,
      state: v.state,
      mergeable: v.mergeable,
    };
  });

  const baseRefs = [...new Set(prs.map((p) => p.base))];
  if (baseRefs.length !== 1) {
    throw new FxError('mixed-bases', `PRs target different base branches: ${baseRefs.join(', ')}`, { bases: baseRefs });
  }
  const sha = ghOrThrow(ctx, ['api', `repos/${slug ?? '{owner}/{repo}'}/commits/${baseRefs[0]}`, '--jq', '.sha']).trim();
  return { data: { prs, base: { ref: baseRefs[0], sha } } };
}
