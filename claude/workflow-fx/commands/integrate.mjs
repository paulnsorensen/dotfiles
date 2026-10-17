// wfx integrate [--repo <path>] --branch <b> --base <ref> --target <ref>
// wfx integrate [--repo <path>] --plan <file|->   (JSON: {branch, base, targets: [ref...]})
// Merges targets into an integration branch with real merge commits.
// It uses merge-tree, commit-tree, and update-ref. It never touches the working tree.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { FxError, badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { identityEnv, mergeTree, resolveCommit } from '../lib/merge.mjs';

const isRef = (v) => typeof v === 'string' && v.length > 0 && !v.startsWith('-');

function readPlan(source, cwd) {
  let text;
  try {
    text = readFileSync(source === '-' ? 0 : resolve(cwd, source), 'utf8');
  } catch (err) {
    throw badInput(`cannot read plan: ${err.message}`);
  }
  let plan;
  try {
    plan = JSON.parse(text);
  } catch (err) {
    throw badInput(`plan is not valid JSON: ${err.message}`);
  }
  const ok =
    plan && typeof plan === 'object' && !Array.isArray(plan) &&
    isRef(plan.branch) && isRef(plan.base) &&
    Array.isArray(plan.targets) && plan.targets.length > 0 && plan.targets.every(isRef);
  if (!ok) throw badInput('plan must be {branch: string, base: string, targets: [string, ...]} with at least one target');
  return plan;
}

function ensureBranch(ctx, repo, branch, base) {
  if (ctx.git(['check-ref-format', '--branch', branch], { cwd: repo }).status !== 0) {
    throw badInput(`invalid branch name: ${branch}`);
  }
  const ref = `refs/heads/${branch}`;
  // Any linked worktree can hold the branch, so the list covers more than the current HEAD.
  const listed = ctx.git(['worktree', 'list', '--porcelain'], { cwd: repo }).stdout.split('\n');
  const head = ctx.git(['symbolic-ref', '-q', 'HEAD'], { cwd: repo }).stdout.trim();
  if (head === ref || listed.includes(`branch ${ref}`)) {
    throw new FxError('branch-checked-out', `branch is checked out: ${branch}`, { branch });
  }
  const sha = resolveCommit(ctx, repo, base);
  const existing = ctx.git(['rev-parse', '--verify', '--quiet', ref], { cwd: repo });
  if (existing.status === 0) {
    const tip = existing.stdout.trim();
    if (ctx.git(['merge-base', '--is-ancestor', sha, tip], { cwd: repo }).status !== 0) {
      throw new FxError('base-not-contained', `branch ${branch} does not contain base ${base}`, { branch, base, sha: tip });
    }
    return { ref, sha: tip };
  }
  const made = ctx.git(['update-ref', ref, sha, ''], { cwd: repo });
  if (made.status !== 0) throw new FxError('git-failed', `cannot create ${branch}: ${made.stderr.trim()}`);
  return { ref, sha };
}

function integrate(ctx, repo, { branch, base, targets }) {
  const shas = targets.map((t) => resolveCommit(ctx, repo, t));
  const { ref, sha: start } = ensureBranch(ctx, repo, branch, base);
  const env = identityEnv(ctx, repo);
  let current = start;
  const integrated = [];

  for (let i = 0; i < targets.length; i++) {
    const contained = ctx.git(['merge-base', '--is-ancestor', shas[i], current], { cwd: repo });
    if (contained.status === 0) {
      integrated.push(targets[i]);
      continue;
    }
    const merged = mergeTree(ctx, repo, current, shas[i]);
    if (!merged.clean) {
      throw new FxError('conflict', `merge conflict integrating ${targets[i]}`, {
        integrated,
        conflict: { target: targets[i], files: merged.files },
        sha: current,
      });
    }
    const commit = ctx.git(
      ['commit-tree', merged.tree, '-p', current, '-p', shas[i], '-m', `wfx integrate ${targets[i]}`],
      { cwd: repo, env },
    );
    const next = commit.stdout.trim();
    if (commit.status !== 0 || !next) throw new FxError('git-failed', `commit-tree failed: ${commit.stderr.trim()}`);
    const moved = ctx.git(['update-ref', ref, next, current], { cwd: repo });
    if (moved.status !== 0) throw new FxError('git-failed', `update-ref failed: ${moved.stderr.trim()}`);
    current = next;
    integrated.push(targets[i]);
  }
  return { branch, sha: current, integrated };
}

export async function run(argv, ctx) {
  const { flags } = parseFlags(argv, { value: ['repo', 'branch', 'base', 'target', 'plan'] });
  const repo = resolve(ctx.cwd, flags.repo ?? '.');
  if (flags.plan) {
    if (flags.branch || flags.base || flags.target) throw badInput('--plan excludes --branch, --base, and --target');
    return { data: integrate(ctx, repo, readPlan(flags.plan, ctx.cwd)) };
  }
  for (const name of ['branch', 'base', 'target']) {
    if (!isRef(flags[name])) throw badInput(`integrate needs --${name} <value> or --plan`);
  }
  return { data: integrate(ctx, repo, { branch: flags.branch, base: flags.base, targets: [flags.target] }) };
}
