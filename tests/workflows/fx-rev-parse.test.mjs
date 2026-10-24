import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { commitFiles, runWfx, tempRepo } from './fx-kit.mjs';

test('resolves a prefix and a full SHA to the full commit SHA', (t) => {
  const repo = tempRepo(t);
  const sha = commitFiles(repo, { 'a.txt': 'a\n' }, 'add a');
  const { status, json } = runWfx(['rev-parse', '--repo', repo, sha.slice(0, 12), sha], { cwd: repo });
  assert.equal(status, 0);
  assert.equal(json.data.shas[sha.slice(0, 12)], sha);
  assert.equal(json.data.shas[sha], sha);
});

test('defaults --repo to the cwd', (t) => {
  const repo = tempRepo(t);
  const sha = commitFiles(repo, { 'a.txt': 'a\n' }, 'add a');
  const { json } = runWfx(['rev-parse', sha.slice(0, 9)], { cwd: repo });
  assert.equal(json.data.shas[sha.slice(0, 9)], sha);
});

test('unknown prefix exits 1 with reason unknown (AC-17)', (t) => {
  const repo = tempRepo(t);
  const { status, json } = runWfx(['rev-parse', '--repo', repo, 'ffffffff'], { cwd: repo });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'unresolved');
  assert.equal(json.error.details.prefixes.ffffffff.reason, 'unknown');
});

test('ambiguous prefix exits 1 with reason ambiguous (AC-17)', (t) => {
  const repo = tempRepo(t);
  // One fast-import run makes thousands of commits, so a 4-hex collision is near certain.
  const stream = [];
  for (let i = 0; i < 4000; i++) {
    stream.push('commit refs/heads/many', `committer T <t@example.invalid> ${1700000000 + i} +0000`, 'data 1', 'x');
    if (i === 0) stream.push('from refs/heads/main');
    stream.push('');
  }
  const imp = spawnSync('git', ['fast-import', '--quiet'], { cwd: repo, input: `${stream.join('\n')}\n`, encoding: 'utf8' });
  assert.equal(imp.status, 0, imp.stderr);
  const shas = spawnSync('git', ['rev-list', 'many'], { cwd: repo, encoding: 'utf8' }).stdout.split('\n').filter(Boolean);
  const seen = new Set();
  let prefix = null;
  for (const sha of shas) {
    const key = sha.slice(0, 4);
    if (seen.has(key)) {
      prefix = key;
      break;
    }
    seen.add(key);
  }
  assert.ok(prefix, 'no 4-hex collision found in 4000 commits');
  const { status, json } = runWfx(['rev-parse', '--repo', repo, prefix], { cwd: repo });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'unresolved');
  assert.equal(json.error.details.prefixes[prefix].reason, 'ambiguous');
});

test('mixed input reports only the failing prefixes', (t) => {
  const repo = tempRepo(t);
  const sha = commitFiles(repo, { 'a.txt': 'a\n' }, 'add a');
  const { json } = runWfx(['rev-parse', '--repo', repo, sha.slice(0, 10), 'ffffffff'], { cwd: repo });
  assert.deepEqual(Object.keys(json.error.details.prefixes), ['ffffffff']);
});

test('no prefix is bad input', (t) => {
  const repo = tempRepo(t);
  const { status, json } = runWfx(['rev-parse'], { cwd: repo });
  assert.equal(status, 2);
  assert.equal(json.error.code, 'bad-input');
});
