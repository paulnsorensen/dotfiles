// wfx integrate: merge-commit integration without touching the caller's checkout.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { WFX, commitFiles, runWfx, tempDir, tempRepo } from './fx-kit.mjs';

function git(repo, ...args) {
  const res = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  return res.stdout.trim();
}

const body = (mark) => ['l0', 'l1', mark, 'l3', 'l4'].map((l) => `${l}\n`).join('');
const snapshot = (repo) => [git(repo, 'rev-parse', 'HEAD'), git(repo, 'symbolic-ref', 'HEAD'), git(repo, 'status', '--porcelain')];

// t1 and t3 edit shared.txt differently; t2 adds a file. All branch from main.
function fixture(t) {
  const repo = tempRepo(t);
  commitFiles(repo, { 'shared.txt': body('orig') }, 'add shared');
  const make = (name, files) => {
    git(repo, 'checkout', '-q', '-b', name, 'main');
    commitFiles(repo, files, `${name} work`);
    git(repo, 'checkout', '-q', 'main');
  };
  make('t1', { 'shared.txt': body('one') });
  make('t2', { 'two.txt': '2\n' });
  make('t3', { 'shared.txt': body('three') });
  return repo;
}

const parents = (repo, ref) => git(repo, 'rev-list', '--parents', '-n', '1', ref).split(' ').slice(1);

test('single target creates the branch at base and merges with two parents', (t) => {
  const repo = fixture(t);
  const before = snapshot(repo);
  const main = git(repo, 'rev-parse', 'main');
  const { status, json } = runWfx(['integrate', '--branch', 'int', '--base', 'main', '--target', 't1'], { cwd: repo });
  assert.equal(status, 0);
  assert.equal(json.ok, true);
  assert.deepEqual(json.data.integrated, ['t1']);
  assert.equal(json.data.branch, 'int');
  assert.equal(json.data.sha, git(repo, 'rev-parse', 'int'));
  assert.deepEqual(parents(repo, 'int'), [main, git(repo, 'rev-parse', 't1')]);
  assert.equal(git(repo, 'log', '-1', '--format=%s', 'int'), 'wfx integrate t1');
  assert.equal(git(repo, 'show', 'int:shared.txt'), body('one').trim());
  assert.deepEqual(snapshot(repo), before);
});

test('re-integrating the same target is a no-op that still counts', (t) => {
  const repo = fixture(t);
  const args = ['integrate', '--branch', 'int', '--base', 'main', '--target', 't1'];
  const first = runWfx(args, { cwd: repo });
  const second = runWfx(args, { cwd: repo });
  assert.equal(second.status, 0);
  assert.equal(second.json.data.sha, first.json.data.sha);
  assert.deepEqual(second.json.data.integrated, ['t1']);
});

test('AC-13: plan stops at the first conflict and keeps the last clean merge', (t) => {
  const repo = fixture(t);
  const before = snapshot(repo);
  const planFile = join(tempDir(t), 'plan.json');
  writeFileSync(planFile, JSON.stringify({ branch: 'int', base: 'main', targets: ['t1', 't2', 't3'] }));
  const { status, json } = runWfx(['integrate', '--repo', repo, '--plan', planFile], { cwd: '/' });
  assert.equal(status, 1);
  assert.equal(json.ok, false);
  assert.equal(json.error.code, 'conflict');
  const d = json.error.details;
  assert.deepEqual(d.integrated, ['t1', 't2']);
  assert.deepEqual(d.conflict, { target: 't3', files: ['shared.txt'] });
  assert.equal(d.sha, git(repo, 'rev-parse', 'int'));
  assert.equal(git(repo, 'log', '-1', '--format=%s', 'int'), 'wfx integrate t2');
  git(repo, 'merge-base', '--is-ancestor', 't2', 'int');
  assert.equal(spawnSync('git', ['merge-base', '--is-ancestor', 't3', 'int'], { cwd: repo }).status, 1);
  assert.deepEqual(snapshot(repo), before);
});

test('plan from stdin integrates all clean targets', (t) => {
  const repo = fixture(t);
  const res = spawnSync(WFX, ['integrate', '--plan', '-'], {
    cwd: repo,
    encoding: 'utf8',
    input: JSON.stringify({ branch: 'int', base: 'main', targets: ['t1', 't2'] }),
  });
  assert.equal(res.status, 0, res.stderr);
  const json = JSON.parse(res.stdout);
  assert.deepEqual(json.data.integrated, ['t1', 't2']);
  assert.equal(git(repo, 'show', 'int:two.txt'), '2');
});

test('bad plan JSON and bad shapes are bad input', (t) => {
  const repo = fixture(t);
  const dir = tempDir(t);
  const cases = ['{not json', '[]', '{"branch":"int","base":"main"}', '{"branch":"int","base":"main","targets":[]}', '{"branch":"int","base":"main","targets":[1]}', '{"branch":5,"base":"main","targets":["t1"]}'];
  cases.forEach((text, i) => {
    const file = join(dir, `p${i}.json`);
    writeFileSync(file, text);
    const res = runWfx(['integrate', '--plan', file], { cwd: repo });
    assert.equal(res.status, 2, text);
    assert.equal(res.json.error.code, 'bad-input');
  });
  const missing = runWfx(['integrate', '--branch', 'int'], { cwd: repo });
  assert.equal(missing.status, 2);
  assert.equal(git(repo, 'branch', '--list', 'int'), '');
});

test('unknown target is an operation failure', (t) => {
  const repo = fixture(t);
  const res = runWfx(['integrate', '--branch', 'int', '--base', 'main', '--target', 'ghost'], { cwd: repo });
  assert.equal(res.status, 1);
  assert.equal(res.json.error.code, 'unknown-ref');
  assert.equal(git(repo, 'branch', '--list', 'int'), '');
});

test('a checked-out integration branch is refused', (t) => {
  const repo = fixture(t);
  const res = runWfx(['integrate', '--branch', 'main', '--base', 'main', '--target', 't1'], { cwd: repo });
  assert.equal(res.status, 1);
  assert.equal(res.json.error.code, 'branch-checked-out');
});
