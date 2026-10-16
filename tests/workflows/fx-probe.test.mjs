// wfx probe: conflict mode and range mode against real temp repos.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { commitFiles, runWfx, tempRepo } from './fx-kit.mjs';

function git(repo, ...args) {
  const res = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  return res.stdout.trim();
}

const lines = (n, mark) => Array.from({ length: 5 }, (_, i) => (i === 2 ? `${mark}\n` : `l${i}${n}\n`)).join('');
const snapshot = (repo) => [git(repo, 'rev-parse', 'HEAD'), git(repo, 'symbolic-ref', 'HEAD'), git(repo, 'status', '--porcelain')];

// main has shared.txt; a and b edit its middle line; c edits another file.
function fixture(t) {
  const repo = tempRepo(t);
  commitFiles(repo, { 'shared.txt': lines('', 'orig') }, 'add shared');
  git(repo, 'checkout', '-q', '-b', 'a');
  commitFiles(repo, { 'shared.txt': lines('', 'from-a') }, 'a edits');
  git(repo, 'checkout', '-q', 'main');
  git(repo, 'checkout', '-q', '-b', 'b');
  commitFiles(repo, { 'shared.txt': lines('', 'from-b') }, 'b edits');
  git(repo, 'checkout', '-q', 'main');
  git(repo, 'checkout', '-q', '-b', 'c');
  commitFiles(repo, { 'other.txt': 'c\n' }, 'c edits');
  git(repo, 'checkout', '-q', 'main');
  return repo;
}

test('AC-12: overlapping heads conflict and name the file', (t) => {
  const repo = fixture(t);
  const before = snapshot(repo);
  const { status, json } = runWfx(['probe', '--base', 'main', '--head', 'a', '--head', 'b'], { cwd: repo });
  assert.equal(status, 0);
  assert.equal(json.ok, true);
  assert.deepEqual(json.data.conflicts, [{ a: 'a', b: 'b', files: ['shared.txt'] }]);
  assert.equal(json.data.base.ref, 'main');
  assert.equal(json.data.base.sha, git(repo, 'rev-parse', 'main'));
  assert.deepEqual(json.data.heads.map((h) => h.ref), ['a', 'b']);
  assert.deepEqual(snapshot(repo), before);
});

test('AC-12: non-overlapping heads report no conflict', (t) => {
  const repo = fixture(t);
  const { status, json } = runWfx(['probe', '--base', 'main', '--head', 'a', '--head', 'c'], { cwd: repo });
  assert.equal(status, 0);
  assert.deepEqual(json.data.conflicts, []);
});

test('AC-12: head against base reports a conflict when base moved', (t) => {
  const repo = fixture(t);
  git(repo, 'checkout', '-q', '-b', 'moved', 'main');
  commitFiles(repo, { 'shared.txt': lines('', 'from-moved') }, 'moved edits');
  const { status, json } = runWfx(['probe', '--repo', repo, '--base', 'moved', '--head', 'a'], { cwd: '/' });
  assert.equal(status, 0);
  assert.deepEqual(json.data.conflicts, [{ a: 'moved', b: 'a', files: ['shared.txt'] }]);
  assert.equal(git(repo, 'symbolic-ref', 'HEAD'), 'refs/heads/moved');
});

test('range mode lists changed paths', (t) => {
  const repo = fixture(t);
  const { status, json } = runWfx(['probe', '--range', 'main..a'], { cwd: repo });
  assert.equal(status, 0);
  assert.deepEqual(json.data, { range: 'main..a', files: ['shared.txt'] });
  const same = runWfx(['probe', '--range', 'main..main'], { cwd: repo });
  assert.deepEqual(same.json.data.files, []);
});

test('unknown ref is an operation failure naming the ref', (t) => {
  const repo = fixture(t);
  const head = runWfx(['probe', '--base', 'main', '--head', 'nope'], { cwd: repo });
  assert.equal(head.status, 1);
  assert.equal(head.json.error.code, 'unknown-ref');
  assert.match(head.json.error.message, /nope/);
  const range = runWfx(['probe', '--range', 'main..ghost'], { cwd: repo });
  assert.equal(range.status, 1);
  assert.equal(range.json.error.code, 'unknown-ref');
});

test('missing or malformed flags are bad input', (t) => {
  const repo = fixture(t);
  for (const args of [['probe'], ['probe', '--base', 'main'], ['probe', '--head', 'a'], ['probe', '--range', 'main'], ['probe', '--range', 'main..a', '--base', 'main']]) {
    const res = runWfx(args, { cwd: repo });
    assert.equal(res.status, 2, args.join(' '));
    assert.equal(res.json.error.code, 'bad-input');
  }
});
