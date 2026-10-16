import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { WFX, runWfx, tempDir, tempRepo } from './fx-kit.mjs';

function headSha(repo) {
  return spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).stdout.trim();
}

test('unknown command exits 2 with a bad-input envelope', () => {
  const { status, json } = runWfx(['nope']);
  assert.equal(status, 2);
  assert.equal(json.ok, false);
  assert.equal(json.cmd, 'nope');
  assert.equal(json.error.code, 'bad-input');
});

test('invalid command name exits 2', () => {
  const { status, json } = runWfx(['../x']);
  assert.equal(status, 2);
  assert.equal(json.error.code, 'bad-input');
});

test('missing command exits 2', () => {
  const { status, json } = runWfx([]);
  assert.equal(status, 2);
  assert.equal(json.error.code, 'bad-input');
});

test('unknown flag exits 2 and names the flag on stderr', (t) => {
  const repo = tempRepo(t);
  const { status, json, stderr } = runWfx(['rev-parse', '--bogus', 'abcd'], { cwd: repo });
  assert.equal(status, 2);
  assert.equal(json.error.code, 'bad-input');
  assert.match(stderr, /unknown flag --bogus/);
});

test('success exits 0 with an ok envelope', (t) => {
  const repo = tempRepo(t);
  const full = headSha(repo);
  const { status, json } = runWfx(['rev-parse', full.slice(0, 10)], { cwd: repo });
  assert.equal(status, 0);
  assert.equal(json.ok, true);
  assert.equal(json.cmd, 'rev-parse');
});

test('operation failure exits 1 with a failure envelope', (t) => {
  const repo = tempRepo(t);
  const { status, json } = runWfx(['rev-parse', 'deadbeef'], { cwd: repo });
  assert.equal(status, 1);
  assert.equal(json.ok, false);
  assert.equal(json.error.code, 'unresolved');
});

test('runs from a temp cwd outside the repo (AC-10)', (t) => {
  const cwd = tempDir(t);
  const repo = tempRepo(t);
  const full = headSha(repo);
  const prefix = full.slice(0, 8);
  const { status, json } = runWfx(['rev-parse', '--repo', repo, prefix], { cwd });
  assert.equal(status, 0);
  assert.deepEqual(json, { ok: true, cmd: 'rev-parse', data: { shas: { [prefix]: full } } });
});

test('runs through a symlink from another cwd', (t) => {
  const cwd = tempDir(t);
  const link = join(tempDir(t), 'wfx-link');
  symlinkSync(WFX, link);
  const repo = tempRepo(t);
  const full = headSha(repo);
  const res = spawnSync(link, ['rev-parse', '--repo', repo, full.slice(0, 8)], { cwd, encoding: 'utf8' });
  assert.equal(res.status, 0);
  assert.equal(JSON.parse(res.stdout).ok, true);
});

test('a non-repo path gives an exit 1 envelope, not a stack trace', (t) => {
  const cwd = tempDir(t);
  const { status, json, stdout } = runWfx(['rev-parse', '--repo', join(cwd, 'missing'), 'abcdef'], { cwd });
  assert.equal(status, 1);
  assert.equal(json.ok, false);
  assert.doesNotMatch(stdout, /\n\s+at /);
});
