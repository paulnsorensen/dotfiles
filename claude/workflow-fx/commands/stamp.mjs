// wfx stamp --pr N --marker <digest> --sha <head>
// Posts the landing marker comment once. The format matches landingMarker() in move-my-cheese.js:
//   <!-- move-my-cheese:landing digest=<16 hex> head=<40 hex> -->
import { badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertSha } from '../lib/push.mjs';

const LANDING_PREFIX = 'move-my-cheese:landing';
const DIGEST_RE = /^[0-9a-f]{16}$/;

export const landingMarker = (digest, head = '') =>
  `<!-- ${LANDING_PREFIX} digest=${digest}${head ? ` head=${head}` : ''} -->`;

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['pr', 'marker', 'sha'] });
  for (const need of ['pr', 'marker', 'sha']) {
    if (!flags[need]) throw badInput(`stamp needs --${need}`);
  }
  const pr = assertPr(flags.pr);
  if (!DIGEST_RE.test(flags.marker)) throw badInput('--marker must be a 16-hex landing digest');
  const sha = assertSha(flags.sha);
  const text = landingMarker(flags.marker, sha);

  const out = ghOrThrow(ctx, ['pr', 'view', pr, '--json', 'comments', '--jq', '[.comments[].body]']);
  let bodies;
  try {
    bodies = JSON.parse(out || '[]');
  } catch {
    throw badInput('gh returned comments that are not JSON');
  }
  if (bodies.some((b) => typeof b === 'string' && b.includes(text))) {
    return { data: { stamped: false, existing: true } };
  }
  ghOrThrow(ctx, ['pr', 'comment', pr, '--body', text]);
  return { data: { stamped: true } };
}
