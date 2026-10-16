// wfx pr create   [--repo-slug owner/name] --base <b> --head <b> --title <t> --body-file <f>
// wfx pr retarget  --pr N --base <b>
// wfx pr comment   --pr N --body-file <f>
// create returns { number, url }. The body always comes from a file, never from the command line.
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { badInput } from '../lib/envelope.mjs';
import { assertPr, ghOrThrow } from '../lib/gh.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertBranch } from '../lib/push.mjs';

const SLUG_RE = /^[\w.-]+\/[\w.-]+$/;
const MAX_TITLE = 256;

function need(flags, ...names) {
  for (const name of names) {
    if (!flags[name]) throw badInput(`pr needs --${name}`);
  }
}

function bodyFile(ctx, value) {
  const path = resolve(ctx.cwd, value);
  if (!existsSync(path)) throw badInput(`--body-file does not exist: ${path}`);
  return path;
}

function create(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['repo-slug', 'base', 'head', 'title', 'body-file'] });
  need(flags, 'base', 'head', 'title', 'body-file');
  const slug = flags['repo-slug'];
  if (slug !== undefined && !SLUG_RE.test(slug)) throw badInput('--repo-slug must be owner/name');
  const base = assertBranch(flags.base);
  const head = assertBranch(flags.head);
  if (flags.title.includes('\n') || flags.title.length > MAX_TITLE) {
    throw badInput(`--title must be one line of at most ${MAX_TITLE} characters`);
  }
  const file = bodyFile(ctx, flags['body-file']);
  const repoArgs = slug ? ['--repo', slug] : [];
  const out = ghOrThrow(ctx, ['pr', 'create', ...repoArgs, '--base', base, '--head', head, '--title', flags.title, '--body-file', file], 'pr-create-failed');
  const url = out.trim().split('\n').pop().trim();
  const match = /\/pull\/([1-9][0-9]*)$/.exec(url);
  if (!match) throw badInput(`gh pr create printed no PR URL: ${out.trim()}`);
  return { data: { number: Number(match[1]), url } };
}

function retarget(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['pr', 'base'] });
  need(flags, 'pr', 'base');
  const pr = assertPr(flags.pr);
  const base = assertBranch(flags.base);
  ghOrThrow(ctx, ['pr', 'edit', pr, '--base', base], 'pr-retarget-failed');
  return { data: { pr: Number(pr), base } };
}

function comment(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['pr', 'body-file'] });
  need(flags, 'pr', 'body-file');
  const pr = assertPr(flags.pr);
  const file = bodyFile(ctx, flags['body-file']);
  ghOrThrow(ctx, ['pr', 'comment', pr, '--body-file', file], 'pr-comment-failed');
  return { data: { pr: Number(pr), commented: true } };
}

export async function run(argv, ctx) {
  const sub = argv[0];
  const rest = argv.slice(1);
  if (sub === 'create') return create(rest, ctx);
  if (sub === 'retarget') return retarget(rest, ctx);
  if (sub === 'comment') return comment(rest, ctx);
  throw badInput('usage: wfx pr create|retarget|comment');
}
